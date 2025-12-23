// XHCI USB Device Management
//
// Manages per-device state for USB devices attached to XHCI ports.
// Each device has:
//   - Slot ID assigned by controller
//   - Device and Input contexts for commands
//   - Transfer ring for EP0 (control)
//   - Optional transfer ring for interrupt endpoint (HID keyboards)
//
// Reference: xHCI Specification 1.2

const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");
const io = @import("io");

const trb = @import("trb.zig");
const ring = @import("ring.zig");
const context = @import("context.zig");
const hid = @import("../class/hid/root.zig");
const hub = @import("../class/hub.zig");

// =============================================================================
// USB Device Structure
// =============================================================================

/// USB Device - tracks all state for an enumerated device
pub const UsbDevice = struct {
    /// IOMMU BDF for DMA allocations
    bdf: iommu.DeviceBdf,
    /// Slot ID assigned by Enable Slot command (1-255)
    slot_id: u8,
    /// Root hub port number (1-based)
    port: u8,
    /// Device speed from PORTSC
    speed: context.Speed,
    /// EP0 max packet size (8 for LS, 64 for FS/HS, 512 for SS)
    max_packet_size: u16,

    // Contexts (DMA-allocated)
    /// Device Context - output from controller
    device_context: *context.DeviceContext,
    device_context_phys: u64,
    /// Input Context - for commands
    input_context: *context.InputContext,
    input_context_phys: u64,

    // Transfer rings
    /// Transfer rings indexed by DCI (Device Context Index)
    /// DCI 1 = Control EP0
    /// DCI 2..31 = Other Endpoints
    endpoints: [32]?ring.TransferRing,

    /// Primary Interrupt DCI (for HID polling) - DEPRECATED: Use active_interfaces instead
    interrupt_dci: u5,

    /// Active interfaces bound to drivers (supports multi-interface devices)
    active_interfaces: [MAX_ACTIVE_INTERFACES]ActiveInterface,
    /// Number of active interfaces
    active_interface_count: u8,

    /// Pending transfers indexed by DCI (0-31)
    /// Security: Tracked for safe cancellation during device disconnect.
    /// Protected by device_lock for thread-safe access.
    pending_transfers: [MAX_PENDING_TRANSFERS]?*TransferRequest = [_]?*TransferRequest{null} ** MAX_PENDING_TRANSFERS,

    // Class driver state
    /// HID driver instance for parsing reports (if HID)
    hid_driver: hid.HidDriver,
    /// DMA buffer for interrupt reports
    /// Security: Use bounded slice to prevent buffer overruns from malicious devices.
    /// Size 64 accommodates max interrupt packet (HS max_packet).
    report_buffer: []u8,
    report_buffer_phys: u64,
    /// Allocated size of report_buffer for validation
    report_buffer_len: usize,
    /// Last queued interrupt request length - used to validate completions
    /// Security: Must match between queue and completion to detect hardware lies
    last_interrupt_request_len: u17 = 0,

    /// Hub driver state (if is_hub is true)
    hub_driver: hub.HubDriver,

    /// Parent device (if connected via hub)
    parent: ?*UsbDevice = null,
    /// Port number on parent device (1-based)
    parent_port: u8 = 0,
    /// Route string for XHCI addressing
    route_string: u20 = 0,

    /// Helper tag to identify device class if needed
    is_hub: bool = false,


    /// Current device state
    state: DeviceState,

    /// Per-device lock for transfer operations and state transitions
    /// Security: Uses Spinlock (not RwLock) for IRQ-safe access from interrupt handlers.
    /// Lock ordering: Acquire after devices_lock (global array lock), before pmm.lock.
    device_lock: sync.Spinlock = .{},

    /// Reference count for safe deallocation
    /// Security: Prevents use-after-free when device is accessed from interrupt handler
    /// while another thread is deallocating. Starts at 1 (creation holds a reference).
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

    const Self = @This();

    /// Device state during enumeration and lifecycle
    pub const DeviceState = enum {
        /// Slot enabled, not yet addressed
        slot_enabled,
        /// USB address assigned
        addressed,
        /// Configuration set, endpoints configured
        configured,
        /// Actively polling for HID reports
        polling,
        /// Disconnect in progress - pending transfers being cancelled
        /// Security: Prevents new transfers from being queued during cleanup
        disconnecting,
        /// Slot disabled, device no longer usable (terminal state)
        /// Resources may still be held until refcount reaches zero
        disabled,
        /// Error state - device unusable
        err,
    };

    /// Maximum number of active interfaces per device
    pub const MAX_ACTIVE_INTERFACES: usize = 8;

    /// Driver type bound to an interface
    pub const DriverType = enum {
        none,
        hid_keyboard,
        hid_mouse,
        hid_generic,
        msc,
        hub,

        /// Check if this is any HID driver type
        pub fn isHid(self: DriverType) bool {
            return self == .hid_keyboard or self == .hid_mouse or self == .hid_generic;
        }
    };

    /// Per-interface driver binding info
    pub const ActiveInterface = struct {
        interface_num: u8,
        dci: u5, // Primary endpoint DCI for this interface
        driver_type: DriverType,
        /// For MSC: bulk OUT DCI (bulk IN is in `dci`)
        secondary_dci: u5 = 0,
    };

    /// Transfer request state for async tracking
    pub const TransferState = enum(u8) {
        /// Request allocated but not yet submitted
        pending,
        /// Request submitted to hardware, awaiting completion
        in_progress,
        /// Transfer completed successfully
        completed,
        /// Transfer cancelled (e.g., during disconnect)
        cancelled,
        /// Transfer failed with error
        failed,
    };

    /// Callback types for transfer completion notification
    pub const TransferCallback = union(enum) {
        /// Interrupt endpoint completion (HID, Hub) - receives data buffer
        interrupt: *const fn (*UsbDevice, []u8) void,
        /// Control transfer completion - receives completion code and residual
        control: *const fn (*UsbDevice, trb.CompletionCode, u24) void,
        /// No callback (polling mode)
        none: void,
    };

    /// Pending transfer request for async tracking
    /// Security: Tracks in-flight transfers for safe cancellation during disconnect.
    /// Each endpoint (DCI) can have at most one pending transfer at a time.
    pub const TransferRequest = struct {
        /// Physical address of first TRB in transfer (for completion matching)
        trb_phys: u64,
        /// Device Context Index for this transfer's endpoint
        dci: u5,
        /// Atomic state for IRQ-safe transitions
        state: std.atomic.Value(TransferState),
        /// Completion code from controller (valid when state == completed/failed)
        completion_code: trb.CompletionCode,
        /// Residual bytes NOT transferred (actual = requested - residual)
        residual: u24,
        /// Requested transfer length (for residual validation)
        request_len: u24,
        /// Callback for completion notification
        callback: TransferCallback,
        /// Intrusive linked list for pool free list
        next: ?*TransferRequest,
        /// Linked kernel IoRequest for reactor/io_uring integration
        /// Null for callback-based completion (HID polling)
        /// Security: When set, complete() also completes the IoRequest
        io_request: ?*io.IoRequest = null,

        /// Initialize a new transfer request
        pub fn init(dci: u5, trb_phys: u64, request_len: u24, callback: TransferCallback) TransferRequest {
            return .{
                .trb_phys = trb_phys,
                .dci = dci,
                .state = std.atomic.Value(TransferState).init(.pending),
                .completion_code = .Invalid,
                .residual = 0,
                .request_len = request_len,
                .callback = callback,
                .next = null,
                .io_request = null,
            };
        }

        /// Attempt atomic state transition
        /// Returns true if transition succeeded, false if current state didn't match expected
        pub fn compareAndSwapState(self: *TransferRequest, expected: TransferState, new: TransferState) bool {
            return self.state.cmpxchgStrong(expected, new, .acq_rel, .acquire) == null;
        }

        /// Complete the transfer with given result
        /// Security: Writes result fields BEFORE transitioning state to prevent TOCTOU
        /// Also completes linked IoRequest if present, triggering sched.unblock()
        pub fn complete(self: *TransferRequest, code: trb.CompletionCode, residual: u24) bool {
            // Write completion data first
            self.completion_code = code;
            self.residual = residual;

            // Then atomically transition state
            const success_state: TransferState = if (code == .Success or code == .ShortPacket) .completed else .failed;
            if (!self.compareAndSwapState(.in_progress, success_state)) {
                return false;
            }

            // Complete linked IoRequest if present (triggers sched.unblock)
            if (self.io_request) |io_req| {
                const io_result = self.toIoResult();
                _ = io_req.complete(io_result);
            }

            return true;
        }

        /// Convert USB completion to kernel IoResult
        /// Maps CompletionCode to appropriate success/error result
        pub fn toIoResult(self: *const TransferRequest) io.IoResult {
            return switch (self.completion_code) {
                .Success, .ShortPacket => blk: {
                    // Calculate actual bytes transferred (requested - residual)
                    const requested: usize = self.request_len;
                    const residual_usize: usize = @intCast(self.residual);
                    const transferred = if (residual_usize <= requested)
                        requested - residual_usize
                    else
                        0;
                    break :blk .{ .success = transferred };
                },
                .StallError => .{ .err = error.EPERM },
                .BabbleDetectedError, .USBTransactionError, .TRBError => .{ .err = error.EIO },
                .ResourceError, .NoSlotsAvailableError => .{ .err = error.ENOMEM },
                .BandwidthError => .{ .err = error.EBUSY },
                .Stopped, .CommandAborted => .{ .err = error.ECANCELED },
                .ContextStateError => .{ .err = error.EINVAL },
                .EventRingFullError => .{ .err = error.EAGAIN },
                else => .{ .err = error.EIO },
            };
        }

        /// Cancel the transfer (during disconnect)
        /// Also cancels linked IoRequest if present
        pub fn cancel(self: *TransferRequest) bool {
            // Try to cancel from pending state
            if (self.compareAndSwapState(.pending, .cancelled)) {
                if (self.io_request) |io_req| {
                    _ = io_req.complete(.cancelled);
                }
                return true;
            }
            // Try to cancel from in_progress state
            if (self.compareAndSwapState(.in_progress, .cancelled)) {
                if (self.io_request) |io_req| {
                    _ = io_req.complete(.cancelled);
                }
                return true;
            }
            return false;
        }
    };

    /// Maximum pending transfers per device (one per endpoint DCI)
    pub const MAX_PENDING_TRANSFERS: usize = 32;

    /// Allocate and initialize a new USB device
    pub fn init(bdf: iommu.DeviceBdf, slot_id: u8, port: u8, speed: context.Speed, parent: ?*UsbDevice, parent_port: u8, route_string: u20) !*Self {
        // Allocate device structure from PMM
        const dev_page = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const dev_virt = @intFromPtr(hal.paging.physToVirt(dev_page));
        const device: *Self = @ptrFromInt(dev_virt);
        errdefer pmm.freePages(dev_page, 1);

        // Allocate Device Context (IOMMU-aware)
        const dc = try context.DeviceContext.alloc(bdf);
        errdefer context.DeviceContext.freeDma(&dc.dma_buf);

        // Allocate Input Context (IOMMU-aware)
        const ic = try context.InputContext.alloc(bdf);
        errdefer context.InputContext.freeDma(&ic.dma_buf);

        // Allocate EP0 Transfer Ring (IOMMU-aware)
        var ep0_ring = try ring.TransferRing.init(bdf);
        errdefer ep0_ring.deinit();

        // Allocate report buffer (one page for DMA alignment)
        // Security: Entire page is zeroed to prevent information leaks if malicious
        // hardware writes beyond the tracked 64-byte buffer size. The TRB request
        // length is also capped to report_buffer_len in queueInterruptTransfer.
        const report_page = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const report_virt: [*]u8 = @ptrCast(hal.paging.physToVirt(report_page));
        const report_buffer_size: usize = 64; // Max HS interrupt packet size

        // Determine default max packet size based on speed
        const default_max_packet: u16 = switch (speed) {
            .low_speed => 8,
            .full_speed => 64,
            .high_speed => 64,
            .super_speed, .super_speed_plus => 512,
            else => 8,
        };

        var new_dev = Self{
            .bdf = bdf,
            .slot_id = slot_id,
            .port = port,
            .speed = speed,
            .max_packet_size = default_max_packet,
            .device_context = dc.ctx,
            .device_context_phys = dc.device_addr, // Use device_addr (IOVA) for hardware
            .input_context = ic.ctx,
            .input_context_phys = ic.device_addr, // Use device_addr (IOVA) for hardware
            .endpoints = [_]?ring.TransferRing{null} ** 32,
            .interrupt_dci = 0,
            .active_interfaces = [_]ActiveInterface{.{ .interface_num = 0, .dci = 0, .driver_type = .none }} ** MAX_ACTIVE_INTERFACES,
            .active_interface_count = 0,
            .hid_driver = .{},
            .hub_driver = undefined,
            .report_buffer = report_virt[0..report_buffer_size],
            .report_buffer_phys = report_page,
            .report_buffer_len = report_buffer_size,
            .state = .slot_enabled,
            .parent = parent,
            .parent_port = parent_port,
            .route_string = route_string,
        };

        // Initialize EP0 ring at DCI 1
        new_dev.endpoints[1] = ep0_ring;

        device.* = new_dev;

        return device;

    }

    /// Build initial Input Context for Address Device command
    /// Sets up Slot Context and EP0 Context
    pub fn buildAddressDeviceContext(self: *Self) void {
        // Clear input context
        @memset(@as([*]u8, @ptrCast(self.input_context))[0..@sizeOf(context.InputContext)], 0);

        // Set add flags: Slot (bit 0) + EP0 (bit 1)
        self.input_context.input_control.setAddFlags(true, 1); // EP0 = endpoint bit 0

        // Initialize Slot Context

        self.input_context.slot = context.SlotContext.initForDevice(
            self.speed,
            self.port,
            self.route_string,
            if (self.parent) |p| p.slot_id else 0,
            self.parent_port,
            1, // context_entries
        );

        // Initialize EP0 Context
        const ep0_ring = &self.endpoints[1].?;
        self.input_context.endpoints[0] = context.EndpointContext.initForEp0(
            self.max_packet_size,
            ep0_ring.getPhysicalAddress(),
            ep0_ring.getCycleState(),
        );

    }

    /// Initialize a Bulk Endpoint
    pub fn initBulkEndpoint(self: *Self, ep_addr: u8) !void {
        // Security: Validate endpoint address before calculating DCI
        const dci = context.InputContext.endpointToDci(ep_addr) orelse return error.InvalidParam;

        // Allocate transfer ring if not present (IOMMU-aware)
        if (self.endpoints[dci] == null) {
            self.endpoints[dci] = try ring.TransferRing.init(self.bdf);
        }

        // We don't update InputContext here immediately;
        // The pattern is initEndpoint -> buildConfigureEndpointContext -> Configure Endpoint Command
    }

    /// Update Input Context to configure a specific endpoint
    pub fn buildConfigureEndpointContext(
        self: *Self,
        ep_addr: u8,
        ep_type: context.EndpointType,
        max_packet: u16,
        interval: u8,
    ) !void {
        // Security: Validate endpoint address before calculating DCI
        const dci = context.InputContext.endpointToDci(ep_addr) orelse return error.InvalidParam;

        // Allocate ring if it doesn't exist (it should, from initXXEndpoint) - IOMMU-aware
        if (self.endpoints[dci] == null) {
            self.endpoints[dci] = try ring.TransferRing.init(self.bdf);
        }

        const ep_ring = &self.endpoints[dci].?;

        // Clear and set up input context
        @memset(@as([*]u8, @ptrCast(self.input_context))[0..@sizeOf(context.InputContext)], 0);

        // Set Add Flags
        // Bit 0 = Slot, Bit N = DCI N (handled by setAddFlags shifting left by 1)
        const endpoint_flag: u31 = @as(u31, 1) << @truncate(dci - 1);
        self.input_context.input_control.setAddFlags(true, endpoint_flag); // Slot + Endpoint

        // Update Slot Context
        // We need to ensure context_entries covers this DCI
        self.input_context.slot = self.device_context.slot;
        if (dci > self.input_context.slot.dw0.context_entries) {
            self.input_context.slot.dw0.context_entries = dci;
        }

        // Initialize Endpoint Context
        // Index in endpoints array is dci - 1
        if (self.input_context.getEndpoint(dci)) |ep| {
             switch (ep_type) {
                .control_bidirectional => {}, // Should use buildAddressDeviceContext or specialized init
                .isoch_in, .isoch_out, 
                .bulk_in, .bulk_out, 
                .interrupt_in, .interrupt_out => {
                    ep.* = context.EndpointContext.initGeneric(
                        ep_type,
                        max_packet,
                        calculateInterval(self.speed, interval),
                        ep_ring.getPhysicalAddress(),
                        ep_ring.getCycleState(),
                    );
                    
                    // Track interrupt endpoint for HID polling
                    if (ep_type == .interrupt_in) {
                        self.interrupt_dci = dci;
                    }
                },
                else => {},
             }
        }
    }

    /// Update max packet size after reading device descriptor
    pub fn updateMaxPacketSize(self: *Self, new_size: u16) void {
        self.max_packet_size = new_size;
    }

    /// Build Input Context for Evaluate Context command (max packet update)
    pub fn buildEvaluateContext(self: *Self) void {
        @memset(@as([*]u8, @ptrCast(self.input_context))[0..@sizeOf(context.InputContext)], 0);

        // Only update EP0
        self.input_context.input_control.setAddFlags(false, 1); // Only EP0

        // Update EP0 max packet size
        const ep0_ring = &self.endpoints[1].?;
        self.input_context.endpoints[0] = context.EndpointContext.initForEp0(
            self.max_packet_size,
            ep0_ring.getPhysicalAddress(),
            ep0_ring.getCycleState(),
        );

    }

    // =========================================================================
    // Multi-Interface Support
    // =========================================================================

    /// Endpoint configuration for multi-endpoint setup
    pub const EndpointConfig = struct {
        ep_addr: u8,
        ep_type: context.EndpointType,
        max_packet: u16,
        interval: u8,
    };

    /// Register an active interface with its driver binding
    /// Returns true if registered, false if at capacity
    pub fn registerActiveInterface(
        self: *Self,
        interface_num: u8,
        dci: u5,
        driver_type: DriverType,
        secondary_dci: u5,
    ) bool {
        if (self.active_interface_count >= MAX_ACTIVE_INTERFACES) {
            console.warn("XHCI: Cannot register interface {}: at capacity", .{interface_num});
            return false;
        }

        self.active_interfaces[self.active_interface_count] = ActiveInterface{
            .interface_num = interface_num,
            .dci = dci,
            .driver_type = driver_type,
            .secondary_dci = secondary_dci,
        };
        self.active_interface_count += 1;

        // Maintain backwards compatibility: set interrupt_dci for first HID
        if (driver_type.isHid() and self.interrupt_dci == 0) {
            self.interrupt_dci = dci;
        }

        console.debug("XHCI: Registered interface {} as {s} (dci={})", .{
            interface_num,
            @tagName(driver_type),
            dci,
        });

        return true;
    }

    /// Find active interface by DCI
    pub fn findActiveInterfaceByDci(self: *const Self, dci: u5) ?*const ActiveInterface {
        for (self.active_interfaces[0..self.active_interface_count]) |*active| {
            if (active.dci == dci or active.secondary_dci == dci) {
                return active;
            }
        }
        return null;
    }

    /// Get slice of active interfaces for iteration
    pub fn getActiveInterfaces(self: *const Self) []const ActiveInterface {
        return self.active_interfaces[0..self.active_interface_count];
    }

    // =========================================================================
    // Async Transfer Request Management
    // =========================================================================

    /// Register a pending transfer for async completion
    /// Security: Must hold device_lock before calling
    /// Uses pending_transfers array indexed by DCI (one per endpoint)
    pub fn registerPendingTransfer(self: *Self, dci: u5, req: *TransferRequest) void {
        // dci is u5 (0-31), which is within bounds of pending_transfers[32]
        self.pending_transfers[dci] = req;
    }

    /// Get and clear pending transfer for completion
    /// Security: Must hold device_lock before calling
    /// Returns the request if found, null otherwise
    /// Clears the slot atomically to prevent double-completion
    pub fn takePendingTransfer(self: *Self, dci: u5) ?*TransferRequest {
        // dci is u5 (0-31), which is within bounds of pending_transfers[32]
        const req = self.pending_transfers[dci];
        self.pending_transfers[dci] = null;
        return req;
    }

    /// Cancel all pending transfers during disconnect
    /// Security: Sets device state to disconnecting first to prevent new submissions
    /// Then cancels each pending transfer and completes linked IoRequest
    pub fn cancelAllPendingTransfers(self: *Self) void {
        // Set state to prevent new submissions
        self.state = .disconnecting;

        // Cancel under device_lock
        const held = self.device_lock.acquire();
        defer held.release();

        for (&self.pending_transfers) |*slot| {
            if (slot.*) |req| {
                // Try to cancel - may fail if already completed
                _ = req.cancel(); // cancel() handles IoRequest completion internally
                slot.* = null;
            }
        }
    }

    /// Build Input Context to configure MULTIPLE endpoints in ONE command
    /// This fixes the critical bug where each call to buildConfigureEndpointContext
    /// would wipe out previously configured endpoints.
    pub fn buildMultiEndpointContext(
        self: *Self,
        endpoint_configs: []const EndpointConfig,
    ) !void {
        if (endpoint_configs.len == 0) return;

        // Clear input context ONCE at the start
        @memset(@as([*]u8, @ptrCast(self.input_context))[0..@sizeOf(context.InputContext)], 0);

        // Copy current slot context from device context
        self.input_context.slot = self.device_context.slot;

        var add_flags: u31 = 0;
        var max_dci: u5 = self.input_context.slot.dw0.context_entries;

        for (endpoint_configs) |cfg| {
            const dci = context.InputContext.endpointToDci(cfg.ep_addr) orelse {
                console.warn("XHCI: Invalid endpoint address 0x{x}", .{cfg.ep_addr});
                continue;
            };

            // Allocate transfer ring if needed (IOMMU-aware)
            if (self.endpoints[dci] == null) {
                self.endpoints[dci] = try ring.TransferRing.init(self.bdf);
            }

            const ep_ring = &self.endpoints[dci].?;

            // Set add flag for this endpoint
            // Bit 0 is slot, bits 1-31 are endpoints, so we shift left by dci-1
            add_flags |= @as(u31, 1) << @truncate(dci - 1);

            // Track maximum DCI
            if (dci > max_dci) max_dci = dci;

            // Configure endpoint context
            if (self.input_context.getEndpoint(dci)) |ep| {
                ep.* = context.EndpointContext.initGeneric(
                    cfg.ep_type,
                    cfg.max_packet,
                    calculateInterval(self.speed, cfg.interval),
                    ep_ring.getPhysicalAddress(),
                    ep_ring.getCycleState(),
                );
            }

            console.debug("XHCI: Configured endpoint 0x{x:0>2} (DCI={}, type={s})", .{
                cfg.ep_addr,
                dci,
                @tagName(cfg.ep_type),
            });
        }

        // Update slot context entries to cover all configured DCIs
        self.input_context.slot.dw0.context_entries = max_dci;

        // Set add flags: Slot + all configured endpoints
        self.input_context.input_control.setAddFlags(true, add_flags);

        console.info("XHCI: Built multi-endpoint context with {} endpoint(s), max_dci={}", .{
            endpoint_configs.len,
            max_dci,
        });
    }

    /// Increment reference count
    /// Security: Must be called while holding devices_lock to prevent race with deinit
    pub fn addRef(self: *Self) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count and free if zero
    /// Security: Returns true if device was freed, false otherwise
    pub fn releaseRef(self: *Self) bool {
        // Use acq_rel ordering to ensure all prior accesses are visible
        // before we potentially free the resources
        const old = self.refcount.fetchSub(1, .acq_rel);
        if (old == 1) {
            // Last reference - perform cleanup
            self.freeResources();
            return true;
        }
        return false;
    }

    /// Internal helper to free all device resources
    /// Security: Only called when refcount reaches zero
    fn freeResources(self: *Self) void {
        self.device_context.free();
        self.input_context.free();
        for (&self.endpoints) |*ep_opt| {
            if (ep_opt.*) |*rng| {
                rng.deinit();
            }
        }
        pmm.freePages(self.report_buffer_phys, 1);

        // Free the device structure itself
        const dev_phys = hal.paging.virtToPhys(@intFromPtr(self));
        pmm.freePages(dev_phys, 1);
    }

    /// Free all device resources
    /// Security: Unregisters device from global array to prevent double-free
    /// if a new device is assigned the same slot ID before deinit completes.
    /// Uses reference counting to ensure safe deallocation.
    pub fn deinit(self: *Self) void {
        // Security: Unregister from global array FIRST to prevent race conditions
        // where another thread looks up this slot while we're freeing resources.
        // This must happen before any resource cleanup.
        unregisterDevice(self.slot_id);

        // Release the creation reference - resources freed when refcount hits 0
        _ = self.releaseRef();
    }
};

