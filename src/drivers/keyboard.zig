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
//   - PS/2 Set 1 scancode to ASCII translation
//   - Modifier key tracking (Shift, Ctrl, Alt)
//   - Thread-safe via Spinlock

const hal = @import("hal");
const sync = @import("sync");
const ring_buffer = @import("ring_buffer");
const console = @import("console");
const uapi = @import("uapi");

/// Keyboard data port (read scancodes)
const KEYBOARD_DATA_PORT: u16 = 0x60;

/// Keyboard status port
const KEYBOARD_STATUS_PORT: u16 = 0x64;

/// Ring buffer sizes (must be power of 2)
const ASCII_BUFFER_SIZE: usize = 256;
const SCANCODE_BUFFER_SIZE: usize = 64;

/// ASCII character ring buffer type
pub const AsciiBuffer = ring_buffer.RingBuffer(u8, ASCII_BUFFER_SIZE);

/// Raw scancode ring buffer type
pub const ScancodeBuffer = ring_buffer.RingBuffer(u8, SCANCODE_BUFFER_SIZE);

/// Keyboard state including buffers and modifier keys
pub const KeyboardState = struct {
    /// Buffer for ASCII characters (shell reads from here)
    ascii_buffer: AsciiBuffer = .{},

    /// Buffer for raw scancodes (games read from here)
    scancode_buffer: ScancodeBuffer = .{},

    /// Modifier key states
    shift_pressed: bool = false,
    ctrl_pressed: bool = false,
    alt_pressed: bool = false,
    caps_lock: bool = false,

    /// Extended key sequence in progress (0xE0 prefix)
    extended_key: bool = false,
};

// Global keyboard state (protected by keyboard_lock)
var keyboard_state: KeyboardState = .{};
var keyboard_lock: sync.Spinlock = .{};
var keyboard_initialized: bool = false;

/// Initialize the keyboard driver
pub fn init() void {
    if (keyboard_initialized) {
        return;
    }

    // Reset state
    keyboard_state = .{};

    keyboard_initialized = true;
    console.info("Keyboard driver initialized", .{});
}

/// Handle keyboard IRQ (called from interrupt handler)
/// Reads scancode from port and populates both buffers
pub fn handleIrq() void {
    if (!keyboard_initialized) {
        // Just read and discard to acknowledge
        _ = hal.io.inb(KEYBOARD_DATA_PORT);
        return;
    }

    // Read scancode from keyboard data port
    const scancode = hal.io.inb(KEYBOARD_DATA_PORT);

    // Acquire lock to protect buffer access
    const held = keyboard_lock.acquire();
    defer held.release();

    // Always store raw scancode for games (FR-030a)
    // Drop oldest if buffer full (ring buffer semantics)
    _ = keyboard_state.scancode_buffer.push(scancode);

    // Process scancode for ASCII translation
    processScancode(scancode);
}

/// Process a scancode and update keyboard state
/// Translates to ASCII when appropriate and stores in ascii_buffer
fn processScancode(scancode: u8) void {
    // Check for extended key prefix
    if (scancode == 0xE0) {
        keyboard_state.extended_key = true;
        return;
    }

    // Determine if this is a key release (break code)
    const is_release = (scancode & 0x80) != 0;
    const key_code = scancode & 0x7F;

    // Handle modifier keys
    if (keyboard_state.extended_key) {
        // Extended key sequences (arrows, etc.)
        keyboard_state.extended_key = false;
        // TODO: Handle extended keys (arrows, insert, delete, etc.)
        return;
    }

    // Handle modifier key presses/releases
    switch (key_code) {
        0x2A, 0x36 => { // Left/Right Shift
            keyboard_state.shift_pressed = !is_release;
            return;
        },
        0x1D => { // Ctrl
            keyboard_state.ctrl_pressed = !is_release;
            return;
        },
        0x38 => { // Alt
            keyboard_state.alt_pressed = !is_release;
            return;
        },
        0x3A => { // Caps Lock (toggle on press only)
            if (!is_release) {
                keyboard_state.caps_lock = !keyboard_state.caps_lock;
            }
            return;
        },
        else => {},
    }

    // Only process key presses for ASCII (not releases)
    if (is_release) {
        return;
    }

    // Translate scancode to ASCII
    const ascii = scancodeToAscii(key_code);
    if (ascii != 0) {
        _ = keyboard_state.ascii_buffer.push(ascii);
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

// =============================================================================
// PS/2 Set 1 Scancode to ASCII Translation Tables
// =============================================================================

/// Unshifted scancode to ASCII mapping (US QWERTY layout)
const scancode_table_unshifted = [128]u8{
    // 0x00 - 0x0F
    0, 0x1B, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, '\t',
    // 0x10 - 0x1F
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's',
    // 0x20 - 0x2F
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v',
    // 0x30 - 0x3F
    'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ', 0, 0, 0, 0, 0, 0,
    // 0x40 - 0x4F (F keys, numpad)
    0, 0, 0, 0, 0, 0, 0, '7', '8', '9', '-', '4', '5', '6', '+', '1',
    // 0x50 - 0x5F
    '2', '3', '0', '.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x60 - 0x7F (unused/reserved)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/// Shifted scancode to ASCII mapping (US QWERTY layout)
const scancode_table_shifted = [128]u8{
    // 0x00 - 0x0F
    0, 0x1B, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, '\t',
    // 0x10 - 0x1F
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0, 'A', 'S',
    // 0x20 - 0x2F
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|', 'Z', 'X', 'C', 'V',
    // 0x30 - 0x3F
    'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' ', 0, 0, 0, 0, 0, 0,
    // 0x40 - 0x4F (F keys, numpad - same as unshifted)
    0, 0, 0, 0, 0, 0, 0, '7', '8', '9', '-', '4', '5', '6', '+', '1',
    // 0x50 - 0x5F
    '2', '3', '0', '.', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    // 0x60 - 0x7F (unused/reserved)
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

/// Convert a scancode to ASCII character
/// Returns 0 for non-printable keys or invalid scancodes
fn scancodeToAscii(scancode: u8) u8 {
    if (scancode >= 128) {
        return 0;
    }

    // Determine if we should use shifted table
    const use_shift = keyboard_state.shift_pressed != keyboard_state.caps_lock;

    var char: u8 = if (use_shift)
        scancode_table_shifted[scancode]
    else
        scancode_table_unshifted[scancode];

    // Caps lock only affects letters
    if (keyboard_state.caps_lock and !keyboard_state.shift_pressed) {
        // Already handled by XOR above for letters
    }

    // Handle Ctrl key combinations
    if (keyboard_state.ctrl_pressed and char >= 'a' and char <= 'z') {
        // Ctrl+letter produces control codes 1-26
        char = char - 'a' + 1;
    } else if (keyboard_state.ctrl_pressed and char >= 'A' and char <= 'Z') {
        char = char - 'A' + 1;
    }

    return char;
}
