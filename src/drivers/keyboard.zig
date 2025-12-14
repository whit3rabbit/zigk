// PS/2 Keyboard Driver
//
// Handles keyboard input via IRQ1, providing both raw scancodes and ASCII characters.
// Uses dual ring buffers to support both shell input and game scancode reading.
//
// Spec Reference: Spec 003 FR-030, FR-030a/b
//
// Features:
//   - Raw scancode buffer (64 entries) for games
//   - ASCII character buffer (256 entries) for shell
//   - KeyEvent buffer (64 entries) for rich event handling
//   - PS/2 Set 1 scancode to ASCII translation (comptime-generated tables)
//   - Modifier key tracking (Shift, Ctrl, Alt)
//   - Extended key support (arrows, Insert, Delete, Home, End, Page Up/Down)
//   - Thread-safe via Spinlock
//
// SCANCODE SET ASSUMPTION:
// This driver assumes Set 1 (XT) scancode mode, which is the default for most
// PC keyboards when the i8042 controller is in translation mode.

const hal = @import("hal");
const sync = @import("sync");
const ring_buffer = @import("ring_buffer");
const console = @import("console");
const uapi = @import("uapi");
const sched = @import("sched");
const thread_mod = @import("thread");
const layout_mod = @import("input/layout.zig");
const us_layout = @import("input/layouts/us.zig");
const dvorak_layout = @import("input/layouts/dvorak.zig");

/// Keyboard data port (read scancodes)
const KEYBOARD_DATA_PORT: u16 = 0x60;

/// Keyboard status/command port
const KEYBOARD_STATUS_PORT: u16 = 0x64;

// PS/2 Controller Commands (sent to 0x64)
const CMD_DISABLE_FIRST_PORT: u8 = 0xAD;
const CMD_DISABLE_SECOND_PORT: u8 = 0xA7;
const CMD_ENABLE_FIRST_PORT: u8 = 0xAE;
const CMD_READ_CONFIG: u8 = 0x20;
const CMD_WRITE_CONFIG: u8 = 0x60;
const CMD_SELF_TEST: u8 = 0xAA;
const CMD_TEST_FIRST_PORT: u8 = 0xAB;

// Keyboard Device Commands
const KBD_CMD_ENABLE: u8 = 0xF4;
const KBD_ACK: u8 = 0xFA;

// PS/2 Response Codes
const SELF_TEST_PASSED: u8 = 0x55;
const PORT_TEST_PASSED: u8 = 0x00;

// PS/2 Config Byte Bits
const CONFIG_FIRST_PORT_IRQ: u8 = 0x01;
const CONFIG_SECOND_PORT_IRQ: u8 = 0x02;
const CONFIG_TRANSLATION: u8 = 0x40;

// =============================================================================
// PS/2 Status Register (packed struct for type-safe bit access)
// =============================================================================

/// PS/2 Controller Status Register (port 0x64)
/// Provides type-safe access to status bits without manual bit masking
pub const StatusReg = packed struct(u8) {
    /// Output buffer full - data available to read from port 0x60
    output_buffer_full: bool,
    /// Input buffer full - controller busy, don't write yet
    input_buffer_full: bool,
    /// System flag - set by firmware during POST
    system_flag: bool,
    /// Command/data - 0: data written to 0x60, 1: command written to 0x64
    command_data: bool,
    /// Reserved (keyboard-specific on some controllers)
    _reserved1: bool = false,
    /// Mouse data - 1: data in output buffer is from mouse, 0: from keyboard
    mouse_data: bool,
    /// Timeout error - communication timeout
    timeout_error: bool,
    /// Parity error - data transmission error
    parity_error: bool,

    comptime {
        if (@sizeOf(@This()) != 1) @compileError("StatusReg must be 1 byte");
    }

    /// Read status register from hardware
    pub fn read() StatusReg {
        return @bitCast(hal.io.inb(KEYBOARD_STATUS_PORT));
    }

    /// Check if data is available to read
    pub fn hasData(self: StatusReg) bool {
        return self.output_buffer_full;
    }

    /// Check if any error occurred
    pub fn hasError(self: StatusReg) bool {
        return self.timeout_error or self.parity_error;
    }

    /// Check if controller is ready to accept input
    pub fn canWrite(self: StatusReg) bool {
        return !self.input_buffer_full;
    }

    /// Check if data is from mouse (not keyboard)
    pub fn isMouseData(self: StatusReg) bool {
        return self.mouse_data;
    }
};

