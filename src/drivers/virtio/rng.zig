//! VirtIO-RNG (Entropy Device) Driver
//!
//! Implements the VirtIO entropy device (device type 4) as defined in
//! OASIS VirtIO Specification 1.2, Section 5.4.
//!
//! This driver provides hardware entropy from the hypervisor to the kernel's
//! random number generator subsystem.
//!
//! Key characteristics:
//! - Single virtqueue (requestq at index 0)
//! - No device-specific feature bits
//! - No device configuration space
//! - Simple protocol: submit empty buffers, device fills with random bytes

const std = @import("std");
const pci = @import("pci");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const console = @import("console");
const virtio = @import("root.zig");
const common = @import("common.zig");

/// VirtIO-RNG PCI identifiers
pub const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
pub const VIRTIO_RNG_DEVICE_ID_MODERN: u16 = 0x1044; // 0x1040 + device_type(4)
pub const VIRTIO_RNG_DEVICE_ID_LEGACY: u16 = 0x1005;

/// VirtIO device type for entropy device
pub const VIRTIO_DEVICE_TYPE_RNG: u8 = 4;

/// Request buffer size (256 bytes is a good balance)
const REQUEST_BUFFER_SIZE: usize = 256;

/// Number of buffers to keep in flight
const NUM_BUFFERS: usize = 4;

