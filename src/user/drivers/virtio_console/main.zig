//! VirtIO-Console Driver (Userspace)
//!
//! Implements the VirtIO console device (device type 3) as defined in
//! OASIS VirtIO Specification 1.2, Section 5.3.
//!
//! The console driver provides multiple serial ports for VM communication:
//! - Port 0: Primary console (maps to QEMU -serial stdio)
//! - Port 1+: Additional ports (QEMU Guest Agent, etc.)
//!
//! Key characteristics:
//! - Receiveq0 (virtqueue 0): Host-to-guest data for port 0
//! - Transmitq0 (virtqueue 1): Guest-to-host data for port 0
//! - Control (virtqueue 2): Port events (if MULTIPORT feature)
//! - Receiveq1-N, Transmitq1-N: Additional ports (if MULTIPORT)
//!
//! Reference: VirtIO Specification 1.2, Section 5.3

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");

// VirtIO-Console PCI identifiers
const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_CONSOLE_DEVICE_ID_MODERN: u16 = 0x1043; // 0x1040 + 3
const VIRTIO_CONSOLE_DEVICE_ID_LEGACY: u16 = 0x1003;

// VirtIO device type for console
const VIRTIO_DEVICE_TYPE_CONSOLE: u8 = 3;

// VirtIO device status bits
const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
const VIRTIO_STATUS_FAILED: u8 = 128;

// VirtIO console feature bits
const VIRTIO_CONSOLE_F_SIZE: u32 = 1 << 0; // Console size provided
const VIRTIO_CONSOLE_F_MULTIPORT: u32 = 1 << 1; // Multiple ports supported
const VIRTIO_CONSOLE_F_EMERG_WRITE: u32 = 1 << 2; // Emergency write supported

// VirtIO console config
const VirtioConsoleConfig = extern struct {
    cols: u16, // Console width in chars
    rows: u16, // Console height in chars
    max_nr_ports: u32, // Max number of ports (if MULTIPORT)
    emerg_wr: u32, // Emergency write register
};

// VirtIO PCI capability types
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

// Queue indices (for single port mode)
const RECEIVEQ: u16 = 0;
const TRANSMITQ: u16 = 1;
const CONTROLQ: u16 = 2; // Only if MULTIPORT

// Control message types
const VIRTIO_CONSOLE_DEVICE_READY: u16 = 0;
const VIRTIO_CONSOLE_DEVICE_ADD: u16 = 1;
const VIRTIO_CONSOLE_DEVICE_REMOVE: u16 = 2;
const VIRTIO_CONSOLE_PORT_READY: u16 = 3;
const VIRTIO_CONSOLE_CONSOLE_PORT: u16 = 4;
const VIRTIO_CONSOLE_RESIZE: u16 = 5;
const VIRTIO_CONSOLE_PORT_OPEN: u16 = 6;
const VIRTIO_CONSOLE_PORT_NAME: u16 = 7;

// Control message structure
const VirtioConsoleControl = extern struct {
    id: u32, // Port number
    event: u16, // Event type
    value: u16, // Event value
};

// Page size
const PAGE_SIZE: usize = 4096;

// Buffer sizes
const RX_BUFFER_SIZE: usize = 4096;
const TX_BUFFER_SIZE: usize = 4096;

// Virtqueue descriptor
const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

// Virtqueue descriptor flags
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

// Common config structure (memory-mapped)
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

// Port state
const PortState = struct {
    open: bool = false,
    host_connected: bool = false,
    is_console: bool = false,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
};

// Driver state
const DriverState = struct {
    // PCI device info
    pci_device: syscall.PciDeviceInfo,

    // MMIO mapped regions (virtual addresses)
    common_cfg_virt: usize,
    notify_virt: usize,
    device_cfg_virt: usize,
    notify_offset_multiplier: u32,

    // Queue memory (DMA)
    rx_queue_dma: syscall.DmaAllocResult,
    tx_queue_dma: syscall.DmaAllocResult,

    // Receive buffer
    rx_buffer_dma: syscall.DmaAllocResult,

    // IRQ
    irq: u8,

    // Feature flags
    has_multiport: bool,
    has_emerg_write: bool,

    // Console dimensions
    cols: u16,
    rows: u16,

    // Port states (max 8 ports for now)
    ports: [8]PortState,
    max_ports: u32,
};

var driver_state: DriverState = undefined;
var driver_initialized: bool = false;

pub fn main() void {
    syscall.print("VirtIO-Console Driver Starting...\n");

    // Register as service
    syscall.register_service("virtio_console") catch |err| {
        printError("Failed to register virtio_console service", err);
        return;
    };
    syscall.print("Registered 'virtio_console' service\n");

    // Find and initialize VirtIO-Console device
    if (!findAndInitDevice()) {
        syscall.print("VirtIO-Console: Device not found or initialization failed\n");
        return;
    }

    syscall.print("VirtIO-Console: Driver initialized\n");
    driver_initialized = true;

    // Main service loop
    serviceLoop();
}

