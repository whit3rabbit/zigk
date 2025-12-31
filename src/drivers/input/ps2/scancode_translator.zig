//! PS/2 Scancode Translator
//!
//! Translates PS/2 Set 1 scancodes to KeyEvents.
//! Handles modifier key state, extended key sequences (0xE0 prefix),
//! and layout-based ASCII translation.

const keyboard_event = @import("../keyboard_event.zig");
const layout_mod = @import("../layout.zig");

pub const KeyEvent = keyboard_event.KeyEvent;

// =============================================================================
// Translator State
// =============================================================================

/// Scancode translator state machine
/// Tracks modifier keys and extended key sequences
pub const ScancodeTranslator = struct {
    /// Modifier key states
    shift_pressed: bool = false,
    ctrl_pressed: bool = false,
    alt_pressed: bool = false,
    caps_lock: bool = false,

    /// Extended key sequence in progress (0xE0 prefix)
    extended_key: bool = false,

    /// Current keyboard layout
    layout: *const layout_mod.Layout,

    /// Initialize with a layout
    pub fn init(layout: *const layout_mod.Layout) ScancodeTranslator {
        return .{
            .layout = layout,
        };
    }

    /// Set the keyboard layout
    pub fn setLayout(self: *ScancodeTranslator, new_layout: *const layout_mod.Layout) void {
        self.layout = new_layout;
    }

    /// Get current modifier states
    pub fn getModifiers(self: *const ScancodeTranslator) struct { shift: bool, ctrl: bool, alt: bool, caps: bool } {
        return .{
            .shift = self.shift_pressed,
            .ctrl = self.ctrl_pressed,
            .alt = self.alt_pressed,
            .caps = self.caps_lock,
        };
    }

    /// Translate a scancode to a KeyEvent and optional ASCII character
    /// Returns null if the scancode doesn't produce an event (e.g., 0xE0 prefix)
    pub fn translate(self: *ScancodeTranslator, scancode: u8) ?TranslateResult {
        // Check for extended key prefix (0xE0)
        if (scancode == 0xE0) {
            self.extended_key = true;
            return null;
        }

        // Determine if this is a key release (break code)
        const is_release = (scancode & 0x80) != 0;
        const key_code = scancode & 0x7F;

        // Handle extended key sequences (arrows, navigation keys)
        if (self.extended_key) {
            self.extended_key = false;
            return self.translateExtendedKey(key_code, is_release);
        }

        // Handle modifier key presses/releases
        switch (key_code) {
            0x2A => { // Left Shift
                self.shift_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .shift_left, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            0x36 => { // Right Shift
                self.shift_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .shift_right, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            0x1D => { // Ctrl
                self.ctrl_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .ctrl, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            0x38 => { // Alt
                self.alt_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .alt, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            0x3A => { // Caps Lock (toggle on press only)
                if (!is_release) {
                    self.caps_lock = !self.caps_lock;
                    return .{
                        .event = .{ .modifier = .{ .key = .caps_lock, .pressed = self.caps_lock } },
                        .ascii = null,
                    };
                }
                return null;
            },
            else => {},
        }

        // Only process key presses for ASCII (not releases)
        if (is_release) {
            return null;
        }

        // Handle function keys (F1-F12)
        if (key_code >= 0x3B and key_code <= 0x44) {
            // F1-F10
            const f_num: u4 = @truncate(key_code - 0x3B + 1);
            if (f_num >= 1 and f_num <= 10) {
                return .{
                    .event = .{ .function = @enumFromInt(f_num) },
                    .ascii = null,
                };
            }
            return null;
        }
        if (key_code == 0x57) { // F11
            return .{
                .event = .{ .function = .f11 },
                .ascii = null,
            };
        }
        if (key_code == 0x58) { // F12
            return .{
                .event = .{ .function = .f12 },
                .ascii = null,
            };
        }

        // Translate scancode to ASCII
        const ascii = self.scancodeToAscii(key_code);
        if (ascii != 0) {
            const event: KeyEvent = switch (ascii) {
                0x1B => .{ .control = .escape },
                0x08 => .{ .control = .backspace },
                '\t' => .{ .control = .tab },
                '\n' => .{ .control = .enter },
                0x7F => .{ .control = .delete },
                else => .{ .char = ascii },
            };
            return .{
                .event = event,
                .ascii = ascii,
            };
        }

        return null;
    }

    /// Translate extended key sequences (0xE0 prefix)
    fn translateExtendedKey(self: *ScancodeTranslator, key_code: u8, is_release: bool) ?TranslateResult {
        // Handle extended modifier keys
        switch (key_code) {
            0x1D => { // Right Ctrl
                self.ctrl_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .ctrl, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            0x38 => { // Right Alt (AltGr)
                self.alt_pressed = !is_release;
                return .{
                    .event = .{ .modifier = .{ .key = .alt, .pressed = !is_release } },
                    .ascii = null,
                };
            },
            else => {},
        }

        // Only process key presses for navigation keys
        if (is_release) {
            return null;
        }

        // Map extended scancodes to navigation keys
        const result: ?struct { nav: KeyEvent.NavigationKey, ascii: ?u8, scroll: ?ScrollAction } = switch (key_code) {
            0x48 => .{ .nav = .up, .ascii = @intFromEnum(KeyEvent.NavigationKey.up), .scroll = null },
            0x50 => .{ .nav = .down, .ascii = @intFromEnum(KeyEvent.NavigationKey.down), .scroll = null },
            0x4B => .{ .nav = .left, .ascii = @intFromEnum(KeyEvent.NavigationKey.left), .scroll = null },
            0x4D => .{ .nav = .right, .ascii = @intFromEnum(KeyEvent.NavigationKey.right), .scroll = null },
            0x47 => .{ .nav = .home, .ascii = @intFromEnum(KeyEvent.NavigationKey.home), .scroll = null },
            0x4F => .{ .nav = .end, .ascii = @intFromEnum(KeyEvent.NavigationKey.end), .scroll = null },
            0x49 => .{ .nav = .page_up, .ascii = @intFromEnum(KeyEvent.NavigationKey.page_up), .scroll = .{ .lines = 10, .up = true } },
            0x51 => .{ .nav = .page_down, .ascii = @intFromEnum(KeyEvent.NavigationKey.page_down), .scroll = .{ .lines = 10, .up = false } },
            0x52 => .{ .nav = .insert, .ascii = @intFromEnum(KeyEvent.NavigationKey.insert), .scroll = null },
            0x53 => null, // Delete - handled separately below
            else => null,
        };

        if (result) |r| {
            return .{
                .event = .{ .navigation = r.nav },
                .ascii = r.ascii,
                .scroll = r.scroll,
            };
        }

        // Delete key - special handling
        if (key_code == 0x53) {
            return .{
                .event = .{ .control = .delete },
                .ascii = 0x7F,
                .scroll = null,
            };
        }

        return null;
    }

    /// Convert a scancode to ASCII character using the current layout
    /// Returns 0 for non-printable keys or invalid scancodes
    fn scancodeToAscii(self: *const ScancodeTranslator, scancode: u8) u8 {
        if (scancode >= 128) {
            return 0;
        }

        // Determine if we should use shifted table
        // XOR of shift and caps_lock gives correct behavior for letters
        const use_shift = self.shift_pressed != self.caps_lock;

        var char: u8 = if (use_shift)
            self.layout.shifted[scancode]
        else
            self.layout.unshifted[scancode];

        // Handle Ctrl key combinations (Ctrl+A = 1, Ctrl+Z = 26)
        if (self.ctrl_pressed) {
            if (char >= 'a' and char <= 'z') {
                char = char - 'a' + 1;
            } else if (char >= 'A' and char <= 'Z') {
                char = char - 'A' + 1;
            }
        }

        return char;
    }
};

// =============================================================================
// Result Types
// =============================================================================

/// Optional scroll action for Page Up/Down
pub const ScrollAction = struct {
    lines: u32,
    up: bool,
};

/// Result of translating a scancode
pub const TranslateResult = struct {
    /// The generated key event
    event: KeyEvent,
    /// ASCII character if applicable (for buffer storage)
    ascii: ?u8 = null,
    /// Scroll action if applicable (for console scrolling)
    scroll: ?ScrollAction = null,
};

// =============================================================================
// Unit Tests
// =============================================================================

test "ScancodeTranslator modifier tracking" {
    const std = @import("std");
    const us_layout = @import("../layouts/us.zig");

    var translator = ScancodeTranslator.init(&us_layout.layout_def);

    // Initially no modifiers pressed
    const mods = translator.getModifiers();
    try std.testing.expect(!mods.shift);
    try std.testing.expect(!mods.ctrl);

    // Press left shift (0x2A)
    const shift_result = translator.translate(0x2A);
    try std.testing.expect(shift_result != null);
    try std.testing.expect(translator.shift_pressed);

    // Release left shift (0x2A | 0x80 = 0xAA)
    _ = translator.translate(0xAA);
    try std.testing.expect(!translator.shift_pressed);
}

test "ScancodeTranslator extended key" {
    const std = @import("std");
    const us_layout = @import("../layouts/us.zig");

    var translator = ScancodeTranslator.init(&us_layout.layout_def);

    // Send 0xE0 prefix
    const prefix_result = translator.translate(0xE0);
    try std.testing.expect(prefix_result == null);
    try std.testing.expect(translator.extended_key);

    // Send up arrow (0x48)
    const up_result = translator.translate(0x48);
    try std.testing.expect(up_result != null);
    try std.testing.expect(!translator.extended_key);
    try std.testing.expectEqual(KeyEvent.NavigationKey.up, up_result.?.event.navigation);
}