// =============================================================================
// Device Array - Track all connected devices
// =============================================================================

/// Maximum number of devices
/// Security: Increased to 256 to match xHCI spec (slot IDs 1-255)
/// Using 256 allows direct indexing without bounds check failures in ReleaseFast
pub const MAX_DEVICES: usize = 256;

/// Global device array indexed by slot_id
var devices: [MAX_DEVICES]?*UsbDevice = [_]?*UsbDevice{null} ** MAX_DEVICES;
var devices_lock: sync.RwLock = .{};

/// Register a device in the global array
/// Security: Validates slot_id bounds and releases old device reference
/// to prevent resource exhaustion from malicious hub enumeration cycling.
/// Uses reference counting to safely handle concurrent access.
pub fn registerDevice(new_device: *UsbDevice) void {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    // slot_id 0 is reserved for host controller
    if (new_device.slot_id == 0) return;

    // First phase: atomically swap in the new device and get the old one
    var old_dev_to_release: ?*UsbDevice = null;
    {
        const held = devices_lock.acquireWrite();
        defer held.release();

        if (devices[new_device.slot_id]) |old_dev| {
            // Avoid double-free if re-registering same device
            if (old_dev != new_device) {
                console.warn("XHCI: Replacing existing device at slot {}", .{new_device.slot_id});
                // Clear the slot first to prevent lookup during cleanup
                devices[new_device.slot_id] = null;
                old_dev_to_release = old_dev;
            }
        }
        devices[new_device.slot_id] = new_device;
    }

    // Second phase: release old device reference AFTER releasing the lock
    // Security: Uses reference counting to safely handle concurrent access.
    // The old device will only be freed when its refcount reaches zero,
    // meaning all interrupt handlers have finished using it.
    if (old_dev_to_release) |old_dev| {
        // Release the creation reference - resources freed when refcount hits 0
        _ = old_dev.releaseRef();
    }
}

