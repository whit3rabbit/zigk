//! E1000e Driver Types

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const sync = @import("sync");
const thread = @import("thread");
const net = @import("net");
const dma = @import("dma");

const MmioDevice = hal.mmio_device.MmioDevice;
const regs = @import("regs.zig");
const desc_mod = @import("desc.zig");
const ctl = @import("ctl.zig");
const config = @import("config.zig");

pub const Reg = regs.Reg;
pub const RxDesc = desc_mod.RxDesc;
pub const TxDesc = desc_mod.TxDesc;
pub const RX_DESC_COUNT = config.RX_DESC_COUNT;
pub const TX_DESC_COUNT = config.TX_DESC_COUNT;

/// E1000e driver instance
pub const E1000e = struct {
    /// MMIO register access (zero-cost wrapper with comptime validation)
    regs: MmioDevice(Reg),

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

    /// DMA buffer tracking for IOMMU integration
    /// These store both physical and device addresses for proper cleanup
    rx_ring_dma: dma.DmaBuffer,
    tx_ring_dma: dma.DmaBuffer,
    rx_buf_dma: [RX_DESC_COUNT]dma.DmaBuffer,
    tx_buf_dma: [TX_DESC_COUNT]dma.DmaBuffer,
    /// Whether IOMMU-aware DMA is being used
    using_iommu_dma: bool,

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
    msix_table_size: u16,
    /// MSI-X vectors: [0]=RX, [1]=TX, [2]=Other
    msix_vectors: [3]u8,

    /// PCI device reference (for MSI-X configuration)
    pci_dev: *const pci.PciDevice,
    /// PCI access method (ECAM for PCIe or Legacy I/O ports)
    pci_access: pci.PciAccess,

    // Typed register accessors
    pub fn readCtrl(self: *const E1000e) ctl.DeviceCtl {
        return ctl.DeviceCtl.fromRaw(self.regs.read(.ctrl));
    }

    pub fn writeCtrl(self: *E1000e, ctrl_val: ctl.DeviceCtl) void {
        self.regs.write(.ctrl, ctrl_val.toRaw());
    }

    pub fn readRctl(self: *const E1000e) ctl.ReceiveCtl {
        return ctl.ReceiveCtl.fromRaw(self.regs.read(.rctl));
    }

    pub fn writeRctl(self: *E1000e, rctl_val: ctl.ReceiveCtl) void {
        self.regs.write(.rctl, rctl_val.toRaw());
    }

    pub fn readTctl(self: *const E1000e) ctl.TransmitCtl {
        return ctl.TransmitCtl.fromRaw(self.regs.read(.tctl));
    }

    pub fn writeTctl(self: *E1000e, tctl_val: ctl.TransmitCtl) void {
        self.regs.write(.tctl, tctl_val.toRaw());
    }
};
