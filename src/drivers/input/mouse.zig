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

// =============================================================================
// PS/2 Controller Ports and Commands
// =============================================================================

const PS2_DATA_PORT: u16 = 0x60;
const PS2_CMD_PORT: u16 = 0x64;

// Controller commands (sent to 0x64)
const CMD_READ_CONFIG: u8 = 0x20;
const CMD_WRITE_CONFIG: u8 = 0x60;
const CMD_DISABLE_SECOND_PORT: u8 = 0xA7;
const CMD_ENABLE_SECOND_PORT: u8 = 0xA8;
const CMD_TEST_SECOND_PORT: u8 = 0xA9;
const CMD_WRITE_MOUSE: u8 = 0xD4; // Send next byte to mouse

// Mouse commands (sent via CMD_WRITE_MOUSE)
const MOUSE_CMD_RESET: u8 = 0xFF;
const MOUSE_CMD_RESEND: u8 = 0xFE;
const MOUSE_CMD_SET_DEFAULTS: u8 = 0xF6;
const MOUSE_CMD_DISABLE_STREAMING: u8 = 0xF5;
const MOUSE_CMD_ENABLE_STREAMING: u8 = 0xF4;
const MOUSE_CMD_SET_SAMPLE_RATE: u8 = 0xF3;
const MOUSE_CMD_GET_DEVICE_ID: u8 = 0xF2;
const MOUSE_CMD_SET_RESOLUTION: u8 = 0xE8;

// Mouse responses
const MOUSE_ACK: u8 = 0xFA;
const MOUSE_RESEND: u8 = 0xFE;
const MOUSE_SELF_TEST_PASSED: u8 = 0xAA;

// Config byte bits
const CONFIG_SECOND_PORT_IRQ: u8 = 0x02;
const CONFIG_SECOND_PORT_CLOCK: u8 = 0x20;

// =============================================================================
// PS/2 Status Register
// =============================================================================

const StatusReg = packed struct(u8) {
    output_buffer_full: bool,
    input_buffer_full: bool,
    system_flag: bool,
    command_data: bool,
    _reserved1: bool = false,
    mouse_data: bool, // Bit 5: 1 = data from mouse, 0 = data from keyboard
    timeout_error: bool,
    parity_error: bool,

    pub fn read() StatusReg {
        return @bitCast(hal.io.inb(PS2_CMD_PORT));
    }

    pub fn hasData(self: StatusReg) bool {
        return self.output_buffer_full;
    }

    pub fn isMouseData(self: StatusReg) bool {
        return self.mouse_data;
    }

    pub fn canWrite(self: StatusReg) bool {
        return !self.input_buffer_full;
    }
};

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
// PS/2 Controller Helpers
// =============================================================================

fn waitInputEmpty() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if (StatusReg.read().canWrite()) return true;
    }
    return false;
}

fn waitOutputFull() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if (StatusReg.read().hasData()) return true;
    }
    return false;
}

fn sendCommand(cmd: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(PS2_CMD_PORT, cmd);
}

fn sendData(data: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(PS2_DATA_PORT, data);
}

fn readData() ?u8 {
    if (waitOutputFull()) {
        return hal.io.inb(PS2_DATA_PORT);
    }
    return null;
}

fn flushBuffer() void {
    var count: u32 = 0;
    while (StatusReg.read().output_buffer_full and count < 16) {
        _ = hal.io.inb(PS2_DATA_PORT);
        count += 1;
    }
}

/// Send a command to the mouse (via controller's D4 command)
/// Retries on RESEND (0xFE) response, up to 3 attempts
fn sendMouseCommand(cmd: u8) bool {
    var retries: u8 = 3;
    while (retries > 0) : (retries -= 1) {
        sendCommand(CMD_WRITE_MOUSE);
        sendData(cmd);

        const response = readData() orelse return false;
        if (response == MOUSE_ACK) return true;
        if (response == MOUSE_RESEND) continue; // Retry
        return false; // Unexpected response
    }
    return false; // Max retries exceeded
}

/// Send a command with a data byte to the mouse
fn sendMouseCommandWithData(cmd: u8, data: u8) bool {
    if (!sendMouseCommand(cmd)) return false;
    sendCommand(CMD_WRITE_MOUSE);
    sendData(data);

    const response = readData() orelse return false;
    return response == MOUSE_ACK;
}

// =============================================================================
// Public API
// =============================================================================

/// Inject a mouse event from an external source (e.g., USB HID driver)
pub fn injectRawInput(dx: i16, dy: i16, dz: i8, buttons: Buttons) void {
    const held = mouse_lock.acquire();
    defer held.release();

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
}

/// Inject absolute position from a tablet/touchscreen device
/// x, y: screen coordinates (0 to width-1, 0 to height-1)
/// max_x, max_y: screen dimensions
pub fn injectAbsoluteInput(x: u32, y: u32, max_x: u32, max_y: u32, buttons: Buttons) void {
    const held = mouse_lock.acquire();
    defer held.release();

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
}

