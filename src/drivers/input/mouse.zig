//! PS/2 Mouse Driver
//!
//! Handles mouse input via IRQ12 (PS/2 controller port 2).
//! Parses 3-byte standard packets or 4-byte IntelliMouse packets (with scroll wheel).
//! Provides movement deltas and button events.
//!
//! Features:
//! - Auto-detection of IntelliMouse extension (scroll wheel).
//! - Packet synchronization/resync logic.
//! - Ring buffer for event storage.
//! - Integration with high-level input subsystem.

const hal = @import("hal");
const sync = @import("sync");
const ring_buffer = @import("ring_buffer");
const console = @import("console");
const input = @import("input");
const uapi = @import("uapi");

// Import shared PS/2 controller module
const ps2 = @import("ps2");

// Re-export StatusReg for backward compatibility
pub const StatusReg = ps2.StatusReg;

// =============================================================================
// Mouse Event Types
// =============================================================================

/// Mouse button state
pub const Buttons = packed struct(u8) {
    left: bool,
    right: bool,
    middle: bool,
    _reserved: u5 = 0,
};

/// Mouse event with movement and button state
pub const MouseEvent = struct {
    /// X movement delta (positive = right)
    dx: i16,
    /// Y movement delta (positive = up, inverted from raw PS/2)
    dy: i16,
    /// Scroll wheel delta (positive = up)
    dz: i8,
    /// Current button state
    buttons: Buttons,
    /// Button state changed since last event
    buttons_changed: Buttons,
};

// =============================================================================
// Ring Buffer
// =============================================================================

const EVENT_BUFFER_SIZE: usize = 64;
pub const EventBuffer = ring_buffer.RingBuffer(MouseEvent, EVENT_BUFFER_SIZE);

// =============================================================================
// Mouse State
// =============================================================================

const MouseState = struct {
    /// Event buffer for userspace
    event_buffer: EventBuffer = .{},

    /// Packet assembly buffer
    packet: [4]u8 = .{ 0, 0, 0, 0 },
    /// Current byte index in packet
    packet_index: u8 = 0,
    /// Expected packet size (3 for standard, 4 for scroll wheel)
    packet_size: u8 = 3,

    /// Previous button state for change detection
    prev_buttons: Buttons = .{ .left = false, .right = false, .middle = false },

    /// Mouse has scroll wheel (IntelliMouse)
    has_scroll_wheel: bool = false,

    /// Input subsystem device identifier
    device_id: u16 = 0,

    /// Consecutive packet errors for resync detection
    consecutive_errors: u8 = 0,
};

// Resync after this many consecutive bad packets
const RESYNC_THRESHOLD: u8 = 5;

/// Error statistics
pub const ErrorStats = struct {
    packet_errors: u32 = 0,
    overflow_errors: u32 = 0,
    buffer_overruns: u32 = 0,
    resync_count: u32 = 0,
    total_packets: u32 = 0, // For flood detection
    flood_warnings: u32 = 0,
};

// Rate limiting constants
const FLOOD_THRESHOLD: u32 = 1000; // Warn if this many packets without buffer drain

// Global state
var mouse_state: MouseState = .{};
var mouse_lock: sync.Spinlock = .{};
var mouse_initialized: bool = false; // Access via atomic ops only
var error_stats: ErrorStats = .{};

// =============================================================================
// Public API
// =============================================================================

/// Inject a mouse event from an external source (e.g., USB HID driver)
pub fn injectRawInput(device_id: u16, dx: i16, dy: i16, dz: i8, buttons: Buttons) void {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    const buttons_changed = Buttons{
        .left = buttons.left != mouse_state.prev_buttons.left,
        .right = buttons.right != mouse_state.prev_buttons.right,
        .middle = buttons.middle != mouse_state.prev_buttons.middle,
    };

    mouse_state.prev_buttons = buttons;

    const event = MouseEvent{
        .dx = dx,
        .dy = dy,
        .dz = dz,
        .buttons = buttons,
        .buttons_changed = buttons_changed,
    };

    if (mouse_state.event_buffer.push(event)) {
        error_stats.buffer_overruns +%= 1;
    }

    // Push to unified input subsystem (for syscall read_input_event)
    if (input.isInitialized()) {
        const timestamp: u64 = 0; // TODO: proper timestamp from HAL
        if (dx != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.X, @as(i32, dx), timestamp);
        }
        if (dy != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.Y, @as(i32, dy), timestamp);
        }
        if (dz != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.WHEEL, @as(i32, dz), timestamp);
        }
        if (buttons_changed.left) {
            input.pushButton(device_id, uapi.input.BtnCode.LEFT, buttons.left, timestamp);
        }
        if (buttons_changed.right) {
            input.pushButton(device_id, uapi.input.BtnCode.RIGHT, buttons.right, timestamp);
        }
        if (buttons_changed.middle) {
            input.pushButton(device_id, uapi.input.BtnCode.MIDDLE, buttons.middle, timestamp);
        }
        input.pushSync(device_id, timestamp);
    }
}

