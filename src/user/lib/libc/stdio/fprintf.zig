// fprintf, sprintf, snprintf implementations (stdio.h)
//
// Formatted output to files and strings.

const std = @import("std");
const syscall = @import("syscall");
const file_mod = @import("file.zig");
const internal = @import("../internal.zig");

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

            // Flags
            var left_align = false;
            var plus_sign = false;
            var space_sign = false;
            var alt_form = false;
            var zero_pad = false;

            while (true) switch (fmt_ptr[0]) {
                '-' => { left_align = true; fmt_ptr += 1; },
                '+' => { plus_sign = true; fmt_ptr += 1; },
                ' ' => { space_sign = true; fmt_ptr += 1; },
                '#' => { alt_form = true; fmt_ptr += 1; },
                '0' => { zero_pad = true; fmt_ptr += 1; },
                else => break,
            };

            // Width
            var width: usize = 0;
            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') {
                width = width * 10 + (fmt_ptr[0] - '0');
                fmt_ptr += 1;
            }

            // Precision
            var precision: usize = 0;
            var has_precision = false;
            if (fmt_ptr[0] == '.') {
                has_precision = true;
                fmt_ptr += 1;
                while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') {
                    precision = precision * 10 + (fmt_ptr[0] - '0');
                    fmt_ptr += 1;
                }
            }

            // Length modifiers
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
                'd', 'i', 'u', 'x', 'X', 'o' => {
                    var num_buf: [64]u8 = undefined;
                    var num_len: usize = 0;
                    var sign_char: ?u8 = null;
                    var prefix: []const u8 = "";

                    // Fetch value and format to temporary buffer
                    if (spec == 'd' or spec == 'i') {
                        const val: i64 = if (is_long_long)
                            @cVaArg(&args, c_longlong)
                        else if (is_long)
                            @as(i64, @cVaArg(&args, c_long))
                        else
                            @as(i64, @cVaArg(&args, c_int));

                        if (val < 0) {
                            sign_char = '-';
                            const uval = @as(u64, @intCast(-val));
                            const s = std.fmt.bufPrint(&num_buf, "{d}", .{uval}) catch break;
                            num_len = s.len;
                        } else {
                            if (plus_sign) sign_char = '+'
                            else if (space_sign) sign_char = ' ';
                            const s = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch break;
                            num_len = s.len;
                        }
                    } else {
                        const val: u64 = if (is_long_long)
                            @cVaArg(&args, c_ulonglong)
                        else if (is_long)
                            @as(u64, @cVaArg(&args, c_ulong))
                        else
                            @as(u64, @cVaArg(&args, c_uint));
                        
                        // Alternate form handling
                        if (alt_form and val != 0) {
                            if (spec == 'o') prefix = "0"
                            else if (spec == 'x') prefix = "0x"
                            else if (spec == 'X') prefix = "0X";
                        }

                        const s = switch (spec) {
                            'o' => std.fmt.bufPrint(&num_buf, "{o}", .{val}),
                            'x' => std.fmt.bufPrint(&num_buf, "{x}", .{val}),
                            'X' => std.fmt.bufPrint(&num_buf, "{X}", .{val}),
                            else => std.fmt.bufPrint(&num_buf, "{d}", .{val}),
                        } catch break;
                        num_len = s.len;
                    }

                    // Calculate padding
                    // Precision overrides zero flag for integers
                    if (has_precision) zero_pad = false;
                    
                    const digits_len = num_len;
                    var zeros_needed: usize = 0;
                    
                    if (has_precision and precision > digits_len) {
                        zeros_needed = precision - digits_len;
                    } else if (!has_precision and zero_pad and !left_align) {
                         // Zero padding via width (only if no precision and not left align)
                         // This is tricky: width includes sign and prefix. 
                         // We calculate spaces first, then check if we should turn them to zeros
                    }

                    const sign_len: usize = if (sign_char != null) 1 else 0;
                    const content_len = sign_len + prefix.len + zeros_needed + digits_len;
                    var padding_spaces: usize = 0;
                    
                    if (width > content_len) {
                        padding_spaces = width - content_len;
                    }

                    // Zero padding from width flag (special case: 0 flag means pad with 0s instead of spaces)
                    // But if precision is given, 0 flag is ignored.
                    if (zero_pad and !left_align and !has_precision) {
                        zeros_needed += padding_spaces;
                        padding_spaces = 0;
                    }

                    // Emit output
                    if (!left_align) {
                        var i: usize = 0;
                        while (i < padding_spaces and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }

                    if (sign_char) |c| {
                        if (written < buf.len) { buf[written] = c; written += 1; }
                    }
                    if (prefix.len > 0) {
                        const copy_len = @min(prefix.len, buf.len - written);
                        internal.safeCopy(buf[written..].ptr, prefix.ptr, copy_len);
                        written += copy_len;
                    }
                    
                    var i: usize = 0;
                    while (i < zeros_needed and written < buf.len) : (i += 1) { buf[written] = '0'; written += 1; }

                    if (num_len > 0) {
                        const copy_len = @min(num_len, buf.len - written);
                        internal.safeCopy(buf[written..].ptr, &num_buf, copy_len);
                        written += copy_len;
                    }

                    if (left_align) {
                        i = 0;
                        while (i < padding_spaces and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }
                },
                'p' => {
                    const val = @cVaArg(&args, usize);
                    var num_buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&num_buf, "0x{x}", .{val}) catch break;
                    
                    var padding: usize = 0;
                    if (width > s.len) padding = width - s.len;

                    if (!left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }
                    
                    const copy_len = @min(s.len, buf.len - written);
                    internal.safeCopy(buf[written..].ptr, &num_buf, copy_len);
                    written += copy_len;

                    if (left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }
                },
                's' => {
                    const val = @cVaArg(&args, ?[*:0]const u8);
                    const safe_str = val orelse "(null)";
                    var len = std.mem.len(safe_str);
                    
                    if (has_precision and len > precision) {
                        len = precision;
                    }

                    var padding: usize = 0;
                    if (width > len) padding = width - len;

                    if (!left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }

                    const copy_len = @min(len, buf.len - written);
                    internal.safeCopy(buf[written..].ptr, safe_str, copy_len);
                    written += copy_len;

                    if (left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }
                },
                'c' => {
                    const val = @cVaArg(&args, c_int);
                    var padding: usize = 0;
                    if (width > 1) padding = width - 1;

                    if (!left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }

                    if (written < buf.len) {
                        buf[written] = @truncate(@as(c_uint, @bitCast(val)));
                        written += 1;
                    }

                     if (left_align) {
                        var i: usize = 0;
                        while (i < padding and written < buf.len) : (i += 1) { buf[written] = ' '; written += 1; }
                    }
                },
                'f', 'F', 'e', 'E', 'g', 'G' => {
                    // Minimal float support (no complex width/prec for now, just basic)
                    const val = @cVaArg(&args, f64);
                    // Use a reasonable default buffer size for float
                     var fbuf: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&fbuf, "{d:.6}", .{val}) catch break;
                    
                    if (written + s.len <= buf.len) {
                        internal.safeCopy(buf[written..].ptr, &fbuf, s.len);
                        written += s.len;
                    }
                },
                '%' => {
                    if (written < buf.len) {
                        buf[written] = '%';
                        written += 1;
                    }
                },
                'n' => {
                    // SECURITY: %n is disabled - allows arbitrary memory write
                    // Consume the argument but do nothing with it
                    _ = @cVaArg(&args, ?*c_int);
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

/// Format into string buffer
/// SECURITY WARNING: sprintf() is inherently unsafe - it cannot know
/// the destination buffer size. This implementation limits output to
/// 1024 bytes as a safety mitigation, but callers MUST ensure their
/// buffer is at least 1024 bytes or use snprintf() instead.
/// RECOMMENDED: Use snprintf() with explicit size parameter.
pub export fn sprintf(dest: ?[*]u8, fmt_str: [*:0]const u8, ...) c_int {
    if (dest == null) return -1;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    // SECURITY: Limit internal buffer to 1024 bytes as a safety measure.
    // This reduces damage from legacy code but is still inherently unsafe.
    // New code should ALWAYS use snprintf() with explicit size.
    var buf: [1024]u8 = undefined;
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
                        internal.safeCopy(buf[written..].ptr, str, copy_len);
                        written += copy_len;
                    } else {
                        const null_str = "(null)";
                        internal.safeCopy(buf[written..].ptr, null_str.ptr, null_str.len);
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
    internal.safeCopy(d, &buf, written);
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

            // Parse precision
            var precision: usize = 0;
            var has_precision = false;
            if (fmt_ptr[0] == '.') {
                has_precision = true;
                fmt_ptr += 1;
                while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') {
                    precision = precision * 10 + (fmt_ptr[0] - '0');
                    fmt_ptr += 1;
                }
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
                    // Apply precision (minimum digits with leading zeros)
                    if (has_precision and precision > 0) {
                        if (val < 0) {
                            if (written < buf.len) {
                                buf[written] = '-';
                                written += 1;
                            }
                            const abs_val: u64 = @intCast(-val);
                            const s = std.fmt.bufPrint(buf[written..], "{d:0>[1]}", .{ abs_val, precision }) catch break;
                            written += s.len;
                        } else {
                            const uval: u64 = @intCast(val);
                            const s = std.fmt.bufPrint(buf[written..], "{d:0>[1]}", .{ uval, precision }) catch break;
                            written += s.len;
                        }
                    } else {
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'u' => {
                    const val: u64 = if (is_long_long)
                        @cVaArg(&args, c_ulonglong)
                    else if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    if (has_precision and precision > 0) {
                        const s = std.fmt.bufPrint(buf[written..], "{d:0>[1]}", .{ val, precision }) catch break;
                        written += s.len;
                    } else {
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'x' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    if (has_precision and precision > 0) {
                        const s = std.fmt.bufPrint(buf[written..], "{x:0>[1]}", .{ val, precision }) catch break;
                        written += s.len;
                    } else {
                        const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'X' => {
                    const val: u64 = if (is_long)
                        @as(u64, @cVaArg(&args, c_ulong))
                    else
                        @as(u64, @cVaArg(&args, c_uint));
                    if (has_precision and precision > 0) {
                        const s = std.fmt.bufPrint(buf[written..], "{X:0>[1]}", .{ val, precision }) catch break;
                        written += s.len;
                    } else {
                        const s = std.fmt.bufPrint(buf[written..], "{X}", .{val}) catch break;
                        written += s.len;
                    }
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
                        internal.safeCopy(buf[written..].ptr, str, copy_len);
                        written += copy_len;
                    } else {
                        const null_str = "(null)";
                        internal.safeCopy(buf[written..].ptr, null_str.ptr, null_str.len);
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
    internal.safeCopy(d, &buf, copy_len);
    d[copy_len] = 0;

    return @intCast(written);
}
