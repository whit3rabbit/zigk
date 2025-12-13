pub const KeyMapping = struct {
    scancode: u8,
    unshifted: u8,
    shifted: u8,
};

/// US QWERTY keyboard layout mappings
pub const us_qwerty = [_]KeyMapping{
    // Row 1: Number row
    .{ .scancode = 0x01, .unshifted = 0x1B, .shifted = 0x1B }, // Escape
    .{ .scancode = 0x02, .unshifted = '1', .shifted = '!' },
    .{ .scancode = 0x03, .unshifted = '2', .shifted = '@' },
    .{ .scancode = 0x04, .unshifted = '3', .shifted = '#' },
    .{ .scancode = 0x05, .unshifted = '4', .shifted = '$' },
    .{ .scancode = 0x06, .unshifted = '5', .shifted = '%' },
    .{ .scancode = 0x07, .unshifted = '6', .shifted = '^' },
    .{ .scancode = 0x08, .unshifted = '7', .shifted = '&' },
    .{ .scancode = 0x09, .unshifted = '8', .shifted = '*' },
    .{ .scancode = 0x0A, .unshifted = '9', .shifted = '(' },
    .{ .scancode = 0x0B, .unshifted = '0', .shifted = ')' },
    .{ .scancode = 0x0C, .unshifted = '-', .shifted = '_' },
    .{ .scancode = 0x0D, .unshifted = '=', .shifted = '+' },
    .{ .scancode = 0x0E, .unshifted = 0x08, .shifted = 0x08 }, // Backspace
    .{ .scancode = 0x0F, .unshifted = '\t', .shifted = '\t' }, // Tab

    // Row 2: QWERTY row
    .{ .scancode = 0x10, .unshifted = 'q', .shifted = 'Q' },
    .{ .scancode = 0x11, .unshifted = 'w', .shifted = 'W' },
    .{ .scancode = 0x12, .unshifted = 'e', .shifted = 'E' },
    .{ .scancode = 0x13, .unshifted = 'r', .shifted = 'R' },
    .{ .scancode = 0x14, .unshifted = 't', .shifted = 'T' },
    .{ .scancode = 0x15, .unshifted = 'y', .shifted = 'Y' },
    .{ .scancode = 0x16, .unshifted = 'u', .shifted = 'U' },
    .{ .scancode = 0x17, .unshifted = 'i', .shifted = 'I' },
    .{ .scancode = 0x18, .unshifted = 'o', .shifted = 'O' },
    .{ .scancode = 0x19, .unshifted = 'p', .shifted = 'P' },
    .{ .scancode = 0x1A, .unshifted = '[', .shifted = '{' },
    .{ .scancode = 0x1B, .unshifted = ']', .shifted = '}' },
    .{ .scancode = 0x1C, .unshifted = '\n', .shifted = '\n' }, // Enter

    // Row 3: ASDF row
    .{ .scancode = 0x1E, .unshifted = 'a', .shifted = 'A' },
    .{ .scancode = 0x1F, .unshifted = 's', .shifted = 'S' },
    .{ .scancode = 0x20, .unshifted = 'd', .shifted = 'D' },
    .{ .scancode = 0x21, .unshifted = 'f', .shifted = 'F' },
    .{ .scancode = 0x22, .unshifted = 'g', .shifted = 'G' },
    .{ .scancode = 0x23, .unshifted = 'h', .shifted = 'H' },
    .{ .scancode = 0x24, .unshifted = 'j', .shifted = 'J' },
    .{ .scancode = 0x25, .unshifted = 'k', .shifted = 'K' },
    .{ .scancode = 0x26, .unshifted = 'l', .shifted = 'L' },
    .{ .scancode = 0x27, .unshifted = ';', .shifted = ':' },
    .{ .scancode = 0x28, .unshifted = '\'', .shifted = '"' },
    .{ .scancode = 0x29, .unshifted = '`', .shifted = '~' },
    .{ .scancode = 0x2B, .unshifted = '\\', .shifted = '|' },

    // Row 4: ZXCV row
    .{ .scancode = 0x2C, .unshifted = 'z', .shifted = 'Z' },
    .{ .scancode = 0x2D, .unshifted = 'x', .shifted = 'X' },
    .{ .scancode = 0x2E, .unshifted = 'c', .shifted = 'C' },
    .{ .scancode = 0x2F, .unshifted = 'v', .shifted = 'V' },
    .{ .scancode = 0x30, .unshifted = 'b', .shifted = 'B' },
    .{ .scancode = 0x31, .unshifted = 'n', .shifted = 'N' },
    .{ .scancode = 0x32, .unshifted = 'm', .shifted = 'M' },
    .{ .scancode = 0x33, .unshifted = ',', .shifted = '<' },
    .{ .scancode = 0x34, .unshifted = '.', .shifted = '>' },
    .{ .scancode = 0x35, .unshifted = '/', .shifted = '?' },

    // Space and numpad
    .{ .scancode = 0x37, .unshifted = '*', .shifted = '*' }, // Numpad *
    .{ .scancode = 0x39, .unshifted = ' ', .shifted = ' ' }, // Space
    .{ .scancode = 0x47, .unshifted = '7', .shifted = '7' }, // Numpad 7
    .{ .scancode = 0x48, .unshifted = '8', .shifted = '8' }, // Numpad 8
    .{ .scancode = 0x49, .unshifted = '9', .shifted = '9' }, // Numpad 9
    .{ .scancode = 0x4A, .unshifted = '-', .shifted = '-' }, // Numpad -
    .{ .scancode = 0x4B, .unshifted = '4', .shifted = '4' }, // Numpad 4
    .{ .scancode = 0x4C, .unshifted = '5', .shifted = '5' }, // Numpad 5
    .{ .scancode = 0x4D, .unshifted = '6', .shifted = '6' }, // Numpad 6
    .{ .scancode = 0x4E, .unshifted = '+', .shifted = '+' }, // Numpad +
    .{ .scancode = 0x4F, .unshifted = '1', .shifted = '1' }, // Numpad 1
    .{ .scancode = 0x50, .unshifted = '2', .shifted = '2' }, // Numpad 2
    .{ .scancode = 0x51, .unshifted = '3', .shifted = '3' }, // Numpad 3
    .{ .scancode = 0x52, .unshifted = '0', .shifted = '0' }, // Numpad 0
    .{ .scancode = 0x53, .unshifted = '.', .shifted = '.' }, // Numpad .
};
