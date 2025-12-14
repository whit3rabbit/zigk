// Input Subsystem
//
// Unified input event management for the kernel.
// Aggregates events from multiple input devices (PS/2, USB HID, VirtIO)
// and provides a unified interface for userspace via syscalls.
//
// Architecture:
//   - Input drivers push events via pushEvent()
//   - Syscall handlers consume events via popEvent()
//   - CursorManager tracks absolute position
//   - Thread wake support for blocking reads

const std = @import("std");
const sync = @import("sync");
const ring_buffer = @import("ring_buffer");
const uapi = @import("uapi");
const cursor_mod = @import("cursor.zig");

// Re-export cursor module
pub const CursorManager = cursor_mod.CursorManager;

// =============================================================================
// Constants
// =============================================================================

/// Maximum number of input devices
const MAX_DEVICES: usize = 8;

/// Event buffer size (must be power of 2)
const EVENT_BUFFER_SIZE: usize = 256;

// =============================================================================
// Event Buffer Type
// =============================================================================

pub const EventBuffer = ring_buffer.RingBuffer(uapi.input.InputEvent, EVENT_BUFFER_SIZE);

// =============================================================================
// Input Device Interface
// =============================================================================

/// Input device capabilities
pub const DeviceCapabilities = uapi.input.Capabilities;

/// Input device type identifier
pub const DeviceType = enum(u8) {
    unknown = 0,
    ps2_mouse = 1,
    usb_mouse = 2,
    usb_tablet = 3,
    virtio_mouse = 4,
    virtio_tablet = 5,
};

/// Input device registration info
pub const DeviceInfo = struct {
    /// Device type
    device_type: DeviceType = .unknown,
    /// Device name (for debugging)
    name: []const u8 = "unknown",
    /// Device capabilities
    capabilities: DeviceCapabilities = .{},
    /// Whether device provides absolute coordinates
    is_absolute: bool = false,
};

// =============================================================================
// Input Subsystem State
// =============================================================================

/// Input subsystem singleton state
const InputSubsystemState = struct {
    /// Unified event queue for userspace
    event_buffer: EventBuffer = .{},

    /// Cursor position manager
    cursor: CursorManager = CursorManager.default,

    /// Current button state (aggregated from all devices)
    button_state: u8 = 0,

    /// Registered device info (for debugging/enumeration)
    devices: [MAX_DEVICES]?DeviceInfo = [_]?DeviceInfo{null} ** MAX_DEVICES,
    device_count: u8 = 0,

    /// Lock for thread-safe access
    lock: sync.Spinlock = .{},

    /// Initialization flag
    initialized: bool = false,

    /// Statistics
    events_pushed: u64 = 0,
    events_dropped: u64 = 0,
};

// Global subsystem state
var state: InputSubsystemState = .{};

// =============================================================================
// Public API
// =============================================================================

/// Initialize the input subsystem
/// Called during kernel initialization before input drivers
pub fn init() void {
    const held = state.lock.acquire();
    defer held.release();

    if (state.initialized) return;

    state.event_buffer = .{};
    state.cursor = CursorManager.default;
    state.button_state = 0;
    state.device_count = 0;
    state.events_pushed = 0;
    state.events_dropped = 0;
    state.initialized = true;
}

/// Check if subsystem is initialized
pub fn isInitialized() bool {
    return @atomicLoad(bool, &state.initialized, .acquire);
}

/// Register an input device
/// Returns device index or error if full
pub fn registerDevice(info: DeviceInfo) !u8 {
    const held = state.lock.acquire();
    defer held.release();

    if (state.device_count >= MAX_DEVICES) {
        return error.TooManyDevices;
    }

    const idx = state.device_count;
    state.devices[idx] = info;
    state.device_count += 1;

    return idx;
}

/// Push an input event to the unified queue
/// Called by input drivers from interrupt context
pub fn pushEvent(event: uapi.input.InputEvent) void {
    const held = state.lock.acquire();
    defer held.release();

    if (!state.initialized) return;

    // Update cursor for relative/absolute events
    switch (event.event_type) {
        .EV_REL => {
            if (event.code == uapi.input.RelCode.X) {
                state.cursor.applyDelta(@truncate(event.value), 0);
            } else if (event.code == uapi.input.RelCode.Y) {
                state.cursor.applyDelta(0, @truncate(event.value));
            }
        },
        .EV_KEY => {
            // Update button state
            updateButtonState(event.code, event.value != 0);
        },
        else => {},
    }

    // Push to event queue
    const dropped = state.event_buffer.push(event);
    state.events_pushed += 1;
    if (dropped) {
        state.events_dropped += 1;
    }
}

/// Push a relative movement event (convenience wrapper)
pub fn pushRelative(code: u16, value: i32, timestamp_ns: u64) void {
    pushEvent(.{
        .timestamp_ns = timestamp_ns,
        .event_type = .EV_REL,
        .code = code,
        .value = value,
    });
}

/// Push an absolute position event (convenience wrapper)
pub fn pushAbsolute(code: u16, value: i32, timestamp_ns: u64) void {
    pushEvent(.{
        .timestamp_ns = timestamp_ns,
        .event_type = .EV_ABS,
        .code = code,
        .value = value,
    });
}