// =============================================================================
// KeyEvent Tagged Union (type-safe key event representation)
// =============================================================================

/// Rich key event type providing type-safe access to different key categories
/// Inspired by Linux input subsystem but using Zig tagged unions
pub const KeyEvent = union(enum) {
    /// Printable ASCII character
    char: u8,
    /// Control keys (Escape, Backspace, Tab, Enter, Delete)
    control: ControlKey,
    /// Navigation keys (arrows, Home, End, Page Up/Down, Insert)
    navigation: NavigationKey,
    /// Function keys (F1-F12)
    function: FunctionKey,
    /// Modifier key state change
    modifier: ModifierEvent,

    pub const ControlKey = enum(u8) {
        escape = 0x1B,
        backspace = 0x08,
        tab = '\t',
        enter = '\n',
        delete = 0x7F,
    };

    pub const NavigationKey = enum(u8) {
        up = 0x80,
        down = 0x81,
        left = 0x82,
        right = 0x83,
        home = 0x84,
        end = 0x85,
        page_up = 0x86,
        page_down = 0x87,
        insert = 0x88,
    };

    pub const FunctionKey = enum(u4) {
        f1 = 1,
        f2 = 2,
        f3 = 3,
        f4 = 4,
        f5 = 5,
        f6 = 6,
        f7 = 7,
        f8 = 8,
        f9 = 9,
        f10 = 10,
        f11 = 11,
        f12 = 12,
    };

    pub const ModifierEvent = struct {
        key: ModifierKey,
        pressed: bool,
    };

    pub const ModifierKey = enum {
        shift_left,
        shift_right,
        ctrl,
        alt,
        caps_lock,
    };

    /// Convert to shell-compatible ASCII byte (for backward compatibility)
    /// Returns null for events that don't have ASCII representation
    pub fn toAscii(self: KeyEvent) ?u8 {
        return switch (self) {
            .char => |c| c,
            .control => |ctrl| @intFromEnum(ctrl),
            .navigation => |nav| @intFromEnum(nav),
            .function => null,
            .modifier => null,
        };
    }

    /// Check if this is a printable character
    pub fn isPrintable(self: KeyEvent) bool {
        return switch (self) {
            .char => true,
            else => false,
        };
    }
};

// =============================================================================
// Ring Buffer Types
// =============================================================================

/// Ring buffer sizes (must be power of 2)
const ASCII_BUFFER_SIZE: usize = 256;
const SCANCODE_BUFFER_SIZE: usize = 64;
const EVENT_BUFFER_SIZE: usize = 64;

/// ASCII character ring buffer type
pub const AsciiBuffer = ring_buffer.RingBuffer(u8, ASCII_BUFFER_SIZE);

/// Raw scancode ring buffer type
pub const ScancodeBuffer = ring_buffer.RingBuffer(u8, SCANCODE_BUFFER_SIZE);

/// KeyEvent ring buffer type
pub const EventBuffer = ring_buffer.RingBuffer(KeyEvent, EVENT_BUFFER_SIZE);

// =============================================================================
// Keyboard State
// =============================================================================

/// Keyboard state including buffers and modifier keys
pub const KeyboardState = struct {
    /// Buffer for ASCII characters (shell reads from here)
    ascii_buffer: AsciiBuffer = .{},

    /// Buffer for raw scancodes (games read from here)
    scancode_buffer: ScancodeBuffer = .{},

    /// Buffer for rich key events (advanced applications)
    event_buffer: EventBuffer = .{},

    /// Modifier key states
    shift_pressed: bool = false,
    ctrl_pressed: bool = false,
    alt_pressed: bool = false,
    caps_lock: bool = false,

    /// Extended key sequence in progress (0xE0 prefix)
    extended_key: bool = false,

    /// Thread blocked waiting for keyboard input (for blocking reads)
    blocked_thread: ?*thread_mod.Thread = null,

    comptime {
        // Warn if struct exceeds reasonable size (not a hard error)
        if (@sizeOf(@This()) > 2048) {
            @compileLog("KeyboardState size: ", @sizeOf(@This()), " bytes");
        }
    }
};

