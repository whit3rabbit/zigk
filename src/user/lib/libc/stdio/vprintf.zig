// vprintf family implementations (stdio.h)
//
// Implements va_list traversal using architecture-aware VaList abstraction.
// Supports both x86_64 System V ABI and aarch64 AAPCS64.

const std = @import("std");
const syscall = @import("syscall");
const file_mod = @import("file.zig");
const va_list_mod = @import("../va_list.zig");
const memory = @import("../memory/root.zig");

const FILE = file_mod.FILE;
const VaList = va_list_mod.VaList;

/// va_list type for C interop - raw pointer to architecture-specific structure
pub const va_list = ?*anyopaque;

/// Format output buffer size for vfprintf/vprintf
const FORMAT_BUF_SIZE = 4096;

/// Format a value as decimal (signed)
fn formatDecimal(buf: []u8, val: i64) []const u8 {
    var temp: [24]u8 = undefined;
    var negative = false;
    // Fix: Use unsigned magnitude to handle INT64_MIN
    var n: u64 = @abs(val);
    var i: usize = temp.len;

    if (val < 0) {
        negative = true;
    }
    if (n == 0) {
        i -= 1;
        temp[i] = '0';
    } else {
        while (n > 0) {
            i -= 1;
            temp[i] = @truncate((n % 10) + '0');
            n /= 10;
        }
    }

    if (negative) {
        i -= 1;
        temp[i] = '-';
    }

    const len = temp.len - i;
    if (len > buf.len) return buf[0..0];
    @memcpy(buf[0..len], temp[i..]);
    return buf[0..len];
}

/// Format a value as unsigned decimal
fn formatUnsigned(buf: []u8, val: u64) []const u8 {
    var temp: [24]u8 = undefined;
    var n = val;

    var i: usize = temp.len;
    if (n == 0) {
        i -= 1;
        temp[i] = '0';
    } else {
        while (n > 0) {
            i -= 1;
            temp[i] = @truncate((n % 10) + '0');
            n /= 10;
        }
    }

    const len = temp.len - i;
    if (len > buf.len) return buf[0..0];
    @memcpy(buf[0..len], temp[i..]);
    return buf[0..len];
}

/// Format a value as hexadecimal
fn formatHex(buf: []u8, val: u64, uppercase: bool) []const u8 {
    const hex_lower = "0123456789abcdef";
    const hex_upper = "0123456789ABCDEF";
    const hex = if (uppercase) hex_upper else hex_lower;

    var temp: [16]u8 = undefined;
    var n = val;

    var i: usize = temp.len;
    if (n == 0) {
        i -= 1;
        temp[i] = '0';
    } else {
        while (n > 0) {
            i -= 1;
            temp[i] = hex[@truncate(n & 0xF)];
            n >>= 4;
        }
    }

    const len = temp.len - i;
    if (len > buf.len) return buf[0..0];
    @memcpy(buf[0..len], temp[i..]);
    return buf[0..len];
}

