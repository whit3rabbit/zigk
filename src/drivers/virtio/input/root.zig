// VirtIO-Input Driver
//
// Provides input device support for VirtIO-Input devices (keyboard, mouse, tablet).
// This is a kernel driver that receives events from the hypervisor and pushes
// them to the unified input subsystem.
//
// Supports:
// - Keyboards: Key press/release events
// - Mice: Relative movement (dx/dy) and buttons
// - Tablets: Absolute positioning with axis range scaling
//
// Reference: VirtIO Specification 1.1, Section 5.8

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const sync = @import("sync");
const virtio = @import("virtio");
const input = @import("input");
const uapi = @import("uapi");

pub const config = @import("config.zig");
pub const irq = @import("irq.zig");

// =============================================================================
// Error Types
// =============================================================================

pub const InputError = error{
    NotVirtioInput,
    InvalidBar,
    MappingFailed,
    CapabilityNotFound,
    ResetFailed,
    FeatureNegotiationFailed,
    QueueAllocationFailed,
    AllocationFailed,
    BufferAllocationFailed,
    DeviceNotReady,
};

// =============================================================================
// Device Type Detection
// =============================================================================

/// Detected device type based on event capabilities
pub const DeviceType = enum {
    /// Keyboard device (has EV_KEY with keyboard keys)
    keyboard,
    /// Mouse device (has EV_REL for relative movement)
    mouse,
    /// Tablet device (has EV_ABS for absolute positioning)
    tablet,
    /// Unknown device type
    unknown,
};

// =============================================================================
// Driver State
// =============================================================================