/// Unregister a device from the global array
pub fn unregisterDevice(slot_id: u8) void {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    if (slot_id > 0) {
        const held = devices_lock.acquireWrite();
        defer held.release();
        devices[slot_id] = null;
    }
}

/// Find a device by slot ID
/// NOTE: This returns a raw pointer without acquiring a reference.
/// For interrupt handlers or any code that may race with device disconnect,
/// use findDeviceWithRef() instead.
pub fn findDevice(slot_id: u8) ?*UsbDevice {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    if (slot_id > 0) {
        const held = devices_lock.acquireRead();
        defer held.release();
        return devices[slot_id];
    }
    return null;
}

/// Find a device by slot ID and acquire a reference
/// Security: Acquires a reference while holding devices_lock to prevent race
/// with device disconnect. Caller MUST call dev.releaseRef() when done.
/// Use this in interrupt handlers or any code that may race with disconnect.
pub fn findDeviceWithRef(slot_id: u8) ?*UsbDevice {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    if (slot_id > 0) {
        const held = devices_lock.acquireRead();
        defer held.release();
        if (devices[slot_id]) |dev| {
            // Acquire reference while holding lock to prevent race with deinit
            dev.addRef();
            return dev;
        }
    }
    return null;
}

/// Find a child device by parent and port
pub fn findChildDevice(parent: *UsbDevice, port: u8) ?*UsbDevice {
    const held = devices_lock.acquireRead();
    defer held.release();
    for (devices) |maybe_dev| {
        if (maybe_dev) |dev| {
            if (dev.parent == parent and dev.parent_port == port) {
                return dev;
            }
        }
    }
    return null;
}