/// Core formatting function - formats to a buffer using VaList abstraction
fn formatToBuffer(dest: [*]u8, limit: usize, fmt: [*:0]const u8, valist: *VaList) usize {
    if (limit == 0) return 0;

    var d_idx: usize = 0;
    var f_idx: usize = 0;

    // Max index we can write to (leaving room for null terminator)
    const write_limit = limit - 1;

    while (fmt[f_idx] != 0) {
        if (fmt[f_idx] != '%') {
            if (d_idx < write_limit) dest[d_idx] = fmt[f_idx];
            d_idx += 1;
            f_idx += 1;
            continue;
        }

        f_idx += 1; // skip '%'
        if (fmt[f_idx] == 0) break;

        // Skip optional flags
        while (fmt[f_idx] == '-' or fmt[f_idx] == '0' or fmt[f_idx] == '+' or fmt[f_idx] == ' ' or fmt[f_idx] == '#') {
            f_idx += 1;
            if (fmt[f_idx] == 0) break;
        }

        // Skip optional width (TODO: implement width padding)
        while (fmt[f_idx] >= '0' and fmt[f_idx] <= '9') {
            f_idx += 1;
            if (fmt[f_idx] == 0) break;
        }

        // Parse optional precision
        var precision: usize = 0;
        var has_precision = false;
        if (fmt[f_idx] == '.') {
            has_precision = true;
            f_idx += 1;
            while (fmt[f_idx] >= '0' and fmt[f_idx] <= '9') {
                precision = precision * 10 + (fmt[f_idx] - '0');
                f_idx += 1;
                if (fmt[f_idx] == 0) break;
            }
        }

        // Skip optional length modifier
        if (fmt[f_idx] == 'l') {
            f_idx += 1;
            if (fmt[f_idx] == 'l') {
                f_idx += 1;
            }
        } else if (fmt[f_idx] == 'h') {
            f_idx += 1;
            if (fmt[f_idx] == 'h') {
                f_idx += 1;
            }
        } else if (fmt[f_idx] == 'z' or fmt[f_idx] == 'j' or fmt[f_idx] == 't') {
            f_idx += 1;
        }

        if (fmt[f_idx] == 0) break;
        const spec = fmt[f_idx];
        f_idx += 1;

        var num_buf: [32]u8 = undefined;

        switch (spec) {
            '%' => {
                if (d_idx < write_limit) dest[d_idx] = '%';
                d_idx += 1;
            },
            's' => {
                const str_ptr = valist.arg(usize);
                if (str_ptr != 0) {
                    const s: [*:0]const u8 = @ptrFromInt(str_ptr);
                    var s_idx: usize = 0;
                    while (s[s_idx] != 0) : (s_idx += 1) {
                        if (d_idx < write_limit) dest[d_idx] = s[s_idx];
                        d_idx += 1;
                    }
                } else {
                    const null_str = "(null)";
                    for (null_str) |c| {
                        if (d_idx < write_limit) dest[d_idx] = c;
                        d_idx += 1;
                    }
                }
            },
            'c' => {
                const ch: u8 = @truncate(valist.arg(usize));
                if (d_idx < write_limit) dest[d_idx] = ch;
                d_idx += 1;
            },
            'd', 'i' => {
                const val: i64 = @bitCast(valist.arg(usize));
                const formatted = formatDecimal(&num_buf, val);
                const min_digits = if (has_precision) precision else 1;
                const is_negative = val < 0;
                const digit_count = if (is_negative) formatted.len - 1 else formatted.len;
                if (is_negative) {
                    if (d_idx < write_limit) dest[d_idx] = '-';
                    d_idx += 1;
                }
                if (digit_count < min_digits) {
                    var zeros = min_digits - digit_count;
                    while (zeros > 0) : (zeros -= 1) {
                        if (d_idx < write_limit) dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                const start: usize = if (is_negative) 1 else 0;
                for (formatted[start..]) |c| {
                    if (d_idx < write_limit) dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'u' => {
                const val = valist.arg(usize);
                const formatted = formatUnsigned(&num_buf, val);
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0) : (zeros -= 1) {
                        if (d_idx < write_limit) dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx < write_limit) dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'x' => {
                const val = valist.arg(usize);
                const formatted = formatHex(&num_buf, val, false);
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0) : (zeros -= 1) {
                        if (d_idx < write_limit) dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx < write_limit) dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'X' => {
                const val = valist.arg(usize);
                const formatted = formatHex(&num_buf, val, true);
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0) : (zeros -= 1) {
                        if (d_idx < write_limit) dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx < write_limit) dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'p' => {
                const val = valist.arg(usize);
                if (d_idx < write_limit) dest[d_idx] = '0';
                d_idx += 1;
                if (d_idx < write_limit) dest[d_idx] = 'x';
                d_idx += 1;
                const formatted = formatHex(&num_buf, val, false);
                for (formatted) |c| {
                    if (d_idx < write_limit) dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'n' => {
                // SECURITY: %n is disabled - allows arbitrary memory write
                // Consume the argument but do nothing with it
                _ = valist.arg(usize);
            },
            else => {
                // Unknown specifier, print it literally
                if (d_idx < write_limit) dest[d_idx] = '%';
                d_idx += 1;
                if (d_idx < write_limit) {
                    dest[d_idx] = spec;
                    d_idx += 1;
                }
            },
        }
    }

    // Null-terminate: write at d_idx if within buffer, otherwise at last position
    if (d_idx < limit) {
        dest[d_idx] = 0;
    } else if (limit > 0) {
        dest[limit - 1] = 0;
    }
    return d_idx;
}

/// vprintf - print formatted output to stdout
pub export fn vprintf(fmt: [*:0]const u8, ap: va_list) c_int {
    var buf: [FORMAT_BUF_SIZE]u8 = undefined;
    var valist = VaList.from(ap);
    const len = formatToBuffer(&buf, buf.len, fmt, &valist);
    if (len > 0) {
        _ = syscall.write(1, &buf, len) catch return -1;
    }
    return @intCast(len);
}

/// vfprintf - print formatted output to file
pub export fn vfprintf(stream: ?*FILE, fmt: [*:0]const u8, ap: va_list) c_int {
    if (stream == null) return -1;
    const f = stream.?;

    var buf: [FORMAT_BUF_SIZE]u8 = undefined;
    var valist = VaList.from(ap);
    const len = formatToBuffer(&buf, buf.len, fmt, &valist);
    if (len > 0) {
        _ = syscall.write(f.fd, &buf, len) catch return -1;
    }
    return @intCast(len);
}

/// vsnprintf - format to string with size limit
pub export fn vsnprintf(dest: ?[*]u8, size: usize, fmt: [*:0]const u8, ap: va_list) c_int {
    if (dest == null or size == 0) return 0;
    var valist = VaList.from(ap);
    const len = formatToBuffer(dest.?, size, fmt, &valist);
    return @intCast(len);
}

/// vsprintf - format to string (UNSAFE - use vsnprintf instead)
/// WARNING: This function cannot know the destination buffer size.
/// It uses a conservative 1024-byte limit, but callers should migrate
/// to vsnprintf() with an explicit size parameter.
pub export fn vsprintf(dest: ?[*]u8, fmt: [*:0]const u8, ap: va_list) c_int {
    // SECURITY: Limit to 1024 bytes as a safety measure.
    // This is still unsafe but reduces the damage from legacy code.
    // New code should ALWAYS use vsnprintf() with explicit size.
    if (dest == null) return 0;
    var valist = VaList.from(ap);
    const len = formatToBuffer(dest.?, 1024, fmt, &valist);
    return @intCast(len);
}

/// vasprintf - allocate and format string (unlimited output size)
/// Uses two-pass approach with va_copy: first pass counts characters needed,
/// second pass formats into an exactly-sized allocated buffer.
/// Sets *strp to the allocated buffer on success.
/// Returns length on success (excluding null terminator), -1 on error.
pub export fn vasprintf(strp: ?*?[*:0]u8, fmt: [*:0]const u8, ap: va_list) c_int {
    if (strp == null) return -1;
    strp.?.* = null;

    var valist = VaList.from(ap);
    var saved = valist.save();

    // Pass 1: count characters needed (1-byte buffer forces counting only)
    var dummy: [1]u8 = undefined;
    const len = formatToBuffer(&dummy, 1, fmt, &valist);

    // Pass 2: allocate exact buffer and format
    const alloc_size = len + 1;
    const ptr = memory.malloc(alloc_size) orelse return -1;
    const dest: [*]u8 = @ptrCast(ptr);

    var restored = saved.toVaList();
    _ = formatToBuffer(dest, alloc_size, fmt, &restored);

    strp.?.* = @ptrCast(dest);
    return @intCast(len);
}