/// VirtIO-Input driver instance
pub const VirtioInputDriver = struct {
    /// VirtIO common configuration MMIO
    common_cfg: *volatile virtio.VirtioPciCommonCfg,

    /// Device-specific configuration space
    device_cfg: *volatile config.VirtioInputConfig,

    /// Notify register base address
    notify_base: u64,

    /// Notify offset multiplier
    notify_off_mult: u32,

    /// ISR status register address
    isr_addr: u64,

    /// Event virtqueue (device writes events, driver reads)
    event_queue: virtio.Virtqueue,

    /// Status virtqueue (driver writes LED updates, etc.) - optional
    status_queue: ?virtio.Virtqueue,

    /// Notify address for event queue
    event_notify_addr: u64,

    /// Pre-allocated event buffers
    event_buffer_base_virt: u64,
    event_buffer_base_phys: u64,

    /// Detected device type
    device_type: DeviceType,

    /// Device name (from ID_NAME query, null-terminated)
    device_name: [128]u8,
    device_name_len: u8,

    /// Input subsystem device ID (from registerDevice)
    input_device_id: u16,

    /// Absolute axis info (for tablets)
    abs_x_info: ?config.VirtioInputAbsInfo,
    abs_y_info: ?config.VirtioInputAbsInfo,

    /// Pending absolute X value (wait for Y before updating cursor)
    pending_abs_x: ?u32,

    /// MSI-X vector (null if using polling)
    msix_vector: ?u8,

    /// PCI device reference
    pci_dev: *const pci.PciDevice,

    /// Initialization complete flag
    initialized: bool,

    /// Lock for thread-safe access
    lock: sync.Spinlock,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize driver from PCI device
    pub fn init(self: *Self, pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) InputError!void {
        self.pci_dev = pci_dev;
        self.initialized = false;
        self.device_type = .unknown;
        self.device_name_len = 0;
        self.input_device_id = 0;
        self.abs_x_info = null;
        self.abs_y_info = null;
        self.pending_abs_x = null;
        self.msix_vector = null;
        self.status_queue = null;
        self.lock = .{};

        // Zero device name
        @memset(&self.device_name, 0);

        // Verify device type
        if (!isVirtioInput(pci_dev)) {
            return error.NotVirtioInput;
        }

        // Get ECAM access
        const ecam = switch (pci_access) {
            .ecam => |e| e,
            .legacy => {
                console.err("VirtIO-Input: Legacy PCI access not supported", .{});
                return error.InvalidBar;
            },
        };

        // Enable bus mastering and memory space
        ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Parse VirtIO capabilities and map MMIO regions
        try self.parseCapabilities(pci_dev, ecam);

        // Initialize device per VirtIO spec
        try self.initializeDevice();

        // Query device configuration to determine type
        self.queryDeviceConfig();

        // Register with input subsystem
        self.registerWithInputSubsystem();

        self.initialized = true;

        const type_str = switch (self.device_type) {
            .keyboard => "keyboard",
            .mouse => "mouse",
            .tablet => "tablet",
            .unknown => "unknown",
        };

        console.info("VirtIO-Input: Initialized {s} device '{s}'", .{
            type_str,
            self.device_name[0..self.device_name_len],
        });
    }

    /// Parse VirtIO PCI capabilities and map MMIO regions
    fn parseCapabilities(self: *Self, pci_dev: *const pci.PciDevice, ecam: pci.Ecam) InputError!void {
        // Check if capabilities are supported
        const status = ecam.read16(pci_dev.bus, pci_dev.device, pci_dev.func, 0x06);
        if ((status & 0x10) == 0) {
            return error.CapabilityNotFound;
        }

        // Get initial capability pointer from offset 0x34
        var cap_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, 0x34);
        cap_ptr &= 0xFC; // Align to DWORD

        var common_found = false;
        var notify_found = false;
        var device_found = false;

        // Iterate through capabilities
        while (cap_ptr != 0) {
            const cap_id = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr);
            const next_ptr = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 1);

            if (cap_id == 0x09) { // VirtIO vendor-specific capability
                const cfg_type = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 3);
                const bar_idx = ecam.read8(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 4);
                const offset = ecam.read32(pci_dev.bus, pci_dev.device, pci_dev.func, cap_ptr + 8);

                if (bar_idx > 5) {
                    cap_ptr = next_ptr;
                    continue;
                }

                const bar = pci_dev.bar[bar_idx];
                if (!bar.isValid() or !bar.is_mmio) {
                    cap_ptr = next_ptr;
                    continue;
                }

                // Security: Validate offset + structure size fits within BAR
                // A malicious hypervisor could provide an offset that exceeds BAR size,
                // causing kernel memory corruption when dereferencing the computed address.
                const bar_size = bar.size;
                const struct_size: u64 = switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => @sizeOf(virtio.VirtioPciCommonCfg),
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => 4, // Minimum notify size
                    virtio.common.VIRTIO_PCI_CAP_ISR_CFG => 4, // ISR is at least 1 byte, align to 4
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => @sizeOf(config.VirtioInputConfig),
                    else => 0,
                };
                if (struct_size > 0 and (offset > bar_size or struct_size > bar_size - offset)) {
                    console.warn("VirtIO-Input: Capability offset {x} + size {x} exceeds BAR{d} size {x}", .{ offset, struct_size, bar_idx, bar_size });
                    cap_ptr = next_ptr;
                    continue;
                }

                // Map BAR if not already mapped
                const bar_virt = vmm.mapMmio(bar.base, bar.size) catch {
                    cap_ptr = next_ptr;
                    continue;
                };

                const virt_addr = bar_virt + offset;

                switch (cfg_type) {
                    virtio.common.VIRTIO_PCI_CAP_COMMON_CFG => {
                        self.common_cfg = @ptrFromInt(virt_addr);
                        common_found = true;
                    },
                    virtio.common.VIRTIO_PCI_CAP_NOTIFY_CFG => {
                        self.notify_base = virt_addr;
                        self.notify_off_mult = ecam.read32(
                            pci_dev.bus,
                            pci_dev.device,
                            pci_dev.func,
                            cap_ptr + 16,
                        );
                        notify_found = true;
                    },
                    virtio.common.VIRTIO_PCI_CAP_ISR_CFG => {
                        self.isr_addr = virt_addr;
                    },
                    virtio.common.VIRTIO_PCI_CAP_DEVICE_CFG => {
                        self.device_cfg = @ptrFromInt(virt_addr);
                        device_found = true;
                    },
                    else => {},
                }
            }

            cap_ptr = next_ptr;
        }

        if (!common_found or !notify_found or !device_found) {
            console.err("VirtIO-Input: Missing required capabilities", .{});
            return error.CapabilityNotFound;
        }
    }

    /// Initialize device per VirtIO spec 3.1.1
    fn initializeDevice(self: *Self) InputError!void {
        // 1. Reset device
        self.common_cfg.device_status = 0;
        hal.mmio.memoryBarrier();

        // Wait for reset to complete
        var timeout: u32 = 1000;
        while (self.common_cfg.device_status != 0 and timeout > 0) : (timeout -= 1) {
            hal.cpu.pause();
        }

        // 2. Set ACKNOWLEDGE
        self.common_cfg.device_status = virtio.VIRTIO_STATUS_ACKNOWLEDGE;
        hal.mmio.memoryBarrier();

        // 3. Set DRIVER
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER;
        hal.mmio.memoryBarrier();

        // 4. Negotiate features (VirtIO-Input has no device-specific features)
        try self.negotiateFeatures();

        // 5. Set FEATURES_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_FEATURES_OK;
        hal.mmio.memoryBarrier();

        // 6. Verify FEATURES_OK
        if ((self.common_cfg.device_status & virtio.VIRTIO_STATUS_FEATURES_OK) == 0) {
            self.common_cfg.device_status |= virtio.VIRTIO_STATUS_FAILED;
            return error.FeatureNegotiationFailed;
        }

        // 7. Set up virtqueues
        try self.setupVirtqueues();

        // 8. Pre-allocate and submit event buffers
        try self.preallocateEventBuffers();

        // 9. Set DRIVER_OK
        self.common_cfg.device_status |= virtio.VIRTIO_STATUS_DRIVER_OK;
        hal.mmio.memoryBarrier();
    }

    /// Negotiate features with device
    fn negotiateFeatures(self: *Self) InputError!void {
        // Read device features (high 32 bits where VIRTIO_F_VERSION_1 lives)
        self.common_cfg.device_feature_select = 1;
        hal.mmio.memoryBarrier();
        const device_features_hi = self.common_cfg.device_feature;

        // Check for VIRTIO_F_VERSION_1 (bit 0 of high word = bit 32 overall)
        if ((device_features_hi & 1) == 0) {
            console.err("VirtIO-Input: VIRTIO_F_VERSION_1 not supported", .{});
            return error.FeatureNegotiationFailed;
        }

        // Accept only VIRTIO_F_VERSION_1
        self.common_cfg.driver_feature_select = 1;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = 1; // Accept VERSION_1

        // Low 32 bits: no features
        self.common_cfg.driver_feature_select = 0;
        hal.mmio.memoryBarrier();
        self.common_cfg.driver_feature = 0;
    }

    /// Set up virtqueues
    fn setupVirtqueues(self: *Self) InputError!void {
        const num_queues = self.common_cfg.num_queues;

        if (num_queues < 1) {
            console.err("VirtIO-Input: No queues available", .{});
            return error.QueueAllocationFailed;
        }

        // Event queue (queue 0) - required
        self.common_cfg.queue_select = config.QueueIndex.EVENTS;
        hal.mmio.memoryBarrier();

        const event_queue_size = self.common_cfg.queue_size;
        if (event_queue_size == 0) {
            return error.QueueAllocationFailed;
        }

        const actual_size: u16 = @min(event_queue_size, 256);
        self.event_queue = virtio.Virtqueue.init(actual_size) orelse
            return error.QueueAllocationFailed;

        // Configure queue addresses
        self.common_cfg.queue_desc = self.event_queue.desc_phys;
        self.common_cfg.queue_avail = self.event_queue.avail_phys;
        self.common_cfg.queue_used = self.event_queue.used_phys;
        self.common_cfg.queue_enable = 1;
        hal.mmio.memoryBarrier();

        // Calculate notify address with checked arithmetic
        // A malicious hypervisor could provide values that overflow
        const notify_off = self.common_cfg.queue_notify_off;
        const offset = std.math.mul(u64, notify_off, self.notify_off_mult) catch {
            console.err("VirtIO-Input: notify offset overflow", .{});
            return error.InvalidBar;
        };
        self.event_notify_addr = std.math.add(u64, self.notify_base, offset) catch {
            console.err("VirtIO-Input: notify address overflow", .{});
            return error.InvalidBar;
        };

        // Status queue (queue 1) - optional, for LED updates
        if (num_queues >= 2) {
            self.common_cfg.queue_select = config.QueueIndex.STATUS;
            hal.mmio.memoryBarrier();

            const status_queue_size = self.common_cfg.queue_size;
            if (status_queue_size > 0) {
                const status_size: u16 = @min(status_queue_size, 64);
                self.status_queue = virtio.Virtqueue.init(status_size);
                if (self.status_queue) |*sq| {
                    self.common_cfg.queue_desc = sq.desc_phys;
                    self.common_cfg.queue_avail = sq.avail_phys;
                    self.common_cfg.queue_used = sq.used_phys;
                    self.common_cfg.queue_enable = 1;
                    hal.mmio.memoryBarrier();
                }
            }
        }
    }

    /// Pre-allocate event buffers and submit to device
    fn preallocateEventBuffers(self: *Self) InputError!void {
        // Calculate pages needed for event buffers
        const event_size = @sizeOf(config.VirtioInputEvent);
        const total_size = config.EVENT_BUFFER_COUNT * event_size;
        const pages_needed = (total_size + 4095) / 4096;

        // Allocate zeroed physical pages
        const phys_base = pmm.allocZeroedPages(pages_needed) orelse
            return error.BufferAllocationFailed;
        const virt_base = @intFromPtr(hal.paging.physToVirt(phys_base));

        self.event_buffer_base_phys = phys_base;
        self.event_buffer_base_virt = virt_base;

        // Submit each buffer to the event queue
        for (0..config.EVENT_BUFFER_COUNT) |i| {
            const offset = i * event_size;
            const buf_virt = virt_base + offset;
            const buf_phys = phys_base + offset;

            // Zero-initialize for security
            const buf_ptr: [*]u8 = @ptrFromInt(buf_virt);
            @memset(buf_ptr[0..event_size], 0);

            // Submit buffer (device-writable only, so it goes in in_bufs)
            // We need to use the Virtqueue directly since it expects slices
            self.submitEventBuffer(buf_phys, event_size) catch |err| {
                console.warn("VirtIO-Input: Failed to submit event buffer {}: {}", .{ i, err });
                break;
            };
        }

        // Notify device that buffers are available
        self.event_queue.kick(self.event_notify_addr);
    }

    /// Submit a single event buffer to the device
    fn submitEventBuffer(self: *Self, phys_addr: u64, size: usize) !void {
        // Allocate a descriptor
        if (self.event_queue.num_free == 0) return error.QueueAllocationFailed;

        const idx = self.event_queue.free_head;
        self.event_queue.free_head = self.event_queue.desc[idx].next;
        self.event_queue.num_free -= 1;

        // Configure descriptor for device-writable buffer
        self.event_queue.desc[idx].addr = phys_addr;
        self.event_queue.desc[idx].len = @intCast(size);
        self.event_queue.desc[idx].flags = virtio.VIRTQ_DESC_F_WRITE;
        self.event_queue.desc[idx].next = 0;

        // Add to available ring
        const avail_idx = self.event_queue.avail.idx % self.event_queue.size;
        self.event_queue.avail.ring[avail_idx] = idx;

        hal.mmio.memoryBarrier();
        self.event_queue.avail.idx +%= 1;
    }

    // ========================================================================
    // Device Configuration Query
    // ========================================================================

    /// Query device configuration to determine type and capabilities
    ///
    /// Note on TOCTOU: Config reads are from volatile MMIO, so a malicious
    /// hypervisor could theoretically change values mid-read. However, the
    /// hypervisor is in the TCB - if malicious, it can compromise the VM
    /// in far worse ways. We validate critical values (axis max > 0) after
    /// reading to prevent trap on @intCast. Further atomic protection is
    /// not warranted given the threat model.
    fn queryDeviceConfig(self: *Self) void {
        // Query device name
        self.device_cfg.select = config.ConfigSelect.ID_NAME;
        self.device_cfg.subsel = 0;
        hal.mmio.memoryBarrier();

        const name_len = self.device_cfg.size;
        if (name_len > 0 and name_len <= 128) {
            // Copy name from volatile config space
            for (0..name_len) |i| {
                self.device_name[i] = self.device_cfg.u[i];
            }
            self.device_name_len = name_len;
        } else {
            // Default name
            const default_name = "VirtIO Input";
            @memcpy(self.device_name[0..default_name.len], default_name);
            self.device_name_len = default_name.len;
        }

        // Detect device type based on supported event types
        self.device_type = .unknown;

        // Check for EV_ABS support (tablets/touchscreens)
        self.device_cfg.select = config.ConfigSelect.EV_BITS;
        self.device_cfg.subsel = config.EventType.EV_ABS;
        hal.mmio.memoryBarrier();

        if (self.device_cfg.size > 0) {
            self.device_type = .tablet;

            // Query ABS_X info
            self.device_cfg.select = config.ConfigSelect.ABS_INFO;
            self.device_cfg.subsel = uapi.input.AbsCode.X;
            hal.mmio.memoryBarrier();

            if (self.device_cfg.size >= @sizeOf(config.VirtioInputAbsInfo)) {
                const info_ptr: *const config.VirtioInputAbsInfo = @ptrCast(@alignCast(@volatileCast(&self.device_cfg.u)));
                const info = info_ptr.*;
                // Security: Validate device-provided values before storing
                // A malicious hypervisor could provide negative max, causing @intCast trap later
                if (info.max > 0 and info.max > info.min) {
                    self.abs_x_info = info;
                } else {
                    console.warn("VirtIO-Input: Invalid ABS_X axis info (min={d}, max={d})", .{ info.min, info.max });
                }
            }

            // Query ABS_Y info
            self.device_cfg.select = config.ConfigSelect.ABS_INFO;
            self.device_cfg.subsel = uapi.input.AbsCode.Y;
            hal.mmio.memoryBarrier();

            if (self.device_cfg.size >= @sizeOf(config.VirtioInputAbsInfo)) {
                const info_ptr: *const config.VirtioInputAbsInfo = @ptrCast(@alignCast(@volatileCast(&self.device_cfg.u)));
                const info = info_ptr.*;
                // Security: Validate device-provided values before storing
                if (info.max > 0 and info.max > info.min) {
                    self.abs_y_info = info;
                } else {
                    console.warn("VirtIO-Input: Invalid ABS_Y axis info (min={d}, max={d})", .{ info.min, info.max });
                }
            }

            if (self.abs_x_info) |x_info| {
                if (self.abs_y_info) |y_info| {
                    console.info("VirtIO-Input: Tablet axis range X:[{d},{d}] Y:[{d},{d}]", .{
                        x_info.min, x_info.max, y_info.min, y_info.max,
                    });
                }
            }

            return;
        }

        // Check for EV_REL (mouse)
        self.device_cfg.select = config.ConfigSelect.EV_BITS;
        self.device_cfg.subsel = config.EventType.EV_REL;
        hal.mmio.memoryBarrier();

        if (self.device_cfg.size > 0) {
            self.device_type = .mouse;
            return;
        }

        // Check for EV_KEY (keyboard)
        self.device_cfg.select = config.ConfigSelect.EV_BITS;
        self.device_cfg.subsel = config.EventType.EV_KEY;
        hal.mmio.memoryBarrier();

        if (self.device_cfg.size > 0) {
            self.device_type = .keyboard;
        }
    }

    /// Register with the kernel input subsystem
    fn registerWithInputSubsystem(self: *Self) void {
        const device_info = input.DeviceInfo{
            .device_type = switch (self.device_type) {
                .mouse => .virtio_mouse,
                .tablet => .virtio_tablet,
                else => .unknown,
            },
            .name = self.device_name[0..self.device_name_len],
            .capabilities = .{
                .has_rel = self.device_type == .mouse,
                .has_abs = self.device_type == .tablet,
                .has_left = true,
                .has_right = true,
                .has_middle = true,
            },
            .is_absolute = self.device_type == .tablet,
        };

        self.input_device_id = input.registerDevice(device_info) catch |err| {
            console.warn("VirtIO-Input: Failed to register with input subsystem: {}", .{err});
            return;
        };
    }

    // ========================================================================
    // Event Processing
    // ========================================================================

    /// Process completed events from the used ring
    pub fn processEvents(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        if (!self.initialized) return;

        while (self.event_queue.hasPending()) {
            const used = self.event_queue.getUsed() orelse break;

            // Validate descriptor index
            if (used.head >= config.EVENT_BUFFER_COUNT) {
                console.warn("VirtIO-Input: Invalid descriptor head {}", .{used.head});
                continue;
            }

            // Get the event buffer
            const event_offset = @as(usize, used.head) * @sizeOf(config.VirtioInputEvent);
            const event_ptr: *const config.VirtioInputEvent =
                @ptrFromInt(self.event_buffer_base_virt + event_offset);
            const event = event_ptr.*;

            // Translate and push to input subsystem
            self.translateAndPushEvent(event);

            // Resubmit the buffer
            self.resubmitEventBuffer(used.head);
        }
    }

    /// Translate VirtIO event to kernel InputEvent and push to subsystem
    fn translateAndPushEvent(self: *Self, event: config.VirtioInputEvent) void {
        const timestamp = hal.timing.getNanoseconds();

        switch (event.type) {
            config.EventType.EV_KEY => {
                // Button/key press
                input.pushButton(self.input_device_id, event.code, event.value != 0, timestamp);
            },
            config.EventType.EV_REL => {
                // Relative movement
                input.pushRelative(self.input_device_id, event.code, event.value, timestamp);
            },
            config.EventType.EV_ABS => {
                // Absolute position
                input.pushAbsolute(self.input_device_id, event.code, event.value, timestamp);

                // Update cursor for absolute devices
                self.handleAbsoluteEvent(event.code, event.value);
            },
            config.EventType.EV_SYN => {
                // Synchronization event
                input.pushSync(self.input_device_id, timestamp);
            },
            else => {
                // Unknown event type, ignore
            },
        }
    }

    /// Handle absolute positioning events for tablet cursor update
    fn handleAbsoluteEvent(self: *Self, code: u16, value: i32) void {
        if (self.abs_x_info == null or self.abs_y_info == null) return;

        // Clamp value to valid range
        const clamped: u32 = @intCast(@max(0, value));

        if (code == uapi.input.AbsCode.X) {
            // Store X, wait for Y
            self.pending_abs_x = clamped;
        } else if (code == uapi.input.AbsCode.Y) {
            // Apply both X and Y when we have both
            const abs_x = self.pending_abs_x orelse return;
            const abs_y = clamped;

            // Get device max values for scaling
            const max_x: u32 = @intCast(self.abs_x_info.?.max);
            const max_y: u32 = @intCast(self.abs_y_info.?.max);

            // Update cursor position (input subsystem handles scaling to screen)
            input.setCursorAbsolute(abs_x, abs_y, max_x, max_y);

            self.pending_abs_x = null;
        }
    }

    /// Resubmit an event buffer after processing
    fn resubmitEventBuffer(self: *Self, idx: u16) void {
        // Defense-in-depth: Validate index even though caller should have checked.
        // Prevents OOB if another code path calls this without validation.
        if (idx >= config.EVENT_BUFFER_COUNT) {
            console.warn("VirtIO-Input: resubmitEventBuffer called with invalid idx {}", .{idx});
            return;
        }

        const event_size = @sizeOf(config.VirtioInputEvent);
        const offset = @as(usize, idx) * event_size;
        const buf_virt = self.event_buffer_base_virt + offset;
        const buf_phys = self.event_buffer_base_phys + offset;

        // Zero the buffer before reuse (security)
        const buf_ptr: [*]u8 = @ptrFromInt(buf_virt);
        @memset(buf_ptr[0..event_size], 0);

        // Resubmit to available ring
        self.submitEventBuffer(buf_phys, event_size) catch {
            console.warn("VirtIO-Input: Failed to resubmit event buffer", .{});
            return;
        };

        // Notify device
        self.event_queue.kick(self.event_notify_addr);
    }

    // ========================================================================
    // Polling (for when MSI-X unavailable)
    // ========================================================================

    /// Poll for events (used when MSI-X unavailable)
    pub fn poll(self: *Self) void {
        self.processEvents();
    }
};

