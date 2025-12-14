// Format string parsing utilities
//
// Helper types and functions for printf/scanf family.
// Cannot share vararg consumption, but can share format parsing.

const std = @import("std");

/// Format specifier parsed from format string
pub const FormatSpec = struct {
    /// Width (0 if not specified, -1 for *)
    width: i32 = 0,
    /// Precision (-1 if not specified, -2 for *)
    precision: i32 = -1,
    /// Flags
    left_justify: bool = false,
    show_sign: bool = false,
    space_sign: bool = false,
    alt_form: bool = false,
    zero_pad: bool = false,
    /// Length modifier
    length: Length = .none,
    /// Conversion specifier
    specifier: u8 = 0,
    /// Number of characters consumed from format string
    consumed: usize = 0,
};

pub const Length = enum {
    none,
    h, // short
    hh, // char
    l, // long
    ll, // long long
    L, // long double
    z, // size_t
    j, // intmax_t
    t, // ptrdiff_t
};

/// Parse a format specifier starting at fmt[0] (which should be '%')
pub fn parseFormatSpec(fmt: [*:0]const u8) FormatSpec {
    var spec = FormatSpec{};
    var i: usize = 1; // Skip '%'

    // Parse flags
    while (true) {
        switch (fmt[i]) {
            '-' => spec.left_justify = true,
            '+' => spec.show_sign = true,
            ' ' => spec.space_sign = true,
            '#' => spec.alt_form = true,
            '0' => spec.zero_pad = true,
            else => break,
        }
        i += 1;
    }

    // Parse width
    if (fmt[i] == '*') {
        spec.width = -1; // Width from argument
        i += 1;
    } else {
        while (fmt[i] >= '0' and fmt[i] <= '9') {
            spec.width = spec.width * 10 + @as(i32, fmt[i] - '0');
            i += 1;
        }
    }

    // Parse precision
    if (fmt[i] == '.') {
        i += 1;
        spec.precision = 0;
        if (fmt[i] == '*') {
            spec.precision = -2; // Precision from argument
            i += 1;
        } else {
            while (fmt[i] >= '0' and fmt[i] <= '9') {
                spec.precision = spec.precision * 10 + @as(i32, fmt[i] - '0');
                i += 1;
            }
        }
    }

    // Parse length modifier
    if (fmt[i] == 'h') {
        i += 1;
        if (fmt[i] == 'h') {
            spec.length = .hh;
            i += 1;
        } else {
            spec.length = .h;
        }
    } else if (fmt[i] == 'l') {
        i += 1;
        if (fmt[i] == 'l') {
            spec.length = .ll;
            i += 1;
        } else {
            spec.length = .l;
        }
    } else if (fmt[i] == 'L') {
        spec.length = .L;
        i += 1;
    } else if (fmt[i] == 'z') {
        spec.length = .z;
        i += 1;
    } else if (fmt[i] == 'j') {
        spec.length = .j;
        i += 1;
    } else if (fmt[i] == 't') {
        spec.length = .t;
        i += 1;
    }

    // Parse conversion specifier
    spec.specifier = fmt[i];
    if (fmt[i] != 0) {
        i += 1;
    }

    spec.consumed = i;
    return spec;
}

/// Format an integer into buffer
/// Returns slice of formatted characters
pub fn formatInt(buf: []u8, value: i64, spec: FormatSpec) []u8 {
    var num = value;
    var is_negative = false;

    if (num < 0) {
        is_negative = true;
        num = -num;
    }

    // Format digits in reverse
    var tmp: [24]u8 = undefined;
    var len: usize = 0;

    if (num == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (num > 0) : (len += 1) {
            tmp[len] = @truncate('0' + @as(u8, @truncate(@as(u64, @bitCast(num)) % 10)));
            num = @divTrunc(num, 10);
        }
    }

    // Build output with padding
    var out_len: usize = 0;
    const min_width: usize = if (spec.width > 0) @intCast(spec.width) else 0;
    const sign_char: ?u8 = if (is_negative) '-' else if (spec.show_sign) '+' else if (spec.space_sign) ' ' else null;
    const sign_len: usize = if (sign_char != null) 1 else 0;
    const digits_len = len;
    const total_content = sign_len + digits_len;

    // Left padding (if not left-justified)
    if (!spec.left_justify and total_content < min_width) {
        const pad_char: u8 = if (spec.zero_pad and spec.precision < 0) '0' else ' ';
        if (pad_char == '0' and sign_char != null) {
            buf[out_len] = sign_char.?;
            out_len += 1;
        }
        while (out_len + digits_len + (if (pad_char != '0' and sign_char != null) sign_len else 0) < min_width) {
            buf[out_len] = pad_char;
            out_len += 1;
        }
        if (pad_char != '0' and sign_char != null) {
            buf[out_len] = sign_char.?;
            out_len += 1;
        }
    } else if (sign_char != null) {
        buf[out_len] = sign_char.?;
        out_len += 1;
    }

    // Digits (reversed)
    var i = len;
    while (i > 0) {
        i -= 1;
        buf[out_len] = tmp[i];
        out_len += 1;
    }

    // Right padding
    while (out_len < min_width) {
        buf[out_len] = ' ';
        out_len += 1;
    }

    return buf[0..out_len];
}

/// Format an unsigned integer in hex
pub fn formatHex(buf: []u8, value: u64, uppercase: bool, spec: FormatSpec) []u8 {
    const hex_lower = "0123456789abcdef";
    const hex_upper = "0123456789ABCDEF";
    const hex = if (uppercase) hex_upper else hex_lower;

    var num = value;
    var tmp: [20]u8 = undefined;
    var len: usize = 0;

    if (num == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (num > 0) : (len += 1) {
            tmp[len] = hex[@truncate(num & 0xf)];
            num >>= 4;
        }
    }

    var out_len: usize = 0;
    const min_width: usize = if (spec.width > 0) @intCast(spec.width) else 0;

    // Prefix for alternate form
    if (spec.alt_form and value != 0) {
        buf[out_len] = '0';
        out_len += 1;
        buf[out_len] = if (uppercase) 'X' else 'x';
        out_len += 1;
    }

    // Padding
    while (out_len + len < min_width) {
        buf[out_len] = if (spec.zero_pad) '0' else ' ';
        out_len += 1;
    }

    // Digits (reversed)
    var i = len;
    while (i > 0) {
        i -= 1;
        buf[out_len] = tmp[i];
        out_len += 1;
    }

    return buf[0..out_len];
}

/// Format an unsigned integer
pub fn formatUnsigned(buf: []u8, value: u64, spec: FormatSpec) []u8 {
    var num = value;
    var tmp: [24]u8 = undefined;
    var len: usize = 0;

    if (num == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (num > 0) : (len += 1) {
            tmp[len] = @truncate('0' + @as(u8, @truncate(num % 10)));
            num /= 10;
        }
    }

    var out_len: usize = 0;
    const min_width: usize = if (spec.width > 0) @intCast(spec.width) else 0;

    // Padding
    while (out_len + len < min_width) {
        buf[out_len] = if (spec.zero_pad) '0' else ' ';
        out_len += 1;
    }

    // Digits (reversed)
    var i = len;
    while (i > 0) {
        i -= 1;
        buf[out_len] = tmp[i];
        out_len += 1;
    }

    return buf[0..out_len];
}