/// Error statistics for debugging hardware issues
pub const ErrorStats = struct {
    parity_errors: u32 = 0,
    timeout_errors: u32 = 0,
    spurious_irqs: u32 = 0,
    buffer_overruns: u32 = 0,
};

// Global keyboard state (protected by keyboard_lock)
var keyboard_state: KeyboardState = .{};
var keyboard_lock: sync.Spinlock = .{};
var keyboard_initialized: bool = false;
var error_stats: ErrorStats = .{};
/// Public IRQ counter for diagnostics
pub var irq_count: u32 = 0;

// =============================================================================
// PS/2 Controller Helpers
// =============================================================================

/// Wait for PS/2 input buffer to be empty (ready to accept commands)
fn waitInputEmpty() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const status = StatusReg.read();
        if (!status.input_buffer_full) return true;
    }
    return false;
}

/// Wait for PS/2 output buffer to have data (ready to read)
fn waitOutputFull() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const status = StatusReg.read();
        if (status.output_buffer_full) return true;
    }
    return false;
}

/// Send command to PS/2 controller (port 0x64)
fn sendCommand(cmd: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(KEYBOARD_STATUS_PORT, cmd);
}

/// Send data to PS/2 controller (port 0x60)
fn sendData(data: u8) void {
    _ = waitInputEmpty();
    hal.io.outb(KEYBOARD_DATA_PORT, data);
}

/// Read data from PS/2 controller (port 0x60), with timeout
fn readData() ?u8 {
    if (waitOutputFull()) {
        return hal.io.inb(KEYBOARD_DATA_PORT);
    }
    return null;
}

/// Flush any stale data from PS/2 output buffer
fn flushBuffer() void {
    var flush_count: u32 = 0;
    while (StatusReg.read().output_buffer_full and flush_count < 16) {
        _ = hal.io.inb(KEYBOARD_DATA_PORT);
        flush_count += 1;
    }
}

// =============================================================================
// Public API
// =============================================================================

/// Inject a scancode from an external source (e.g., USB HID driver)
pub fn injectScancode(scancode: u8) void {
    const held = keyboard_lock.acquire();

    // Store raw scancode in buffer (mimic behavior of handleIrq)
    if (keyboard_state.scancode_buffer.push(scancode)) {
        error_stats.buffer_overruns +%= 1;
    }

    processScancode(scancode);

    // Wake up blocked threads if needed
    if (keyboard_state.blocked_thread) |blocked| {
        if (!keyboard_state.ascii_buffer.isEmpty()) {
            keyboard_state.blocked_thread = null;
            held.release();
            sched.unblock(blocked);
            return;
        }
    }

    held.release();
}

