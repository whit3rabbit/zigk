/// Keyboard Layout Definitions

/// Maps a scancode (index) to an ASCII character or special internal code
pub const KeyMap = [128]u8;

/// Defines a complete keyboard layout
pub const Layout = struct {
    /// Human-readable name of the layout (e.g., "US QWERTY", "Dvorak")
    name: []const u8,

    /// Unshifted key mappings (e.g., 'a', '1')
    unshifted: KeyMap,

    /// Shifted key mappings (e.g., 'A', '!')
    shifted: KeyMap,

    /// AltGr key mappings (optional, e.g., '€')
    altgr: ?KeyMap = null,
};
