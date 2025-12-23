//! Intel E1000e (82574L) Network Driver Facade

const pci = @import("pci");
const net = @import("net");
const console = @import("console");

// Internal modules
const types = @import("types.zig");
const init_mod = @import("init.zig");
const rx = @import("rx.zig");
const tx = @import("tx.zig");
const worker = @import("worker.zig");
const regs = @import("regs.zig");
const desc_mod = @import("desc.zig");
const ctl = @import("ctl.zig");
const config = @import("config.zig");
const pool_mod = @import("pool.zig");

// Export submodules
pub const Regs = regs;
pub const Desc = desc_mod;
pub const Ctl = ctl;
pub const Config = config;
pub const Pool = pool_mod;
pub const Rx = rx;
pub const Tx = tx;
pub const Init = init_mod;
pub const Worker = worker;
pub const Types = types;

// Re-export types
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

/// Main E1000e Struct (re-exported from types)
pub const E1000e = types.E1000e;

// ============================================================================
// Public API Functions (Facade)
// ============================================================================

/// Initialize driver for a PCI device
pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*E1000e {
    return init_mod.init(pci_dev, pci_access);
}

/// Initialize driver for first found E1000e device
pub fn initFromPci(devices: *const pci.DeviceList, pci_access: pci.PciAccess) !*E1000e {
    return init_mod.initFromPci(devices, pci_access);
}

/// Get the driver instance (if initialized)
pub fn getDriver() ?*E1000e {
    return init_mod.getDriver();
}

/// IRQ handler entry point (called from HAL)
pub fn irqHandler() void {
    if (init_mod.getDriver()) |driver| {
        // Delegate to worker module which handles IRQ logic and NAPI state
        worker.handleIrq(driver);
    }
}

/// Transmit a packet
pub fn transmit(driver: *E1000e, data: []const u8) bool {
    return tx.transmit(driver, data);
}

/// Transmit a packet asynchronously with IoRequest completion
///
/// Unlike `transmit()` which returns immediately with success/failure,
/// this function queues an IoRequest that will be completed when the
/// hardware finishes transmitting the packet.
///
/// @param driver E1000e driver instance
/// @param data Packet data (copied to descriptor buffer)
/// @param io_request IoRequest to complete on TX completion
/// @return error if packet invalid or ring full
pub fn transmitAsync(driver: *E1000e, data: []const u8, io_request: *@import("io").IoRequest) tx.AsyncTxError!void {
    return tx.transmitAsync(driver, data, io_request);
}

/// Check for TX ring stall and reset if stuck
pub fn checkTxWatchdog(driver: *E1000e) void {
    tx.checkTxWatchdog(driver);
}

/// Update multicast hardware filter
pub fn applyMulticastFilter(driver: *E1000e, iface: *const net.Interface) void {
    init_mod.applyMulticastFilter(driver, iface);
}

/// Process received packets with a budget
pub fn processRxLimited(driver: *E1000e, callback: *const fn ([]u8) void, limit: usize) usize {
    return rx.processRxLimited(driver, callback, limit);
}

/// Process all received packets
pub fn processRx(driver: *E1000e, callback: *const fn ([]u8) void) void {
    rx.processRx(driver, callback);
}

/// Check if there are packets waiting
pub fn hasPackets(driver: *E1000e) bool {
    return rx.hasPackets(driver);
}

/// Set RX callback for packet processing
pub fn setRxCallback(driver: *E1000e, callback: *const fn ([]u8) void) void {
    rx.setRxCallback(driver, callback);
}

/// Get MAC address
pub fn getMacAddress(driver: *const E1000e) [6]u8 {
    return driver.mac_addr;
}

/// Get current link speed in Mbps
pub fn getLinkSpeed(driver: *const E1000e) u16 {
    const status_val = driver.regs.read(.status);
    if ((status_val & regs.STATUS.LU) == 0) return 0; // Link down

    const speed_bits = (status_val & regs.STATUS.SPEED_MASK) >> regs.STATUS.SPEED_SHIFT;
    return switch (speed_bits) {
        0 => 10,
        1 => 100,
        2 => 1000,
        else => 0,
    };
}