/// Find first device in polling state (for interrupt handling)
pub fn findPollingDevice() ?*UsbDevice {
    const held = devices_lock.acquireRead();
    defer held.release();
    for (devices) |maybe_dev| {
        if (maybe_dev) |dev| {
            if (dev.state == .polling) {
                return dev;
            }
        }
    }
    return null;
}

/// Data needed for processing an interrupt event, copied under lock
/// Security: This struct contains copies of device data and holds a reference
/// to prevent use-after-free. Caller MUST call releaseRef() when done.
pub const InterruptEventData = struct {
    /// Device pointer - protected by reference count acquired during lookup
    /// Security: Caller MUST call dev.releaseRef() when finished processing
    dev: *UsbDevice,
    /// Copy of the interrupt endpoint DCI
    interrupt_dci: u5,
    /// Copy of the report buffer slice (bounded by report_buffer_len)
    report_buffer: []u8,
    /// Copy of the report buffer length for validation
    report_buffer_len: usize,
    /// Copy of the last queued request length for residual calculation
    /// Security: Use this instead of hardcoded constant to prevent divergence
    last_request_len: u17,
    /// Whether device is in polling state
    is_polling: bool,
    /// Whether this is a HID device (keyboard/mouse/tablet)
    is_hid: bool,
    /// Whether this is a hub device
    is_hub: bool,

    /// Release the device reference when done processing
    /// Security: MUST be called after processing to allow device cleanup
    pub fn release(self: *const InterruptEventData) void {
        _ = self.dev.releaseRef();
    }
};

