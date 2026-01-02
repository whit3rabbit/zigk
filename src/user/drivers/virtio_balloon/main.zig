//! VirtIO-Balloon Driver (Userspace)
//!
//! Implements the VirtIO balloon device (device type 5) as defined in
//! OASIS VirtIO Specification 1.2, Section 5.5.
//!
//! The balloon driver enables dynamic memory management between host and guest:
//! - Inflate: Guest gives pages back to host (reduces guest memory)
//! - Deflate: Host returns pages to guest (increases guest memory)
//! - Stats: Report memory statistics to host
//!
//! Key characteristics:
//! - Inflateq (virtqueue 0): Guest-to-host page addresses for inflation
//! - Deflateq (virtqueue 1): Guest-to-host page addresses for deflation
//! - Statsq (virtqueue 2): Memory statistics reporting (optional)
//!
//! Reference: VirtIO Specification 1.2, Section 5.5

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");

// VirtIO-Balloon PCI identifiers
const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_BALLOON_DEVICE_ID_MODERN: u16 = 0x1045; // 0x1040 + 5
const VIRTIO_BALLOON_DEVICE_ID_LEGACY: u16 = 0x1002;

// VirtIO device type for balloon
const VIRTIO_DEVICE_TYPE_BALLOON: u8 = 5;

// VirtIO device status bits
const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
const VIRTIO_STATUS_FAILED: u8 = 128;

// VirtIO balloon feature bits
const VIRTIO_BALLOON_F_MUST_TELL_HOST: u32 = 1 << 0;
const VIRTIO_BALLOON_F_STATS_VQ: u32 = 1 << 1;
const VIRTIO_BALLOON_F_DEFLATE_ON_OOM: u32 = 1 << 2;

// VirtIO balloon config
const VirtioBalloonConfig = extern struct {
    num_pages: u32, // Number of pages host wants in balloon
    actual: u32, // Number of pages actually in balloon
};

// VirtIO PCI capability types
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

// Queue indices
const INFLATE_QUEUE: u16 = 0;
const DEFLATE_QUEUE: u16 = 1;
const STATS_QUEUE: u16 = 2;

// Page size (4KB)
const PAGE_SIZE: usize = 4096;

// Maximum pages to inflate/deflate per operation
const MAX_PAGES_PER_OP: usize = 256;

// Statistics tag definitions
const VIRTIO_BALLOON_S_SWAP_IN: u16 = 0;
const VIRTIO_BALLOON_S_SWAP_OUT: u16 = 1;
const VIRTIO_BALLOON_S_MAJFLT: u16 = 2;
const VIRTIO_BALLOON_S_MINFLT: u16 = 3;
const VIRTIO_BALLOON_S_MEMFREE: u16 = 4;
const VIRTIO_BALLOON_S_MEMTOT: u16 = 5;
const VIRTIO_BALLOON_S_AVAIL: u16 = 6;
const VIRTIO_BALLOON_S_CACHES: u16 = 7;

// Statistics entry
const VirtioBalloonStat = extern struct {
    tag: u16,
    val: u64,
};

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

// Driver state
const DriverState = struct {
    // PCI device info
    pci_device: syscall.PciDeviceInfo,

    // MMIO mapped regions (virtual addresses)
    common_cfg_virt: usize,
    notify_virt: usize,
    device_cfg_virt: usize,

    // Queue memory (DMA)
    inflate_queue_dma: syscall.DmaAllocResult,
    deflate_queue_dma: syscall.DmaAllocResult,

    // Balloon state
    num_pages_in_balloon: u32,
    target_pages: u32,

    // IRQ
    irq: u8,

    // Feature flags
    has_stats_vq: bool,
    deflate_on_oom: bool,

    // Ballooned page tracking (simple array for now)
    balloon_pages: [MAX_PAGES_PER_OP]u64,
    balloon_page_count: usize,
};

var driver_state: DriverState = undefined;
var driver_initialized: bool = false;

pub fn main() void {
    syscall.print("VirtIO-Balloon Driver Starting...\n");

    // Register as service
    syscall.register_service("virtio_balloon") catch |err| {
        printError("Failed to register virtio_balloon service", err);
        return;
    };
    syscall.print("Registered 'virtio_balloon' service\n");

    // Find and initialize VirtIO-Balloon device
    if (!findAndInitDevice()) {
        syscall.print("VirtIO-Balloon: Device not found or initialization failed\n");
        return;
    }

    syscall.print("VirtIO-Balloon: Driver initialized\n");
    driver_initialized = true;

    // Main service loop
    serviceLoop();
}