/// Initialize the keyboard driver with proper PS/2 controller setup
pub fn init() void {
    if (keyboard_initialized) {
        return;
    }

    console.info("PS/2 keyboard: initializing controller", .{});

    // 1. Disable devices during setup
    sendCommand(CMD_DISABLE_FIRST_PORT);
    sendCommand(CMD_DISABLE_SECOND_PORT);

    // 2. Flush output buffer (discard stale data from BIOS/firmware)
    flushBuffer();

    // 3. Read config, disable IRQs temporarily
    sendCommand(CMD_READ_CONFIG);
    var config = readData() orelse 0x00;
    config &= ~CONFIG_FIRST_PORT_IRQ;
    config &= ~CONFIG_SECOND_PORT_IRQ;

    sendCommand(CMD_WRITE_CONFIG);
    sendData(config);

    // 4. Self-test (0xAA -> expect 0x55)
    sendCommand(CMD_SELF_TEST);
    const self_test_result = readData();
    if (self_test_result) |result| {
        if (result != SELF_TEST_PASSED) {
            console.warn("PS/2 self-test returned 0x{X:0>2}, expected 0x55", .{result});
        }
    } else {
        console.warn("PS/2 self-test timeout (no response)", .{});
    }

    // 5. Test first port (0xAB -> expect 0x00)
    sendCommand(CMD_TEST_FIRST_PORT);
    const port_test_result = readData();
    if (port_test_result) |result| {
        if (result != PORT_TEST_PASSED) {
            console.warn("PS/2 port test returned 0x{X:0>2}, expected 0x00", .{result});
        }
    } else {
        console.warn("PS/2 port test timeout (no response)", .{});
    }

    // 6. Enable first port
    sendCommand(CMD_ENABLE_FIRST_PORT);

    // 7. Enable IRQ and translation for first port
    sendCommand(CMD_READ_CONFIG);
    config = readData() orelse 0x00;
    config |= CONFIG_FIRST_PORT_IRQ;
    config |= CONFIG_TRANSLATION; // Enable Set 1 translation

    sendCommand(CMD_WRITE_CONFIG);
    sendData(config);

    // 8. Enable Keyboard Scanning
    sendData(KBD_CMD_ENABLE);
    const ack = readData();
    if (ack) |a| {
        if (a != KBD_ACK) {
            console.warn("PS/2 keyboard: enable failed, got 0x{X:0>2}", .{a});
        }
    } else {
        console.warn("PS/2 keyboard: enable timeout", .{});
    }

    // 9. Flush any stale data again
    flushBuffer();

    // 10. Reset keyboard state
    keyboard_state = .{};
    error_stats = .{};

    keyboard_initialized = true;
    console.info("PS/2 keyboard: initialized", .{});

    // Verify final PS/2 configuration for diagnostics
    sendCommand(CMD_READ_CONFIG);
    const final_config = readData() orelse 0xFF;
    console.info("PS/2 config: 0x{X:0>2} (IRQ1_EN={}, XLAT={})", .{
        final_config,
        (final_config & CONFIG_FIRST_PORT_IRQ) != 0,
        (final_config & CONFIG_TRANSLATION) != 0,
    });
}

