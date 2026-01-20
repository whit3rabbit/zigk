//! SPICE Agent VirtIO-Serial Transport
//!
//! Handles communication with the SPICE host via virtio-serial device.
//! The SPICE agent uses a specific port name "com.redhat.spice.0" for
//! the vdagent channel.
//!
//! Reference: VirtIO Specification 1.2, Section 5.3 (Console Device)

const std = @import("std");
const syscall = @import("syscall");
const protocol = @import("protocol.zig");

// ============================================================================
// VirtIO-Serial PCI Identifiers
// ============================================================================

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_SERIAL_DEVICE_ID_MODERN: u16 = 0x1043; // 0x1040 + 3
const VIRTIO_SERIAL_DEVICE_ID_LEGACY: u16 = 0x1003;

// ============================================================================
// VirtIO Device Status and Features
// ============================================================================

const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
const VIRTIO_STATUS_FAILED: u8 = 128;

/// VirtIO console feature: Multiple ports supported
const VIRTIO_CONSOLE_F_MULTIPORT: u32 = 1 << 1;

// ============================================================================
// VirtIO PCI Capability Types
// ============================================================================

const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

// ============================================================================
// Queue Indices
// ============================================================================

const RECEIVEQ: u16 = 0;
const TRANSMITQ: u16 = 1;
const CONTROLQ: u16 = 2;

// For MULTIPORT: queues 2*port_id and 2*port_id+1 (after control queue)
// Port 0: queues 0, 1
// Control: queue 2
// Port 1: queues 4, 5
// etc.

// ============================================================================
// Control Message Types (for MULTIPORT)
// ============================================================================

const VIRTIO_CONSOLE_DEVICE_READY: u16 = 0;
const VIRTIO_CONSOLE_DEVICE_ADD: u16 = 1;
const VIRTIO_CONSOLE_DEVICE_REMOVE: u16 = 2;
const VIRTIO_CONSOLE_PORT_READY: u16 = 3;
const VIRTIO_CONSOLE_CONSOLE_PORT: u16 = 4;
const VIRTIO_CONSOLE_RESIZE: u16 = 5;
const VIRTIO_CONSOLE_PORT_OPEN: u16 = 6;
const VIRTIO_CONSOLE_PORT_NAME: u16 = 7;

// ============================================================================
// VirtIO Structures
// ============================================================================

const VirtioPciCommonCfg = extern struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    msix_config: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_driver: u64,
    queue_device: u64,
};

const VirtioConsoleConfig = extern struct {
    cols: u16,
    rows: u16,
    max_nr_ports: u32,
    emerg_wr: u32,
};

const VirtioConsoleControl = extern struct {
    id: u32,
    event: u16,
    value: u16,
};

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

// ============================================================================
// Transport State
// ============================================================================

pub const TransportError = error{
    DeviceNotFound,
    InitializationFailed,
    PortNotFound,
    SendFailed,
    ReceiveFailed,
    BufferTooSmall,
    NotInitialized,
};