fn serviceLoop() void {
    var rx_buf: [256]u8 = undefined;

    while (true) {
        // Sleep for a bit
        syscall.sleep_ms(100) catch {};

        if (!driver_initialized) continue;

        // Check for received data
        const received = checkReceive(&rx_buf);
        if (received > 0) {
            // Echo received data for now
            syscall.print("VirtIO-Console: RX ");
            printDec(received);
            syscall.print(" bytes\n");
        }
    }
}

fn checkReceive(buf: []u8) usize {
    // Check if there's data in the receive queue
    // TODO: Implement proper virtqueue polling
    _ = buf;
    return 0;
}

fn transmit(data: []const u8) bool {
    if (!driver_initialized) return false;

    // Submit data to transmit queue
    // TODO: Implement proper virtqueue submission
    _ = data;
    return true;
}

fn findAndInitDevice() bool {
    // Enumerate PCI devices
    var pci_devices: [32]syscall.PciDeviceInfo = undefined;
    const device_count = syscall.pci_enumerate(&pci_devices) catch {
        syscall.print("VirtIO-Console: PCI enumeration failed\n");
        return false;
    };

    for (pci_devices[0..device_count]) |*dev| {
        if (dev.vendor_id == VIRTIO_VENDOR_ID and
            (dev.device_id == VIRTIO_CONSOLE_DEVICE_ID_MODERN or
            dev.device_id == VIRTIO_CONSOLE_DEVICE_ID_LEGACY))
        {
            syscall.print("VirtIO-Console: Found device at ");
            printDec(dev.bus);
            syscall.print(":");
            printDec(dev.device);
            syscall.print(".");
            printDec(dev.func);
            syscall.print("\n");

            driver_state.pci_device = dev.*;
            driver_state.irq = dev.irq_line;

            // Initialize the device
            return initDevice(dev);
        }
    }

    return false;
}

fn initDevice(dev: *const syscall.PciDeviceInfo) bool {
    // Find VirtIO capabilities
    if (!mapMmioRegions(dev)) {
        syscall.print("VirtIO-Console: Failed to map MMIO regions\n");
        return false;
    }

    // Allocate DMA memory for queues
    if (!allocateQueueMemory()) {
        syscall.print("VirtIO-Console: Failed to allocate queue memory\n");
        return false;
    }

    // Initialize device per VirtIO spec
    if (!initVirtioDevice()) {
        syscall.print("VirtIO-Console: Failed to initialize VirtIO device\n");
        return false;
    }

    // Read console config
    const device_cfg: *volatile VirtioConsoleConfig = @ptrFromInt(driver_state.device_cfg_virt);
    driver_state.cols = device_cfg.cols;
    driver_state.rows = device_cfg.rows;

    if (driver_state.has_multiport) {
        driver_state.max_ports = device_cfg.max_nr_ports;
        if (driver_state.max_ports > 8) driver_state.max_ports = 8;
    } else {
        driver_state.max_ports = 1;
    }

    syscall.print("VirtIO-Console: ");
    printDec(driver_state.cols);
    syscall.print("x");
    printDec(driver_state.rows);
    syscall.print(", ");
    printDec(driver_state.max_ports);
    syscall.print(" ports\n");

    // Initialize port states
    for (&driver_state.ports) |*port| {
        port.* = PortState{};
    }
    driver_state.ports[0].open = true; // Port 0 always open

    return true;
}

fn mapMmioRegions(dev: *const syscall.PciDeviceInfo) bool {
    // Check for capabilities
    const status = pciConfigRead(dev, 0x06);
    if ((status & 0x10) == 0) {
        syscall.print("VirtIO-Console: Device does not support capabilities\n");
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
                    // Map BAR
                    const bar_virt = syscall.mmap_phys(bar.base, @intCast(bar.size)) catch continue;
                    const virt_addr = @intFromPtr(bar_virt) + @as(usize, offset);

                    switch (cfg_type) {
                        VIRTIO_PCI_CAP_COMMON_CFG => {
                            driver_state.common_cfg_virt = virt_addr;
                            common_found = true;
                        },
                        VIRTIO_PCI_CAP_NOTIFY_CFG => {
                            driver_state.notify_virt = virt_addr;
                            // Read notify offset multiplier from cap_ptr + 16
                            driver_state.notify_offset_multiplier = pciConfigRead(dev, cap_ptr + 16);
                            notify_found = true;
                        },
                        VIRTIO_PCI_CAP_DEVICE_CFG => {
                            driver_state.device_cfg_virt = virt_addr;
                            device_found = true;
                        },
                        else => {},
                    }
                }
            }
        }

        cap_ptr = next_cap;
    }

    if (!common_found or !notify_found or !device_found) {
        syscall.print("VirtIO-Console: Missing required capabilities\n");
        return false;
    }

    return true;
}

