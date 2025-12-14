// Character classification functions (ctype.h)
//
// Provides is* and to* functions for character classification
// and case conversion. All functions follow the C standard ABI.

const internal = @import("internal.zig");

/// Check if character is a whitespace character
pub export fn isspace(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c) 1 else 0;
}

/// Check if character is a decimal digit (0-9)
pub export fn isdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= '0' and ch <= '9') 1 else 0;
}

/// Check if character is an alphabetic letter (a-z, A-Z)
pub export fn isalpha(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) 1 else 0;
}

/// Check if character is alphanumeric (letter or digit)
pub export fn isalnum(c: c_int) c_int {
    return if (isalpha(c) != 0 or isdigit(c) != 0) 1 else 0;
}

/// Check if character is an uppercase letter (A-Z)
pub export fn isupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 'A' and ch <= 'Z') 1 else 0;
}

/// Check if character is a lowercase letter (a-z)
pub export fn islower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 'a' and ch <= 'z') 1 else 0;
}

/// Check if character is printable (including space)
pub export fn isprint(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 0x20 and ch <= 0x7e) 1 else 0;
}

/// Check if character is a hexadecimal digit (0-9, a-f, A-F)
pub export fn isxdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if ((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F') or (ch >= 'a' and ch <= 'f')) 1 else 0;
}

/// Convert character to uppercase
pub export fn toupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return @as(c_int, internal.toUpperInternal(ch));
}

/// Convert character to lowercase
pub export fn tolower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return @as(c_int, internal.toLowerInternal(ch));
}

/// Check if character is a control character
pub export fn iscntrl(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch < 0x20 or ch == 0x7f) 1 else 0;
}

/// Check if character is a graphical character (printable, not space)
pub export fn isgraph(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch > 0x20 and ch <= 0x7e) 1 else 0;
}

/// Check if character is punctuation (graphical but not alphanumeric)
pub export fn ispunct(c: c_int) c_int {
    return if (isgraph(c) != 0 and isalnum(c) == 0) 1 else 0;
}

/// Check if character is a blank (space or tab)
pub export fn isblank(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch == ' ' or ch == '\t') 1 else 0;
}

/// Check if character is in the ASCII range (0-127)
pub export fn isascii(c: c_int) c_int {
    return if (c >= 0 and c <= 127) 1 else 0;
}

/// Convert to ASCII by clearing high bit
pub export fn toascii(c: c_int) c_int {
    return c & 0x7f;
}