/// Handle keyboard IRQ (called from interrupt handler)
/// Reads scancode from port and populates all buffers
pub fn handleIrq() void {
    // Count all IRQs for diagnostics (even before init check)
    irq_count +%= 1;
    if (irq_count == 1 or irq_count % 100 == 0) {
        console.info("KBD IRQ #{d}", .{irq_count});
    }

    if (!keyboard_initialized) {
        // Just read and discard to acknowledge
        _ = hal.io.inb(KEYBOARD_DATA_PORT);
        return;
    }

    // Check status register before reading data (prevents spurious reads)
    const status = StatusReg.read();

    if (!status.hasData()) {
        // No data ready - spurious interrupt
        if (error_stats.spurious_irqs % 100 == 0) {
             console.debug("KBD: Spurious IRQ (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        }
        error_stats.spurious_irqs +%= 1;
        return;
    }

    // Skip mouse data - let mouse IRQ handler deal with it
    if (status.isMouseData()) {
        console.debug("KBD: Mouse data ignored (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        return;
    }

    // Check for transmission errors
    if (status.hasError()) {
        console.warn("KBD: Error (Status=0x{X:0>2})", .{@as(u8, @bitCast(status))});
        if (status.parity_error) error_stats.parity_errors +%= 1;
        if (status.timeout_error) error_stats.timeout_errors +%= 1;
        // Read and discard bad data
        _ = hal.io.inb(KEYBOARD_DATA_PORT);
        return;
    }

    // Read scancode from keyboard data port
    const scancode = hal.io.inb(KEYBOARD_DATA_PORT);
    console.debug("KBD: Scancode 0x{X:0>2}", .{scancode});

    // Acquire lock to protect buffer access
    const held = keyboard_lock.acquire();

    // Always store raw scancode for games (FR-030a)
    // Track buffer overruns for debugging
    if (keyboard_state.scancode_buffer.push(scancode)) {
        error_stats.buffer_overruns +%= 1;
    }

    // Process scancode for ASCII translation and event generation
    processScancode(scancode);

    // Wake any thread blocked waiting for input
    // Only wake if we added a printable character (ascii_buffer not empty)
    if (keyboard_state.blocked_thread) |blocked| {
        if (!keyboard_state.ascii_buffer.isEmpty()) {
            keyboard_state.blocked_thread = null;
            held.release();
            // Unblock outside the lock to avoid deadlock with scheduler
            sched.unblock(blocked);
            return;
        }
    }

    held.release();
}

/// Process a scancode and update keyboard state
/// Translates to ASCII when appropriate and stores in buffers
fn processScancode(scancode: u8) void {
    // Check for extended key prefix (0xE0)
    if (scancode == 0xE0) {
        keyboard_state.extended_key = true;
        return;
    }

    // Determine if this is a key release (break code)
    const is_release = (scancode & 0x80) != 0;
    const key_code = scancode & 0x7F;

    // Handle extended key sequences (arrows, navigation keys)
    if (keyboard_state.extended_key) {
        keyboard_state.extended_key = false;
        processExtendedKey(key_code, is_release);
        return;
    }

    // Handle modifier key presses/releases
    switch (key_code) {
        0x2A => { // Left Shift
            keyboard_state.shift_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .shift_left, .pressed = !is_release },
            });
            return;
        },
        0x36 => { // Right Shift
            keyboard_state.shift_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .shift_right, .pressed = !is_release },
            });
            return;
        },
        0x1D => { // Ctrl
            keyboard_state.ctrl_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .ctrl, .pressed = !is_release },
            });
            return;
        },
        0x38 => { // Alt
            keyboard_state.alt_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .alt, .pressed = !is_release },
            });
            return;
        },
        0x3A => { // Caps Lock (toggle on press only)
            if (!is_release) {
                keyboard_state.caps_lock = !keyboard_state.caps_lock;
                _ = keyboard_state.event_buffer.push(.{
                    .modifier = .{ .key = .caps_lock, .pressed = keyboard_state.caps_lock },
                });
            }
            return;
        },
        else => {},
    }

    // Only process key presses for ASCII (not releases)
    if (is_release) {
        return;
    }

    // Handle function keys (F1-F12)
    if (key_code >= 0x3B and key_code <= 0x44) {
        // F1-F10
        const f_num: u4 = @truncate(key_code - 0x3B + 1);
        if (f_num >= 1 and f_num <= 10) {
            _ = keyboard_state.event_buffer.push(.{
                .function = @enumFromInt(f_num),
            });
        }
        return;
    }
    if (key_code == 0x57) { // F11
        _ = keyboard_state.event_buffer.push(.{ .function = .f11 });
        return;
    }
    if (key_code == 0x58) { // F12
        _ = keyboard_state.event_buffer.push(.{ .function = .f12 });
        return;
    }

    // Translate scancode to ASCII
    const ascii = scancodeToAscii(key_code);
    if (ascii != 0) {
        _ = keyboard_state.ascii_buffer.push(ascii);

        // Also create a KeyEvent
        const event: KeyEvent = switch (ascii) {
            0x1B => .{ .control = .escape },
            0x08 => .{ .control = .backspace },
            '\t' => .{ .control = .tab },
            '\n' => .{ .control = .enter },
            0x7F => .{ .control = .delete },
            else => .{ .char = ascii },
        };
        _ = keyboard_state.event_buffer.push(event);
    }
}

