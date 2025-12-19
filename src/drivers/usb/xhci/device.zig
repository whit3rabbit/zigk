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

const trb = @import("trb.zig");
const ring = @import("ring.zig");
const context = @import("context.zig");
const hid = @import("../class/hid.zig");
const hub = @import("../class/hub.zig");

// =============================================================================
// USB Device Structure
// =============================================================================

/// USB Device - tracks all state for an enumerated device
pub const UsbDevice = struct {
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

    /// Primary Interrupt DCI (for HID polling)
    interrupt_dci: u5,

    // Class driver state
    /// HID driver instance for parsing reports (if HID)
    hid_driver: hid.HidDriver,
    /// DMA buffer for interrupt reports (8 bytes for boot protocol)
    report_buffer: [*]u8,
    report_buffer_phys: u64,

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

    const Self = @This();

    /// Device state during enumeration
    pub const DeviceState = enum {
        /// Slot enabled, not yet addressed
        slot_enabled,
        /// USB address assigned
        addressed,
        /// Configuration set, endpoints configured
        configured,
        /// Actively polling for HID reports
        polling,
        /// Error state - device unusable
        err,
    };

    /// Allocate and initialize a new USB device
    pub fn init(slot_id: u8, port: u8, speed: context.Speed, parent: ?*UsbDevice, parent_port: u8, route_string: u20) !*Self {
        // Allocate device structure from PMM
        const dev_page = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const dev_virt = @intFromPtr(hal.paging.physToVirt(dev_page));
        const device: *Self = @ptrFromInt(dev_virt);
        errdefer pmm.freePages(dev_page, 1);

        // Allocate Device Context
        const dc = try context.DeviceContext.alloc();
        errdefer dc.ctx.free();

        // Allocate Input Context
        const ic = try context.InputContext.alloc();
        errdefer ic.ctx.free();

        // Allocate EP0 Transfer Ring
        var ep0_ring = try ring.TransferRing.init();
        errdefer ep0_ring.deinit();

        // Allocate report buffer (one page, we only need 8 bytes)
        const report_page = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const report_virt = hal.paging.physToVirt(report_page);

        // Determine default max packet size based on speed
        const default_max_packet: u16 = switch (speed) {
            .low_speed => 8,
            .full_speed => 64,
            .high_speed => 64,
            .super_speed, .super_speed_plus => 512,
            else => 8,
        };

        var new_dev = Self{
            .slot_id = slot_id,
            .port = port,
            .speed = speed,
            .max_packet_size = default_max_packet,
            .device_context = dc.ctx,
            .device_context_phys = dc.phys,
            .input_context = ic.ctx,
            .input_context_phys = ic.phys,
            .endpoints = [_]?ring.TransferRing{null} ** 32,
            .interrupt_dci = 0,
            .hid_driver = .{},
            .hub_driver = undefined,
            .report_buffer = @ptrFromInt(@intFromPtr(report_virt)),
            .report_buffer_phys = report_page,
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
        const dci = context.InputContext.endpointToDci(ep_addr);
        
        // Allocate transfer ring if not present
        if (self.endpoints[dci] == null) {
            self.endpoints[dci] = try ring.TransferRing.init();
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
        const dci = context.InputContext.endpointToDci(ep_addr);
        
        // Allocate ring if it doesn't exist (it should, from initXXEndpoint)
        if (self.endpoints[dci] == null) {
            self.endpoints[dci] = try ring.TransferRing.init();
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

    /// Free all device resources
    pub fn deinit(self: *Self) void {
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

/// Register a device in the global array
/// Security: Validates slot_id bounds to prevent out-of-bounds writes
pub fn registerDevice(device: *UsbDevice) void {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    // slot_id 0 is reserved for host controller
    if (device.slot_id > 0) {
        devices[device.slot_id] = device;
    }
}

/// Unregister a device from the global array
pub fn unregisterDevice(slot_id: u8) void {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    if (slot_id > 0) {
        devices[slot_id] = null;
    }
}

/// Find a device by slot ID
pub fn findDevice(slot_id: u8) ?*UsbDevice {
    // slot_id is u8, max value 255, which is < MAX_DEVICES (256)
    if (slot_id > 0) {
        return devices[slot_id];
    }
    return null;
}

/// Find first device in polling state (for interrupt handling)
pub fn findPollingDevice() ?*UsbDevice {
    for (devices) |maybe_dev| {
        if (maybe_dev) |dev| {
            if (dev.state == .polling) {
                return dev;
            }
        }
    }
    return null;
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
    /// Bytes transferred (or residual for short packet)
    bytes_transferred: u24,
};

/// Global pending transfer for synchronous operations
/// Only one control transfer at a time per device
/// Security: Use atomic flag for completed status to prevent race conditions
/// between interrupt handler and polling code.
var pending_transfer_storage: PendingTransfer = undefined;
var pending_transfer_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Start tracking a pending transfer
/// Security: Uses atomic operations for thread-safe initialization
pub fn startPendingTransfer(trb_phys: u64, slot_id: u8, ep_dci: u5) void {
    // Initialize the storage
    pending_transfer_storage = PendingTransfer{
        .trb_phys = trb_phys,
        .slot_id = slot_id,
        .ep_dci = ep_dci,
        .completed = std.atomic.Value(bool).init(false),
        .completion_code = .Invalid,
        .bytes_transferred = 0,
    };
    // Publish the transfer atomically
    pending_transfer_active.store(true, .release);
}

/// Mark pending transfer as completed
/// Security: Safe to call from interrupt context
pub fn completePendingTransfer(code: trb.CompletionCode, residual: u24) void {
    if (pending_transfer_active.load(.acquire)) {
        pending_transfer_storage.completion_code = code;
        pending_transfer_storage.bytes_transferred = residual;
        pending_transfer_storage.completed.store(true, .release);
    }
}

/// Check if pending transfer matches event
pub fn matchesPendingTransfer(slot_id: u8, ep_dci: u5) bool {
    if (pending_transfer_active.load(.acquire)) {
        const pt = &pending_transfer_storage;
        return pt.slot_id == slot_id and pt.ep_dci == ep_dci and !pt.completed.load(.acquire);
    }
    return false;
}

/// Get pending transfer if active (for polling)
pub fn getPendingTransfer() ?*PendingTransfer {
    if (pending_transfer_active.load(.acquire)) {
        return &pending_transfer_storage;
    }
    return null;
}

/// Clear pending transfer
pub fn clearPendingTransfer() void {
    pending_transfer_active.store(false, .release);
}