fn serviceLoop() void {
    while (true) {
        // Sleep for a bit
        syscall.sleep_ms(1000) catch {};

        if (!driver_initialized) continue;

        // Check for target change from host
        checkTargetChange();
    }
}

fn checkTargetChange() void {
    // Read target from device config
    const device_cfg: *volatile VirtioBalloonConfig = @ptrFromInt(driver_state.device_cfg_virt);
    const target = device_cfg.num_pages;

    if (target == driver_state.target_pages) return;

    syscall.print("VirtIO-Balloon: Target changed from ");
    printDec(driver_state.target_pages);
    syscall.print(" to ");
    printDec(target);
    syscall.print(" pages\n");

    driver_state.target_pages = target;

    // Adjust balloon
    if (target > driver_state.num_pages_in_balloon) {
        // Need to inflate (give pages to host)
        const pages_to_add = target - driver_state.num_pages_in_balloon;
        inflate(pages_to_add);
    } else if (target < driver_state.num_pages_in_balloon) {
        // Need to deflate (get pages back from host)
        const pages_to_remove = driver_state.num_pages_in_balloon - target;
        deflate(pages_to_remove);
    }
}

fn inflate(pages_requested: u32) void {
    // Inflate balloon by allocating pages and telling host about them
    // TODO: Allocate pages from kernel and submit to inflate queue
    _ = pages_requested;
    syscall.print("VirtIO-Balloon: Inflate not yet implemented\n");
}

fn deflate(pages_requested: u32) void {
    // Deflate balloon by reclaiming pages from host
    // TODO: Submit page addresses to deflate queue and free them
    _ = pages_requested;
    syscall.print("VirtIO-Balloon: Deflate not yet implemented\n");
}

fn findAndInitDevice() bool {
    // Enumerate PCI devices
    var pci_devices: [32]syscall.PciDeviceInfo = undefined;
    const device_count = syscall.pci_enumerate(&pci_devices) catch {
        syscall.print("VirtIO-Balloon: PCI enumeration failed\n");
        return false;
    };

    for (pci_devices[0..device_count]) |*dev| {
        if (dev.vendor_id == VIRTIO_VENDOR_ID and
            (dev.device_id == VIRTIO_BALLOON_DEVICE_ID_MODERN or
            dev.device_id == VIRTIO_BALLOON_DEVICE_ID_LEGACY))
        {
            syscall.print("VirtIO-Balloon: Found device at ");
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
        syscall.print("VirtIO-Balloon: Failed to map MMIO regions\n");
        return false;
    }

    // Allocate DMA memory for queues
    if (!allocateQueueMemory()) {
        syscall.print("VirtIO-Balloon: Failed to allocate queue memory\n");
        return false;
    }

    // Initialize device per VirtIO spec
    if (!initVirtioDevice()) {
        syscall.print("VirtIO-Balloon: Failed to initialize VirtIO device\n");
        return false;
    }

    // Read initial target
    const device_cfg: *volatile VirtioBalloonConfig = @ptrFromInt(driver_state.device_cfg_virt);
    driver_state.target_pages = device_cfg.num_pages;
    driver_state.num_pages_in_balloon = 0;
    driver_state.balloon_page_count = 0;

    syscall.print("VirtIO-Balloon: Initial target = ");
    printDec(driver_state.target_pages);
    syscall.print(" pages\n");

    return true;
}

fn mapMmioRegions(dev: *const syscall.PciDeviceInfo) bool {
    // Check for capabilities
    const status = pciConfigRead(dev, 0x06);
    if ((status & 0x10) == 0) {
        syscall.print("VirtIO-Balloon: Device does not support capabilities\n");
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
        syscall.print("VirtIO-Balloon: Missing required capabilities\n");
        return false;
    }

    return true;
}

fn allocateQueueMemory() bool {
    // Allocate DMA memory for inflate and deflate queues
    const queue_pages = 4; // 16KB per queue

    driver_state.inflate_queue_dma = syscall.alloc_dma(queue_pages) catch {
        return false;
    };

    driver_state.deflate_queue_dma = syscall.alloc_dma(queue_pages) catch {
        return false;
    };

    return true;
}

fn initVirtioDevice() bool {
    // VirtIO device initialization sequence
    // TODO: Implement full initialization with queue setup
    // For now, just acknowledge the device
    syscall.print("VirtIO-Balloon: Device initialization stub\n");
    return true;
}

fn pciConfigRead(dev: *const syscall.PciDeviceInfo, offset: u12) u32 {
    return syscall.pci_config_read(dev.bus, @truncate(dev.device), @truncate(dev.func), offset) catch 0;
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