// =============================================================================
// Global Driver Instance
// =============================================================================

// Safety: These globals are only modified during single-threaded kernel init
// (PCI enumeration). After init, only read access occurs. If concurrent init
// is ever needed, add a spinlock here to protect modifications.
var g_drivers: [8]?*VirtioInputDriver = [_]?*VirtioInputDriver{null} ** 8;
var g_driver_count: u8 = 0;

/// Get the first driver (for simple cases)
pub fn getDriver() ?*VirtioInputDriver {
    if (g_driver_count == 0) return null;
    return g_drivers[0];
}

/// Get driver by index
pub fn getDriverByIndex(idx: u8) ?*VirtioInputDriver {
    if (idx >= g_driver_count) return null;
    return g_drivers[idx];
}

/// Get number of initialized drivers
pub fn getDriverCount() u8 {
    return g_driver_count;
}

// =============================================================================
// Public API
// =============================================================================

/// Check if PCI device is a VirtIO-Input device
pub fn isVirtioInput(pci_dev: *const pci.PciDevice) bool {
    return pci_dev.vendor_id == config.PCI_VENDOR_VIRTIO and
        pci_dev.device_id == config.PCI_DEVICE_INPUT;
}

/// Initialize VirtIO-Input driver from PCI device
pub fn initFromPci(
    pci_dev: *const pci.PciDevice,
    pci_access: pci.PciAccess,
) InputError!*VirtioInputDriver {
    if (g_driver_count >= 8) {
        console.warn("VirtIO-Input: Maximum devices reached", .{});
        return error.AllocationFailed;
    }

    // Allocate driver structure
    const driver = heap.allocator().create(VirtioInputDriver) catch
        return error.AllocationFailed;
    errdefer heap.allocator().destroy(driver);

    // Initialize driver
    try driver.init(pci_dev, pci_access);

    // Store in global array
    g_drivers[g_driver_count] = driver;
    g_driver_count += 1;

    return driver;
}

/// Poll all VirtIO-Input devices for events
pub fn pollAll() void {
    for (0..g_driver_count) |i| {
        if (g_drivers[i]) |driver| {
            driver.poll();
        }
    }
}