/// Inject absolute position from a tablet/touchscreen device
/// x, y: screen coordinates (0 to width-1, 0 to height-1)
/// max_x, max_y: screen dimensions
pub fn injectAbsoluteInput(device_id: u16, x: u32, y: u32, max_x: u32, max_y: u32, buttons: Buttons) void {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    // Update cursor position using absolute coordinates
    input.setCursorAbsolute(x, y, max_x, max_y);

    const buttons_changed = Buttons{
        .left = buttons.left != mouse_state.prev_buttons.left,
        .right = buttons.right != mouse_state.prev_buttons.right,
        .middle = buttons.middle != mouse_state.prev_buttons.middle,
    };

    mouse_state.prev_buttons = buttons;

    // Create event with zero delta (position is absolute)
    const event = MouseEvent{
        .dx = 0,
        .dy = 0,
        .dz = 0,
        .buttons = buttons,
        .buttons_changed = buttons_changed,
    };

    if (mouse_state.event_buffer.push(event)) {
        error_stats.buffer_overruns +%= 1;
    }

    // Push to unified input subsystem (for syscall read_input_event)
    if (input.isInitialized()) {
        const timestamp: u64 = 0; // TODO: proper timestamp from HAL

        // Push absolute position events
        input.pushAbsolute(device_id, uapi.input.AbsCode.X, @as(i32, @intCast(x)), timestamp);
        input.pushAbsolute(device_id, uapi.input.AbsCode.Y, @as(i32, @intCast(y)), timestamp);

        // Push button events on change
        if (buttons_changed.left) {
            input.pushButton(device_id, uapi.input.BtnCode.LEFT, buttons.left, timestamp);
        }
        if (buttons_changed.right) {
            input.pushButton(device_id, uapi.input.BtnCode.RIGHT, buttons.right, timestamp);
        }
        if (buttons_changed.middle) {
            input.pushButton(device_id, uapi.input.BtnCode.MIDDLE, buttons.middle, timestamp);
        }
        input.pushSync(device_id, timestamp);
    }
}

/// Initialize the PS/2 mouse
pub fn init() void {
    if (@atomicLoad(bool, &mouse_initialized, .acquire)) return;

    console.info("PS/2 mouse: initializing", .{});
    if (input.isInitialized()) {
        mouse_state.device_id = input.registerDevice(.{
            .device_type = .ps2_mouse,
            .name = "ps2-mouse",
            .capabilities = .{
                .has_rel = true,
                .has_left = true,
                .has_right = true,
                .has_middle = true,
                .has_wheel = true,
            },
            .is_absolute = false,
        }) catch 0;
    }

    // 1. Enable the second PS/2 port (mouse)
    ps2.sendCommand(ps2.CMD_ENABLE_SECOND_PORT);

    // 2. Test the second port
    ps2.sendCommand(ps2.CMD_TEST_SECOND_PORT);
    const port_test = ps2.readData();
    if (port_test) |result| {
        if (result != 0x00) {
            console.warn("PS/2 mouse: port test returned 0x{X:0>2}", .{result});
        }
    } else {
        console.warn("PS/2 mouse: port test timeout", .{});
    }

    // 3. Enable second port IRQ in controller config
    ps2.sendCommand(ps2.CMD_READ_CONFIG);
    var config = ps2.readData() orelse 0x00;
    config |= ps2.CONFIG_SECOND_PORT_IRQ; // Enable IRQ12
    config &= ~ps2.CONFIG_SECOND_PORT_CLOCK; // Enable clock (clear disable bit)

    ps2.sendCommand(ps2.CMD_WRITE_CONFIG);
    ps2.sendData(config);

    // 4. Reset the mouse
    ps2.flushBuffer();
    if (ps2.sendMouseCommand(ps2.MOUSE_CMD_RESET)) {
        // Wait for self-test result (0xAA) and device ID (0x00)
        const self_test = ps2.readData();
        const device_id = ps2.readData();

        if (self_test) |st| {
            if (st != ps2.MOUSE_SELF_TEST_PASSED) {
                console.warn("PS/2 mouse: self-test returned 0x{X:0>2}", .{st});
            }
        }
        _ = device_id; // Standard mouse returns 0x00
    } else {
        console.warn("PS/2 mouse: reset command failed", .{});
    }

    // 5. Try to enable scroll wheel (IntelliMouse magic sequence)
    // Set sample rate to 200, 100, 80 in sequence
    if (enableScrollWheel()) {
        mouse_state.has_scroll_wheel = true;
        mouse_state.packet_size = 4;
        console.info("PS/2 mouse: scroll wheel detected", .{});
    }

    // 6. Set default parameters
    _ = ps2.sendMouseCommand(ps2.MOUSE_CMD_SET_DEFAULTS);
    _ = ps2.sendMouseCommandWithData(ps2.MOUSE_CMD_SET_SAMPLE_RATE, 100); // 100 samples/sec
    _ = ps2.sendMouseCommandWithData(ps2.MOUSE_CMD_SET_RESOLUTION, 2); // 4 counts/mm

    // 7. Enable data streaming
    if (!ps2.sendMouseCommand(ps2.MOUSE_CMD_ENABLE_STREAMING)) {
        console.warn("PS/2 mouse: failed to enable streaming", .{});
    }

    @atomicStore(bool, &mouse_initialized, true, .release);
    console.info("PS/2 mouse: initialized", .{});
}

