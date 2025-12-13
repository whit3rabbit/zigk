const layout = @import("../layout.zig");

/// Helper to generate a KeyMap from a list of sparse mappings
fn buildKeyMap(comptime mappings: []const struct { u8, u8 }) layout.KeyMap {
    var map = [_]u8{0} ** 128;
    for (mappings) |m| {
        map[m[0]] = m[1];
    }
    return map;
}

const dvorak_unshifted = buildKeyMap(&.{
    .{ 0x01, 0x1B }, // Escape
    .{ 0x02, '1' },
    .{ 0x03, '2' },
    .{ 0x04, '3' },
    .{ 0x05, '4' },
    .{ 0x06, '5' },
    .{ 0x07, '6' },
    .{ 0x08, '7' },
    .{ 0x09, '8' },
    .{ 0x0A, '9' },
    .{ 0x0B, '0' },
    .{ 0x0C, '[' },
    .{ 0x0D, ']' },
    .{ 0x0E, 0x08 }, // Backspace
    .{ 0x0F, '\t' }, // Tab
    .{ 0x10, '\'' },
    .{ 0x11, ',' },
    .{ 0x12, '.' },
    .{ 0x13, 'p' },
    .{ 0x14, 'y' },
    .{ 0x15, 'f' },
    .{ 0x16, 'g' },
    .{ 0x17, 'c' },
    .{ 0x18, 'r' },
    .{ 0x19, 'l' },
    .{ 0x1A, '/' },
    .{ 0x1B, '=' },
    .{ 0x1C, '\n' }, // Enter
    .{ 0x1E, 'a' },
    .{ 0x1F, 'o' },
    .{ 0x20, 'e' },
    .{ 0x21, 'u' },
    .{ 0x22, 'i' },
    .{ 0x23, 'd' },
    .{ 0x24, 'h' },
    .{ 0x25, 't' },
    .{ 0x26, 'n' },
    .{ 0x27, 's' },
    .{ 0x28, '-' },
    .{ 0x29, '`' },
    .{ 0x2B, '\\' },
    .{ 0x2C, ';' },
    .{ 0x2D, 'q' },
    .{ 0x2E, 'j' },
    .{ 0x2F, 'k' },
    .{ 0x30, 'x' },
    .{ 0x31, 'b' },
    .{ 0x32, 'm' },
    .{ 0x33, 'w' },
    .{ 0x34, 'v' },
    .{ 0x35, 'z' },
    .{ 0x37, '*' }, // Numpad *
    .{ 0x39, ' ' }, // Space
});

const dvorak_shifted = buildKeyMap(&.{
    .{ 0x01, 0x1B }, // Escape
    .{ 0x02, '!' },
    .{ 0x03, '@' },
    .{ 0x04, '#' },
    .{ 0x05, '$' },
    .{ 0x06, '%' },
    .{ 0x07, '^' },
    .{ 0x08, '&' },
    .{ 0x09, '*' },
    .{ 0x0A, '(' },
    .{ 0x0B, ')' },
    .{ 0x0C, '{' },
    .{ 0x0D, '}' },
    .{ 0x0E, 0x08 }, // Backspace
    .{ 0x0F, '\t' }, // Tab
    .{ 0x10, '"' },
    .{ 0x11, '<' },
    .{ 0x12, '>' },
    .{ 0x13, 'P' },
    .{ 0x14, 'Y' },
    .{ 0x15, 'F' },
    .{ 0x16, 'G' },
    .{ 0x17, 'C' },
    .{ 0x18, 'R' },
    .{ 0x19, 'L' },
    .{ 0x1A, '?' },
    .{ 0x1B, '+' },
    .{ 0x1C, '\n' }, // Enter
    .{ 0x1E, 'A' },
    .{ 0x1F, 'O' },
    .{ 0x20, 'E' },
    .{ 0x21, 'U' },
    .{ 0x22, 'I' },
    .{ 0x23, 'D' },
    .{ 0x24, 'H' },
    .{ 0x25, 'T' },
    .{ 0x26, 'N' },
    .{ 0x27, 'S' },
    .{ 0x28, '_' },
    .{ 0x29, '~' },
    .{ 0x2B, '|' },
    .{ 0x2C, ':' },
    .{ 0x2D, 'Q' },
    .{ 0x2E, 'J' },
    .{ 0x2F, 'K' },
    .{ 0x30, 'X' },
    .{ 0x31, 'B' },
    .{ 0x32, 'M' },
    .{ 0x33, 'W' },
    .{ 0x34, 'V' },
    .{ 0x35, 'Z' },
    .{ 0x37, '*' }, // Numpad *
    .{ 0x39, ' ' }, // Space
});

pub const layout_def = layout.Layout{
    .name = "US Dvorak",
    .unshifted = dvorak_unshifted,
    .shifted = dvorak_shifted,
};