/// Safely get interrupt event data for a device under the lock
/// Security: Acquires a reference to prevent use-after-free. Caller MUST
/// call result.release() when done processing to allow device cleanup.
/// Returns null if device not found or not in valid state for interrupt.
pub fn getInterruptEventData(slot_id: u8, ep_dci: u5) ?InterruptEventData {
    if (slot_id == 0) return null;

    const held = devices_lock.acquireRead();
    defer held.release();

    const dev = devices[slot_id] orelse return null;

    // Validate this is the expected interrupt endpoint
    if (dev.interrupt_dci != ep_dci) return null;

    // Only process if device is in polling state
    if (dev.state != .polling) return null;

    // Security: Acquire reference while holding lock to prevent race with deinit
    // The caller MUST call result.release() when done processing.
    dev.addRef();

    return InterruptEventData{
        .dev = dev,
        .interrupt_dci = dev.interrupt_dci,
        .report_buffer = dev.report_buffer,
        .report_buffer_len = dev.report_buffer_len,
        .last_request_len = dev.last_interrupt_request_len,
        .is_polling = true,
        .is_hid = dev.hid_driver.is_keyboard or dev.hid_driver.is_mouse or dev.hid_driver.is_tablet,
        .is_hub = dev.is_hub,
    };
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Calculate XHCI interval value from USB bInterval
/// USB bInterval is in frames (FS/LS) or microframes (HS/SS)
/// XHCI interval is log2 of 125us intervals
fn calculateInterval(speed: context.Speed, bInterval: u8) u8 {
    return switch (speed) {
        // Low/Full speed: bInterval is in 1ms units
        // Convert to 125us units: multiply by 8
        .low_speed, .full_speed => blk: {
            if (bInterval == 0) break :blk 0;
            // Find log2(bInterval * 8) = log2(bInterval) + 3
            var val = bInterval;
            var log: u8 = 3;
            while (val > 1) : (val >>= 1) {
                log += 1;
            }
            break :blk log;
        },
        // High/Super speed: bInterval is already log2+1 of 125us intervals
        .high_speed, .super_speed, .super_speed_plus => bInterval,
        else => bInterval,
    };
}

// =============================================================================
// Pending Transfer Tracking
// =============================================================================

/// Pending transfer info for synchronous control transfers
pub const PendingTransfer = struct {
    /// Physical address of first TRB in transfer
    trb_phys: u64,
    /// Slot ID for matching
    slot_id: u8,
    /// Endpoint DCI for matching
    ep_dci: u5,
    /// Completion status (atomic for interrupt-safe access)
    completed: std.atomic.Value(bool),
    /// Completion code from controller
    completion_code: trb.CompletionCode,
    /// Residual: bytes NOT transferred (actual = requested - residual)
    /// IMPORTANT: This is the RESIDUAL from the Transfer Event TRB, not the actual byte count.
    residual: u24,
};

/// Global pending transfer for synchronous operations
///
/// WARNING: KNOWN LIMITATION - This is a GLOBAL singleton, not per-device!
/// Only ONE synchronous control transfer can be active across ALL devices
/// at any given time. Concurrent synchronous transfers on different devices
/// will cause the later one to timeout because the first overwrites the
/// pending_transfer_storage before its completion event arrives.
///
/// Recommended migration path:
/// 1. Use the async TransferRequest pool (transfer_pool.zig) for new code
/// 2. TransferRequest supports IoRequest integration for proper async I/O
/// 3. This legacy path is kept for backwards compatibility only
///
/// Security: Uses spinlock to prevent TOCTOU race conditions between
/// interrupt handler and polling code. The race window was between
/// writing to storage and setting active=true, where an interrupt
/// could check active (false) and miss a valid pending transfer.
var pending_transfer_storage: PendingTransfer = undefined;
var pending_transfer_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var pending_transfer_lock: sync.Spinlock = .{};

/// Start tracking a pending transfer
/// Security: Uses spinlock to atomically initialize storage and set active flag,
/// preventing TOCTOU race where interrupt fires between write and flag set.
pub fn startPendingTransfer(trb_phys: u64, slot_id: u8, ep_dci: u5) void {
    const held = pending_transfer_lock.acquire();
    defer held.release();

    // Initialize the storage
    pending_transfer_storage = PendingTransfer{
        .trb_phys = trb_phys,
        .slot_id = slot_id,
        .ep_dci = ep_dci,
        .completed = std.atomic.Value(bool).init(false),
        .completion_code = .Invalid,
        .residual = 0,
    };
    // Publish the transfer atomically (within lock)
    pending_transfer_active.store(true, .release);
}

/// Mark pending transfer as completed
/// Security: Safe to call from interrupt context (uses IRQ-safe spinlock)
pub fn completePendingTransfer(code: trb.CompletionCode, residual: u24) void {
    const held = pending_transfer_lock.acquire();
    defer held.release();

    if (pending_transfer_active.load(.acquire)) {
        pending_transfer_storage.completion_code = code;
        pending_transfer_storage.residual = residual;
        pending_transfer_storage.completed.store(true, .release);
    }
}

/// Check if pending transfer matches event
/// Security: Protected by spinlock to ensure consistent read
pub fn matchesPendingTransfer(slot_id: u8, ep_dci: u5) bool {
    const held = pending_transfer_lock.acquire();
    defer held.release();

    if (pending_transfer_active.load(.acquire)) {
        const pt = &pending_transfer_storage;
        return pt.slot_id == slot_id and pt.ep_dci == ep_dci and !pt.completed.load(.acquire);
    }
    return false;
}

/// Get pending transfer if active (for polling)
/// Security: Returns a copy by value to avoid race condition where caller
/// accesses struct fields after lock is released while interrupt handler modifies them.
pub fn getPendingTransfer() ?PendingTransfer {
    const held = pending_transfer_lock.acquire();
    defer held.release();

    if (pending_transfer_active.load(.acquire)) {
        // Return copy by value - caller gets consistent snapshot
        return PendingTransfer{
            .trb_phys = pending_transfer_storage.trb_phys,
            .slot_id = pending_transfer_storage.slot_id,
            .ep_dci = pending_transfer_storage.ep_dci,
            .completed = std.atomic.Value(bool).init(pending_transfer_storage.completed.load(.acquire)),
            .completion_code = pending_transfer_storage.completion_code,
            .residual = pending_transfer_storage.residual,
        };
    }
    return null;
}

/// Clear pending transfer
pub fn clearPendingTransfer() void {
    const held = pending_transfer_lock.acquire();
    defer held.release();

    pending_transfer_active.store(false, .release);
}
