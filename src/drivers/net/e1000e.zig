// Intel E1000e (82574L) Network Driver
//
// Implements a driver for the Intel 82574L Gigabit Ethernet Controller.
// Uses MMIO for register access and legacy descriptors for RX/TX.
//
// Architecture follows Linux kernel's drivers/net/ethernet/intel/e1000e/netdev.c
// with adaptations for Zig and this kernel's threading model.
//
// Features:
//   - Receive and transmit packet handling with ring buffers
//   - NAPI-style interrupt coalescing and polling
//   - Hardware checksum offloading (IP, TCP, UDP)
//   - MSI-X interrupt support (falls back to legacy INTx)
//   - TX watchdog for stuck transmit detection
//
// Ring Buffer Model:
//   Both RX and TX use circular descriptor rings. Each descriptor is 16 bytes
//   and points to a packet buffer. Hardware and software coordinate via HEAD
//   and TAIL pointers:
//
//   RX: Hardware writes packets, software reads them
//       HEAD = hardware's next write position (hardware advances after write)
//       TAIL = software's release pointer (one beyond last valid for hardware)
//       Available = (TAIL - HEAD + N) mod N
//
//   TX: Software writes packets, hardware transmits them
//       HEAD = hardware's next read position (hardware advances after transmit)
//       TAIL = software's submit pointer (one beyond last packet to send)
//       Pending = (TAIL - HEAD + N) mod N
//
// Memory Barriers:
//   - readBarrier() (lfence): Used after checking descriptor status before
//     reading data. Ensures we see hardware's writes to all descriptor fields.
//   - writeBarrier() (sfence): Used after writing descriptor contents before
//     updating TAIL. Ensures hardware sees our writes before the pointer update.
//
// References:
//   - Intel 82574L Gigabit Ethernet Controller Datasheet (316080)
//   - Linux kernel: drivers/net/ethernet/intel/e1000e/
//   - OSDev Wiki: Intel Ethernet i217

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const sync = @import("sync");
const console = @import("console");
const thread = @import("thread");
const sched = @import("sched");
const heap = @import("heap");
const net = @import("net");

const mmio = hal.mmio;

// ============================================================================
// E1000e Register Definitions (MMIO offsets)
// ============================================================================

const Reg = struct {
    // Device Control
    pub const CTRL: u64 = 0x0000;       // Device Control
    pub const STATUS: u64 = 0x0008;     // Device Status
    pub const CTRL_EXT: u64 = 0x0018;   // Extended Device Control

    // EEPROM
    pub const EERD: u64 = 0x0014;       // EEPROM Read

    // Interrupt
    pub const ICR: u64 = 0x00C0;        // Interrupt Cause Read
    pub const ITR: u64 = 0x00C4;        // Interrupt Throttle Rate
    pub const ICS: u64 = 0x00C8;        // Interrupt Cause Set
    pub const IMS: u64 = 0x00D0;        // Interrupt Mask Set
    pub const IMC: u64 = 0x00D8;        // Interrupt Mask Clear

    // Receive
    pub const RCTL: u64 = 0x0100;       // Receive Control
    pub const RDBAL: u64 = 0x2800;      // RX Descriptor Base Low
    pub const RDBAH: u64 = 0x2804;      // RX Descriptor Base High
    pub const RDLEN: u64 = 0x2808;      // RX Descriptor Length
    pub const RDH: u64 = 0x2810;        // RX Descriptor Head
    pub const RDT: u64 = 0x2818;        // RX Descriptor Tail
    pub const RDTR: u64 = 0x2820;       // RX Delay Timer
    pub const RADV: u64 = 0x282C;       // RX Interrupt Absolute Delay

    // Receive Checksum Control
    pub const RXCSUM: u64 = 0x5000;     // Receive Checksum Control

    // Transmit
    pub const TCTL: u64 = 0x0400;       // Transmit Control
    pub const TIPG: u64 = 0x0410;       // TX Inter-Packet Gap
    pub const TDBAL: u64 = 0x3800;      // TX Descriptor Base Low
    pub const TDBAH: u64 = 0x3804;      // TX Descriptor Base High
    pub const TDLEN: u64 = 0x3808;      // TX Descriptor Length
    pub const TDH: u64 = 0x3810;        // TX Descriptor Head
    pub const TDT: u64 = 0x3818;        // TX Descriptor Tail
    pub const TXDCTL: u64 = 0x3828;     // TX Descriptor Control
    pub const TADV: u64 = 0x382C;       // TX Interrupt Absolute Delay

    // Statistics
    pub const MPC: u64 = 0x4010;        // Missed Packets Count (cleared on read)

    // Receive Address (MAC)
    pub const RAL0: u64 = 0x5400;       // Receive Address Low (MAC bytes 0-3)
    pub const RAH0: u64 = 0x5404;       // Receive Address High (MAC bytes 4-5)

    // Multicast Table Array
    pub const MTA_BASE: u64 = 0x5200;   // Multicast Table Array (128 entries)

    // MSI-X Registers (82574L specific)
    pub const IVAR: u64 = 0x00E4;        // Interrupt Vector Allocation
    pub const EITR0: u64 = 0x00E8;       // Extended Interrupt Throttle Rate 0
    pub const EITR1: u64 = 0x00EC;       // Extended Interrupt Throttle Rate 1
    pub const EITR2: u64 = 0x00F0;       // Extended Interrupt Throttle Rate 2
    pub const EIAC: u64 = 0x00DC;        // Extended Interrupt Auto Clear
    pub const EIAM: u64 = 0x00E0;        // Extended Interrupt Auto Mask
    pub const EICS: u64 = 0x00E8;        // Extended Interrupt Cause Set
    pub const EIMS: u64 = 0x00D4;        // Extended Interrupt Mask Set (read-only set)
    pub const EIMC: u64 = 0x00D8;        // Extended Interrupt Mask Clear (write-only clear)
};

/// Device Control Register (CTRL) bit layout
/// Reference: 82574L Datasheet Section 13.4.1
pub const DeviceCtl = packed struct(u32) {
    full_duplex: bool = false,           // Bit 0: FD
    _reserved_1_2: u2 = 0,               // Bits 1-2: Reserved
    link_reset: bool = false,            // Bit 3: LRST
    _reserved_4: bool = false,           // Bit 4: Reserved
    auto_speed_detect: bool = false,     // Bit 5: ASDE
    set_link_up: bool = false,           // Bit 6: SLU
    invert_loss_of_signal: bool = false, // Bit 7: ILOS
    speed_selection: u2 = 0,             // Bits 8-9: Speed selection
    _reserved_10: bool = false,          // Bit 10: Reserved
    force_speed: bool = false,           // Bit 11: Force Speed
    force_duplex: bool = false,          // Bit 12: Force Duplex
    _reserved_13_17: u5 = 0,             // Bits 13-17: Reserved
    sdp0_data: bool = false,             // Bit 18: SDP0 Data
    sdp1_data: bool = false,             // Bit 19: SDP1 Data
    sdp0_iodir: bool = false,            // Bit 20: SDP0 I/O Direction
    sdp1_iodir: bool = false,            // Bit 21: SDP1 I/O Direction
    _reserved_22_25: u4 = 0,             // Bits 22-25: Reserved
    device_reset: bool = false,          // Bit 26: RST
    rx_flow_control: bool = false,       // Bit 27: RFCE
    tx_flow_control: bool = false,       // Bit 28: TFCE
    _reserved_29: bool = false,          // Bit 29: Reserved
    vlan_mode: bool = false,             // Bit 30: VME
    phy_reset: bool = false,             // Bit 31: PHY_RST

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("DeviceCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) DeviceCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: DeviceCtl) u32 {
        return @bitCast(self);
    }
};

// Device Status Register bits
// Reference: 82574L Datasheet Section 13.4.2
const STATUS = struct {
    pub const FD: u32 = 1 << 0;         // Full Duplex indication
    pub const LU: u32 = 1 << 1;         // Link Up indication
    pub const SPEED_SHIFT: u5 = 6;      // Speed bits [7:6]
    pub const SPEED_MASK: u32 = 0b11 << 6;
    // Speed values: 00=10Mb/s, 01=100Mb/s, 10=1000Mb/s, 11=reserved
};

/// Receive Control Register (RCTL) bit layout
/// Reference: 82574L Datasheet Section 13.4.22
pub const ReceiveCtl = packed struct(u32) {
    _reserved_0: bool = false,           // Bit 0: Reserved
    enable: bool = false,                // Bit 1: EN - Receiver Enable
    store_bad_packets: bool = false,     // Bit 2: SBP - Store Bad Packets
    unicast_promisc: bool = false,       // Bit 3: UPE - Unicast Promiscuous
    multicast_promisc: bool = false,     // Bit 4: MPE - Multicast Promiscuous
    long_packet: bool = false,           // Bit 5: LPE - Long Packet Enable
    loopback_mode: u2 = 0,               // Bits 6-7: LBM - Loopback Mode
    rdmts: u2 = 0,                       // Bits 8-9: RDMTS - RX Desc Min Threshold
    _reserved_10_11: u2 = 0,             // Bits 10-11: Reserved
    multicast_offset: u2 = 0,            // Bits 12-13: MO - Multicast Offset
    _reserved_14: bool = false,          // Bit 14: Reserved
    broadcast_accept: bool = false,      // Bit 15: BAM - Broadcast Accept Mode
    buffer_size: u2 = 0,                 // Bits 16-17: BSIZE - Buffer Size
    vlan_filter: bool = false,           // Bit 18: VFE - VLAN Filter Enable
    cfien: bool = false,                 // Bit 19: CFIEN - CFI Enable
    cfi: bool = false,                   // Bit 20: CFI - Canonical Form Indicator
    _reserved_21_22: u2 = 0,             // Bits 21-22: Reserved
    dpf: bool = false,                   // Bit 23: DPF - Discard Pause Frames
    pmcf: bool = false,                  // Bit 24: PMCF - Pass MAC Control Frames
    _reserved_25: bool = false,          // Bit 25: Reserved
    strip_crc: bool = false,             // Bit 26: SECRC - Strip Ethernet CRC
    _reserved_27_31: u5 = 0,             // Bits 27-31: Reserved

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("ReceiveCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) ReceiveCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: ReceiveCtl) u32 {
        return @bitCast(self);
    }

    /// Buffer size in bytes based on BSIZE field
    pub fn getBufferSize(self: ReceiveCtl) u16 {
        return switch (self.buffer_size) {
            0 => 2048,
            1 => 1024,
            2 => 512,
            3 => 256,
        };
    }
};

