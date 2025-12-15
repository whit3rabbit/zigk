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

// Internal module imports
const regs = @import("regs.zig");
const desc_mod = @import("desc.zig");
const ctl = @import("ctl.zig");
const config = @import("config.zig");
const pool_mod = @import("pool.zig");
const rx = @import("rx.zig");
const tx = @import("tx.zig");

// Re-export submodules for external access
pub const Regs = regs;
pub const Desc = desc_mod;
pub const Ctl = ctl;
pub const Config = config;
pub const Pool = pool_mod;
pub const Rx = rx;
pub const Tx = tx;

// Re-export commonly used types
pub const Reg = regs.Reg;
pub const RxDesc = desc_mod.RxDesc;
pub const TxDesc = desc_mod.TxDesc;
pub const DeviceCtl = ctl.DeviceCtl;
pub const ReceiveCtl = ctl.ReceiveCtl;
pub const TransmitCtl = ctl.TransmitCtl;
pub const InterruptCause = ctl.InterruptCause;
pub const RX_DESC_COUNT = config.RX_DESC_COUNT;
pub const TX_DESC_COUNT = config.TX_DESC_COUNT;
pub const BUFFER_SIZE = config.BUFFER_SIZE;
pub const PACKET_POOL_SIZE = config.PACKET_POOL_SIZE;
pub const PacketPool = pool_mod.PacketPool;
pub const packet_pool = &pool_mod.packet_pool;

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
    /// Callback receives ownership of packet - MUST free via packet_pool.release()
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
    pub fn readReg(self: *const Self, offset: u64) u32 {
        if (offset + 4 > self.mmio_size) {
            @panic("E1000e: MMIO read out of bounds");
        }
        return mmio.read32(self.mmio_base + offset);
    }

    /// Write a 32-bit device register with bounds checking
    /// Panics if offset is outside mapped MMIO region (indicates driver bug)
    pub fn writeReg(self: *Self, offset: u64, value: u32) void {
        if (offset + 4 > self.mmio_size) {
            @panic("E1000e: MMIO write out of bounds");
        }
        mmio.write32(self.mmio_base + offset, value);
    }

    // Typed register accessors for packed structs
    fn readCtrl(self: *const Self) DeviceCtl {
        return DeviceCtl.fromRaw(self.readReg(Reg.CTRL));
    }

    fn writeCtrl(self: *Self, ctrl_val: DeviceCtl) void {
        self.writeReg(Reg.CTRL, ctrl_val.toRaw());
    }

    fn readRctl(self: *const Self) ReceiveCtl {
        return ReceiveCtl.fromRaw(self.readReg(Reg.RCTL));
    }

    fn writeRctl(self: *Self, rctl_val: ReceiveCtl) void {
        self.writeReg(Reg.RCTL, rctl_val.toRaw());
    }

    pub fn readTctl(self: *const Self) TransmitCtl {
        return TransmitCtl.fromRaw(self.readReg(Reg.TCTL));
    }

    pub fn writeTctl(self: *Self, tctl_val: TransmitCtl) void {
        self.writeReg(Reg.TCTL, tctl_val.toRaw());
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
        self.writeReg(Reg.RXCSUM, regs.RXCSUM.IPOFL | regs.RXCSUM.TUOFL);

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
        var rctl_val = self.readRctl();

        const addrs = iface.getMulticastMacs();
        if (iface.accept_all_multicast or addrs.len == 0) {
            rctl_val.multicast_promisc = true;
            self.writeRctl(rctl_val);
            return;
        }

        // Program hash table for joined multicast MACs.
        rctl_val.multicast_promisc = false;
        self.writeRctl(rctl_val);

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
            self.writeReg(Reg.EIMS, regs.INT.RXT0 | regs.INT.RXDMT0 | regs.INT.LSC | regs.INT.TXDW);
        } else {
            // Legacy: Enable RX timer, RX descriptor minimum threshold, link status change
            self.writeReg(Reg.IMS, regs.INT.RXT0 | regs.INT.RXDMT0 | regs.INT.LSC);
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
        var ctrl_val = self.readCtrl();
        ctrl_val.set_link_up = true;
        self.writeCtrl(ctrl_val);
    }

    // ========================================================================
    // Packet Transmission (delegates to tx.zig)
    // ========================================================================

    /// Transmit a packet
    /// Returns true on success, false if TX ring is full or packet invalid
    pub fn transmit(self: *Self, data: []const u8) bool {
        return tx.transmit(self, data);
    }

    /// Check for TX ring stall and reset if stuck
    pub fn checkTxWatchdog(self: *Self) void {
        tx.checkTxWatchdog(self);
    }

    // ========================================================================
    // Packet Reception (delegates to rx.zig)
    // ========================================================================

    /// Process received packets with a budget (NAPI-style polling)
    /// Returns number of packets processed
    pub fn processRxLimited(self: *Self, callback: *const fn ([]u8) void, limit: usize) usize {
        return rx.processRxLimited(self, callback, limit);
    }

    /// Process all received packets (legacy wrapper)
    pub fn processRx(self: *Self, callback: *const fn ([]u8) void) void {
        rx.processRx(self, callback);
    }

    /// Check if there are packets waiting
    pub fn hasPackets(self: *Self) bool {
        return rx.hasPackets(self);
    }

    /// Set RX callback for packet processing
    pub fn setRxCallback(self: *Self, callback: *const fn ([]u8) void) void {
        rx.setRxCallback(self, callback);
    }

    // ========================================================================
    // Worker Thread
    // ========================================================================

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
                self.writeReg(Reg.IMS, regs.INT.RXT0 | regs.INT.RXDMT0);

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

    // ========================================================================
    // Link State
    // ========================================================================

    /// Handle link status change - decode and log speed/duplex
    fn handleLinkChange(self: *Self) void {
        const status = self.readReg(Reg.STATUS);
        const link_up = (status & regs.STATUS.LU) != 0;

        if (link_up) {
            const duplex: []const u8 = if ((status & regs.STATUS.FD) != 0) "Full" else "Half";
            const speed_bits = (status & regs.STATUS.SPEED_MASK) >> regs.STATUS.SPEED_SHIFT;
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
        if ((status & regs.STATUS.LU) == 0) return 0; // Link down

        const speed_bits = (status & regs.STATUS.SPEED_MASK) >> regs.STATUS.SPEED_SHIFT;
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
            self.writeReg(Reg.IMC, regs.INT.RXT0 | regs.INT.RXDMT0);

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
