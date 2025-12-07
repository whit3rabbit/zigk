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

    // Transmit
    pub const TCTL: u64 = 0x0400;       // Transmit Control
    pub const TIPG: u64 = 0x0410;       // TX Inter-Packet Gap
    pub const TDBAL: u64 = 0x3800;      // TX Descriptor Base Low
    pub const TDBAH: u64 = 0x3804;      // TX Descriptor Base High
    pub const TDLEN: u64 = 0x3808;      // TX Descriptor Length
    pub const TDH: u64 = 0x3810;        // TX Descriptor Head
    pub const TDT: u64 = 0x3818;        // TX Descriptor Tail

    // Receive Address (MAC)
    pub const RAL0: u64 = 0x5400;       // Receive Address Low (MAC bytes 0-3)
    pub const RAH0: u64 = 0x5404;       // Receive Address High (MAC bytes 4-5)

    // Multicast Table Array
    pub const MTA_BASE: u64 = 0x5200;   // Multicast Table Array (128 entries)
};

// Device Control Register bits
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
pub const RxDesc = extern struct {
    buffer_addr: u64,       // Physical address of receive buffer
    length: u16,            // Received packet length
    checksum: u16,          // Packet checksum
    status: u8,             // Status bits
    errors: u8,             // Error bits
    special: u16,           // VLAN tag

    pub const STATUS_DD: u8 = 1 << 0;   // Descriptor Done
    pub const STATUS_EOP: u8 = 1 << 1;  // End of Packet
};

/// Legacy TX Descriptor (16 bytes)
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

    /// RX descriptor ring
    rx_ring: [*]RxDesc,
    rx_ring_phys: u64,

    /// TX descriptor ring
    tx_ring: [*]TxDesc,
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
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            if ((self.readReg(Reg.CTRL) & CTRL.RST) == 0) {
                break;
            }
            // Small delay
            var j: usize = 0;
            while (j < 1000) : (j += 1) {
                asm volatile ("pause");
            }
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
        self.rx_ring = @ptrCast(@alignCast(hal.paging.physToVirt(rx_ring_phys)));

        // Allocate TX descriptor ring
        const tx_ring_phys = pmm.allocZeroedPage() orelse {
            return error.OutOfMemory;
        };
        self.tx_ring_phys = tx_ring_phys;
        self.tx_ring = @ptrCast(@alignCast(hal.paging.physToVirt(tx_ring_phys)));

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

        // Set Inter-Packet Gap (standard values for gigabit)
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

    /// Enable interrupts
    fn enableInterrupts(self: *Self) void {
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
        // Pad short packets, collision threshold and distance for full duplex
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
                console.warn("E1000e: RX error {x}", .{desc.errors});
            } else if ((desc.status & RxDesc.STATUS_EOP) != 0) {
                // Valid packet received
                const len = desc.length;
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

            // Tell hardware about the returned descriptor
            self.writeReg(Reg.RDT, old_cur);
        }
    }

    /// Check if there are packets waiting
    pub fn hasPackets(self: *Self) bool {
        const desc = &self.rx_ring[self.rx_cur];
        return (desc.status & RxDesc.STATUS_DD) != 0;
    }

    // ========================================================================
    // Interrupt Handler
    // ========================================================================

    /// Handle interrupt from NIC
    pub fn handleIrq(self: *Self) void {
        // Read ICR to get interrupt cause and clear interrupt
        const icr = self.readReg(Reg.ICR);

        if ((icr & INT.RXT0) != 0 or (icr & INT.RXDMT0) != 0) {
            // RX interrupt - process received packets
            self.processRx(&defaultRxCallback);
        }

        if ((icr & INT.LSC) != 0) {
            // Link status change
            const status = self.readReg(Reg.STATUS);
            const link_up = (status & 2) != 0;
            console.info("E1000e: Link {s}", .{if (link_up) "UP" else "DOWN"});
        }
    }

    /// Get MAC address
    pub fn getMacAddress(self: *const Self) [6]u8 {
        return self.mac_addr;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct { rx_packets: u64, tx_packets: u64, rx_bytes: u64, tx_bytes: u64 } {
        return .{
            .rx_packets = self.rx_packets,
            .tx_packets = self.tx_packets,
            .rx_bytes = self.rx_bytes,
            .tx_bytes = self.tx_bytes,
        };
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