// Receive Checksum Control bits
const RXCSUM = struct {
    pub const IPOFL: u32 = 1 << 8;      // IP Checksum Offload Enable
    pub const TUOFL: u32 = 1 << 9;      // TCP/UDP Checksum Offload Enable
};

/// Transmit Control Register (TCTL) bit layout
/// Reference: 82574L Datasheet Section 13.4.37
pub const TransmitCtl = packed struct(u32) {
    _reserved_0: bool = false,           // Bit 0: Reserved
    enable: bool = false,                // Bit 1: EN - Transmitter Enable
    _reserved_2: bool = false,           // Bit 2: Reserved
    pad_short_packets: bool = false,     // Bit 3: PSP - Pad Short Packets
    collision_threshold: u8 = 0,         // Bits 4-11: CT - Collision Threshold
    collision_distance: u10 = 0,         // Bits 12-21: COLD - Collision Distance
    swxoff: bool = false,                // Bit 22: SWXOFF - Software XOFF
    _reserved_23: bool = false,          // Bit 23: Reserved
    retransmit_late_coll: bool = false,  // Bit 24: RTLC - Retransmit on Late Collision
    _reserved_25: bool = false,          // Bit 25: Reserved
    unortx: bool = false,                // Bit 26: UNORTX - Underrun No Retransmit
    _reserved_27_31: u5 = 0,             // Bits 27-31: Reserved

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("TransmitCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) TransmitCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: TransmitCtl) u32 {
        return @bitCast(self);
    }
};

// Interrupt bits (legacy constants for backward compatibility)
const INT = struct {
    pub const TXDW: u32 = 1 << 0;       // TX Descriptor Written Back
    pub const TXQE: u32 = 1 << 1;       // TX Queue Empty
    pub const LSC: u32 = 1 << 2;        // Link Status Change
    pub const RXSEQ: u32 = 1 << 3;      // RX Sequence Error
    pub const RXDMT0: u32 = 1 << 4;     // RX Descriptor Min Threshold
    pub const RXO: u32 = 1 << 6;        // RX Overrun
    pub const RXT0: u32 = 1 << 7;       // RX Timer Interrupt
};

/// Interrupt Cause Register (ICR) bit layout
/// Reference: 82574L Datasheet Section 13.4.17
/// Type-safe packed struct for cleaner interrupt handling
pub const InterruptCause = packed struct(u32) {
    tx_desc_written: bool = false,      // Bit 0: TXDW
    tx_queue_empty: bool = false,       // Bit 1: TXQE
    link_status_change: bool = false,   // Bit 2: LSC
    rx_seq_error: bool = false,         // Bit 3: RXSEQ
    rx_desc_min_threshold: bool = false, // Bit 4: RXDMT0
    _reserved_5: bool = false,          // Bit 5: reserved
    rx_overrun: bool = false,           // Bit 6: RXO
    rx_timer: bool = false,             // Bit 7: RXT0
    _reserved_8_31: u24 = 0,            // Bits 8-31: reserved/other causes

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("InterruptCause must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) InterruptCause {
        return @bitCast(raw);
    }

    pub fn toRaw(self: InterruptCause) u32 {
        return @bitCast(self);
    }

    /// Check if any RX interrupt is pending
    pub fn hasRxInterrupt(self: InterruptCause) bool {
        return self.rx_timer or self.rx_desc_min_threshold;
    }
};

// ============================================================================
// Descriptor Structures
// ============================================================================

/// Legacy RX Descriptor (16 bytes)
/// Reference: 82574L Datasheet Section 3.2.3
pub const RxDesc = extern struct {
    buffer_addr: u64,       // Physical address of receive buffer
    length: u16,            // Received packet length
    checksum: u16,          // Packet checksum
    status: u8,             // Status bits
    errors: u8,             // Error bits
    special: u16,           // VLAN tag

    pub const STATUS_DD: u8 = 1 << 0;   // Descriptor Done
    pub const STATUS_EOP: u8 = 1 << 1;  // End of Packet

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("RxDesc must be 16 bytes");
    }
};

/// RX Descriptor Error bits
/// Reference: 82574L Datasheet Section 3.2.3.2
const RXERR = struct {
    pub const CE: u8 = 1 << 0;     // CRC Error or Alignment Error
    pub const SE: u8 = 1 << 1;     // Symbol Error (invalid symbol)
    pub const SEQ: u8 = 1 << 2;    // Sequence Error
    pub const RSV: u8 = 1 << 3;    // Reserved
    pub const CXE: u8 = 1 << 4;    // Carrier Extension Error
    pub const TCPE: u8 = 1 << 5;   // TCP/UDP Checksum Error
    pub const IPE: u8 = 1 << 6;    // IP Checksum Error
    pub const RXE: u8 = 1 << 7;    // RX Data Error (FIFO overrun)
};

/// Legacy TX Descriptor (16 bytes)
/// Reference: 82574L Datasheet Section 3.3.3
pub const TxDesc = extern struct {
    buffer_addr: u64,       // Physical address of transmit buffer
    length: u16,            // Packet length
    cso: u8,                // Checksum Offset
    cmd: u8,                // Command bits
    status: u8,             // Status bits
    css: u8,                // Checksum Start
    special: u16,           // VLAN tag

    pub const CMD_EOP: u8 = 1 << 0;     // End of Packet
    pub const CMD_IFCS: u8 = 1 << 1;    // Insert FCS/CRC
    pub const CMD_IC: u8 = 1 << 2;      // Insert Checksum
    pub const CMD_RS: u8 = 1 << 3;      // Report Status
    pub const STATUS_DD: u8 = 1 << 0;   // Descriptor Done

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("TxDesc must be 16 bytes");
    }
};

// ============================================================================
// Driver Configuration
// ============================================================================

/// Number of RX descriptors (must be multiple of 8)
pub const RX_DESC_COUNT: usize = 512;
/// Number of TX descriptors (must be multiple of 8)
pub const TX_DESC_COUNT: usize = 512;
/// Size of each packet buffer
pub const BUFFER_SIZE: usize = 2048;

// Compile-time validation of configuration constants
// These ensure driver correctness at compile time rather than runtime
comptime {
    // Intel 82574L requires descriptor counts to be multiples of 8
    // Reference: Datasheet Section 3.2.6 and 3.3.6
    if (RX_DESC_COUNT % 8 != 0) {
        @compileError("RX_DESC_COUNT must be a multiple of 8");
    }
    if (TX_DESC_COUNT % 8 != 0) {
        @compileError("TX_DESC_COUNT must be a multiple of 8");
    }

    // Descriptor indices (rx_cur, tx_cur) are u16, so counts must fit
    if (RX_DESC_COUNT > 65535) {
        @compileError("RX_DESC_COUNT exceeds u16 range");
    }
    if (TX_DESC_COUNT > 65535) {
        @compileError("TX_DESC_COUNT exceeds u16 range");
    }

    // Buffer size must match RCTL.BSIZE setting (0 = 2048 bytes)
    // and not exceed page size for simple PMM allocation
    if (BUFFER_SIZE != 2048) {
        @compileError("BUFFER_SIZE must be 2048 to match RCTL.BSIZE=0");
    }

    // Buffer size must not exceed page size to ensure single-page allocation
    // in allocateRings() does not overflow. Hardware-provided packet length
    // is clamped to BUFFER_SIZE, so this bounds the trust boundary.
    if (BUFFER_SIZE > pmm.PAGE_SIZE) {
        @compileError("BUFFER_SIZE must not exceed PAGE_SIZE for single-page allocation");
    }
}

// ============================================================================
// Packet Buffer Pool
// ============================================================================

/// Pool size: 2x descriptor count for double-buffering headroom
pub const PACKET_POOL_SIZE: usize = 1024;