/// Initialize the PS/2 mouse
pub fn init() void {
    if (@atomicLoad(bool, &mouse_initialized, .acquire)) return;

    console.info("PS/2 mouse: initializing", .{});

    // 1. Enable the second PS/2 port (mouse)
    sendCommand(CMD_ENABLE_SECOND_PORT);

    // 2. Test the second port
    sendCommand(CMD_TEST_SECOND_PORT);
    const port_test = readData();
    if (port_test) |result| {
        if (result != 0x00) {
            console.warn("PS/2 mouse: port test returned 0x{X:0>2}", .{result});
        }
    } else {
        console.warn("PS/2 mouse: port test timeout", .{});
    }

    // 3. Enable second port IRQ in controller config
    sendCommand(CMD_READ_CONFIG);
    var config = readData() orelse 0x00;
    config |= CONFIG_SECOND_PORT_IRQ; // Enable IRQ12
    config &= ~CONFIG_SECOND_PORT_CLOCK; // Enable clock (clear disable bit)

    sendCommand(CMD_WRITE_CONFIG);
    sendData(config);

    // 4. Reset the mouse
    flushBuffer();
    if (sendMouseCommand(MOUSE_CMD_RESET)) {
        // Wait for self-test result (0xAA) and device ID (0x00)
        const self_test = readData();
        const device_id = readData();

        if (self_test) |st| {
            if (st != MOUSE_SELF_TEST_PASSED) {
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
    _ = sendMouseCommand(MOUSE_CMD_SET_DEFAULTS);
    _ = sendMouseCommandWithData(MOUSE_CMD_SET_SAMPLE_RATE, 100); // 100 samples/sec
    _ = sendMouseCommandWithData(MOUSE_CMD_SET_RESOLUTION, 2); // 4 counts/mm

    // 7. Enable data streaming
    if (!sendMouseCommand(MOUSE_CMD_ENABLE_STREAMING)) {
        console.warn("PS/2 mouse: failed to enable streaming", .{});
    }

    @atomicStore(bool, &mouse_initialized, true, .release);
    console.info("PS/2 mouse: initialized", .{});
}

/// Try to enable IntelliMouse scroll wheel mode
fn enableScrollWheel() bool {
    // Magic sequence: set sample rate to 200, 100, 80
    if (!sendMouseCommandWithData(MOUSE_CMD_SET_SAMPLE_RATE, 200)) return false;
    if (!sendMouseCommandWithData(MOUSE_CMD_SET_SAMPLE_RATE, 100)) return false;
    if (!sendMouseCommandWithData(MOUSE_CMD_SET_SAMPLE_RATE, 80)) return false;

    // Get device ID - should be 0x03 for IntelliMouse
    if (!sendMouseCommand(MOUSE_CMD_GET_DEVICE_ID)) return false;

    const id = readData() orelse return false;
    return id == 0x03;
}

/// Handle mouse IRQ (called from IRQ12 handler)
pub fn handleIrq() void {
    if (!@atomicLoad(bool, &mouse_initialized, .acquire)) {
        // Discard data to acknowledge
        _ = hal.io.inb(PS2_DATA_PORT);
        return;
    }

    const status = StatusReg.read();

    // Verify data is from mouse
    if (!status.hasData() or !status.isMouseData()) {
        return;
    }

    const byte = hal.io.inb(PS2_DATA_PORT);

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

        // Push relative movement events
        if (dx != 0) {
            input.pushRelative(uapi.input.RelCode.X, @as(i32, dx), timestamp);
        }
        if (dy != 0) {
            input.pushRelative(uapi.input.RelCode.Y, @as(i32, dy), timestamp);
        }
        if (dz != 0) {
            input.pushRelative(uapi.input.RelCode.WHEEL, @as(i32, dz), timestamp);
        }

        // Push button events on change
        if (buttons_changed.left) {
            input.pushButton(uapi.input.BtnCode.LEFT, buttons.left, timestamp);
        }
        if (buttons_changed.right) {
            input.pushButton(uapi.input.BtnCode.RIGHT, buttons.right, timestamp);
        }
        if (buttons_changed.middle) {
            input.pushButton(uapi.input.BtnCode.MIDDLE, buttons.middle, timestamp);
        }

        // Push sync event to mark end of this packet's events
        input.pushSync(timestamp);
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
    const held = mouse_lock.acquire();
    defer held.release();

    return mouse_state.event_buffer.pop();
}

/// Check if there are events available
pub fn hasEvent() bool {
    const held = mouse_lock.acquire();
    defer held.release();

    return !mouse_state.event_buffer.isEmpty();
}

/// Get current button state
pub fn getButtons() Buttons {
    const held = mouse_lock.acquire();
    defer held.release();

    return mouse_state.prev_buttons;
}

/// Check if mouse has scroll wheel (thread-safe)
pub fn hasScrollWheel() bool {
    const held = mouse_lock.acquire();
    defer held.release();
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