/// Process extended key sequences (0xE0 prefix)
fn processExtendedKey(key_code: u8, is_release: bool) void {
    // Handle extended modifier keys
    switch (key_code) {
        0x1D => { // Right Ctrl
            keyboard_state.ctrl_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .ctrl, .pressed = !is_release },
            });
            return;
        },
        0x38 => { // Right Alt (AltGr)
            keyboard_state.alt_pressed = !is_release;
            _ = keyboard_state.event_buffer.push(.{
                .modifier = .{ .key = .alt, .pressed = !is_release },
            });
            return;
        },
        else => {},
    }

    // Only process key presses for navigation keys
    if (is_release) {
        return;
    }

    // Map extended scancodes to navigation keys
    const nav_key: ?KeyEvent.NavigationKey = switch (key_code) {
        0x48 => .up,
        0x50 => .down,
        0x4B => .left,
        0x4D => .right,
        0x47 => .home,
        0x4F => .end,
        0x49 => blk: {
            console.scroll(10, true);
            break :blk .page_up;
        },
        0x51 => blk: {
            console.scroll(10, false);
            break :blk .page_down;
        },
        0x52 => .insert,
        0x53 => blk: {
            // Delete key - special handling
            _ = keyboard_state.ascii_buffer.push(0x7F);
            _ = keyboard_state.event_buffer.push(.{ .control = .delete });
            break :blk null;
        },
        else => null,
    };

    if (nav_key) |nav| {
        // Push to ASCII buffer with special codes (0x80+)
        _ = keyboard_state.ascii_buffer.push(@intFromEnum(nav));
        // Push to event buffer
        _ = keyboard_state.event_buffer.push(.{ .navigation = nav });
    }
}

/// Get an ASCII character from the input buffer (non-blocking)
/// Returns null if buffer is empty
/// Syscall: SYS_GETCHAR (1004) - but blocking version would loop on this
pub fn getChar() ?u8 {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.ascii_buffer.pop();
}

/// Get an ASCII character from the input buffer (blocking with optional timeout)
/// Returns null on timeout, character otherwise.
///
/// timeout_ticks: Number of scheduler ticks to wait, or null for infinite.
///
/// NOTE: Uses proper interrupt/lock ordering to prevent race conditions.
/// The lock is released before blocking, but interrupts remain disabled
/// until sched.block() atomically re-enables them.
pub fn getCharBlockingTimeout(timeout_ticks: ?u64) ?u8 {
    const start_tick = if (timeout_ticks != null) sched.getTickCount() else 0;

    while (true) {
        // Fast path: try non-blocking read
        if (getChar()) |c| {
            return c;
        }

        // Check timeout before blocking
        if (timeout_ticks) |max| {
            if (sched.getTickCount() -% start_tick >= max) {
                return null;
            }
        }

        // Need to block - must be atomic with checking buffer
        // Disable interrupts to prevent IRQ between check and block
        const saved_flags = hal.cpu.disableInterruptsSaveFlags();

        {
            const held = keyboard_lock.acquire();
            defer held.release();

            // Double-check after acquiring lock (TOCTOU prevention)
            if (keyboard_state.ascii_buffer.pop()) |c| {
                hal.cpu.restoreInterrupts(saved_flags);
                return c;
            }

            // No character - register ourselves as blocked
            if (sched.getCurrentThread()) |curr| {
                keyboard_state.blocked_thread = curr;
            }
        }
        // Lock released here, interrupts still disabled

        // Block the thread - this atomically enables interrupts and halts
        // The keyboard IRQ will wake us when a character arrives
        sched.block();
        // When we wake up, loop to check buffer again (handles spurious wakeups)
    }
}

/// Get an ASCII character from the input buffer (blocking, infinite timeout)
/// Blocks the calling thread until a character is available.
/// Returns the character when available.
pub fn getCharBlocking() u8 {
    // Infinite timeout - will always return a character
    return getCharBlockingTimeout(null).?;
}

/// Get a KeyEvent from the event buffer (non-blocking)
/// Returns null if buffer is empty
pub fn getEvent() ?KeyEvent {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.event_buffer.pop();
}

/// Get a raw scancode from the buffer (non-blocking)
/// Returns null if buffer is empty
/// Syscall: SYS_READ_SCANCODE (1003)
pub fn getScancode() ?u8 {
    const held = keyboard_lock.acquire();
    defer held.release();

    return keyboard_state.scancode_buffer.pop();
}

/// Check if there are characters available
pub fn hasChar() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.ascii_buffer.isEmpty();
}

/// Check if there are scancodes available
pub fn hasScancode() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.scancode_buffer.isEmpty();
}

/// Check if there are events available
pub fn hasEvent() bool {
    const held = keyboard_lock.acquire();
    defer held.release();

    return !keyboard_state.event_buffer.isEmpty();
}