/// Try to enable IntelliMouse scroll wheel mode
fn enableScrollWheel() bool {
    // Magic sequence: set sample rate to 200, 100, 80
    if (!ps2.sendMouseCommandWithData(ps2.MOUSE_CMD_SET_SAMPLE_RATE, 200)) return false;
    if (!ps2.sendMouseCommandWithData(ps2.MOUSE_CMD_SET_SAMPLE_RATE, 100)) return false;
    if (!ps2.sendMouseCommandWithData(ps2.MOUSE_CMD_SET_SAMPLE_RATE, 80)) return false;

    // Get device ID - should be 0x03 for IntelliMouse
    if (!ps2.sendMouseCommand(ps2.MOUSE_CMD_GET_DEVICE_ID)) return false;

    const id = ps2.readData() orelse return false;
    return id == 0x03;
}

/// Handle mouse IRQ (called from IRQ12 handler)
pub fn handleIrq() void {
    if (!@atomicLoad(bool, &mouse_initialized, .acquire)) {
        // Discard data to acknowledge
        _ = hal.io.inb(ps2.DATA_PORT);
        return;
    }

    const status = ps2.StatusReg.read();

    // Check if data is available
    if (!status.hasData()) {
        // Spurious IRQ - still read from data port to clear controller state
        // Some emulators may not deliver subsequent IRQs if buffer isn't cleared
        _ = hal.io.inb(ps2.DATA_PORT);
        return;
    }

    // Skip keyboard data - read to clear buffer but don't process
    // (Symmetric with keyboard handler which skips mouse data)
    if (!status.isMouseData()) {
        _ = hal.io.inb(ps2.DATA_PORT);
        return;
    }

    const byte = hal.io.inb(ps2.DATA_PORT);

    const held = mouse_lock.acquire();
    defer held.release();

    // First byte of packet must have bit 3 set (always 1)
    if (mouse_state.packet_index == 0 and (byte & 0x08) == 0) {
        // Out of sync - discard and wait for valid first byte
        error_stats.packet_errors +%= 1;
        mouse_state.consecutive_errors +%= 1;

        // Log resync after threshold consecutive errors
        if (mouse_state.consecutive_errors >= RESYNC_THRESHOLD) {
            error_stats.resync_count +%= 1;
            mouse_state.consecutive_errors = 0;
            console.warn("PS/2 mouse: resyncing packet stream", .{});
        }
        return;
    }

    // Valid byte received - reset error counter
    mouse_state.consecutive_errors = 0;

    mouse_state.packet[mouse_state.packet_index] = byte;
    mouse_state.packet_index += 1;

    // Check if packet is complete
    if (mouse_state.packet_index >= mouse_state.packet_size) {
        processPacket();
        mouse_state.packet_index = 0;
    }
}