/// VirtIO-Serial transport state
pub const Transport = struct {
    /// PCI device info
    pci_device: syscall.PciDeviceInfo,

    /// MMIO mapped regions
    common_cfg_virt: usize,
    notify_virt: usize,
    device_cfg_virt: usize,
    notify_offset_multiplier: u32,

    /// Queue memory (DMA)
    rx_queue_dma: syscall.DmaAllocResult,
    tx_queue_dma: syscall.DmaAllocResult,
    ctrl_queue_dma: syscall.DmaAllocResult,

    /// Buffers
    rx_buffer_dma: syscall.DmaAllocResult,
    tx_buffer_dma: syscall.DmaAllocResult,

    /// Port ID for SPICE agent (discovered via port name)
    spice_port_id: u32,

    /// Feature flags
    has_multiport: bool,

    /// Initialization state
    initialized: bool,

    const Self = @This();

    /// Initialize transport by finding and setting up virtio-serial device
    pub fn init() TransportError!Self {
        var self = Self{
            .pci_device = undefined,
            .common_cfg_virt = 0,
            .notify_virt = 0,
            .device_cfg_virt = 0,
            .notify_offset_multiplier = 0,
            .rx_queue_dma = undefined,
            .tx_queue_dma = undefined,
            .ctrl_queue_dma = undefined,
            .rx_buffer_dma = undefined,
            .tx_buffer_dma = undefined,
            .spice_port_id = 0,
            .has_multiport = false,
            .initialized = false,
        };

        // Find VirtIO-Serial device
        if (!self.findDevice()) {
            return TransportError.DeviceNotFound;
        }

        // Map MMIO regions
        if (!self.mapMmioRegions()) {
            return TransportError.InitializationFailed;
        }

        // Allocate DMA memory
        if (!self.allocateQueueMemory()) {
            return TransportError.InitializationFailed;
        }

        // Initialize device
        if (!self.initDevice()) {
            return TransportError.InitializationFailed;
        }

        self.initialized = true;
        return self;
    }

    /// Find VirtIO-Serial PCI device
    fn findDevice(self: *Self) bool {
        var pci_devices: [32]syscall.PciDeviceInfo = undefined;
        const device_count = syscall.pci_enumerate(&pci_devices) catch {
            return false;
        };

        for (pci_devices[0..device_count]) |*dev| {
            if (dev.vendor_id == VIRTIO_VENDOR_ID and
                (dev.device_id == VIRTIO_SERIAL_DEVICE_ID_MODERN or
                dev.device_id == VIRTIO_SERIAL_DEVICE_ID_LEGACY))
            {
                self.pci_device = dev.*;
                return true;
            }
        }

        return false;
    }

    /// Map MMIO regions from PCI capabilities
    fn mapMmioRegions(self: *Self) bool {
        const dev = &self.pci_device;

        // Check for capabilities
        const status = pciConfigRead(dev, 0x06);
        if ((status & 0x10) == 0) {
            return false;
        }

        // Walk capability list
        const cap_ptr_val = pciConfigRead(dev, 0x34);
        var cap_ptr = @as(u8, @truncate(cap_ptr_val)) & 0xFC;

        var common_found = false;
        var notify_found = false;
        var device_found = false;

        while (cap_ptr != 0 and cap_ptr < 0xFF) {
            const cap_header = pciConfigRead(dev, cap_ptr);
            const cap_id = @as(u8, @truncate(cap_header));
            const next_cap = @as(u8, @truncate(cap_header >> 8));

            if (cap_id == 0x09) { // VirtIO vendor-specific
                const cfg_type = @as(u8, @truncate(cap_header >> 24));
                const bar_word = pciConfigRead(dev, cap_ptr + 4);
                const bar_idx = @as(u8, @truncate(bar_word));
                const offset = pciConfigRead(dev, cap_ptr + 8);

                if (bar_idx < 6) {
                    const bar = dev.bar[bar_idx];
                    if (bar.base != 0 and bar.size > 0) {
                        const bar_virt = syscall.mmap_phys(bar.base, @intCast(bar.size)) catch {
                            cap_ptr = next_cap;
                            continue;
                        };
                        const virt_addr = @intFromPtr(bar_virt) + @as(usize, offset);

                        switch (cfg_type) {
                            VIRTIO_PCI_CAP_COMMON_CFG => {
                                self.common_cfg_virt = virt_addr;
                                common_found = true;
                            },
                            VIRTIO_PCI_CAP_NOTIFY_CFG => {
                                self.notify_virt = virt_addr;
                                self.notify_offset_multiplier = pciConfigRead(dev, cap_ptr + 16);
                                notify_found = true;
                            },
                            VIRTIO_PCI_CAP_DEVICE_CFG => {
                                self.device_cfg_virt = virt_addr;
                                device_found = true;
                            },
                            else => {},
                        }
                    }
                }
            }

            cap_ptr = next_cap;
        }

        return common_found and notify_found and device_found;
    }

    /// Allocate DMA memory for queues
    fn allocateQueueMemory(self: *Self) bool {
        const queue_pages = 4; // 16KB per queue

        self.rx_queue_dma = syscall.alloc_dma(queue_pages) catch return false;
        self.tx_queue_dma = syscall.alloc_dma(queue_pages) catch return false;
        self.ctrl_queue_dma = syscall.alloc_dma(queue_pages) catch return false;
        self.rx_buffer_dma = syscall.alloc_dma(2) catch return false; // 8KB RX buffer
        self.tx_buffer_dma = syscall.alloc_dma(2) catch return false; // 8KB TX buffer

        return true;
    }

    /// Initialize VirtIO device
    fn initDevice(self: *Self) bool {
        const common_cfg: *volatile VirtioPciCommonCfg = @ptrFromInt(self.common_cfg_virt);

        // Reset device
        common_cfg.device_status = 0;

        // Acknowledge
        common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE;

        // Driver
        common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;

        // Negotiate features
        common_cfg.device_feature_select = 0;
        const device_features = common_cfg.device_feature;

        var driver_features: u32 = 0;
        if ((device_features & VIRTIO_CONSOLE_F_MULTIPORT) != 0) {
            driver_features |= VIRTIO_CONSOLE_F_MULTIPORT;
            self.has_multiport = true;
        }

        common_cfg.driver_feature_select = 0;
        common_cfg.driver_feature = driver_features;

        // Features OK
        common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK;

        if ((common_cfg.device_status & VIRTIO_STATUS_FEATURES_OK) == 0) {
            common_cfg.device_status = VIRTIO_STATUS_FAILED;
            return false;
        }

        // Setup RX queue
        common_cfg.queue_select = RECEIVEQ;
        if (common_cfg.queue_size == 0) return false;
        common_cfg.queue_desc = self.rx_queue_dma.phys_addr;
        common_cfg.queue_driver = self.rx_queue_dma.phys_addr + 0x1000;
        common_cfg.queue_device = self.rx_queue_dma.phys_addr + 0x2000;
        common_cfg.queue_enable = 1;

        // Setup TX queue
        common_cfg.queue_select = TRANSMITQ;
        if (common_cfg.queue_size == 0) return false;
        common_cfg.queue_desc = self.tx_queue_dma.phys_addr;
        common_cfg.queue_driver = self.tx_queue_dma.phys_addr + 0x1000;
        common_cfg.queue_device = self.tx_queue_dma.phys_addr + 0x2000;
        common_cfg.queue_enable = 1;

        // Setup control queue if multiport
        if (self.has_multiport) {
            common_cfg.queue_select = CONTROLQ;
            if (common_cfg.queue_size > 0) {
                common_cfg.queue_desc = self.ctrl_queue_dma.phys_addr;
                common_cfg.queue_driver = self.ctrl_queue_dma.phys_addr + 0x1000;
                common_cfg.queue_device = self.ctrl_queue_dma.phys_addr + 0x2000;
                common_cfg.queue_enable = 1;
            }
        }

        // Driver OK
        common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
            VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK;

        return true;
    }

    /// Send data to the SPICE host
    pub fn send(self: *Self, data: []const u8) TransportError!void {
        if (!self.initialized) return TransportError.NotInitialized;
        if (data.len > 8192 - @sizeOf(protocol.VDIChunkHeader)) {
            return TransportError.BufferTooSmall;
        }

        // Copy data to TX buffer with VDI chunk header
        const tx_buf: [*]u8 = @ptrFromInt(self.tx_buffer_dma.virt_addr);
        const chunk_hdr = protocol.VDIChunkHeader.init(@intCast(data.len));

        @memcpy(tx_buf[0..@sizeOf(protocol.VDIChunkHeader)], std.mem.asBytes(&chunk_hdr));
        @memcpy(tx_buf[@sizeOf(protocol.VDIChunkHeader)..][0..data.len], data);

        // TODO: Implement proper virtqueue submission
        // For now, this is a stub that prepares the buffer but doesn't send
    }

    /// Receive data from the SPICE host
    pub fn receive(self: *Self, buf: []u8) TransportError!usize {
        if (!self.initialized) return TransportError.NotInitialized;

        // TODO: Implement proper virtqueue polling
        _ = buf;
        return 0;
    }

    /// Check if SPICE port was found
    pub fn isSpicePortFound(self: *const Self) bool {
        return self.initialized and (self.spice_port_id > 0 or !self.has_multiport);
    }
};

/// Helper to read PCI config space
fn pciConfigRead(dev: *const syscall.PciDeviceInfo, offset: u12) u32 {
    return syscall.pci_config_read(dev.bus, @truncate(dev.device), @truncate(dev.func), offset) catch 0;
}
