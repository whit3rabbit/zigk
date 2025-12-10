// Intel E1000e (82574L) Network Driver
//
// Implements a driver for the Intel 82574L Gigabit Ethernet Controller.
// Uses MMIO for register access and legacy descriptors for RX/TX.
//
// Features:
//   - Receive and transmit packet handling
//   - Interrupt-driven packet reception
//   - MAC address retrieval from EEPROM/RAL
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet

const hal = @import("hal");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const sync = @import("sync");
const console = @import("console");
const thread = @import("thread");
const sched = @import("sched");

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
};

// Device Control Register bits
// Reference: 82574L Datasheet Section 13.4.1
const CTRL = struct {
    pub const FD: u32 = 1 << 0;         // Full Duplex
    pub const LRST: u32 = 1 << 3;       // Link Reset
    pub const ASDE: u32 = 1 << 5;       // Auto-Speed Detection Enable
    pub const SLU: u32 = 1 << 6;        // Set Link Up
    pub const ILOS: u32 = 1 << 7;       // Invert Loss of Signal
    pub const RST: u32 = 1 << 26;       // Device Reset
    pub const VME: u32 = 1 << 30;       // VLAN Mode Enable
    pub const PHY_RST: u32 = 1 << 31;   // PHY Reset
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

// Receive Control Register bits
const RCTL = struct {
    pub const EN: u32 = 1 << 1;         // Receiver Enable
    pub const SBP: u32 = 1 << 2;        // Store Bad Packets
    pub const UPE: u32 = 1 << 3;        // Unicast Promiscuous
    pub const MPE: u32 = 1 << 4;        // Multicast Promiscuous
    pub const LPE: u32 = 1 << 5;        // Long Packet Enable
    pub const LBM_NONE: u32 = 0 << 6;   // Loopback Mode: None
    pub const RDMTS_HALF: u32 = 0 << 8; // RX Descriptor Min Threshold: 1/2
    pub const MO_36: u32 = 0 << 12;     // Multicast Offset: bits [47:36]
    pub const BAM: u32 = 1 << 15;       // Broadcast Accept Mode
    pub const BSIZE_2048: u32 = 0 << 16; // Buffer Size: 2048 bytes
    pub const BSIZE_1024: u32 = 1 << 16;
    pub const BSIZE_512: u32 = 2 << 16;
    pub const BSIZE_256: u32 = 3 << 16;
    pub const VFE: u32 = 1 << 18;       // VLAN Filter Enable
    pub const CFIEN: u32 = 1 << 19;     // Canonical Form Indicator Enable
    pub const CFI: u32 = 1 << 20;       // Canonical Form Indicator
    pub const SECRC: u32 = 1 << 26;     // Strip Ethernet CRC
};

// Transmit Control Register bits
const TCTL = struct {
    pub const EN: u32 = 1 << 1;         // Transmit Enable
    pub const PSP: u32 = 1 << 3;        // Pad Short Packets
    pub const CT_SHIFT: u5 = 4;         // Collision Threshold shift
    pub const COLD_SHIFT: u5 = 12;      // Collision Distance shift
    pub const RTLC: u32 = 1 << 24;      // Re-transmit on Late Collision
};

// Interrupt bits
const INT = struct {
    pub const TXDW: u32 = 1 << 0;       // TX Descriptor Written Back
    pub const TXQE: u32 = 1 << 1;       // TX Queue Empty
    pub const LSC: u32 = 1 << 2;        // Link Status Change
    pub const RXSEQ: u32 = 1 << 3;      // RX Sequence Error
    pub const RXDMT0: u32 = 1 << 4;     // RX Descriptor Min Threshold
    pub const RXO: u32 = 1 << 6;        // RX Overrun
    pub const RXT0: u32 = 1 << 7;       // RX Timer Interrupt
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
pub const RX_DESC_COUNT: usize = 32;
/// Number of TX descriptors (must be multiple of 8)
pub const TX_DESC_COUNT: usize = 32;
/// Size of each packet buffer
pub const BUFFER_SIZE: usize = 2048;

// ============================================================================
// Driver State
// ============================================================================

/// E1000e driver instance
pub const E1000e = struct {
    /// MMIO base virtual address
    mmio_base: u64,

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

    /// Lock for thread-safe access
    lock: sync.Spinlock,

    /// Statistics
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

    const Self = @This();

    // ========================================================================
    // Register Access
    // ========================================================================

    fn readReg(self: *const Self, offset: u64) u32 {
        return mmio.read32(self.mmio_base + offset);
    }

    fn writeReg(self: *Self, offset: u64, value: u32) void {
        mmio.write32(self.mmio_base + offset, value);
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize E1000e driver for a PCI device
    pub fn init(pci_dev: *const pci.PciDevice, pci_ecam: *const pci.Ecam) !*Self {
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
        driver.* = Self{
            .mmio_base = mmio_base,
            .mac_addr = [_]u8{0} ** 6,
            .rx_ring = undefined,
            .rx_ring_phys = 0,
            .tx_ring = undefined,
            .tx_ring_phys = 0,
            .rx_buffers = undefined,
            .rx_buffers_phys = undefined,
            .tx_buffers = undefined,
            .tx_buffers_phys = undefined,
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

        // Initialize RX
        driver.initRx();

        // Initialize TX
        driver.initTx();

        // Clear multicast table
        driver.clearMulticastTable();

        // Enable interrupts
        driver.enableInterrupts();

        // Create worker thread
        driver.worker_thread = try thread.createKernelThread(workerEntry, .{
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
        self.writeReg(Reg.CTRL, CTRL.RST);

        // Wait for reset to complete (RST bit clears)
        // Reference: 82574L Datasheet Section 13.4.1 - reset completes when RST bit clears
        if (!mmio.poll32(self.mmio_base + Reg.CTRL, CTRL.RST, 0, 1_000_000)) {
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
    fn allocateRings(self: *Self) !void {
        // Allocate RX descriptor ring (must be 16-byte aligned, use full page)
        const rx_ring_phys = pmm.allocZeroedPage() orelse {
            return error.OutOfMemory;
        };
        self.rx_ring_phys = rx_ring_phys;
        // Cast to volatile pointer - hardware modifies descriptor status fields
        self.rx_ring = @ptrCast(@volatileCast(@as([*]RxDesc, @ptrCast(@alignCast(hal.paging.physToVirt(rx_ring_phys))))));

        // Allocate TX descriptor ring
        const tx_ring_phys = pmm.allocZeroedPage() orelse {
            return error.OutOfMemory;
        };
        self.tx_ring_phys = tx_ring_phys;
        // Cast to volatile pointer - hardware modifies descriptor status fields
        self.tx_ring = @ptrCast(@volatileCast(@as([*]TxDesc, @ptrCast(@alignCast(hal.paging.physToVirt(tx_ring_phys))))));

        // Allocate RX packet buffers
        for (0..RX_DESC_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse {
                return error.OutOfMemory;
            };
            self.rx_buffers_phys[i] = buf_phys;
            self.rx_buffers[i] = hal.paging.physToVirt(buf_phys);
        }

        // Allocate TX packet buffers
        for (0..TX_DESC_COUNT) |i| {
            const buf_phys = pmm.allocZeroedPage() orelse {
                return error.OutOfMemory;
            };
            self.tx_buffers_phys[i] = buf_phys;
            self.tx_buffers[i] = hal.paging.physToVirt(buf_phys);
        }

        console.info("E1000e: Allocated {d} RX and {d} TX descriptors", .{
            RX_DESC_COUNT,
            TX_DESC_COUNT,
        });
    }

    /// Initialize RX subsystem
    fn initRx(self: *Self) void {
        // Initialize RX descriptors
        for (0..RX_DESC_COUNT) |i| {
            self.rx_ring[i] = RxDesc{
                .buffer_addr = self.rx_buffers_phys[i],
                .length = 0,
                .checksum = 0,
                .status = 0,
                .errors = 0,
                .special = 0,
            };
        }

        // Set RX descriptor base address
        self.writeReg(Reg.RDBAL, @truncate(self.rx_ring_phys));
        self.writeReg(Reg.RDBAH, @truncate(self.rx_ring_phys >> 32));

        // Set RX descriptor length (in bytes)
        self.writeReg(Reg.RDLEN, RX_DESC_COUNT * @sizeOf(RxDesc));

        // Set head and tail pointers
        self.writeReg(Reg.RDH, 0);
        self.writeReg(Reg.RDT, RX_DESC_COUNT - 1);

        self.rx_cur = 0;
    }

    /// Initialize TX subsystem
    fn initTx(self: *Self) void {
        // Initialize TX descriptors as empty
        for (0..TX_DESC_COUNT) |i| {
            self.tx_ring[i] = TxDesc{
                .buffer_addr = self.tx_buffers_phys[i],
                .length = 0,
                .cso = 0,
                .cmd = 0,
                .status = TxDesc.STATUS_DD, // Mark as done initially
                .css = 0,
                .special = 0,
            };
        }

        // Set TX descriptor base address
        self.writeReg(Reg.TDBAL, @truncate(self.tx_ring_phys));
        self.writeReg(Reg.TDBAH, @truncate(self.tx_ring_phys >> 32));

        // Set TX descriptor length
        self.writeReg(Reg.TDLEN, TX_DESC_COUNT * @sizeOf(TxDesc));

        // Set head and tail pointers
        self.writeReg(Reg.TDH, 0);
        self.writeReg(Reg.TDT, 0);

        // Set Inter-Packet Gap
        // Reference: 82574L Datasheet Section 13.4.34 "Transmit IPG Register"
        // IPGT (bits 9:0) = 10: Minimum inter-packet gap (IPG) for back-to-back packets
        // IPGR1 (bits 19:10) = 10: Part 1 of IPG for non-back-to-back
        // IPGR2 (bits 29:20) = 10: Part 2 of IPG for non-back-to-back
        // Values are in units of link clock cycles (8ns at 1Gbps)
        self.writeReg(Reg.TIPG, (10 << 0) | (10 << 10) | (10 << 20));

        self.tx_cur = 0;
    }

    /// Clear multicast table array
    fn clearMulticastTable(self: *Self) void {
        var i: u64 = 0;
        while (i < 128) : (i += 1) {
            self.writeReg(Reg.MTA_BASE + i * 4, 0);
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

    /// Enable interrupts
    fn enableInterrupts(self: *Self) void {
        // Configure interrupt coalescing to reduce interrupt frequency under load
        self.configureInterruptThrottle();

        // Enable RX timer, RX descriptor minimum threshold, link status change
        self.writeReg(Reg.IMS, INT.RXT0 | INT.RXDMT0 | INT.LSC);
    }

    /// Enable RX and TX
    fn enableRxTx(self: *Self) void {
        // Enable receiver
        // Accept broadcast, unicast to our MAC, 2048 byte buffers, strip CRC
        const rctl = RCTL.EN | RCTL.BAM | RCTL.BSIZE_2048 | RCTL.SECRC;
        self.writeReg(Reg.RCTL, rctl);

        // Enable transmitter
        // Reference: 82574L Datasheet Section 13.4.37 "Transmit Control Register"
        // Pad short packets, collision threshold and distance for full duplex
        // CT (Collision Threshold) = 15: Standard value for half-duplex (unused in FD)
        // COLD (Collision Distance) = 64: Standard for gigabit (512 bit times)
        const tctl = TCTL.EN | TCTL.PSP |
            (@as(u32, 15) << TCTL.CT_SHIFT) |
            (@as(u32, 64) << TCTL.COLD_SHIFT);
        self.writeReg(Reg.TCTL, tctl);

        // Set link up
        var ctrl = self.readReg(Reg.CTRL);
        ctrl |= CTRL.SLU;
        self.writeReg(Reg.CTRL, ctrl);
    }

    // ========================================================================
    // Packet Transmission
    // ========================================================================

    /// Transmit a packet
    /// Returns true on success, false if TX ring is full
    pub fn transmit(self: *Self, data: []const u8) bool {
        if (data.len > BUFFER_SIZE or data.len == 0) {
            return false;
        }

        const held = self.lock.acquire();
        defer held.release();

        // Check if current descriptor is available
        const desc = &self.tx_ring[self.tx_cur];
        if ((desc.status & TxDesc.STATUS_DD) == 0) {
            // Descriptor not done, TX ring full
            self.tx_dropped += 1;
            return false;
        }

        // Copy data to buffer
        const buf = self.tx_buffers[self.tx_cur];
        @memcpy(buf[0..data.len], data);

        // Set up descriptor
        desc.* = TxDesc{
            .buffer_addr = self.tx_buffers_phys[self.tx_cur],
            .length = @truncate(data.len),
            .cso = 0,
            .cmd = TxDesc.CMD_EOP | TxDesc.CMD_IFCS | TxDesc.CMD_RS,
            .status = 0,
            .css = 0,
            .special = 0,
        };

        // Advance tail pointer
        self.tx_cur = @truncate((@as(u32, self.tx_cur) + 1) % TX_DESC_COUNT);
        // Memory barrier ensures descriptor writes are visible to NIC before tail update
        mmio.writeBarrier();
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
    pub fn processRx(self: *Self, callback: *const fn ([]u8) void) void {
        const held = self.lock.acquire();
        defer held.release();

        while (true) {
            const desc = &self.rx_ring[self.rx_cur];

            // Check if descriptor has a packet
            if ((desc.status & RxDesc.STATUS_DD) == 0) {
                break; // No more packets
            }

            // Check for errors
            if (desc.errors != 0) {
                self.logRxErrors(desc.errors);
            } else if ((desc.status & RxDesc.STATUS_EOP) != 0) {
                // Valid packet received
                // Clamp length to buffer size to prevent OOB access from malicious/faulty hardware
                const len: u16 = @min(desc.length, BUFFER_SIZE);
                const buf = self.rx_buffers[self.rx_cur];

                self.rx_packets += 1;
                self.rx_bytes += len;

                // Call callback with packet data
                callback(buf[0..len]);
            }

            // Reset descriptor for reuse
            desc.status = 0;
            desc.errors = 0;
            desc.length = 0;

            // Update tail pointer to return descriptor to hardware
            const old_cur = self.rx_cur;
            self.rx_cur = @truncate((@as(u32, self.rx_cur) + 1) % RX_DESC_COUNT);

            // Memory barrier ensures descriptor reset is visible to NIC before tail update
            mmio.writeBarrier();
            // Tell hardware about the returned descriptor
            self.writeReg(Reg.RDT, old_cur);
        }
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

    /// Worker thread entry point
    pub fn workerLoop(self: *Self) void {
        while (true) {
            // Disable interrupts to check queue emptiness safely
            // This prevents the race where an ISR runs after we check but before we block
            const flags = hal.cpu.disableInterrupts();
            if (!self.hasPackets()) {
                // Queue is empty, safe to block.
                // sched.block() sets state to .Blocked.
                // If ISR fires after we unlock inside block/yield, unblock() sees .Blocked -> .Ready.
                sched.block();
            }
            hal.cpu.restoreInterrupts(flags);
            
            // Process received packets (drains the ring)
            self.processRx(&defaultRxCallback);
        }
    }

    /// Check if there are packets waiting
    pub fn hasPackets(self: *Self) bool {
        const desc = &self.rx_ring[self.rx_cur];
        return (desc.status & RxDesc.STATUS_DD) != 0;
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
        var tctl = self.readReg(Reg.TCTL);
        tctl &= ~TCTL.EN;
        self.writeReg(Reg.TCTL, tctl);

        // Reset head and tail pointers
        self.writeReg(Reg.TDH, 0);
        self.writeReg(Reg.TDT, 0);
        self.tx_cur = 0;

        // Mark all descriptors as done
        for (0..TX_DESC_COUNT) |i| {
            self.tx_ring[i].status = TxDesc.STATUS_DD;
        }

        // Re-enable transmitter
        tctl |= TCTL.EN;
        self.writeReg(Reg.TCTL, tctl);

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

    /// Handle interrupt from NIC
    pub fn handleIrq(self: *Self) void {
        // Read ICR to get interrupt cause and clear interrupt
        const icr = self.readReg(Reg.ICR);

        if ((icr & INT.RXT0) != 0 or (icr & INT.RXDMT0) != 0) {
            // RX interrupt - wake worker thread
            if (self.worker_thread) |t| {
                sched.unblock(t);
            }
        }

        if ((icr & INT.LSC) != 0) {
            // Link status change - decode speed and duplex
            self.handleLinkChange();
        }
    }

    /// Get MAC address
    pub fn getMacAddress(self: *const Self) [6]u8 {
        return self.mac_addr;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct {
        rx_packets: u64,
        tx_packets: u64,
        rx_bytes: u64,
        tx_bytes: u64,
        rx_errors: u64,
        rx_crc_errors: u64,
        rx_dropped: u64,
        tx_dropped: u64,
    } {
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
    pub fn deinit(self: *Self) void {
        console.info("E1000e: Deinitializing driver", .{});

        // Disable interrupts
        self.writeReg(Reg.IMC, 0xFFFFFFFF);

        // Disable RX and TX
        self.writeReg(Reg.RCTL, 0);
        self.writeReg(Reg.TCTL, 0);

        // Reset device to known state
        self.writeReg(Reg.CTRL, CTRL.RST);

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
            pmm.freePage(self.rx_ring_phys);
            self.rx_ring_phys = 0;
        }
        if (self.tx_ring_phys != 0) {
            pmm.freePage(self.tx_ring_phys);
            self.tx_ring_phys = 0;
        }

        driver_initialized = false;
        console.info("E1000e: Deinitialized", .{});
    }
};

// ============================================================================
// Static Instance and Callbacks
// ============================================================================

/// Static driver instance (for single NIC)
var driver_instance: E1000e = undefined;
var driver_initialized: bool = false;

/// Default RX callback (just logs packets for now)
fn defaultRxCallback(data: []u8) void {
    _ = data;
    // Placeholder - real implementation would pass to network stack
}

/// Get the driver instance (if initialized)
pub fn getDriver() ?*E1000e {
    if (driver_initialized) {
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
fn workerEntry() void {
    if (getDriver()) |driver| {
        driver.workerLoop();
    }
}

/// Initialize E1000e driver for the first found E1000/E1000e NIC
pub fn initFromPci(devices: *const pci.DeviceList, pci_ecam: *const pci.Ecam) !*E1000e {
    // Find E1000/E1000e NIC
    const nic = devices.findE1000() orelse {
        console.err("E1000e: No Intel E1000/E1000e NIC found", .{});
        return error.NoDevice;
    };

    const driver = try E1000e.init(nic, pci_ecam);
    driver_initialized = true;
    return driver;
}