/// Get current modifier key states
pub fn getModifiers() struct { shift: bool, ctrl: bool, alt: bool, caps: bool } {
    const held = keyboard_lock.acquire();
    defer held.release();

    return .{
        .shift = keyboard_state.shift_pressed,
        .ctrl = keyboard_state.ctrl_pressed,
        .alt = keyboard_state.alt_pressed,
        .caps = keyboard_state.caps_lock,
    };
}

/// Get error statistics (for debugging)
pub fn getErrorStats() ErrorStats {
    return error_stats;
}

// =============================================================================
// Layout Management
// =============================================================================

// Current active layout (defaults to US QWERTY)
var current_layout: *const layout_mod.Layout = &us_layout.layout_def;

/// Set the current keyboard layout
pub fn setLayout(new_layout: *const layout_mod.Layout) void {
    const held = keyboard_lock.acquire();
    defer held.release();
    current_layout = new_layout;
    console.info("Keyboard: Switched layout to {s}", .{new_layout.name});
}

/// Get the current layout name
pub fn getLayoutName() []const u8 {
    return current_layout.name;
}

// Available built-in layouts
pub const layouts = struct {
    pub const us = &us_layout.layout_def;
    pub const dvorak = &dvorak_layout.layout_def;
};

/// Convert a scancode to ASCII character
/// Returns 0 for non-printable keys or invalid scancodes
fn scancodeToAscii(scancode: u8) u8 {
    if (scancode >= 128) {
        return 0;
    }

    // Determine if we should use shifted table
    // XOR of shift and caps_lock gives correct behavior for letters
    const use_shift = keyboard_state.shift_pressed != keyboard_state.caps_lock;

    var char: u8 = if (use_shift)
        current_layout.shifted[scancode]
    else
        current_layout.unshifted[scancode];

    // Handle Ctrl key combinations (Ctrl+A = 1, Ctrl+Z = 26)
    if (keyboard_state.ctrl_pressed) {
        if (char >= 'a' and char <= 'z') {
            char = char - 'a' + 1;
        } else if (char >= 'A' and char <= 'Z') {
            char = char - 'A' + 1;
        }
    }

    return char;
}

// =============================================================================
// Unit Tests
// =============================================================================

test "StatusReg packed struct size" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(StatusReg));
}

test "KeyEvent toAscii" {
    const std = @import("std");

    const char_event = KeyEvent{ .char = 'x' };
    try std.testing.expectEqual(@as(?u8, 'x'), char_event.toAscii());

    const ctrl_event = KeyEvent{ .control = .escape };
    try std.testing.expectEqual(@as(?u8, 0x1B), ctrl_event.toAscii());

    const nav_event = KeyEvent{ .navigation = .up };
    try std.testing.expectEqual(@as(?u8, 0x80), nav_event.toAscii());

    const func_event = KeyEvent{ .function = .f1 };
    try std.testing.expectEqual(@as(?u8, null), func_event.toAscii());
}

test "layout switching" {
    const std = @import("std");

    // Test default US layout
    try std.testing.expectEqual(@as(u8, 'a'), current_layout.unshifted[0x1E]);

    // Switch to Dvorak
    setLayout(layouts.dvorak);
    try std.testing.expectEqual(@as(u8, 'a'), current_layout.unshifted[0x1E]); // Wait, Dvorak 'a' is at same scan code 0x1E? No...
    // 0x1E 'a' in US is 'a'. In Dvorak 0x1E ('a' position) is 'a'.
    // Wait, Dvorak layout:
    // ASDF row: A O E U I D H T N S
    // US:       A S D F G H J K L ;
    // Scan code 0x1E is 'A' (leftmost home row char).
    // In Dvorak, key to right of CapsLock (typically 'A') IS 'A'.
    // So 0x1E IS 'a' in both.
    
    // Let's test 's' (0x1F). US='s', Dvorak='o'.
    try std.testing.expectEqual(@as(u8, 'o'), current_layout.unshifted[0x1F]);
    
    // Switch back
    setLayout(layouts.us);
    try std.testing.expectEqual(@as(u8, 's'), current_layout.unshifted[0x1F]);
}
