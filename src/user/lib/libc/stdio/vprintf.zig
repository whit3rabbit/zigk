// vprintf family implementations (stdio.h)
//
// Implements va_list traversal for x86_64 System V ABI.
// The va_list structure tracks both register-saved and stack-passed arguments.

const std = @import("std");
const syscall = @import("syscall.zig");
const file_mod = @import("file.zig");

const FILE = file_mod.FILE;

/// va_list type for C interop (x86_64 System V ABI)
/// This is a pointer to a 24-byte structure
pub const va_list = ?*anyopaque;

/// x86_64 System V ABI va_list structure layout:
/// - gp_offset (4 bytes): offset in reg_save_area for next GP register arg
/// - fp_offset (4 bytes): offset in reg_save_area for next FP register arg
/// - overflow_arg_area (8 bytes): pointer to stack-passed arguments
/// - reg_save_area (8 bytes): pointer to register save area
const VA_GP_OFFSET = 0;
const VA_FP_OFFSET = 4;
const VA_OVERFLOW_ARG_AREA = 8;
const VA_REG_SAVE_AREA = 16;

/// Maximum GP registers used for argument passing (6 registers * 8 bytes = 48)
const GP_REG_LIMIT: u32 = 48;

/// Read a u32 from potentially unaligned memory
inline fn readU32(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) |
        (@as(u32, ptr[1]) << 8) |
        (@as(u32, ptr[2]) << 16) |
        (@as(u32, ptr[3]) << 24);
}

/// Read a u64 from potentially unaligned memory
inline fn readU64(ptr: [*]const u8) u64 {
    return @as(u64, ptr[0]) |
        (@as(u64, ptr[1]) << 8) |
        (@as(u64, ptr[2]) << 16) |
        (@as(u64, ptr[3]) << 24) |
        (@as(u64, ptr[4]) << 32) |
        (@as(u64, ptr[5]) << 40) |
        (@as(u64, ptr[6]) << 48) |
        (@as(u64, ptr[7]) << 56);
}

/// Write a u32 to potentially unaligned memory
inline fn writeU32(ptr: [*]u8, val: u32) void {
    ptr[0] = @truncate(val);
    ptr[1] = @truncate(val >> 8);
    ptr[2] = @truncate(val >> 16);
    ptr[3] = @truncate(val >> 24);
}

/// Get next argument from va_list (advances the va_list state)
fn vaArg(ap: va_list) usize {
    const ptr: [*]u8 = @ptrCast(ap orelse return 0);

    // Read current gp_offset
    const gp_offset = readU32(ptr + VA_GP_OFFSET);

    if (gp_offset < GP_REG_LIMIT) {
        // Argument is in register save area
        const reg_save_addr = readU64(ptr + VA_REG_SAVE_AREA);
        if (reg_save_addr != 0) {
            const reg_save: [*]const u8 = @ptrFromInt(reg_save_addr);
            const val = readU64(reg_save + gp_offset);

            // Advance gp_offset by 8 bytes
            writeU32(ptr + VA_GP_OFFSET, gp_offset + 8);

            return val;
        }
    }

    // Argument is on the stack (overflow area)
    const overflow_addr = readU64(ptr + VA_OVERFLOW_ARG_AREA);
    if (overflow_addr != 0) {
        const overflow: [*]const u8 = @ptrFromInt(overflow_addr);
        const val = readU64(overflow);

        // Advance overflow_arg_area by 8 bytes
        const new_overflow = overflow_addr + 8;
        const overflow_ptr = ptr + VA_OVERFLOW_ARG_AREA;
        overflow_ptr[0] = @truncate(new_overflow);
        overflow_ptr[1] = @truncate(new_overflow >> 8);
        overflow_ptr[2] = @truncate(new_overflow >> 16);
        overflow_ptr[3] = @truncate(new_overflow >> 24);
        overflow_ptr[4] = @truncate(new_overflow >> 32);
        overflow_ptr[5] = @truncate(new_overflow >> 40);
        overflow_ptr[6] = @truncate(new_overflow >> 48);
        overflow_ptr[7] = @truncate(new_overflow >> 56);

        return val;
    }

    return 0;
}

/// Format output buffer size for vfprintf/vprintf
const FORMAT_BUF_SIZE = 4096;

