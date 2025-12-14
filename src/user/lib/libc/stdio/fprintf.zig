// fprintf, sprintf, snprintf implementations (stdio.h)
//
// Formatted output to files and strings.

const std = @import("std");
const syscall = @import("syscall.zig");
const file_mod = @import("file.zig");

const FILE = file_mod.FILE;

/// Print formatted output to file stream
pub export fn fprintf(stream: ?*FILE, fmt_str: [*:0]const u8, ...) c_int {
    if (stream == null) return -1;
    const f = stream.?;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [4096]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = fmt_str;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            // Skip flags
            while (fmt_ptr[0] == '-' or fmt_ptr[0] == '+' or fmt_ptr[0] == ' ' or
                fmt_ptr[0] == '#' or fmt_ptr[0] == '0')
            {
                fmt_ptr += 1;
            }

            // Skip width
            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            // Skip precision
            if (fmt_ptr[0] == '.') {
                fmt_ptr += 1;
                while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;
            }

            // Check length modifier
            var is_long: bool = false;
            var is_long_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'l') {
                    is_long_long = true;
                    fmt_ptr += 1;
                }
            } else if (fmt_ptr[0] == 'h') {
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'h') fmt_ptr += 1;
            } else if (fmt_ptr[0] == 'z' or fmt_ptr[0] == 'j' or fmt_ptr[0] == 't') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    const val: i64 = if (is_long_long)
                        @cVaArg(&args, c_longlong)
                    else if (is_long)
                        @as(i64, @cVaArg(&args, c_long))
                    else
                        @as(i64, @cVaArg(&args, c_int));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'u' => {
                    const val: u64 = if (is_long_long)
                        @cVaArg(&args, c_ulonglong)
                    else if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'x' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
                    written += s.len;
                },
                'X' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{X}", .{val}) catch break;
                    written += s.len;
                },
                'o' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{o}", .{val}) catch break;
                    written += s.len;
                },
                'p' => {
                    const val = @cVaArg(&args, usize);
                    const s = std.fmt.bufPrint(buf[written..], "0x{x}", .{val}) catch break;
                    written += s.len;
                },
                's' => {
                    const val = @cVaArg(&args, ?[*:0]const u8);
                    if (val) |str| {
                        const len = std.mem.len(str);
                        const copy_len = @min(len, buf.len - written);
                        @memcpy(buf[written..][0..copy_len], str[0..copy_len]);
                        written += copy_len;
                    } else {
                        const null_str = "(null)";
                        if (written + null_str.len <= buf.len) {
                            @memcpy(buf[written..][0..null_str.len], null_str);
                            written += null_str.len;
                        }
                    }
                },
                'c' => {
                    const val = @cVaArg(&args, c_int);
                    if (written < buf.len) {
                        buf[written] = @truncate(@as(c_uint, @bitCast(val)));
                        written += 1;
                    }
                },
                'f', 'F', 'e', 'E', 'g', 'G' => {
                    const val = @cVaArg(&args, f64);
                    const s = std.fmt.bufPrint(buf[written..], "{d:.6}", .{val}) catch break;
                    written += s.len;
                },
                '%' => {
                    if (written < buf.len) {
                        buf[written] = '%';
                        written += 1;
                    }
                },
                'n' => {
                    const ptr = @cVaArg(&args, ?*c_int);
                    if (ptr) |p| {
                        p.* = @intCast(written);
                    }
                },
                else => {
                    if (written < buf.len) {
                        buf[written] = spec;
                        written += 1;
                    }
                },
            }
        } else {
            buf[written] = fmt_ptr[0];
            written += 1;
            fmt_ptr += 1;
        }
    }

    const bytes_written = syscall.write(f.fd, &buf, written) catch {
        f.has_error = true;
        return -1;
    };
    return @intCast(bytes_written);
}