/// Push a button event (convenience wrapper)
pub fn pushButton(code: u16, pressed: bool, timestamp_ns: u64) void {
    pushEvent(.{
        .timestamp_ns = timestamp_ns,
        .event_type = .EV_KEY,
        .code = code,
        .value = if (pressed) 1 else 0,
    });
}

/// Push a sync event (marks end of a set of events)
pub fn pushSync(timestamp_ns: u64) void {
    pushEvent(.{
        .timestamp_ns = timestamp_ns,
        .event_type = .EV_SYN,
        .code = uapi.input.SynCode.REPORT,
        .value = 0,
    });
}

/// Pop an event from the queue (non-blocking)
/// Returns null if no events available
pub fn popEvent() ?uapi.input.InputEvent {
    const held = state.lock.acquire();
    defer held.release();

    return state.event_buffer.pop();
}

/// Check if events are available
pub fn hasEvents() bool {
    const held = state.lock.acquire();
    defer held.release();

    return !state.event_buffer.isEmpty();
}

/// Cursor position result type
pub const CursorPositionResult = struct { x: i32, y: i32 };

/// Get current cursor position
pub fn getCursorPosition() CursorPositionResult {
    const held = state.lock.acquire();
    defer held.release();

    const pos = state.cursor.getPosition();
    return .{ .x = pos.x, .y = pos.y };
}

/// Get current button state as bitmask
pub fn getButtonState() u8 {
    const held = state.lock.acquire();
    defer held.release();

    return state.button_state;
}

/// Set cursor bounds (screen dimensions)
pub fn setCursorBounds(width: u32, height: u32) void {
    const held = state.lock.acquire();
    defer held.release();

    state.cursor.setBounds(width, height);
}

/// Set cursor sensitivity
pub fn setCursorSensitivity(sensitivity: u16) void {
    const held = state.lock.acquire();
    defer held.release();

    state.cursor.setSensitivity(sensitivity);
}

/// Get subsystem statistics
pub fn getStats() struct { events_pushed: u64, events_dropped: u64, queue_len: usize } {
    const held = state.lock.acquire();
    defer held.release();

    return .{
        .events_pushed = state.events_pushed,
        .events_dropped = state.events_dropped,
        .queue_len = state.event_buffer.len(),
    };
}

/// Get number of registered devices
pub fn getDeviceCount() u8 {
    const held = state.lock.acquire();
    defer held.release();

    return state.device_count;
}

/// Get device info by index
pub fn getDeviceInfo(idx: u8) ?DeviceInfo {
    const held = state.lock.acquire();
    defer held.release();

    if (idx >= state.device_count) return null;
    return state.devices[idx];
}

// =============================================================================
// Internal Functions
// =============================================================================

/// Update button state from button event
fn updateButtonState(code: u16, pressed: bool) void {
    const bit: u8 = switch (code) {
        uapi.input.BtnCode.LEFT => 0x01,
        uapi.input.BtnCode.RIGHT => 0x02,
        uapi.input.BtnCode.MIDDLE => 0x04,
        uapi.input.BtnCode.SIDE => 0x08,
        uapi.input.BtnCode.EXTRA => 0x10,
        else => return,
    };

    if (pressed) {
        state.button_state |= bit;
    } else {
        state.button_state &= ~bit;
    }
}

// =============================================================================
// Unit Tests
// =============================================================================

test "InputSubsystem basic operations" {
    // Reset state for test
    state = .{};
    init();

    try std.testing.expect(isInitialized());
    try std.testing.expect(!hasEvents());

    // Push an event
    pushRelative(uapi.input.RelCode.X, 10, 0);
    try std.testing.expect(hasEvents());

    // Pop the event
    const event = popEvent();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(uapi.input.EventType.EV_REL, event.?.event_type);
    try std.testing.expectEqual(uapi.input.RelCode.X, event.?.code);
    try std.testing.expectEqual(@as(i32, 10), event.?.value);

    try std.testing.expect(!hasEvents());
}

test "InputSubsystem cursor tracking" {
    state = .{};
    init();

    // Set bounds
    setCursorBounds(1920, 1080);

    // Push relative movement
    pushRelative(uapi.input.RelCode.X, 100, 0);
    pushRelative(uapi.input.RelCode.Y, -50, 0); // Negative Y moves cursor down

    const pos = getCursorPosition();
    try std.testing.expectEqual(@as(i32, 100), pos.x);
    try std.testing.expectEqual(@as(i32, 50), pos.y);
}

test "InputSubsystem button state" {
    state = .{};
    init();

    // Press left button
    pushButton(uapi.input.BtnCode.LEFT, true, 0);
    try std.testing.expectEqual(@as(u8, 0x01), getButtonState());

    // Press right button
    pushButton(uapi.input.BtnCode.RIGHT, true, 0);
    try std.testing.expectEqual(@as(u8, 0x03), getButtonState());

    // Release left button
    pushButton(uapi.input.BtnCode.LEFT, false, 0);
    try std.testing.expectEqual(@as(u8, 0x02), getButtonState());
}