/// Pre-allocated packet buffer pool for RX processing.
/// Eliminates heap allocation under spinlock in processRxLimited().
///
/// Benefits:
/// - No nested spinlock acquisition (heap has its own lock)
/// - Bounded allocation latency (O(n) worst case, typically O(1))
/// - No OOM during packet processing
/// - No heap fragmentation from packet-sized allocations
///
/// Callers MUST release buffers back to the pool after processing.
pub const PacketPool = struct {
    /// Pre-allocated packet buffers
    /// Each buffer is BUFFER_SIZE bytes (2048), total ~2MB for 1024 buffers
    buffers: [PACKET_POOL_SIZE][BUFFER_SIZE]u8 = undefined,

    /// Bitmap tracking which buffers are allocated
    allocated: [PACKET_POOL_SIZE]bool = [_]bool{false} ** PACKET_POOL_SIZE,

    /// Hint for O(1) allocation: first index that might be free
    free_head: usize = 0,

    /// Count of free buffers (for debugging/stats)
    free_count: usize = PACKET_POOL_SIZE,

    /// Lock for thread-safe access
    lock: sync.Spinlock = .{},

    const Self = @This();

    /// Acquire a buffer from the pool.
    /// Returns null if pool is exhausted (backpressure signal).
    /// Caller MUST call release() when done with the buffer.
    pub fn acquire(self: *Self) ?[]u8 {
        const held = self.lock.acquire();
        defer held.release();

        if (self.free_count == 0) return null;

        // Linear search from free_head hint
        var i = self.free_head;
        while (i < PACKET_POOL_SIZE) : (i += 1) {
            if (!self.allocated[i]) {
                self.allocated[i] = true;
                self.free_count -= 1;
                // Advance hint past this allocation
                self.free_head = i + 1;
                return &self.buffers[i];
            }
        }

        // Wrap around if we started mid-pool
        i = 0;
        while (i < self.free_head) : (i += 1) {
            if (!self.allocated[i]) {
                self.allocated[i] = true;
                self.free_count -= 1;
                self.free_head = i + 1;
                return &self.buffers[i];
            }
        }

        return null;
    }

    /// Return a buffer to the pool.
    /// Safe to call with slices shorter than BUFFER_SIZE (only pointer is checked).
    pub fn release(self: *Self, buf: []u8) void {
        const held = self.lock.acquire();
        defer held.release();

        // Calculate index from pointer arithmetic
        const base = @intFromPtr(&self.buffers[0]);
        const ptr = @intFromPtr(buf.ptr);

        // Validate pointer is within our buffer range
        if (ptr < base) return;
        const offset = ptr - base;
        const idx = offset / BUFFER_SIZE;

        // Validate index and that it was actually allocated
        if (idx >= PACKET_POOL_SIZE) return;
        if (!self.allocated[idx]) return; // Double-free protection

        self.allocated[idx] = false;
        self.free_count += 1;

        // Reset hint if this buffer is before current hint
        if (idx < self.free_head) {
            self.free_head = idx;
        }
    }

    /// Get current pool statistics
    pub fn getStats(self: *Self) struct { free: usize, used: usize } {
        const held = self.lock.acquire();
        defer held.release();
        return .{
            .free = self.free_count,
            .used = PACKET_POOL_SIZE - self.free_count,
        };
    }
};

/// Global packet pool instance for RX buffer allocation
pub var packet_pool: PacketPool = .{};

// ============================================================================
// Driver State
// ============================================================================