fn allocateQueueMemory() bool {
    // Allocate DMA memory for RX and TX queues
    const queue_pages = 4; // 16KB per queue

    driver_state.rx_queue_dma = syscall.alloc_dma(queue_pages) catch {
        return false;
    };

    driver_state.tx_queue_dma = syscall.alloc_dma(queue_pages) catch {
        return false;
    };

    // Allocate receive buffer
    driver_state.rx_buffer_dma = syscall.alloc_dma(1) catch {
        return false;
    };

    return true;
}

fn initVirtioDevice() bool {
    const common_cfg: *volatile VirtioPciCommonCfg = @ptrFromInt(driver_state.common_cfg_virt);

    // 1. Reset device
    common_cfg.device_status = 0;

    // 2. Acknowledge
    common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE;

    // 3. Driver
    common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;

    // 4. Negotiate features
    common_cfg.device_feature_select = 0;
    const device_features = common_cfg.device_feature;

    var driver_features: u32 = 0;
    if ((device_features & VIRTIO_CONSOLE_F_SIZE) != 0) {
        driver_features |= VIRTIO_CONSOLE_F_SIZE;
    }
    if ((device_features & VIRTIO_CONSOLE_F_MULTIPORT) != 0) {
        driver_features |= VIRTIO_CONSOLE_F_MULTIPORT;
        driver_state.has_multiport = true;
    }
    if ((device_features & VIRTIO_CONSOLE_F_EMERG_WRITE) != 0) {
        driver_features |= VIRTIO_CONSOLE_F_EMERG_WRITE;
        driver_state.has_emerg_write = true;
    }

    common_cfg.driver_feature_select = 0;
    common_cfg.driver_feature = driver_features;

    // 5. Features OK
    common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK;

    // Verify features accepted
    if ((common_cfg.device_status & VIRTIO_STATUS_FEATURES_OK) == 0) {
        syscall.print("VirtIO-Console: Feature negotiation failed\n");
        common_cfg.device_status = VIRTIO_STATUS_FAILED;
        return false;
    }

    // 6. Set up queues
    // RX queue
    common_cfg.queue_select = RECEIVEQ;
    const rx_queue_size = common_cfg.queue_size;
    if (rx_queue_size == 0) {
        syscall.print("VirtIO-Console: RX queue not available\n");
        return false;
    }
    common_cfg.queue_desc = driver_state.rx_queue_dma.phys_addr;
    common_cfg.queue_driver = driver_state.rx_queue_dma.phys_addr + 0x1000;
    common_cfg.queue_device = driver_state.rx_queue_dma.phys_addr + 0x2000;
    common_cfg.queue_enable = 1;

    // TX queue
    common_cfg.queue_select = TRANSMITQ;
    const tx_queue_size = common_cfg.queue_size;
    if (tx_queue_size == 0) {
        syscall.print("VirtIO-Console: TX queue not available\n");
        return false;
    }
    common_cfg.queue_desc = driver_state.tx_queue_dma.phys_addr;
    common_cfg.queue_driver = driver_state.tx_queue_dma.phys_addr + 0x1000;
    common_cfg.queue_device = driver_state.tx_queue_dma.phys_addr + 0x2000;
    common_cfg.queue_enable = 1;

    // 7. Driver OK
    common_cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
        VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK;

    syscall.print("VirtIO-Console: Device initialized\n");
    return true;
}

fn pciConfigRead(dev: *const syscall.PciDeviceInfo, offset: u12) u32 {
    return syscall.pci_config_read(dev.bus, @truncate(dev.device), @truncate(dev.func), offset) catch 0;
}

// Public API for other services (like QEMU Guest Agent)

pub fn openPort(port_id: u32) bool {
    if (port_id >= driver_state.max_ports) return false;
    if (!driver_initialized) return false;

    driver_state.ports[port_id].open = true;
    return true;
}

pub fn closePort(port_id: u32) void {
    if (port_id >= driver_state.max_ports) return;
    if (port_id == 0) return; // Cannot close port 0

    driver_state.ports[port_id].open = false;
}

pub fn writePort(port_id: u32, data: []const u8) usize {
    if (port_id >= driver_state.max_ports) return 0;
    if (!driver_initialized) return 0;
    if (!driver_state.ports[port_id].open) return 0;

    // For now, only port 0 works (single queue mode)
    if (port_id != 0 and !driver_state.has_multiport) return 0;

    if (transmit(data)) {
        return data.len;
    }
    return 0;
}

pub fn readPort(port_id: u32, buf: []u8) usize {
    if (port_id >= driver_state.max_ports) return 0;
    if (!driver_initialized) return 0;
    if (!driver_state.ports[port_id].open) return 0;

    // For now, only port 0 works
    if (port_id != 0 and !driver_state.has_multiport) return 0;

    return checkReceive(buf);
}

// Helper functions

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printDec(value: u64) void {
    if (value == 0) {
        syscall.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    syscall.print(buf[i..]);
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}
