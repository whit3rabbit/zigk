// sscanf implementation (stdio.h)
//
// Formatted input from string.
// Supports: %d, %i, %u, %x, %s, %c, %n, %%

const std = @import("std");
const internal = @import("../internal.zig");

/// Parse formatted input from string
pub export fn sscanf(str: ?[*:0]const u8, fmt: ?[*:0]const u8, ...) c_int {
    if (str == null or fmt == null) return -1;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var s = str.?;
    var f = fmt.?;
    var matched: c_int = 0;

    while (f[0] != 0) {
        // Skip whitespace in format (matches any amount in input)
        if (internal.isWhitespace(f[0])) {
            while (internal.isWhitespace(s[0])) s += 1;
            f += 1;
            continue;
        }

        // Literal match
        if (f[0] != '%') {
            if (s[0] != f[0]) break;
            s += 1;
            f += 1;
            continue;
        }

        // Format specifier
        f += 1;
        if (f[0] == 0) break;

        // Handle %%
        if (f[0] == '%') {
            if (s[0] != '%') break;
            s += 1;
            f += 1;
            continue;
        }

        // Check for assignment suppression
        var suppress = false;
        if (f[0] == '*') {
            suppress = true;
            f += 1;
        }

        // Parse width
        var width: usize = 0;
        while (f[0] >= '0' and f[0] <= '9') {
            width = width * 10 + @as(usize, f[0] - '0');
            f += 1;
        }
        if (width == 0) width = ~@as(usize, 0); // No limit

        // Length modifier
        var is_long = false;
        var is_short = false;
        if (f[0] == 'l') {
            is_long = true;
            f += 1;
            if (f[0] == 'l') f += 1; // ll
        } else if (f[0] == 'h') {
            is_short = true;
            f += 1;
            if (f[0] == 'h') f += 1; // hh
        }

        const spec = f[0];
        f += 1;

        switch (spec) {
            'd', 'i' => {
                // Skip leading whitespace
                while (internal.isWhitespace(s[0])) s += 1;

                // Parse sign
                var negative = false;
                if (s[0] == '-') {
                    negative = true;
                    s += 1;
                } else if (s[0] == '+') {
                    s += 1;
                }

                // Determine base for %i
                var base: u8 = 10;
                if (spec == 'i' and s[0] == '0') {
                    if (s[1] == 'x' or s[1] == 'X') {
                        base = 16;
                        s += 2;
                    } else {
                        base = 8;
                    }
                }

                // Parse digits
                var value: i64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    var digit: ?u8 = null;
                    if (s[0] >= '0' and s[0] <= '9') {
                        digit = s[0] - '0';
                    } else if (base == 16) {
                        if (s[0] >= 'a' and s[0] <= 'f') {
                            digit = s[0] - 'a' + 10;
                        } else if (s[0] >= 'A' and s[0] <= 'F') {
                            digit = s[0] - 'A' + 10;
                        }
                    }

                    if (digit == null or digit.? >= base) break;
                    value = value * base + digit.?;
                    s += 1;
                    digits += 1;
                }

                if (digits == 0) break; // No digits matched

                if (negative) value = -value;

                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(&args, ?*c_long);
                        if (ptr) |p| p.* = @intCast(value);
                    } else if (is_short) {
                        const ptr = @cVaArg(&args, ?*c_short);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(&args, ?*c_int);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'u' => {
                while (internal.isWhitespace(s[0])) s += 1;

                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width and s[0] >= '0' and s[0] <= '9') {
                    value = value * 10 + @as(u64, s[0] - '0');
                    s += 1;
                    digits += 1;
                }

                if (digits == 0) break;

                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(&args, ?*c_ulong);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(&args, ?*c_uint);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            'x', 'X' => {
                while (internal.isWhitespace(s[0])) s += 1;

                // Skip optional 0x prefix
                if (s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
                    s += 2;
                }

                var value: u64 = 0;
                var digits: usize = 0;
                while (digits < width) {
                    const digit = internal.hexDigitValue(s[0]);
                    if (digit == null) break;
                    value = value * 16 + digit.?;
                    s += 1;
                    digits += 1;
                }

                if (digits == 0) break;

                if (!suppress) {
                    if (is_long) {
                        const ptr = @cVaArg(&args, ?*c_ulong);
                        if (ptr) |p| p.* = @intCast(value);
                    } else {
                        const ptr = @cVaArg(&args, ?*c_uint);
                        if (ptr) |p| p.* = @intCast(value);
                    }
                    matched += 1;
                }
            },
            's' => {
                while (internal.isWhitespace(s[0])) s += 1;

                if (!suppress) {
                    const ptr = @cVaArg(&args, ?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < width and s[0] != 0 and !internal.isWhitespace(s[0])) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        dest[i] = 0;
                        if (i > 0) matched += 1;
                    }
                } else {
                    while (s[0] != 0 and !internal.isWhitespace(s[0])) s += 1;
                }
            },
            'c' => {
                // %c does NOT skip whitespace
                const count = if (width == ~@as(usize, 0)) 1 else width;

                if (!suppress) {
                    const ptr = @cVaArg(&args, ?[*]u8);
                    if (ptr) |dest| {
                        var i: usize = 0;
                        while (i < count and s[0] != 0) {
                            dest[i] = s[0];
                            s += 1;
                            i += 1;
                        }
                        if (i > 0) matched += 1;
                    }
                } else {
                    var i: usize = 0;
                    while (i < count and s[0] != 0) {
                        s += 1;
                        i += 1;
                    }
                }
            },
            'n' => {
                // Store number of characters read so far
                if (!suppress) {
                    const ptr = @cVaArg(&args, ?*c_int);
                    if (ptr) |p| {
                        p.* = @intCast(@intFromPtr(s) - @intFromPtr(str.?));
                    }
                }
                // %n doesn't count as a matched item
            },
            '[' => {
                // Scanset - simplified: just skip to ]
                while (f[0] != 0 and f[0] != ']') f += 1;
                if (f[0] == ']') f += 1;
                // Not fully implemented
            },
            else => {
                // Unknown specifier
                break;
            },
        }
    }

    return matched;
}

/// fscanf - formatted input from file (stub - would need file reading)
pub export fn fscanf(stream: ?*anyopaque, fmt: ?[*:0]const u8, ...) c_int {
    _ = stream;
    _ = fmt;
    // Would need to read from file and parse
    return 0;
}

/// scanf - formatted input from stdin (stub)
pub export fn scanf(fmt: ?[*:0]const u8, ...) c_int {
    _ = fmt;
    // Would need to read from stdin
    return 0;
}