/// VirtIO-RNG Driver
pub const VirtioRngDriver = struct {
    /// Virtqueue for random data requests
    vq: common.Virtqueue,

    /// Common configuration MMIO pointer
    common_cfg: *volatile common.VirtioPciCommonCfg,

    /// Notify register MMIO address
    notify_addr: u64,

    /// ISR status register address
    isr_addr: u64,

    /// Pre-allocated request buffers
    buffers: [NUM_BUFFERS][REQUEST_BUFFER_SIZE]u8,

    /// Tracks which buffers are currently in use
    buffer_in_use: [NUM_BUFFERS]bool,

    /// PCI device reference
    pci_dev: pci.PciDevice,

    /// Whether the driver is initialized and ready
    ready: bool,

    const Self = @This();

    /// Global singleton instance
    var instance: Self = undefined;
    var initialized: bool = false;

    /// Initialize VirtIO-RNG driver
    pub fn init() ?*Self {
        if (initialized) return &instance;

        // Find VirtIO-RNG device on PCI bus
        const devices = pci.getDevices() orelse return null;

        for (devices.devices[0..devices.count]) |*dev| {
            if (dev.vendor_id == VIRTIO_VENDOR_ID and
                (dev.device_id == VIRTIO_RNG_DEVICE_ID_MODERN or
                dev.device_id == VIRTIO_RNG_DEVICE_ID_LEGACY))
            {
                // Found VirtIO-RNG device
                if (initDevice(dev)) {
                    initialized = true;
                    return &instance;
                }
            }
        }

        return null;
    }

    /// Initialize the device
    fn initDevice(dev: *const pci.PciDevice) bool {
        const ecam = pci.getEcam() orelse return false;

        // Enable bus mastering and memory access
        const cmd_reg = ecam.read16(dev.bus, dev.device, dev.func, 0x04);
        ecam.write16(dev.bus, dev.device, dev.func, 0x04, cmd_reg | 0x7);

        // Find VirtIO capabilities in PCI config space
        const caps = findVirtioCapabilities(dev, ecam) orelse return false;

        // Map common configuration space
        const common_cfg_virt = vmm.mapMmioExplicit(caps.common_cfg_phys, 0x1000) catch return false;
        instance.common_cfg = @ptrFromInt(common_cfg_virt);

        instance.notify_addr = vmm.mapMmioExplicit(caps.notify_phys, 0x1000) catch return false;
        instance.isr_addr = vmm.mapMmioExplicit(caps.isr_phys, 0x1000) catch return false;

        // Reset device
        instance.common_cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        // Acknowledge device
        instance.common_cfg.device_status = common.VIRTIO_STATUS_ACKNOWLEDGE;

        // Indicate driver loaded
        instance.common_cfg.device_status |= common.VIRTIO_STATUS_DRIVER;

        // Feature negotiation - VirtIO-RNG has no device-specific features
        // Only negotiate VIRTIO_F_VERSION_1 for modern devices
        instance.common_cfg.device_feature_select = 1; // High 32 bits
        const device_features_hi = instance.common_cfg.device_feature;

        instance.common_cfg.driver_feature_select = 1;
        instance.common_cfg.driver_feature = device_features_hi & (1 << (common.VIRTIO_F_VERSION_1 - 32));

        // Set FEATURES_OK
        instance.common_cfg.device_status |= common.VIRTIO_STATUS_FEATURES_OK;
        hal.mmio.memoryBarrier();

        // Verify FEATURES_OK is still set
        if ((instance.common_cfg.device_status & common.VIRTIO_STATUS_FEATURES_OK) == 0) {
            console.err("VirtIO-RNG: Feature negotiation failed", .{});
            instance.common_cfg.device_status |= common.VIRTIO_STATUS_FAILED;
            return false;
        }

        // Initialize virtqueue 0 (requestq)
        instance.common_cfg.queue_select = 0;
        const queue_size = instance.common_cfg.queue_size;

        if (queue_size == 0) {
            console.err("VirtIO-RNG: Queue size is 0", .{});
            return false;
        }

        // Limit queue size to 256 (our VirtqAvail/VirtqUsed have fixed 256 entries)
        const actual_size: u16 = if (queue_size > 256) 256 else queue_size;

        instance.vq = common.Virtqueue.init(actual_size) orelse {
            console.err("VirtIO-RNG: Failed to allocate virtqueue", .{});
            return false;
        };

        // Configure queue addresses
        instance.common_cfg.queue_desc = instance.vq.desc_phys;
        instance.common_cfg.queue_avail = instance.vq.avail_phys;
        instance.common_cfg.queue_used = instance.vq.used_phys;
        instance.common_cfg.queue_enable = 1;

        // Set DRIVER_OK - device is ready
        instance.common_cfg.device_status |= common.VIRTIO_STATUS_DRIVER_OK;
        hal.mmio.memoryBarrier();

        // Initialize buffer tracking
        for (&instance.buffer_in_use) |*in_use| {
            in_use.* = false;
        }
        for (&instance.buffers) |*buf| {
            @memset(buf, 0);
        }

        instance.pci_dev = dev.*;
        instance.ready = true;

        console.info("VirtIO-RNG: Initialized successfully (queue_size={d})", .{actual_size});
        return true;
    }

    /// Find VirtIO PCI capabilities
    fn findVirtioCapabilities(dev: *const pci.PciDevice, ecam: pci.Ecam) ?struct {
        common_cfg_phys: u64,
        notify_phys: u64,
        isr_phys: u64,
    } {
        // Read capabilities pointer from PCI config (offset 0x34)
        var cap_ptr = ecam.read8(dev.bus, dev.device, dev.func, 0x34);

        var common_cfg_phys: u64 = 0;
        var notify_phys: u64 = 0;
        var isr_phys: u64 = 0;

        while (cap_ptr != 0) {
            const cap_id = ecam.read8(dev.bus, dev.device, dev.func, cap_ptr);
            const cap_next = ecam.read8(dev.bus, dev.device, dev.func, cap_ptr + 1);

            // VirtIO uses capability ID 0x09 (vendor-specific)
            if (cap_id == 0x09) {
                const cfg_type = ecam.read8(dev.bus, dev.device, dev.func, cap_ptr + 3);
                const bar_idx = ecam.read8(dev.bus, dev.device, dev.func, cap_ptr + 4);
                const offset = ecam.read32(dev.bus, dev.device, dev.func, @intCast(cap_ptr + 8));

                if (bar_idx < 6) {
                    const bar = dev.bar[bar_idx];
                    if (bar.size > 0) {
                        const phys_addr = (bar.base & 0xFFFFFFFFFFFFFFF0) + offset;

                        switch (cfg_type) {
                            common.VIRTIO_PCI_CAP_COMMON_CFG => common_cfg_phys = phys_addr,
                            common.VIRTIO_PCI_CAP_NOTIFY_CFG => notify_phys = phys_addr,
                            common.VIRTIO_PCI_CAP_ISR_CFG => isr_phys = phys_addr,
                            else => {},
                        }
                    }
                }
            }

            cap_ptr = cap_next;
        }

        if (common_cfg_phys == 0 or notify_phys == 0 or isr_phys == 0) {
            return null;
        }

        return .{
            .common_cfg_phys = common_cfg_phys,
            .notify_phys = notify_phys,
            .isr_phys = isr_phys,
        };
    }

    /// Request random bytes from the device
    /// Returns number of bytes received, or error
    pub fn getEntropy(self: *Self, buffer: []u8) !usize {
        if (!self.ready) return error.NotReady;
        if (buffer.len == 0) return 0;

        // Zero-initialize buffer before DMA (security: prevents info leak)
        @memset(buffer, 0);

        // Find a free internal buffer
        var buf_idx: ?usize = null;
        for (self.buffer_in_use, 0..) |in_use, i| {
            if (!in_use) {
                buf_idx = i;
                break;
            }
        }

        if (buf_idx == null) {
            // All buffers in use, try to reclaim one
            if (self.vq.getUsed()) |result| {
                // A buffer completed
                const idx = result.head % NUM_BUFFERS;
                self.buffer_in_use[idx] = false;
                buf_idx = idx;
            } else {
                return error.ResourceBusy;
            }
        }

        const idx = buf_idx.?;
        self.buffer_in_use[idx] = true;

        // Zero the internal buffer
        @memset(&self.buffers[idx], 0);

        // Create slice for the buffer
        const buf_slice: []u8 = &self.buffers[idx];

        // Add buffer to virtqueue (device-writable only for RNG)
        const in_bufs: [1][]u8 = .{buf_slice};
        const out_bufs: [0][]const u8 = .{};

        _ = self.vq.addBuf(&out_bufs, &in_bufs) orelse {
            self.buffer_in_use[idx] = false;
            return error.VirtqueueFull;
        };

        // Notify device
        self.vq.kick(self.notify_addr);

        // Wait for completion (polling - could be made interrupt-driven)
        var timeout: u32 = 100000;
        while (!self.vq.hasPending() and timeout > 0) : (timeout -= 1) {
            hal.cpu.pause();
        }

        if (timeout == 0) {
            self.buffer_in_use[idx] = false;
            return error.Timeout;
        }

        // Get result
        const result = self.vq.getUsed() orelse {
            self.buffer_in_use[idx] = false;
            return error.DeviceError;
        };

        self.buffer_in_use[idx] = false;

        // Copy received bytes to output buffer
        const bytes_received: usize = @min(result.len, @as(u32, @intCast(buffer.len)));
        if (bytes_received > 0 and bytes_received <= REQUEST_BUFFER_SIZE) {
            @memcpy(buffer[0..bytes_received], self.buffers[idx][0..bytes_received]);
        }

        return bytes_received;
    }

    /// Check if driver is available and ready
    pub fn isAvailable() bool {
        return initialized and instance.ready;
    }

    /// Get the driver instance
    pub fn getInstance() ?*Self {
        if (initialized) return &instance;
        return null;
    }
};

/// Feed entropy from VirtIO-RNG to kernel entropy pool
pub fn feedKernelEntropy() void {
    const driver = VirtioRngDriver.getInstance() orelse return;

    var buffer: [REQUEST_BUFFER_SIZE]u8 = undefined;
    const bytes_read = driver.getEntropy(&buffer) catch return;

    if (bytes_read == 0) return;

    // Mix into kernel entropy pool
    // Import the kernel random module to feed entropy
    const random = @import("prng");
    var i: usize = 0;
    while (i + 8 <= bytes_read) : (i += 8) {
        const val = std.mem.readInt(u64, buffer[i..][0..8], .little);
        random.mixEntropy(val);
    }

    // Handle remaining bytes
    if (i < bytes_read) {
        var remaining: [8]u8 = .{0} ** 8;
        @memcpy(remaining[0..(bytes_read - i)], buffer[i..bytes_read]);
        random.mixEntropy(std.mem.readInt(u64, &remaining, .little));
    }
}