/// Format into string buffer (no size limit - unsafe!)
pub export fn sprintf(dest: ?[*]u8, fmt_str: [*:0]const u8, ...) c_int {
    if (dest == null) return -1;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [8192]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = fmt_str;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            while (fmt_ptr[0] == '-' or fmt_ptr[0] == '+' or fmt_ptr[0] == ' ' or
                fmt_ptr[0] == '#' or fmt_ptr[0] == '0')
            {
                fmt_ptr += 1;
            }

            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            if (fmt_ptr[0] == '.') {
                fmt_ptr += 1;
                while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;
            }

            var is_long: bool = false;
            var is_long_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'l') {
                    is_long_long = true;
                    fmt_ptr += 1;
                }
            } else if (fmt_ptr[0] == 'h') {
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'h') fmt_ptr += 1;
            } else if (fmt_ptr[0] == 'z' or fmt_ptr[0] == 'j' or fmt_ptr[0] == 't') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    const val: i64 = if (is_long_long)
                        @cVaArg(&args, c_longlong)
                    else if (is_long)
                        @as(i64, @cVaArg(&args, c_long))
                    else
                        @as(i64, @cVaArg(&args, c_int));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'u' => {
                    const val: u64 = if (is_long_long)
                        @cVaArg(&args, c_ulonglong)
                    else if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'x' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
                    written += s.len;
                },
                'X' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{X}", .{val}) catch break;
                    written += s.len;
                },
                'p' => {
                    const val = @cVaArg(&args, usize);
                    const s = std.fmt.bufPrint(buf[written..], "0x{x}", .{val}) catch break;
                    written += s.len;
                },
                's' => {
                    const val = @cVaArg(&args, ?[*:0]const u8);
                    if (val) |str| {
                        const len = std.mem.len(str);
                        const copy_len = @min(len, buf.len - written);
                        @memcpy(buf[written..][0..copy_len], str[0..copy_len]);
                        written += copy_len;
                    } else {
                        const null_str = "(null)";
                        @memcpy(buf[written..][0..null_str.len], null_str);
                        written += null_str.len;
                    }
                },
                'c' => {
                    const val = @cVaArg(&args, c_int);
                    if (written < buf.len) {
                        buf[written] = @truncate(@as(c_uint, @bitCast(val)));
                        written += 1;
                    }
                },
                'f', 'F', 'e', 'E', 'g', 'G' => {
                    const val = @cVaArg(&args, f64);
                    const s = std.fmt.bufPrint(buf[written..], "{d:.6}", .{val}) catch break;
                    written += s.len;
                },
                '%' => {
                    if (written < buf.len) {
                        buf[written] = '%';
                        written += 1;
                    }
                },
                else => {
                    if (written < buf.len) {
                        buf[written] = spec;
                        written += 1;
                    }
                },
            }
        } else {
            buf[written] = fmt_ptr[0];
            written += 1;
            fmt_ptr += 1;
        }
    }

    const d = dest.?;
    @memcpy(d[0..written], buf[0..written]);
    d[written] = 0;

    return @intCast(written);
}

/// Format into string buffer with size limit
pub export fn snprintf(dest: ?[*]u8, size: usize, fmt_str: [*:0]const u8, ...) c_int {
    if (dest == null or size == 0) return 0;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [8192]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = fmt_str;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            while (fmt_ptr[0] == '-' or fmt_ptr[0] == '+' or fmt_ptr[0] == ' ' or
                fmt_ptr[0] == '#' or fmt_ptr[0] == '0')
            {
                fmt_ptr += 1;
            }

            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            if (fmt_ptr[0] == '.') {
                fmt_ptr += 1;
                while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;
            }

            var is_long: bool = false;
            var is_long_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'l') {
                    is_long_long = true;
                    fmt_ptr += 1;
                }
            } else if (fmt_ptr[0] == 'h') {
                fmt_ptr += 1;
                if (fmt_ptr[0] == 'h') fmt_ptr += 1;
            } else if (fmt_ptr[0] == 'z' or fmt_ptr[0] == 'j' or fmt_ptr[0] == 't') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    const val: i64 = if (is_long_long)
                        @cVaArg(&args, c_longlong)
                    else if (is_long)
                        @as(i64, @cVaArg(&args, c_long))
                    else
                        @as(i64, @cVaArg(&args, c_int));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'u' => {
                    const val: u64 = if (is_long_long)
                        @cVaArg(&args, c_ulonglong)
                    else if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'x' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
                    written += s.len;
                },
                'X' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    const s = std.fmt.bufPrint(buf[written..], "{X}", .{val}) catch break;
                    written += s.len;
                },
                'p' => {
                    const val = @cVaArg(&args, usize);
                    const s = std.fmt.bufPrint(buf[written..], "0x{x}", .{val}) catch break;
                    written += s.len;
                },
                's' => {
                    const val = @cVaArg(&args, ?[*:0]const u8);
                    if (val) |str| {
                        const len = std.mem.len(str);
                        const copy_len = @min(len, buf.len - written);
                        @memcpy(buf[written..][0..copy_len], str[0..copy_len]);
                        written += copy_len;
                    } else {
                        const null_str = "(null)";
                        @memcpy(buf[written..][0..null_str.len], null_str);
                        written += null_str.len;
                    }
                },
                'c' => {
                    const val = @cVaArg(&args, c_int);
                    if (written < buf.len) {
                        buf[written] = @truncate(@as(c_uint, @bitCast(val)));
                        written += 1;
                    }
                },
                'f', 'F', 'e', 'E', 'g', 'G' => {
                    const val = @cVaArg(&args, f64);
                    const s = std.fmt.bufPrint(buf[written..], "{d:.6}", .{val}) catch break;
                    written += s.len;
                },
                '%' => {
                    if (written < buf.len) {
                        buf[written] = '%';
                        written += 1;
                    }
                },
                else => {
                    if (written < buf.len) {
                        buf[written] = spec;
                        written += 1;
                    }
                },
            }
        } else {
            buf[written] = fmt_ptr[0];
            written += 1;
            fmt_ptr += 1;
        }
    }

    const d = dest.?;
    const copy_len = @min(written, size - 1);
    @memcpy(d[0..copy_len], buf[0..copy_len]);
    d[copy_len] = 0;

    return @intCast(written);
}