/// Format a value as decimal (signed)
fn formatDecimal(buf: []u8, val: i64) []const u8 {
    var temp: [24]u8 = undefined;
    var n: u64 = undefined;
    var negative = false;

    if (val < 0) {
        negative = true;
        n = @intCast(-val);
    } else {
        n = @intCast(val);
    }

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

/// Core formatting function - formats to a buffer
fn formatToBuffer(dest: [*]u8, limit: usize, fmt: [*:0]const u8, ap: va_list) usize {
    if (limit == 0) return 0;

    var d_idx: usize = 0;
    var f_idx: usize = 0;

    while (fmt[f_idx] != 0 and d_idx < limit - 1) {
        if (fmt[f_idx] != '%') {
            dest[d_idx] = fmt[f_idx];
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
                dest[d_idx] = '%';
                d_idx += 1;
            },
            's' => {
                const str_ptr = vaArg(ap);
                if (str_ptr != 0) {
                    const s: [*:0]const u8 = @ptrFromInt(str_ptr);
                    var s_idx: usize = 0;
                    while (s[s_idx] != 0 and d_idx < limit - 1) : (s_idx += 1) {
                        dest[d_idx] = s[s_idx];
                        d_idx += 1;
                    }
                } else {
                    // Handle NULL string
                    const null_str = "(null)";
                    for (null_str) |c| {
                        if (d_idx >= limit - 1) break;
                        dest[d_idx] = c;
                        d_idx += 1;
                    }
                }
            },
            'c' => {
                const ch: u8 = @truncate(vaArg(ap));
                dest[d_idx] = ch;
                d_idx += 1;
            },
            'd', 'i' => {
                const val: i64 = @bitCast(vaArg(ap));
                const formatted = formatDecimal(&num_buf, val);
                // Apply precision (minimum digits) with leading zeros
                const min_digits = if (has_precision) precision else 1;
                const is_negative = val < 0;
                const digit_count = if (is_negative) formatted.len - 1 else formatted.len;
                // Print sign first if negative
                if (is_negative) {
                    if (d_idx < limit - 1) {
                        dest[d_idx] = '-';
                        d_idx += 1;
                    }
                }
                // Pad with zeros
                if (digit_count < min_digits) {
                    var zeros = min_digits - digit_count;
                    while (zeros > 0 and d_idx < limit - 1) : (zeros -= 1) {
                        dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                // Print digits (skip sign if negative)
                const start: usize = if (is_negative) 1 else 0;
                for (formatted[start..]) |c| {
                    if (d_idx >= limit - 1) break;
                    dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'u' => {
                const val = vaArg(ap);
                const formatted = formatUnsigned(&num_buf, val);
                // Apply precision (minimum digits) with leading zeros
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0 and d_idx < limit - 1) : (zeros -= 1) {
                        dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx >= limit - 1) break;
                    dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'x' => {
                const val = vaArg(ap);
                const formatted = formatHex(&num_buf, val, false);
                // Apply precision (minimum digits) with leading zeros
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0 and d_idx < limit - 1) : (zeros -= 1) {
                        dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx >= limit - 1) break;
                    dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'X' => {
                const val = vaArg(ap);
                const formatted = formatHex(&num_buf, val, true);
                // Apply precision (minimum digits) with leading zeros
                const min_digits = if (has_precision) precision else 1;
                if (formatted.len < min_digits) {
                    var zeros = min_digits - formatted.len;
                    while (zeros > 0 and d_idx < limit - 1) : (zeros -= 1) {
                        dest[d_idx] = '0';
                        d_idx += 1;
                    }
                }
                for (formatted) |c| {
                    if (d_idx >= limit - 1) break;
                    dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'p' => {
                const val = vaArg(ap);
                // Print "0x" prefix
                if (d_idx < limit - 1) {
                    dest[d_idx] = '0';
                    d_idx += 1;
                }
                if (d_idx < limit - 1) {
                    dest[d_idx] = 'x';
                    d_idx += 1;
                }
                const formatted = formatHex(&num_buf, val, false);
                for (formatted) |c| {
                    if (d_idx >= limit - 1) break;
                    dest[d_idx] = c;
                    d_idx += 1;
                }
            },
            'n' => {
                // %n - store number of characters written so far
                const ptr = vaArg(ap);
                if (ptr != 0) {
                    const n_ptr: *i32 = @ptrFromInt(ptr);
                    n_ptr.* = @intCast(d_idx);
                }
            },
            else => {
                // Unknown specifier, print it literally
                dest[d_idx] = '%';
                d_idx += 1;
                if (d_idx < limit - 1) {
                    dest[d_idx] = spec;
                    d_idx += 1;
                }
            },
        }
    }

    dest[d_idx] = 0; // null terminate
    return d_idx;
}

/// vprintf - print formatted output to stdout
pub export fn vprintf(fmt: [*:0]const u8, ap: va_list) c_int {
    var buf: [FORMAT_BUF_SIZE]u8 = undefined;
    const len = formatToBuffer(&buf, buf.len, fmt, ap);
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
    const len = formatToBuffer(&buf, buf.len, fmt, ap);
    if (len > 0) {
        _ = syscall.write(f.fd, &buf, len) catch return -1;
    }
    return @intCast(len);
}

/// vsnprintf - format to string with size limit
pub export fn vsnprintf(dest: ?[*]u8, size: usize, fmt: [*:0]const u8, ap: va_list) c_int {
    if (dest == null or size == 0) return 0;
    const len = formatToBuffer(dest.?, size, fmt, ap);
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
    return vsnprintf(dest, 1024, fmt, ap);
}

/// vasprintf - allocate and format string (stub - needs allocator)
pub export fn vasprintf(strp: ?*?[*:0]u8, fmt: [*:0]const u8, ap: va_list) c_int {
    _ = fmt;
    _ = ap;
    if (strp == null) return -1;
    strp.?.* = null;
    return -1;
}