/// E1000e driver instance
pub const E1000e = struct {
    /// MMIO base virtual address
    mmio_base: u64,
    /// MMIO region size (used for bounds checking)
    mmio_size: usize,

    /// MAC address
    mac_addr: [6]u8,

    /// RX descriptor ring (volatile: hardware modifies status fields)
    rx_ring: [*]volatile RxDesc,
    rx_ring_phys: u64,

    /// TX descriptor ring (volatile: hardware modifies status fields)
    tx_ring: [*]volatile TxDesc,
    tx_ring_phys: u64,

    /// RX packet buffers (one per descriptor)
    rx_buffers: [RX_DESC_COUNT][*]u8,
    rx_buffers_phys: [RX_DESC_COUNT]u64,

    /// TX packet buffers (one per descriptor)
    tx_buffers: [TX_DESC_COUNT][*]u8,
    tx_buffers_phys: [TX_DESC_COUNT]u64,

    /// Current RX descriptor index
    rx_cur: u16,

    /// Current TX descriptor index
    tx_cur: u16,

    /// IRQ line for this device
    irq_line: u8,

    /// Lock for thread-safe access to driver state
    lock: sync.Spinlock,

    /// Statistics (protected by lock)
    rx_packets: u64,
    tx_packets: u64,
    rx_bytes: u64,
    tx_bytes: u64,
    /// Error counters
    rx_errors: u64,
    rx_crc_errors: u64,
    rx_dropped: u64,
    tx_dropped: u64,

    /// TX watchdog state
    tx_watchdog_last_tdh: u32,
    tx_watchdog_stall_count: u16,

    /// Worker thread for packet processing
    worker_thread: ?*thread.Thread,

    /// RX Packet Callback (from higher layers)
    /// Callback receives ownership of packet - MUST free via heap.allocator().free()
    rx_callback: ?*const fn ([]u8) void,

    /// Shutdown flag for clean worker thread termination
    /// Use @atomicLoad/@atomicStore for thread-safe access
    shutdown_requested: bool,

    /// MSI-X state
    msix_enabled: bool,
    msix_table_base: u64,
    /// MSI-X vectors: [0]=RX, [1]=TX, [2]=Other
    msix_vectors: [3]u8,

    /// PCI device reference (for MSI-X configuration)
    pci_dev: *const pci.PciDevice,
    pci_ecam: *const pci.Ecam,

    const Self = @This();

    // ========================================================================
    // Register Access
    // ========================================================================

    /// Read a 32-bit device register with bounds checking
    /// Panics if offset is outside mapped MMIO region (indicates driver bug)
    fn readReg(self: *const Self, offset: u64) u32 {
        if (offset + 4 > self.mmio_size) {
            @panic("E1000e: MMIO read out of bounds");
        }
        return mmio.read32(self.mmio_base + offset);
    }

    /// Write a 32-bit device register with bounds checking
    /// Panics if offset is outside mapped MMIO region (indicates driver bug)
    fn writeReg(self: *Self, offset: u64, value: u32) void {
        if (offset + 4 > self.mmio_size) {
            @panic("E1000e: MMIO write out of bounds");
        }
        mmio.write32(self.mmio_base + offset, value);
    }

    // Typed register accessors for packed structs
    fn readCtrl(self: *const Self) DeviceCtl {
        return DeviceCtl.fromRaw(self.readReg(Reg.CTRL));
    }

    fn writeCtrl(self: *Self, ctrl: DeviceCtl) void {
        self.writeReg(Reg.CTRL, ctrl.toRaw());
    }

    fn readRctl(self: *const Self) ReceiveCtl {
        return ReceiveCtl.fromRaw(self.readReg(Reg.RCTL));
    }

    fn writeRctl(self: *Self, rctl: ReceiveCtl) void {
        self.writeReg(Reg.RCTL, rctl.toRaw());
    }

    fn readTctl(self: *const Self) TransmitCtl {
        return TransmitCtl.fromRaw(self.readReg(Reg.TCTL));
    }

    fn writeTctl(self: *Self, tctl: TransmitCtl) void {
        self.writeReg(Reg.TCTL, tctl.toRaw());
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize E1000e driver for a PCI device
    ///
    /// SAFETY: This function must not be called while the driver is already
    /// initialized. Call deinit() first if re-initialization is needed.
    pub fn init(pci_dev: *const pci.PciDevice, pci_ecam: *const pci.Ecam) !*Self {
        // Guard against double-init without deinit
        // This prevents use-after-free and double-free bugs from concurrent
        // or repeated init calls.
        if (@atomicLoad(bool, &driver_initialized, .acquire)) {
            console.err("E1000e: Driver already initialized - call deinit() first", .{});
            return error.AlreadyInitialized;
        }

        console.info("E1000e: Initializing {x:0>4}:{x:0>4}", .{
            pci_dev.vendor_id,
            pci_dev.device_id,
        });

        // Get MMIO BAR
        const bar = pci_dev.getMmioBar() orelse {
            console.err("E1000e: No MMIO BAR found", .{});
            return error.NoMmioBar;
        };

        console.info("E1000e: BAR0 at phys=0x{x:0>16} size={d}KB", .{
            bar.base,
            bar.size / 1024,
        });

        // Enable bus mastering and memory space
        pci_ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        pci_ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Map MMIO region
        const mmio_base = vmm.mapMmio(bar.base, bar.size) catch |err| {
            console.err("E1000e: Failed to map MMIO: {}", .{err});
            return error.MmioMapFailed;
        };

        // Allocate driver state (using static for now, should use heap)
        const driver = &driver_instance;

        // Cleanup previous allocations if any (prevents memory leak on re-init)
        if (driver.rx_ring_phys != 0 or driver.tx_ring_phys != 0) {
            console.warn("E1000e: Cleaning up previous allocations before re-init", .{});
            driver.freeRings();
        }

        driver.* = Self{
            .mmio_base = mmio_base,
            .mmio_size = bar.size,
            .mac_addr = [_]u8{0} ** 6,
            // Ring pointers set by allocateRings() - undefined until then
            // We check rx_ring_phys != 0 before any access
            .rx_ring = undefined,
            .rx_ring_phys = 0,
            .tx_ring = undefined,
            .tx_ring_phys = 0,
            // Buffer pointer arrays populated by allocateRings()
            // Cannot zero-init [*]u8 pointers in Zig, but _phys arrays track validity
            .rx_buffers = undefined,
            .rx_buffers_phys = [_]u64{0} ** RX_DESC_COUNT,
            .tx_buffers = undefined,
            .tx_buffers_phys = [_]u64{0} ** TX_DESC_COUNT,
            .rx_cur = 0,
            .tx_cur = 0,
            .irq_line = pci_dev.irq_line,
            .lock = sync.Spinlock{},
            .rx_packets = 0,
            .tx_packets = 0,
            .rx_bytes = 0,
            .tx_bytes = 0,
            .rx_errors = 0,
            .rx_crc_errors = 0,
            .rx_dropped = 0,
            .tx_dropped = 0,
            .tx_watchdog_last_tdh = 0,
            .tx_watchdog_stall_count = 0,
            .worker_thread = null,
            .rx_callback = null,
            .msix_enabled = false,
            .msix_table_base = 0,
            .msix_vectors = [_]u8{0} ** 3,
            .pci_dev = pci_dev,
            .pci_ecam = pci_ecam,
            .shutdown_requested = false,
        };

        // Reset device
        driver.reset();

        // Read MAC address
        driver.readMacAddress();
        console.info("E1000e: MAC address {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            driver.mac_addr[0],
            driver.mac_addr[1],
            driver.mac_addr[2],
            driver.mac_addr[3],
            driver.mac_addr[4],
            driver.mac_addr[5],
        });

        // Allocate descriptor rings and buffers
        try driver.allocateRings();
        errdefer driver.freeRings(); // Cleanup if subsequent init steps fail

        // Initialize RX
        driver.initRx();

        // Initialize TX
        driver.initTx();

        // Clear multicast table
        driver.clearMulticastTable();

        // Try to enable MSI-X (falls back to legacy if not available)
        driver.initMsix();

        // Enable interrupts (uses MSI-X or legacy based on initMsix result)
        driver.enableInterrupts();

        // Mark driver as initialized BEFORE creating worker thread
        // to prevent race condition where worker runs before flag is set
        @atomicStore(bool, &driver_initialized, true, .release);

        // Create worker thread
        // Pass workerEntry directly (it is now compatible callconv(.c)) and the driver instance as context
        driver.worker_thread = try thread.createKernelThread(workerEntry, driver, .{
            .name = "net_worker",
            .priority = 10, // High priority
        });
        sched.addThread(driver.worker_thread.?);

        // Enable RX and TX
        driver.enableRxTx();

        console.info("E1000e: Initialization complete", .{});
        return driver;
    }

    /// Reset the device
    fn reset(self: *Self) void {
        console.info("E1000e: Resetting device...", .{});

        // Set the reset bit
        self.writeCtrl(.{ .device_reset = true });

        // Wait for reset to complete (RST bit clears)
        // Reference: 82574L Datasheet Section 13.4.1 - reset completes when RST bit clears
        // 100ms timeout is generous for reset operation
        const reset_mask = (DeviceCtl{ .device_reset = true }).toRaw();
        if (!mmio.poll32Timed(self.mmio_base + Reg.CTRL, reset_mask, 0, 100_000)) {
            console.warn("E1000e: Reset timeout (RST bit stuck)", .{});
        }

        // Disable interrupts during setup
        self.writeReg(Reg.IMC, 0xFFFFFFFF);

        // Read ICR to clear pending interrupts
        _ = self.readReg(Reg.ICR);

        console.info("E1000e: Reset complete", .{});
    }

    /// Read MAC address from RAL/RAH registers
    fn readMacAddress(self: *Self) void {
        const ral = self.readReg(Reg.RAL0);
        const rah = self.readReg(Reg.RAH0);

        self.mac_addr[0] = @truncate(ral);
        self.mac_addr[1] = @truncate(ral >> 8);
        self.mac_addr[2] = @truncate(ral >> 16);
        self.mac_addr[3] = @truncate(ral >> 24);
        self.mac_addr[4] = @truncate(rah);
        self.mac_addr[5] = @truncate(rah >> 8);
    }

    /// Allocate descriptor rings and packet buffers
    /// Uses errdefer to clean up previously allocated pages on failure
    fn allocateRings(self: *Self) !void {
        // Calculate number of pages needed for rings
        // 512 descriptors * 16 bytes = 8192 bytes (2 pages)
        const rx_ring_size = RX_DESC_COUNT * @sizeOf(RxDesc);
        const rx_ring_pages = (rx_ring_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

        // Allocate RX descriptor ring (must be physically contiguous)
        const rx_ring_phys = pmm.allocZeroedPages(rx_ring_pages) orelse {
            return error.OutOfMemory;
        };
        errdefer pmm.freePages(rx_ring_phys, rx_ring_pages);

        self.rx_ring_phys = rx_ring_phys;
        // Cast to volatile pointer - hardware modifies descriptor status fields
        self.rx_ring = @ptrCast(@volatileCast(@as([*]RxDesc, @ptrCast(@alignCast(hal.paging.physToVirt(rx_ring_phys))))));

        // Calculate number of pages needed for TX ring
        const tx_ring_size = TX_DESC_COUNT * @sizeOf(TxDesc);
        const tx_ring_pages = (tx_ring_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

        // Allocate TX descriptor ring
        const tx_ring_phys = pmm.allocZeroedPages(tx_ring_pages) orelse {
            return error.OutOfMemory;
        };
        errdefer pmm.freePages(tx_ring_phys, tx_ring_pages);

        self.tx_ring_phys = tx_ring_phys;
        // Cast to volatile pointer - hardware modifies descriptor status fields
        self.tx_ring = @ptrCast(@volatileCast(@as([*]TxDesc, @ptrCast(@alignCast(hal.paging.physToVirt(tx_ring_phys))))));

        // Allocate RX packet buffers with cleanup tracking
        var rx_buffers_allocated: usize = 0;
        errdefer {
            for (0..rx_buffers_allocated) |i| {
                pmm.freePage(self.rx_buffers_phys[i]);
            }
        }

        for (0..RX_DESC_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse {
                return error.OutOfMemory;
            };
            self.rx_buffers_phys[i] = buf_phys;
            self.rx_buffers[i] = hal.paging.physToVirt(buf_phys);
            rx_buffers_allocated += 1;
        }

        // Allocate TX packet buffers with cleanup tracking
        var tx_buffers_allocated: usize = 0;
        errdefer {
            for (0..tx_buffers_allocated) |i| {
                pmm.freePage(self.tx_buffers_phys[i]);
            }
        }

        for (0..TX_DESC_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse {
                return error.OutOfMemory;
            };
            self.tx_buffers_phys[i] = buf_phys;
            self.tx_buffers[i] = hal.paging.physToVirt(buf_phys);
            tx_buffers_allocated += 1;
        }

        console.info("E1000e: Allocated {d} RX and {d} TX descriptors", .{
            RX_DESC_COUNT,
            TX_DESC_COUNT,
        });
    }

    /// Free descriptor rings and packet buffers (lightweight cleanup without device reset)
    /// Used for errdefer cleanup if init fails after allocateRings, or before re-initialization
    fn freeRings(self: *Self) void {
        // Free RX packet buffers
        for (0..RX_DESC_COUNT) |i| {
            if (self.rx_buffers_phys[i] != 0) {
                pmm.freePage(self.rx_buffers_phys[i]);
                self.rx_buffers_phys[i] = 0;
            }
        }

        // Free TX packet buffers
        for (0..TX_DESC_COUNT) |i| {
            if (self.tx_buffers_phys[i] != 0) {
                pmm.freePage(self.tx_buffers_phys[i]);
                self.tx_buffers_phys[i] = 0;
            }
        }

        // Free descriptor rings
        if (self.rx_ring_phys != 0) {
            const rx_ring_size = RX_DESC_COUNT * @sizeOf(RxDesc);
            const rx_ring_pages = (rx_ring_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
            pmm.freePages(self.rx_ring_phys, rx_ring_pages);
            self.rx_ring_phys = 0;
        }
        if (self.tx_ring_phys != 0) {
            const tx_ring_size = TX_DESC_COUNT * @sizeOf(TxDesc);
            const tx_ring_pages = (tx_ring_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
            pmm.freePages(self.tx_ring_phys, tx_ring_pages);
            self.tx_ring_phys = 0;
        }
    }

    /// Initialize RX subsystem
    ///
    /// Sets up the receive descriptor ring and configures hardware registers.
    /// This follows the Intel 82574L initialization sequence (Datasheet 14.5).
    ///
    /// Ring Buffer Model (matches Linux e1000e):
    /// - HEAD (RDH): Hardware's write position, advances after each receive
    /// - TAIL (RDT): Software's "release" pointer, one beyond last valid descriptor
    /// - Hardware writes to descriptors from HEAD to TAIL-1 (inclusive)
    /// - Available descriptors = (TAIL - HEAD + N) mod N (0 when HEAD == TAIL)
    ///
    /// Initial state: HEAD=0, TAIL=N-1
    /// - Hardware can write to descriptors 0 through N-2 (N-1 total)
    /// - Descriptor N-1 serves as the initial "stopper"
    fn initRx(self: *Self) void {
        // Initialize all RX descriptors with buffer addresses
        // Each descriptor points to a pre-allocated 4KB page for packet data
        for (0..RX_DESC_COUNT) |i| {
            self.rx_ring[i] = RxDesc{
                .buffer_addr = self.rx_buffers_phys[i],
                .length = 0, // Hardware will set actual length
                .checksum = 0, // Hardware will compute if offload enabled
                .status = 0, // DD=0 means descriptor is available
                .errors = 0,
                .special = 0, // VLAN tag, set by hardware
            };
        }

        // Program descriptor ring base address (64-bit physical address)
        // Must be 16-byte aligned per Intel spec
        self.writeReg(Reg.RDBAL, @truncate(self.rx_ring_phys));
        self.writeReg(Reg.RDBAH, @truncate(self.rx_ring_phys >> 32));

        // Set descriptor ring length in bytes (must be 128-byte aligned)
        // Hardware uses this to calculate ring wrap
        self.writeReg(Reg.RDLEN, RX_DESC_COUNT * @sizeOf(RxDesc));

        // Enable hardware checksum offloading
        // IPOFL: IP checksum offload - hardware verifies IPv4 header checksum
        // TUOFL: TCP/UDP checksum offload - hardware verifies L4 checksum
        // Results are reported in descriptor status/errors fields
        self.writeReg(Reg.RXCSUM, RXCSUM.IPOFL | RXCSUM.TUOFL);

        // Initialize head and tail pointers
        // HEAD = 0: hardware starts writing at descriptor 0
        // TAIL = N-1: hardware can use descriptors 0 to N-2, leaving N-1 as stopper
        //
        // Note: We could set TAIL = N (wrapped to 0) per strict Intel spec
        // interpretation, but TAIL = N-1 is the common convention that ensures
        // HEAD != TAIL initially (avoiding the ambiguous "empty" state).
        self.writeReg(Reg.RDH, 0);
        self.writeReg(Reg.RDT, RX_DESC_COUNT - 1);

        // Software read position starts at 0 (same as HEAD)
        self.rx_cur = 0;
    }

    /// Initialize TX subsystem
    ///
    /// Sets up the transmit descriptor ring and configures hardware registers.
    /// This follows the Intel 82574L initialization sequence (Datasheet 14.4).
    ///
    /// TX Ring Buffer Model (opposite of RX):
    /// - HEAD (TDH): Hardware's read position, advances after transmitting
    /// - TAIL (TDT): Software's "submit" pointer, one beyond last packet to send
    /// - Software writes packets to descriptors and advances TAIL
    /// - Hardware transmits from HEAD to TAIL-1, then advances HEAD
    /// - Available slots = N - ((TAIL - HEAD + N) mod N) - 1
    ///
    /// Initial state: HEAD=0, TAIL=0
    /// - Ring is empty (HEAD == TAIL)
    /// - All descriptors marked DD=1 (completed) so transmit() can use them
    fn initTx(self: *Self) void {
        // Initialize all TX descriptors as "completed" (DD=1)
        // This allows transmit() to immediately use any descriptor.
        // Each descriptor has a pre-allocated buffer for packet data.
        for (0..TX_DESC_COUNT) |i| {
            self.tx_ring[i] = TxDesc{
                .buffer_addr = self.tx_buffers_phys[i],
                .length = 0,
                .cso = 0, // Checksum offset
                .cmd = 0, // Command bits (EOP, RS, etc.)
                .status = TxDesc.STATUS_DD, // Mark as done/available
                .css = 0, // Checksum start
                .special = 0, // VLAN tag
            };
        }

        // Program descriptor ring base address (64-bit physical address)
        // Must be 16-byte aligned per Intel spec
        self.writeReg(Reg.TDBAL, @truncate(self.tx_ring_phys));
        self.writeReg(Reg.TDBAH, @truncate(self.tx_ring_phys >> 32));

        // Set descriptor ring length in bytes (must be 128-byte aligned)
        self.writeReg(Reg.TDLEN, TX_DESC_COUNT * @sizeOf(TxDesc));

        // Initialize head and tail pointers to 0 (empty ring)
        // Unlike RX where we pre-fill descriptors, TX starts empty.
        // Software will advance TDT as packets are queued for transmission.
        self.writeReg(Reg.TDH, 0);
        self.writeReg(Reg.TDT, 0);

        // Configure Inter-Packet Gap timing
        // Reference: 82574L Datasheet Section 13.4.34 "Transmit IPG Register"
        //
        // IPGT (bits 9:0) = 10: Minimum IPG for back-to-back packets
        //   - IEEE 802.3 specifies 96 bit times minimum
        //   - Value 10 = 10 * 8ns = 80ns at 1Gbps (close to 96 bit times)
        //
        // IPGR1 (bits 19:10) = 10: Part 1 of IPG for non-back-to-back
        // IPGR2 (bits 29:20) = 10: Part 2 of IPG for non-back-to-back
        //   - Used for collision recovery timing in half-duplex mode
        //   - Not critical for full-duplex gigabit operation
        self.writeReg(Reg.TIPG, (10 << 0) | (10 << 10) | (10 << 20));

        // Software write position starts at 0
        self.tx_cur = 0;
    }

    /// Clear multicast table array
    /// The MTA has 128 32-bit entries per Intel 82574L datasheet
    fn clearMulticastTable(self: *Self) void {
        const MTA_ENTRY_COUNT: usize = 128;
        for (0..MTA_ENTRY_COUNT) |i| {
            self.writeReg(Reg.MTA_BASE + @as(u64, i) * 4, 0);
        }
    }

    /// Update multicast hardware filter from interface state.
    /// Uses IEEE 802.3 CRC32 hash (12 MSB bits) per Intel 82574L spec.
    pub fn applyMulticastFilter(self: *Self, iface: *const net.Interface) void {
        // If host wants all multicast or no entries exist, enable MPE and clear table.
        // RFC 1112: host must receive joined groups; we fall back to all-multicast
        // when no precise filter is available.
        self.clearMulticastTable();
        var rctl = self.readRctl();

        const addrs = iface.getMulticastMacs();
        if (iface.accept_all_multicast or addrs.len == 0) {
            rctl.multicast_promisc = true;
            self.writeRctl(rctl);
            return;
        }

        // Program hash table for joined multicast MACs.
        rctl.multicast_promisc = false;
        self.writeRctl(rctl);

        for (addrs) |mac| {
            var crc = std.hash.crc.Crc32.init();
            crc.update(&mac);
            // Intel uses 12 MSB bits of reflected CRC (bits 31:20)
            const hash: u12 = @truncate(crc.final() >> 20);
            const reg_index = hash >> 5; // Upper 7 bits select MTA register
            const bit_index: u5 = @intCast(hash & 0x1F); // Lower 5 bits select bit within register

            const mta_reg = Reg.MTA_BASE + @as(u64, reg_index) * 4;
            var val = self.readReg(mta_reg);
            val |= @as(u32, 1) << bit_index;
            self.writeReg(mta_reg, val);
        }
    }

    /// Configure interrupt throttle rate to reduce CPU load under high packet rates
    /// Reference: 82574L Datasheet Section 13.4.18 "Interrupt Throttling"
    fn configureInterruptThrottle(self: *Self) void {
        // RDTR: RX Delay Timer - delay RX interrupt by N microseconds
        // This coalesces multiple packets into fewer interrupts
        self.writeReg(Reg.RDTR, 256); // ~256us delay before RX interrupt

        // RADV: RX Absolute Delay - maximum time to delay RX interrupt
        // Ensures packets are delivered even if threshold not met
        self.writeReg(Reg.RADV, 512); // Maximum 512us absolute delay

        // TADV: TX Absolute Delay - maximum time to delay TX completion interrupt
        self.writeReg(Reg.TADV, 128); // Maximum 128us for TX
    }

    /// Initialize MSI-X if available
    /// Falls back to legacy interrupts if MSI-X not supported
    fn initMsix(self: *Self) void {
        // Check for MSI-X capability
        const msix_cap = pci.findMsix(self.pci_ecam, self.pci_dev);
        if (msix_cap == null) {
            console.info("E1000e: MSI-X not available, using legacy interrupts", .{});
            return;
        }

        const cap = msix_cap.?;

        // 82574L has 5 MSI-X vectors, but we only use 3:
        // Vector 0: RX interrupts
        // Vector 1: TX interrupts
        // Vector 2: Other (link status, etc.)
        if (cap.table_size < 3) {
            console.warn("E1000e: Not enough MSI-X vectors ({d})", .{cap.table_size});
            return;
        }

        // Enable MSI-X
        const alloc = pci.enableMsix(self.pci_ecam, self.pci_dev, &cap, 0);
        if (alloc == null) {
            console.warn("E1000e: Failed to enable MSI-X", .{});
            return;
        }

        self.msix_table_base = alloc.?.table_base;

        // Get APIC ID for interrupt delivery (use BSP for now)
        const dest_apic_id: u8 = 0;

        // Allocate vectors - use base vectors starting from 0x30
        // In a real implementation, these would be dynamically allocated
        const base_vector: u8 = 0x30;
        self.msix_vectors[0] = base_vector; // RX
        self.msix_vectors[1] = base_vector + 1; // TX
        self.msix_vectors[2] = base_vector + 2; // Other

        // Configure MSI-X table entries
        pci.configureMsixEntry(self.msix_table_base, 0, self.msix_vectors[0], dest_apic_id);
        pci.configureMsixEntry(self.msix_table_base, 1, self.msix_vectors[1], dest_apic_id);
        pci.configureMsixEntry(self.msix_table_base, 2, self.msix_vectors[2], dest_apic_id);

        // Configure IVAR register to route interrupts to MSI-X vectors
        // 82574L IVAR format (per Intel datasheet):
        // Bits 2:0   - RX Queue 0 vector
        // Bit 3      - RX Queue 0 valid
        // Bits 6:4   - RX Queue 1 vector
        // Bit 7      - RX Queue 1 valid
        // Bits 10:8  - TX Queue 0 vector
        // Bit 11     - TX Queue 0 valid
        // Bits 14:12 - TX Queue 1 vector
        // Bit 15     - TX Queue 1 valid
        // Bits 18:16 - Other vector
        // Bit 19     - Other valid
        const ivar: u32 = (0 | (1 << 3)) | // RX0 -> vector 0, valid
            ((@as(u32, 1) << 8) | (1 << 11)) | // TX0 -> vector 1, valid
            ((@as(u32, 2) << 16) | (1 << 19)); // Other -> vector 2, valid
        self.writeReg(Reg.IVAR, ivar);

        // Enable MSI-X vectors
        pci.enableMsixVectors(self.pci_ecam, self.pci_dev, &cap);

        // Disable legacy INTx
        pci.msi.disableIntx(self.pci_ecam, self.pci_dev);

        self.msix_enabled = true;
        console.info("E1000e: MSI-X enabled with {d} vectors", .{@as(u8, 3)});
    }

    /// Enable interrupts
    fn enableInterrupts(self: *Self) void {
        // Configure interrupt coalescing to reduce interrupt frequency under load
        self.configureInterruptThrottle();

        if (self.msix_enabled) {
            // Use extended interrupt mask for MSI-X
            // Enable: RX, TX, and Other causes
            // These map to the MSI-X vectors via IVAR
            self.writeReg(Reg.EIMS, INT.RXT0 | INT.RXDMT0 | INT.LSC | INT.TXDW);
        } else {
            // Legacy: Enable RX timer, RX descriptor minimum threshold, link status change
            self.writeReg(Reg.IMS, INT.RXT0 | INT.RXDMT0 | INT.LSC);
        }
    }

    /// Enable RX and TX
    fn enableRxTx(self: *Self) void {
        // Enable receiver
        // Accept broadcast, unicast to our MAC, 2048 byte buffers, strip CRC
        self.writeRctl(.{
            .enable = true,
            .broadcast_accept = true,
            // Accept multicast in hardware; software filter enforces RFC 1112 memberships
            .multicast_promisc = true,
            .buffer_size = 0, // 2048 bytes
            .strip_crc = true,
        });

        // Enable transmitter
        // Reference: 82574L Datasheet Section 13.4.37 "Transmit Control Register"
        // Pad short packets, collision threshold and distance for full duplex
        // CT (Collision Threshold) = 15: Standard value for half-duplex (unused in FD)
        // COLD (Collision Distance) = 64: Standard for gigabit (512 bit times)
        self.writeTctl(.{
            .enable = true,
            .pad_short_packets = true,
            .collision_threshold = 15,
            .collision_distance = 64,
        });

        // Set link up
        var ctrl = self.readCtrl();
        ctrl.set_link_up = true;
        self.writeCtrl(ctrl);
    }

    // ========================================================================
    // Packet Transmission
    // ========================================================================

    /// Transmit a packet (similar to Linux e1000_xmit_frame)
    ///
    /// Queues a packet for transmission by:
    /// 1. Finding an available descriptor (DD=1 means hardware finished with it)
    /// 2. Copying packet data to the descriptor's buffer
    /// 3. Setting up descriptor fields (length, command, checksum offload)
    /// 4. Advancing TDT to notify hardware
    ///
    /// TX Ring Flow:
    /// - Software writes to descriptor at tx_cur, advances TDT = tx_cur + 1
    /// - Hardware reads from TDH, transmits, sets DD=1, advances TDH
    /// - Ring is full when (TDT + 1) mod N == TDH
    /// - Ring is empty when TDT == TDH
    ///
    /// Returns true on success, false if TX ring is full or packet invalid
    pub fn transmit(self: *Self, data: []const u8) bool {
        // Validate packet size
        if (data.len > BUFFER_SIZE or data.len == 0) {
            return false;
        }

        const held = self.lock.acquire();
        defer held.release();

        // Check if current descriptor is available (DD=1 means completed)
        //
        // Per Intel 82574L Datasheet Section 3.3.3:
        // The DD (Descriptor Done) bit is set by hardware AFTER the packet
        // has been transmitted and the descriptor buffer is no longer needed.
        // This is the authoritative signal that the descriptor can be reused.
        //
        // Note: We intentionally do NOT read TDH register here. Reading TDH
        // adds PCI latency and is unnecessary - the DD bit is the definitive
        // indicator per Intel spec. Linux e1000e driver also trusts DD alone.
        const desc = &self.tx_ring[self.tx_cur];
        if ((desc.status & TxDesc.STATUS_DD) == 0) {
            // Hardware hasn't finished with this descriptor yet
            self.tx_dropped += 1;
            return false;
        }

        // Memory barrier: ensure we see hardware's writes to status field
        // before we read or overwrite any descriptor fields
        mmio.readBarrier();

        // Parse packet for hardware checksum offloading
        // E1000e can insert TCP/UDP checksums if we provide CSS (start) and CSO (offset)
        var css: u8 = 0; // Checksum Start: byte offset where checksum calculation begins
        var cso: u8 = 0; // Checksum Offset: byte offset within L4 header for checksum field
        var cmd_extra: u8 = 0;

        // Attempt checksum offload for IPv4 + TCP/UDP packets
        // Minimum size: Ethernet (14) + IPv4 minimum (20) = 34 bytes
        if (data.len >= 34) {
            // Parse EtherType at offset 12-13 (big endian)
            const eth_type = (@as(u16, data[12]) << 8) | data[13];

            if (eth_type == 0x0800) { // IPv4
                // IPv4 header: version/IHL at offset 14, protocol at offset 23
                const ver_ihl = data[14];
                const ip_ver = ver_ihl >> 4;
                const ip_ihl = ver_ihl & 0x0F; // Header length in 32-bit words

                if (ip_ver == 4 and ip_ihl >= 5) {
                    const ip_header_len = @as(usize, ip_ihl) * 4;
                    const l4_offset = 14 + ip_header_len;
                    const ip_proto = data[23];

                    // Verify packet has enough data for L4 header
                    if (l4_offset + 8 <= data.len) {
                        if (ip_proto == 6) { // TCP
                            // TCP checksum is at offset 16 within TCP header
                            // CSO is absolute offset from packet start per Intel spec
                            css = @intCast(l4_offset);
                            cso = @intCast(l4_offset + 16);
                            cmd_extra = TxDesc.CMD_IC;
                        } else if (ip_proto == 17) { // UDP
                            // UDP checksum is at offset 6 within UDP header
                            // CSO is absolute offset from packet start per Intel spec
                            css = @intCast(l4_offset);
                            cso = @intCast(l4_offset + 6);
                            cmd_extra = TxDesc.CMD_IC;
                        }
                    }
                }
            }
        }

        // Copy packet data to descriptor's pre-allocated buffer
        const buf = self.tx_buffers[self.tx_cur];
        @memcpy(buf[0..data.len], data);

        // Configure descriptor for transmission
        // CMD_EOP: End of Packet (entire packet in one descriptor)
        // CMD_IFCS: Insert Frame Check Sequence (hardware appends CRC)
        // CMD_RS: Report Status (hardware will set DD when complete)
        // CMD_IC: Insert Checksum (if checksum offload is configured)
        desc.* = TxDesc{
            .buffer_addr = self.tx_buffers_phys[self.tx_cur],
            .length = @truncate(data.len),
            .cso = cso,
            .cmd = TxDesc.CMD_EOP | TxDesc.CMD_IFCS | TxDesc.CMD_RS | cmd_extra,
            .status = 0, // Clear DD; hardware will set it after transmission
            .css = css,
            .special = 0,
        };

        // Advance software tail pointer
        self.tx_cur = @truncate((@as(u32, self.tx_cur) + 1) % TX_DESC_COUNT);

        // Write barrier ensures descriptor contents are visible to hardware
        // before we update TDT. Without this, hardware might see the new
        // tail but stale descriptor data.
        mmio.writeBarrier();

        // Notify hardware by writing TDT
        // Per Intel spec: TDT points one beyond the last valid descriptor
        // Setting TDT = tx_cur queues the descriptor we just wrote
        self.writeReg(Reg.TDT, self.tx_cur);

        self.tx_packets += 1;
        self.tx_bytes += data.len;

        return true;
    }

    // ========================================================================
    // Packet Reception
    // ========================================================================

    /// Process received packets
    /// Calls callback for each received packet
    /// Batch size for RDT updates (same as Linux E1000_RX_BUFFER_WRITE)
    /// Updating RDT every N descriptors reduces register write overhead while
    /// ensuring hardware doesn't starve during large batch processing.
    const RX_BUFFER_WRITE: usize = 16;

    /// Process received packets with a budget (NAPI-style polling)
    ///
    /// Implements a receive path similar to Linux e1000_clean_rx_irq:
    /// - Processes up to `limit` packets per call
    /// - Updates RDT periodically to return descriptors to hardware
    /// - Uses memory barriers to ensure descriptor visibility
    /// - Uses pre-allocated packet pool to avoid heap allocation under spinlock
    ///
    /// RDT (Receive Descriptor Tail) Semantics:
    /// Per Intel 82574L Datasheet Section 3.2.6: "The tail pointer points to
    /// one location beyond the last valid descriptor in the descriptor ring."
    /// Hardware writes to descriptors from HEAD to TAIL-1 (inclusive).
    /// Setting RDT = rx_cur means hardware can use all descriptors up to rx_cur-1.
    ///
    /// Callback takes ownership of buffer and MUST free via packet_pool.release()
    ///
    /// Returns number of packets processed
    pub fn processRxLimited(self: *Self, callback: *const fn ([]u8) void, limit: usize) usize {
        console.debug("E1000e: processRxLimited self={*} cb={*} limit={d}", .{ self, callback, limit });

        var processed: usize = 0;
        var batch_count: usize = 0;

        while (processed < limit) {
            // Acquire buffer from packet pool OUTSIDE driver spinlock.
            // This avoids nested spinlock acquisition (pool has its own lock).
            const pkt_buf = packet_pool.acquire() orelse {
                // Pool exhausted - backpressure signal, stop processing
                break;
            };

            const held = self.lock.acquire();

            const desc = &self.rx_ring[self.rx_cur];

            // Check if descriptor has a packet (DD = Descriptor Done)
            if ((desc.status & RxDesc.STATUS_DD) == 0) {
                held.release();
                packet_pool.release(pkt_buf);
                break; // No more packets ready
            }

            // Memory barrier: ensure we see all hardware writes to descriptor
            // fields before reading length/data. Required because hardware and
            // software access the same memory without locks.
            mmio.readBarrier();

            // Check for receive errors
            if (desc.errors != 0) {
                self.logRxErrors(desc.errors);
                // Fall through to reset descriptor
            } else if ((desc.status & RxDesc.STATUS_EOP) != 0) {
                // Valid complete packet received (EOP = End of Packet)
                // Clamp length to buffer size and validate minimum Ethernet frame size
                const raw_len: usize = @min(@as(usize, desc.length), BUFFER_SIZE);

                // Minimum Ethernet frame: 14 bytes (6 dst + 6 src + 2 ethertype)
                // Packets smaller than this are malformed and should be dropped
                if (raw_len < 14) {
                    self.rx_dropped += 1;
                } else {
                    const buf = self.rx_buffers[self.rx_cur];

                    // Copy packet to pool buffer to avoid use-after-free.
                    // The descriptor buffer will be reused immediately, so we must
                    // copy before returning the descriptor to hardware.
                    @memcpy(pkt_buf[0..raw_len], buf[0..raw_len]);

                    self.rx_packets += 1;
                    self.rx_bytes += raw_len;

                    // Reset descriptor for hardware reuse before releasing lock
                    desc.status = 0;
                    desc.errors = 0;
                    desc.length = 0;

                    // Advance to next descriptor
                    self.rx_cur = @truncate((@as(u32, self.rx_cur) + 1) % RX_DESC_COUNT);
                    processed += 1;
                    batch_count += 1;

                    // Periodic RDT update (like Linux E1000_RX_BUFFER_WRITE)
                    if (batch_count >= RX_BUFFER_WRITE) {
                        self.updateRdt();
                        batch_count = 0;
                    }

                    held.release();

                    // Callback OUTSIDE spinlock - callback takes ownership of buffer
                    // and MUST call packet_pool.release() when done
                    callback(pkt_buf[0..raw_len]);
                    continue;
                }
            }

            // Error path or non-EOP packet: reset descriptor and return buffer to pool
            desc.status = 0;
            desc.errors = 0;
            desc.length = 0;

            self.rx_cur = @truncate((@as(u32, self.rx_cur) + 1) % RX_DESC_COUNT);
            processed += 1;
            batch_count += 1;

            if (batch_count >= RX_BUFFER_WRITE) {
                self.updateRdt();
                batch_count = 0;
            }

            held.release();
            packet_pool.release(pkt_buf);
        }

        // Final RDT update for any remaining processed descriptors
        if (batch_count > 0) {
            const held = self.lock.acquire();
            self.updateRdt();
            held.release();
        }

        return processed;
    }

    /// Update RDT register to return processed descriptors to hardware
    ///
    /// Per Intel 82574L Datasheet: RDT points one beyond the last valid
    /// descriptor. Setting RDT = rx_cur makes descriptors from HEAD to
    /// rx_cur-1 available for hardware to write to.
    ///
    /// Note: If rx_cur == HEAD (software caught up completely), this results
    /// in zero available descriptors momentarily. This is acceptable because:
    /// 1. Hardware has internal packet buffering
    /// 2. The next interrupt/poll will process new packets quickly
    /// 3. This matches the Intel-specified behavior
    fn updateRdt(self: *Self) void {
        // Write barrier ensures all descriptor resets are visible to hardware
        // before we update the tail pointer. Without this, hardware might see
        // the new tail but stale descriptor contents.
        mmio.writeBarrier();

        // RDT = rx_cur per Intel spec: "one beyond the last valid descriptor"
        self.writeReg(Reg.RDT, self.rx_cur);
    }

    /// Process all received packets (legacy wrapper)
    pub fn processRx(self: *Self, callback: *const fn ([]u8) void) void {
        _ = self.processRxLimited(callback, RX_DESC_COUNT);
    }

    /// Log decoded RX errors and update statistics
    fn logRxErrors(self: *Self, errors: u8) void {
        // Update statistics
        self.rx_errors += 1;
        if ((errors & RXERR.CE) != 0) {
            self.rx_crc_errors += 1;
        }

        var buf: [48]u8 = undefined;
        var len: usize = 0;

        if ((errors & RXERR.CE) != 0) {
            @memcpy(buf[len..][0..4], "CRC ");
            len += 4;
        }
        if ((errors & RXERR.SE) != 0) {
            @memcpy(buf[len..][0..4], "SYM ");
            len += 4;
        }
        if ((errors & RXERR.SEQ) != 0) {
            @memcpy(buf[len..][0..4], "SEQ ");
            len += 4;
        }
        if ((errors & RXERR.TCPE) != 0) {
            @memcpy(buf[len..][0..5], "TCPE ");
            len += 5;
        }
        if ((errors & RXERR.IPE) != 0) {
            @memcpy(buf[len..][0..4], "IPE ");
            len += 4;
        }
        if ((errors & RXERR.RXE) != 0) {
            @memcpy(buf[len..][0..5], "FIFO ");
            len += 5;
        }

        if (len > 0) {
            console.warn("E1000e: RX errors: {s}(0x{x:0>2})", .{ buf[0..len], errors });
        } else {
            console.warn("E1000e: RX error 0x{x:0>2}", .{errors});
        }
    }

    /// Worker thread entry point (NAPI-style polling)
    ///
    /// Implements a receive polling loop with proper interrupt synchronization.
    /// The key insight from Linux NAPI is: re-enable interrupts BEFORE checking
    /// for pending work. This closes the race window where packets could arrive
    /// between the empty check and the block() call.
    ///
    /// Interrupt flow:
    /// 1. IRQ fires, handler masks interrupts and unblocks worker
    /// 2. Worker processes packets until ring appears empty
    /// 3. Worker re-enables interrupts (IMS write)
    /// 4. Worker checks for packets AFTER IMS write
    /// 5. If empty, worker blocks; any new packet will fire IRQ and unblock
    pub fn workerLoop(self: *Self) void {
        const BATCH_LIMIT = 64;

        while (!@atomicLoad(bool, &self.shutdown_requested, .acquire)) {
            // Atomic load prevents torn pointer read if setRxCallback() called concurrently
            const cb = @atomicLoad(?*const fn ([]u8) void, &self.rx_callback, .acquire) orelse &defaultRxCallback;

            // Process a batch of packets
            const processed = self.processRxLimited(cb, BATCH_LIMIT);

            if (processed < BATCH_LIMIT) {
                // We drained the ring (or close to it).
                // Use NAPI-style: re-enable interrupts BEFORE checking for work.
                // This closes the race window where packets could arrive between
                // the hasPackets() check and the block() call.

                const flags = hal.cpu.disableInterruptsSaveFlags();

                // Re-enable RX interrupts FIRST (before checking for packets).
                // This ensures any packets arriving NOW will trigger an interrupt
                // that will unblock us if we decide to block.
                self.writeReg(Reg.IMS, INT.RXT0 | INT.RXDMT0);

                // Memory barrier to ensure IMS write completes before checking state.
                // On x86 this is sfence which orders stores.
                mmio.writeBarrier();

                // Now check if we should block.
                // If packets arrived after IMS write, hasPackets() will return true.
                // If packets arrive after this check, the interrupt will fire and unblock us.
                if (!self.hasPackets() and !@atomicLoad(bool, &self.shutdown_requested, .acquire)) {
                    sched.block();
                }
                hal.cpu.restoreInterrupts(flags);
            } else {
                // We hit the batch limit, there might be more packets.
                // Yield to scheduler to allow other threads to run, but keep polling.
                sched.yield();
            }
        }
        // Worker thread is exiting - will be joined by deinit()
    }

    /// Check if there are packets waiting
    /// Note: Caller should use processRx() to actually read packets, which
    /// has proper memory barriers. This is just a quick poll check.
    pub fn hasPackets(self: *Self) bool {
        const desc = &self.rx_ring[self.rx_cur];
        const has_packet = (desc.status & RxDesc.STATUS_DD) != 0;
        if (has_packet) {
            // Ensure subsequent reads see hardware writes
            mmio.readBarrier();
        }
        return has_packet;
    }

    /// Set RX callback for packet processing
    /// Thread-safe: uses atomic store to prevent torn pointer write if worker is reading
    pub fn setRxCallback(self: *Self, callback: *const fn ([]u8) void) void {
        @atomicStore(?*const fn ([]u8) void, &self.rx_callback, callback, .release);
    }

    // ========================================================================
    // TX Watchdog
    // ========================================================================

    /// TX watchdog threshold - number of consecutive stall checks before reset
    const TX_WATCHDOG_THRESHOLD: u16 = 100;

    /// Check for TX ring stall and reset if stuck
    /// Call periodically from timer tick or worker thread
    pub fn checkTxWatchdog(self: *Self) void {
        const tdh = self.readReg(Reg.TDH);
        const tdt = self.readReg(Reg.TDT);

        // If TDH == TDT, ring is empty - no stall possible
        if (tdh == tdt) {
            self.tx_watchdog_stall_count = 0;
            return;
        }

        // If TDH hasn't moved and ring not empty, potential stall
        if (tdh == self.tx_watchdog_last_tdh) {
            self.tx_watchdog_stall_count += 1;
            if (self.tx_watchdog_stall_count >= TX_WATCHDOG_THRESHOLD) {
                console.err("E1000e: TX watchdog triggered (TDH={d} TDT={d})", .{ tdh, tdt });
                self.resetTx();
            }
        } else {
            self.tx_watchdog_stall_count = 0;
        }
        self.tx_watchdog_last_tdh = tdh;
    }

    /// Reset TX subsystem after watchdog timeout
    fn resetTx(self: *Self) void {
        console.warn("E1000e: Resetting TX subsystem", .{});

        // Disable transmitter
        var tctl = self.readTctl();
        tctl.enable = false;
        self.writeTctl(tctl);

        // Reset head and tail pointers
        self.writeReg(Reg.TDH, 0);
        self.writeReg(Reg.TDT, 0);
        self.tx_cur = 0;

        // Mark all descriptors as done
        for (0..TX_DESC_COUNT) |i| {
            self.tx_ring[i].status = TxDesc.STATUS_DD;
        }

        // Re-enable transmitter
        tctl.enable = true;
        self.writeTctl(tctl);

        // Reset watchdog state
        self.tx_watchdog_stall_count = 0;
        self.tx_watchdog_last_tdh = 0;

        console.info("E1000e: TX reset complete", .{});
    }

    // ========================================================================
    // Link State
    // ========================================================================

    /// Handle link status change - decode and log speed/duplex
    fn handleLinkChange(self: *Self) void {
        const status = self.readReg(Reg.STATUS);
        const link_up = (status & STATUS.LU) != 0;

        if (link_up) {
            const duplex: []const u8 = if ((status & STATUS.FD) != 0) "Full" else "Half";
            const speed_bits = (status & STATUS.SPEED_MASK) >> STATUS.SPEED_SHIFT;
            const speed: []const u8 = switch (speed_bits) {
                0 => "10",
                1 => "100",
                2 => "1000",
                else => "?",
            };
            console.info("E1000e: Link UP - {s}Mbps {s} Duplex", .{ speed, duplex });
        } else {
            console.info("E1000e: Link DOWN", .{});
        }
    }

    /// Get link speed in Mbps (0 if link down)
    pub fn getLinkSpeed(self: *const Self) u16 {
        const status = self.readReg(Reg.STATUS);
        if ((status & STATUS.LU) == 0) return 0; // Link down

        const speed_bits = (status & STATUS.SPEED_MASK) >> STATUS.SPEED_SHIFT;
        return switch (speed_bits) {
            0 => 10,
            1 => 100,
            2 => 1000,
            else => 0,
        };
    }

    // ========================================================================
    // Interrupt Handler
    // ========================================================================

    /// Handle interrupt from NIC (similar to Linux e1000_intr)
    ///
    /// Implements NAPI-style interrupt handling:
    /// 1. Read ICR to determine interrupt cause (also clears the interrupt)
    /// 2. For RX: mask further RX interrupts and wake worker thread
    /// 3. Worker thread polls RX ring until empty, then re-enables interrupts
    ///
    /// This approach (interrupt -> mask -> poll -> unmask) prevents interrupt
    /// storms during high packet rates while maintaining low latency for
    /// light traffic. Matches Linux NAPI (New API) design.
    ///
    /// Interrupt sources handled:
    /// - RXT0 (RX Timer): Packet received, timer expired
    /// - RXDMT0 (RX Desc Min Threshold): RX ring getting full
    /// - LSC (Link Status Change): Link up/down event
    pub fn handleIrq(self: *Self) void {
        // Read ICR to get interrupt cause and clear pending interrupt.
        // Reading ICR is atomic with clearing on 82574L.
        const icr = InterruptCause.fromRaw(self.readReg(Reg.ICR));

        if (icr.hasRxInterrupt()) {
            // RX interrupt - transition to polling mode
            //
            // Mask RX interrupts (IMC = Interrupt Mask Clear) to prevent
            // further interrupts while we're polling. The worker thread
            // will re-enable them via IMS after draining the RX queue.
            //
            // This is the core of NAPI: interrupt to wake, poll to drain,
            // re-enable when done.
            self.writeReg(Reg.IMC, INT.RXT0 | INT.RXDMT0);

            // Wake the worker thread to process received packets
            if (self.worker_thread) |t| {
                sched.unblock(t);
            }
        }

        if (icr.link_status_change) {
            // Link status change - log new link state
            // This handles cable plug/unplug and auto-negotiation completion
            self.handleLinkChange();
        }
    }

    /// Get MAC address
    pub fn getMacAddress(self: *const Self) [6]u8 {
        return self.mac_addr;
    }

    /// Get statistics (thread-safe)
    /// Acquires lock to ensure consistent snapshot of all counters
    pub fn getStats(self: *Self) struct {
        rx_packets: u64,
        tx_packets: u64,
        rx_bytes: u64,
        tx_bytes: u64,
        rx_errors: u64,
        rx_crc_errors: u64,
        rx_dropped: u64,
        tx_dropped: u64,
    } {
        const held = self.lock.acquire();
        defer held.release();

        return .{
            .rx_packets = self.rx_packets,
            .tx_packets = self.tx_packets,
            .rx_bytes = self.rx_bytes,
            .tx_bytes = self.tx_bytes,
            .rx_errors = self.rx_errors,
            .rx_crc_errors = self.rx_crc_errors,
            .rx_dropped = self.rx_dropped,
            .tx_dropped = self.tx_dropped,
        };
    }

    // ========================================================================
    // Driver Cleanup
    // ========================================================================

    /// Deinitialize driver and release resources
    /// Call before hot-unplug or driver reload
    ///
    /// SAFETY: This function waits for the worker thread to exit before
    /// freeing resources, preventing use-after-free.
    pub fn deinit(self: *Self) void {
        console.info("E1000e: Deinitializing driver", .{});

        // Signal worker thread to exit
        @atomicStore(bool, &self.shutdown_requested, true, .release);

        // Wake worker if it's blocked waiting for packets, then wait for exit
        if (self.worker_thread) |wt| {
            sched.unblock(wt);

            // Wait for worker thread to reach Zombie state (exit cleanly).
            // This prevents use-after-free: we must not free descriptor rings
            // or buffers while the worker could still be accessing them.
            // Use timeout to avoid hanging forever if something goes wrong.
            const timeout_ticks = 1000; // ~10 seconds at 100Hz timer
            if (!thread.joinWithTimeout(wt, timeout_ticks)) {
                console.err("E1000e: Worker thread join timed out - forcing cleanup", .{});
                // Worker didn't exit in time. Continue with cleanup but warn.
                // This is a last resort to prevent kernel hang.
            } else {
                console.info("E1000e: Worker thread joined successfully", .{});
            }

            // Clean up the worker thread structure
            _ = thread.destroyThread(wt);
            self.worker_thread = null;
        }

        // Disable interrupts
        self.writeReg(Reg.IMC, 0xFFFFFFFF);

        // Disable RX and TX
        self.writeRctl(.{});
        self.writeTctl(.{});

        // Reset device to known state
        self.writeCtrl(.{ .device_reset = true });

        // Free descriptor rings and buffers
        // Use the shared freeRings() to avoid code duplication
        self.freeRings();

        // Unmap MMIO
        vmm.unmapMmio(self.mmio_base, self.mmio_size);

        // Use release ordering to ensure all cleanup is visible before
        // other threads see driver_initialized = false
        @atomicStore(bool, &driver_initialized, false, .release);
        console.info("E1000e: Deinitialized", .{});
    }
};

// ============================================================================
// Static Instance and Callbacks
// ============================================================================

/// Static driver instance (for single NIC)
/// Note: driver_instance fields are undefined until driver_initialized is true
var driver_instance: E1000e = undefined;
/// Use atomic operations to safely check from multiple threads (IRQ handler, getDriver)
var driver_initialized: bool = false;

/// Default RX callback (just logs packets for now)
fn defaultRxCallback(data: []u8) void {
    _ = data;
    // Placeholder - real implementation would pass to network stack
}

/// Get the driver instance (if initialized)
/// Thread-safe: uses atomic load on driver_initialized flag
pub fn getDriver() ?*E1000e {
    if (@atomicLoad(bool, &driver_initialized, .acquire)) {
        return &driver_instance;
    }
    return null;
}

/// IRQ handler entry point (called from HAL)
pub fn irqHandler() void {
    if (getDriver()) |driver| {
        driver.handleIrq();
    }
}

    /// Static worker entry point
    /// Runs workerLoop then exits cleanly so deinit() can join the thread.
    fn workerEntry(ctx: ?*anyopaque) callconv(.c) void {
        console.info("E1000e: Worker thread started", .{});
        if (ctx) |ptr| {
            const driver: *E1000e = @ptrCast(@alignCast(ptr));
            console.info("E1000e: Worker thread entering loop with driver={*}", .{driver});
            
            // Now we can safely call the member function because we have the correct self pointer
            driver.workerLoop();
        } else {
            console.err("E1000e: Worker thread failed to get driver context!", .{});
        }
        // Worker thread finished - call scheduler exit to mark thread as Zombie.
        // This allows deinit() to join (wait for Zombie state) before freeing resources.
        console.info("E1000e: Worker thread exiting", .{});
        sched.exit();
    }

/// Initialize E1000e driver for the first found E1000/E1000e NIC
pub fn initFromPci(devices: *const pci.DeviceList, pci_ecam: *const pci.Ecam) !*E1000e {
    // Find E1000/E1000e NIC
    const nic = devices.findE1000() orelse {
        console.err("E1000e: No Intel E1000/E1000e NIC found", .{});
        return error.NoDevice;
    };

    const driver = try E1000e.init(nic, pci_ecam);
    // driver_initialized is now set inside init() before worker thread creation
    return driver;
}
