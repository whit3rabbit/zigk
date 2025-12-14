// String to number conversion (stdlib.h)
//
// Functions for parsing numbers from strings.

const internal = @import("../internal.zig");

/// Convert string to integer
pub export fn atoi(str: ?[*:0]const u8) c_int {
    if (str == null) return 0;
    var s = str.?;

    // Skip whitespace
    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    // Handle sign
    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Parse digits
    var result: c_int = 0;
    while (s[0] >= '0' and s[0] <= '9') {
        result = result * 10 + @as(c_int, s[0] - '0');
        s += 1;
    }

    return if (negative) -result else result;
}

/// Convert string to long integer
pub export fn atol(str: ?[*:0]const u8) c_long {
    if (str == null) return 0;
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    var result: c_long = 0;
    while (s[0] >= '0' and s[0] <= '9') {
        result = result * 10 + @as(c_long, s[0] - '0');
        s += 1;
    }

    return if (negative) -result else result;
}

/// Convert string to long long integer
pub export fn atoll(str: ?[*:0]const u8) c_longlong {
    if (str == null) return 0;
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    var result: c_longlong = 0;
    while (s[0] >= '0' and s[0] <= '9') {
        result = result * 10 + @as(c_longlong, s[0] - '0');
        s += 1;
    }

    return if (negative) -result else result;
}

/// Convert string to long with base detection
pub export fn strtol(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_long {
    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    // Skip whitespace
    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    // Handle sign
    var negative: bool = false;
    if (s[0] == '-') {
        negative = true;
        s += 1;
    } else if (s[0] == '+') {
        s += 1;
    }

    // Determine base
    var base: c_int = base_arg;
    if (base == 0) {
        if (s[0] == '0') {
            if (s[1] == 'x' or s[1] == 'X') {
                base = 16;
                s += 2;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s += 2;
    }

    // Parse digits
    var result: c_long = 0;
    while (true) {
        var digit: c_int = -1;
        if (s[0] >= '0' and s[0] <= '9') {
            digit = s[0] - '0';
        } else if (s[0] >= 'a' and s[0] <= 'z') {
            digit = s[0] - 'a' + 10;
        } else if (s[0] >= 'A' and s[0] <= 'Z') {
            digit = s[0] - 'A' + 10;
        }

        if (digit < 0 or digit >= base) break;
        result = result * base + digit;
        s += 1;
    }

    if (endptr) |ep| {
        ep.* = @ptrCast(@constCast(s));
    }

    return if (negative) -result else result;
}

/// Convert string to unsigned long with base detection
pub export fn strtoul(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_ulong {
    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    while (internal.isWhitespace(s[0])) {
        s += 1;
    }

    if (s[0] == '+') s += 1;

    var base: c_int = base_arg;
    if (base == 0) {
        if (s[0] == '0') {
            if (s[1] == 'x' or s[1] == 'X') {
                base = 16;
                s += 2;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s += 2;
    }

    var result: c_ulong = 0;
    while (true) {
        var digit: c_int = -1;
        if (s[0] >= '0' and s[0] <= '9') {
            digit = s[0] - '0';
        } else if (s[0] >= 'a' and s[0] <= 'z') {
            digit = s[0] - 'a' + 10;
        } else if (s[0] >= 'A' and s[0] <= 'Z') {
            digit = s[0] - 'A' + 10;
        }

        if (digit < 0 or digit >= base) break;
        result = result * @as(c_ulong, @intCast(base)) + @as(c_ulong, @intCast(digit));
        s += 1;
    }

    if (endptr) |ep| {
        ep.* = @ptrCast(@constCast(s));
    }

    return result;
}

/// Convert string to long long with base detection
pub export fn strtoll(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_longlong {
    // Implementation similar to strtol but with c_longlong
    const result = strtol(str, endptr, base_arg);
    return @as(c_longlong, result);
}

/// Convert string to unsigned long long with base detection
pub export fn strtoull(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_ulonglong {
    const result = strtoul(str, endptr, base_arg);
    return @as(c_ulonglong, result);
}

/// Convert string to double (simplified)
pub export fn atof(nptr: ?[*:0]const u8) f64 {
    if (nptr == null) return 0.0;
    const s = nptr.?;

    var i: usize = 0;

    // Skip whitespace
    while (s[i] != 0 and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

    // Check sign
    var negative: bool = false;
    if (s[i] == '-') {
        negative = true;
        i += 1;
    } else if (s[i] == '+') {
        i += 1;
    }

    // Parse integer part
    var result: f64 = 0.0;
    while (s[i] != 0 and s[i] >= '0' and s[i] <= '9') {
        result = result * 10.0 + @as(f64, @floatFromInt(s[i] - '0'));
        i += 1;
    }

    // Parse fractional part
    if (s[i] == '.') {
        i += 1;
        var frac: f64 = 0.1;
        while (s[i] != 0 and s[i] >= '0' and s[i] <= '9') {
            result += @as(f64, @floatFromInt(s[i] - '0')) * frac;
            frac *= 0.1;
            i += 1;
        }
    }

    // TODO: Handle exponent (e/E notation)

    return if (negative) -result else result;
}

/// Convert string to double with end pointer
pub export fn strtod(nptr: ?[*:0]const u8, endptr: ?*?[*:0]u8) f64 {
    // Simplified - just use atof and set endptr to end of parsed portion
    const result = atof(nptr);
    if (endptr) |ep| {
        if (nptr) |s| {
            var i: usize = 0;
            // Skip what was parsed
            while (s[i] != 0 and (s[i] == ' ' or s[i] == '\t' or s[i] == '-' or s[i] == '+' or
                (s[i] >= '0' and s[i] <= '9') or s[i] == '.')) : (i += 1)
            {}
            ep.* = @ptrCast(@constCast(s + i));
        } else {
            ep.* = null;
        }
    }
    return result;
}

/// Convert string to float
pub export fn strtof(nptr: ?[*:0]const u8, endptr: ?*?[*:0]u8) f32 {
    return @floatCast(strtod(nptr, endptr));
}