/// Process a complete mouse packet
fn processPacket() void {
    const packet = mouse_state.packet;

    // Byte 0: Y overflow, X overflow, Y sign, X sign, 1, Middle, Right, Left
    const flags = packet[0];

    // Check for overflow - discard packet if set
    if ((flags & 0xC0) != 0) {
        error_stats.overflow_errors +%= 1;
        return;
    }

    // Extract button state
    const buttons = Buttons{
        .left = (flags & 0x01) != 0,
        .right = (flags & 0x02) != 0,
        .middle = (flags & 0x04) != 0,
    };

    // Extract movement deltas with proper sign extension
    // PS/2 uses 9-bit signed values: 8 data bits + sign bit in flags
    const dx: i16 = if ((flags & 0x10) != 0)
        @as(i16, packet[1]) - 256
    else
        @as(i16, packet[1]);

    // Y is inverted so positive = up (standard convention)
    const dy: i16 = if ((flags & 0x20) != 0)
        256 - @as(i16, packet[2])
    else
        -@as(i16, packet[2]);

    // Extract scroll wheel if present (4-bit signed value)
    const dz: i8 = if (mouse_state.has_scroll_wheel) blk: {
        const raw: u8 = packet[3] & 0x0F;
        // Sign extend from 4 bits: if bit 3 set, value is negative
        break :blk if ((raw & 0x08) != 0)
            @as(i8, @bitCast(raw | 0xF0)) // Sign extend by setting upper bits
        else
            @as(i8, @intCast(raw));
    } else 0;

    // Detect button changes
    const buttons_changed = Buttons{
        .left = buttons.left != mouse_state.prev_buttons.left,
        .right = buttons.right != mouse_state.prev_buttons.right,
        .middle = buttons.middle != mouse_state.prev_buttons.middle,
    };

    mouse_state.prev_buttons = buttons;

    // Create event
    const event = MouseEvent{
        .dx = dx,
        .dy = dy,
        .dz = dz,
        .buttons = buttons,
        .buttons_changed = buttons_changed,
    };

    // Push to legacy buffer (for backward compat with existing API)
    if (mouse_state.event_buffer.push(event)) {
        error_stats.buffer_overruns +%= 1;
    }

    // Push to input subsystem if initialized
    if (input.isInitialized()) {
        const timestamp: u64 = 0; // TODO: proper timestamp from HAL
        const device_id = mouse_state.device_id;

        // Push relative movement events
        if (dx != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.X, @as(i32, dx), timestamp);
        }
        if (dy != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.Y, @as(i32, dy), timestamp);
        }
        if (dz != 0) {
            input.pushRelative(device_id, uapi.input.RelCode.WHEEL, @as(i32, dz), timestamp);
        }

        // Push button events on change
        if (buttons_changed.left) {
            input.pushButton(device_id, uapi.input.BtnCode.LEFT, buttons.left, timestamp);
        }
        if (buttons_changed.right) {
            input.pushButton(device_id, uapi.input.BtnCode.RIGHT, buttons.right, timestamp);
        }
        if (buttons_changed.middle) {
            input.pushButton(device_id, uapi.input.BtnCode.MIDDLE, buttons.middle, timestamp);
        }

        // Push sync event to mark end of this packet's events
        input.pushSync(device_id, timestamp);
    }

    // Flood detection: track total packets and warn if buffer keeps overflowing
    error_stats.total_packets +%= 1;
    if (error_stats.buffer_overruns > 0 and
        error_stats.total_packets > FLOOD_THRESHOLD and
        error_stats.buffer_overruns * 10 > error_stats.total_packets)
    {
        // More than 10% of packets are overruns - potential flood
        if (error_stats.flood_warnings == 0) {
            console.warn("PS/2 mouse: possible packet flood detected", .{});
        }
        error_stats.flood_warnings +%= 1;
    }
}

/// Get a mouse event (non-blocking)
pub fn getEvent() ?MouseEvent {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    return mouse_state.event_buffer.pop();
}

/// Check if there are events available
pub fn hasEvent() bool {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    return !mouse_state.event_buffer.isEmpty();
}

/// Get current button state
pub fn getButtons() Buttons {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }

    return mouse_state.prev_buttons;
}

/// Check if mouse has scroll wheel (thread-safe)
pub fn hasScrollWheel() bool {
    const flags = hal.cpu.disableInterruptsSaveFlags();
    const held = mouse_lock.acquire();
    defer {
        held.release();
        hal.cpu.restoreInterrupts(flags);
    }
    return mouse_state.has_scroll_wheel;
}

/// Check if mouse is initialized (thread-safe)
pub fn isInitialized() bool {
    return @atomicLoad(bool, &mouse_initialized, .acquire);
}

/// Get error statistics
pub fn getErrorStats() ErrorStats {
    return error_stats;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "Buttons packed struct size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Buttons));
}

test "StatusReg packed struct size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StatusReg));
}
