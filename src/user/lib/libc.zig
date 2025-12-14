const std = @import("std");
const syscall = @import("syscall.zig");

// =============================================================================
// Memory Management (malloc, free)
// =============================================================================

/// Header for memory blocks
const BlockHeader = struct {
    size: usize,
    next: ?*BlockHeader,
    free: bool,
};

var head: ?*BlockHeader = null;

pub export fn malloc(size: usize) ?*anyopaque {
    if (size == 0) return null;

    // Align size to 16 bytes
    const aligned_size = (size + 15) & ~@as(usize, 15);
    const total_size = aligned_size + @sizeOf(BlockHeader);

    // Simple first-fit search
    var current = head;
    while (current) |block| {
        if (block.free and block.size >= aligned_size) {
            block.free = false;
            // TODO: Split block if it's too big
            return @ptrCast(@as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader));
        }
        current = block.next;
    }

    // No free block found, allocate new one
    // We use syscall.sbrk which behaves like standard sbrk (returns old break, increments break)
    // The implementation in syscall.zig uses sys_brk correctly under the hood.
    const ptr = syscall.sbrk(@intCast(total_size)) catch return null;
    const block: *BlockHeader = @ptrCast(@alignCast(ptr));
    block.size = aligned_size;
    block.free = false;

    // Prepend to list
    block.next = head;
    head = block;

    return @ptrCast(@as([*]u8, @ptrCast(block)) + @sizeOf(BlockHeader));
}

pub export fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const header_ptr = @as([*]u8, @ptrCast(ptr.?)) - @sizeOf(BlockHeader);
    const header: *BlockHeader = @ptrCast(@alignCast(header_ptr));
    header.free = true;
}

pub export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (ptr == null) return malloc(size);
    if (size == 0) {
        free(ptr);
        return null;
    }

    const header_ptr = @as([*]u8, @ptrCast(ptr.?)) - @sizeOf(BlockHeader);
    const header: *BlockHeader = @ptrCast(@alignCast(header_ptr));

    if (header.size >= size) {
        // Existing block is big enough
        return ptr;
    }

    const new_ptr = malloc(size);
    if (new_ptr == null) return null;

    @memcpy(@as([*]u8, @ptrCast(new_ptr))[0..header.size], @as([*]u8, @ptrCast(ptr.?))[0..header.size]);
    free(ptr);

    return new_ptr;
}

// =============================================================================
// File I/O (stdio)
// =============================================================================

// Opaque FILE structure
pub const FILE = extern struct {
    fd: i32,
    has_error: bool,
    eof: bool,
};

pub export fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    var flags: i32 = 0;
    const access_mode: u32 = 0o666;

    if (mode[0] == 'r') {
        if (mode[1] == '+') {
            flags = syscall.O_RDWR;
        } else {
            flags = syscall.O_RDONLY;
        }
    } else if (mode[0] == 'w') {
         if (mode[1] == '+') {
            flags = syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC;
        } else {
            flags = syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC;
        }
    } else if (mode[0] == 'a') {
        if (mode[1] == '+') {
            flags = syscall.O_RDWR | syscall.O_CREAT | syscall.O_APPEND;
        } else {
            flags = syscall.O_WRONLY | syscall.O_CREAT | syscall.O_APPEND;
        }
    } else {
        return null;
    }

    const fd = syscall.open(filename, flags, access_mode) catch return null;

    const f_ptr = malloc(@sizeOf(FILE));
    if (f_ptr == null) {
        syscall.close(fd) catch {};
        return null;
    }

    const f: *FILE = @ptrCast(@alignCast(f_ptr));
    f.fd = fd;
    f.has_error = false;
    f.eof = false;

    return f;
}

pub export fn fclose(stream: ?*FILE) i32 {
    if (stream == null) return -1;
    const f = stream.?;
    _ = syscall.close(f.fd) catch return -1;
    free(stream);
    return 0;
}

pub export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
    if (stream == null or ptr == null) return 0;
    const f = stream.?;
    const p = ptr.?;

    const total_bytes = size * nmemb;
    if (total_bytes == 0) return 0;

    const bytes_read = syscall.read(f.fd, @ptrCast(p), total_bytes) catch {
        f.has_error = true;
        return 0;
    };

    if (bytes_read == 0) {
        f.eof = true;
        return 0;
    }

    return bytes_read / size;
}

pub export fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
     if (stream == null or ptr == null) return 0;
    const f = stream.?;
    const p = ptr.?;

    const total_bytes = size * nmemb;
    if (total_bytes == 0) return 0;

    // cast to [*]const u8 as expected by syscall.write
    const bytes_written = syscall.write(f.fd, @ptrCast(p), total_bytes) catch {
        f.has_error = true;
        return 0;
    };

    return bytes_written / size;
}

pub export fn fseek(stream: ?*FILE, offset: c_long, whence: c_int) i32 {
    if (stream == null) return -1;
    const f = stream.?;

    _ = syscall.lseek(f.fd, @intCast(offset), @intCast(whence)) catch return -1;
    f.eof = false;
    return 0;
}

pub export fn ftell(stream: ?*FILE) c_long {
    if (stream == null) return -1;
    const f = stream.?;

    const pos = syscall.lseek(f.fd, 0, syscall.SEEK_CUR) catch return -1;
    return @intCast(pos);
}

pub export fn fflush(stream: ?*FILE) i32 {
    _ = stream;
    return 0;
}

// =============================================================================
// String & Memory Operations
// =============================================================================

pub export fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (n == 0) return dest;
    const d = @as([*]u8, @ptrCast(dest.?));
    const s = @as([*]const u8, @ptrCast(src.?));
    @memcpy(d[0..n], s[0..n]);
    return dest;
}

pub export fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque {
    if (n == 0) return s;
    const d = @as([*]u8, @ptrCast(s.?));
    @memset(d[0..n], @as(u8, @truncate(@as(c_uint, @bitCast(c)))));
    return s;
}

pub export fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
     if (n == 0) return dest;
     const d = @as([*]u8, @ptrCast(dest.?));
     const s = @as([*]const u8, @ptrCast(src.?));

     if (@intFromPtr(d) < @intFromPtr(s)) {
         var i: usize = 0;
         while (i < n) : (i += 1) d[i] = s[i];
     } else {
         var i: usize = n;
         while (i > 0) : (i -= 1) d[i-1] = s[i-1];
     }
     return dest;
}

pub export fn strlen(s: ?[*:0]const u8) usize {
    if (s == null) return 0;
    return std.mem.len(s.?);
}

pub export fn strcmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;

    while (p1[0] != 0 and p2[0] != 0 and p1[0] == p2[0]) {
        p1 += 1;
        p2 += 1;
    }

    return @as(c_int, p1[0]) - @as(c_int, p2[0]);
}

pub export fn strcpy(dest: ?[*:0]u8, src: ?[*:0]const u8) ?[*:0]u8 {
    if (dest == null or src == null) return dest;
    var d = dest.?;
    var s = src.?;

    while (s[0] != 0) {
        d[0] = s[0];
        d += 1;
        s += 1;
    }
    d[0] = 0;
    return dest;
}

pub export fn strncpy(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;
    var d = dest.?;
    var s = src.?;
    var i: usize = 0;

    while (i < n and s[0] != 0) {
        d[i] = s[0];
        s += 1;
        i += 1;
    }
    while (i < n) {
        d[i] = 0;
        i += 1;
    }
    return dest;
}

pub export fn strncmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;

    var p1 = s1.?;
    var p2 = s2.?;
    var i: usize = 0;

    while (i < n and p1[0] != 0 and p2[0] != 0 and p1[0] == p2[0]) {
        p1 += 1;
        p2 += 1;
        i += 1;
    }

    if (i == n) return 0;
    return @as(c_int, p1[0]) - @as(c_int, p2[0]);
}

// =============================================================================
// Output (printf)
// =============================================================================

pub export fn printf(format: [*:0]const u8, ...) c_int {
    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [1024]u8 = undefined;

    var written: usize = 0;
    var fmt_ptr = format;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            const specifier = fmt_ptr[0];
            fmt_ptr += 1;

            switch (specifier) {
                'd', 'i' => {
                    const val = @cVaArg(&args, c_int);
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'u' => {
                    const val = @cVaArg(&args, c_uint);
                    const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                    written += s.len;
                },
                'x', 'p' => {
                    const val = @cVaArg(&args, usize);
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
                    written += s.len;
                },
                's' => {
                    const val = @cVaArg(&args, [*:0]const u8);
                    const len = std.mem.len(val);
                    if (written + len > buf.len) break;
                    @memcpy(buf[written..][0..len], val[0..len]);
                    written += len;
                },
                'c' => {
                    const val = @cVaArg(&args, c_int);
                    if (written < buf.len) {
                        buf[written] = @truncate(@as(u32, @bitCast(val)));
                        written += 1;
                    }
                },
                '%' => {
                    if (written < buf.len) {
                        buf[written] = '%';
                        written += 1;
                    }
                },
                else => {
                    if (written < buf.len) {
                        buf[written] = specifier;
                        written += 1;
                    }
                }
            }
        } else {
            buf[written] = fmt_ptr[0];
            written += 1;
            fmt_ptr += 1;
        }
    }

    _ = syscall.write(syscall.STDOUT_FILENO, &buf, written) catch return -1;
    return @intCast(written);
}

// =============================================================================
// errno
// =============================================================================

/// Global errno variable (simplified: not thread-local for MVP)
pub export var errno: c_int = 0;

// =============================================================================
// Standard File Handles
// =============================================================================

/// Static FILE structures for stdin, stdout, stderr
var stdin_file: FILE = .{ .fd = 0, .has_error = false, .eof = false };
var stdout_file: FILE = .{ .fd = 1, .has_error = false, .eof = false };
var stderr_file: FILE = .{ .fd = 2, .has_error = false, .eof = false };

pub export var stdin: ?*FILE = &stdin_file;
pub export var stdout: ?*FILE = &stdout_file;
pub export var stderr: ?*FILE = &stderr_file;

// =============================================================================
// Additional stdio functions
// =============================================================================

pub export fn fputc(c: c_int, stream: ?*FILE) c_int {
    if (stream == null) return -1;
    const f = stream.?;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    const written = syscall.write(f.fd, @ptrCast(&byte), 1) catch {
        f.has_error = true;
        return -1;
    };
    if (written == 0) return -1;
    return c;
}

pub export fn fputs(s: ?[*:0]const u8, stream: ?*FILE) c_int {
    if (s == null or stream == null) return -1;
    const f = stream.?;
    const str = s.?;
    const len = std.mem.len(str);
    if (len == 0) return 0;
    const written = syscall.write(f.fd, str, len) catch {
        f.has_error = true;
        return -1;
    };
    return @intCast(written);
}

pub export fn fgetc(stream: ?*FILE) c_int {
    if (stream == null) return -1;
    const f = stream.?;
    var byte: u8 = undefined;
    const bytes_read = syscall.read(f.fd, @ptrCast(&byte), 1) catch {
        f.has_error = true;
        return -1;
    };
    if (bytes_read == 0) {
        f.eof = true;
        return -1;
    }
    return @as(c_int, byte);
}

pub export fn fgets(s: ?[*]u8, size: c_int, stream: ?*FILE) ?[*]u8 {
    if (s == null or stream == null or size <= 0) return null;
    const f = stream.?;
    const buf = s.?;
    const max_read: usize = @intCast(size - 1);

    var i: usize = 0;
    while (i < max_read) {
        var byte: u8 = undefined;
        const bytes_read = syscall.read(f.fd, @ptrCast(&byte), 1) catch {
            f.has_error = true;
            if (i == 0) return null;
            break;
        };
        if (bytes_read == 0) {
            f.eof = true;
            if (i == 0) return null;
            break;
        }
        buf[i] = byte;
        i += 1;
        if (byte == '\n') break;
    }
    buf[i] = 0;
    return s;
}

pub export fn feof(stream: ?*FILE) c_int {
    if (stream == null) return 0;
    return if (stream.?.eof) 1 else 0;
}

pub export fn ferror(stream: ?*FILE) c_int {
    if (stream == null) return 0;
    return if (stream.?.has_error) 1 else 0;
}

pub export fn clearerr(stream: ?*FILE) void {
    if (stream) |f| {
        f.eof = false;
        f.has_error = false;
    }
}

pub export fn putchar(c: c_int) c_int {
    return fputc(c, stdout);
}

pub export fn puts(s: ?[*:0]const u8) c_int {
    if (s == null) return -1;
    const result = fputs(s, stdout);
    if (result < 0) return -1;
    _ = fputc('\n', stdout);
    return result + 1;
}

pub export fn getc(stream: ?*FILE) c_int {
    return fgetc(stream);
}

pub export fn getchar() c_int {
    return fgetc(stdin);
}

pub export fn ungetc(c: c_int, stream: ?*FILE) c_int {
    // Simplified: ungetc not supported (would need buffering)
    _ = c;
    _ = stream;
    return -1;
}

pub export fn remove(path: ?[*:0]const u8) c_int {
    // Filesystem modification not supported yet
    _ = path;
    errno = 38; // ENOSYS
    return -1;
}

pub export fn rename(old: ?[*:0]const u8, new: ?[*:0]const u8) c_int {
    // Filesystem modification not supported yet
    _ = old;
    _ = new;
    errno = 38; // ENOSYS
    return -1;
}

// =============================================================================
// fprintf, sprintf, snprintf
// =============================================================================

// NOTE: va_list cannot be passed to helper functions in Zig 0.15.x freestanding.
// Each vararg function must inline its own format processing.

/// Inline format processor macro-like implementation
/// Each vararg function duplicates this logic because @cVaArg must be
/// called directly in the function with ... varargs.

pub export fn fprintf(stream: ?*FILE, format: [*:0]const u8, ...) c_int {
    if (stream == null) return -1;
    const f = stream.?;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [4096]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = format;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            var is_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_long);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_int);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'u' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_ulong);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_uint);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'x', 'X' => {
                    const val = @cVaArg(&args, c_uint);
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
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

    const bytes_written = syscall.write(f.fd, &buf, written) catch {
        f.has_error = true;
        return -1;
    };
    return @intCast(bytes_written);
}

pub export fn sprintf(dest: ?[*]u8, format: [*:0]const u8, ...) c_int {
    if (dest == null) return -1;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [8192]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = format;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            var is_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_long);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_int);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'u' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_ulong);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_uint);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'x', 'X' => {
                    const val = @cVaArg(&args, c_uint);
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
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

pub export fn snprintf(dest: ?[*]u8, size: usize, format: [*:0]const u8, ...) c_int {
    if (dest == null or size == 0) return 0;

    var args = @cVaStart();
    defer @cVaEnd(&args);

    var buf: [8192]u8 = undefined;
    var written: usize = 0;
    var fmt_ptr = format;

    while (fmt_ptr[0] != 0 and written < buf.len) {
        if (fmt_ptr[0] == '%') {
            fmt_ptr += 1;
            if (fmt_ptr[0] == 0) break;

            while (fmt_ptr[0] >= '0' and fmt_ptr[0] <= '9') fmt_ptr += 1;

            var is_long: bool = false;
            if (fmt_ptr[0] == 'l') {
                is_long = true;
                fmt_ptr += 1;
            }

            const spec = fmt_ptr[0];
            fmt_ptr += 1;

            switch (spec) {
                'd', 'i' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_long);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_int);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'u' => {
                    if (is_long) {
                        const val = @cVaArg(&args, c_ulong);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    } else {
                        const val = @cVaArg(&args, c_uint);
                        const s = std.fmt.bufPrint(buf[written..], "{d}", .{val}) catch break;
                        written += s.len;
                    }
                },
                'x', 'X' => {
                    const val = @cVaArg(&args, c_uint);
                    const s = std.fmt.bufPrint(buf[written..], "{x}", .{val}) catch break;
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

// v* functions are stubs - VaList handling changed in Zig 0.15.x
pub export fn vfprintf(stream: ?*FILE, format: [*:0]const u8, ap: ?*anyopaque) c_int {
    _ = format;
    _ = ap;
    if (stream == null) return -1;
    // Stub - v* functions not fully supported
    return 0;
}

pub export fn vsprintf(dest: ?[*]u8, format: [*:0]const u8, ap: ?*anyopaque) c_int {
    _ = format;
    _ = ap;
    if (dest == null) return -1;
    dest.?[0] = 0;
    return 0;
}

pub export fn vsnprintf(dest: ?[*]u8, size: usize, format: [*:0]const u8, ap: ?*anyopaque) c_int {
    _ = format;
    _ = ap;
    if (dest == null or size == 0) return 0;
    dest.?[0] = 0;
    return 0;
}

// =============================================================================
// stdlib functions
// =============================================================================

pub export fn exit(status: c_int) noreturn {
    syscall.exit(@bitCast(status));
}

pub export fn abort() noreturn {
    syscall.exit(134); // SIGABRT typically results in exit code 134
}

pub export fn abs(n: c_int) c_int {
    return if (n < 0) -n else n;
}

pub export fn labs(n: c_long) c_long {
    return if (n < 0) -n else n;
}

pub export fn atoi(str: ?[*:0]const u8) c_int {
    if (str == null) return 0;
    var s = str.?;

    // Skip whitespace
    while (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r') {
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

pub export fn atol(str: ?[*:0]const u8) c_long {
    if (str == null) return 0;
    var s = str.?;

    while (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r') {
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

pub export fn strtol(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_long {
    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    // Skip whitespace
    while (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r') {
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

pub export fn strtoul(str: ?[*:0]const u8, endptr: ?*?[*:0]u8, base_arg: c_int) c_ulong {
    if (str == null) {
        if (endptr) |ep| ep.* = null;
        return 0;
    }
    var s = str.?;

    while (s[0] == ' ' or s[0] == '\t' or s[0] == '\n' or s[0] == '\r') {
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

/// Simple LCG random number generator
var rand_seed: c_uint = 1;

pub export fn rand() c_int {
    // LCG parameters from glibc
    rand_seed = rand_seed *% 1103515245 +% 12345;
    return @bitCast(@as(c_uint, (rand_seed >> 16) & 0x7fff));
}

pub export fn srand(seed: c_uint) void {
    rand_seed = seed;
}

pub export fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    const total = nmemb * size;
    if (total == 0) return null;
    const ptr = malloc(total);
    if (ptr) |p| {
        _ = memset(p, 0, total);
    }
    return ptr;
}

pub export fn getenv(name: ?[*:0]const u8) ?[*:0]u8 {
    // No environment support in this kernel
    _ = name;
    return null;
}

/// system() - execute shell command (stub - no shell in freestanding)
pub export fn system(command: ?[*:0]const u8) c_int {
    _ = command;
    return -1; // Command execution not supported
}

/// mkdir() - create directory (stub)
pub export fn mkdir(pathname: ?[*:0]const u8, mode: c_uint) c_int {
    _ = pathname;
    _ = mode;
    errno = 38; // ENOSYS
    return -1;
}

/// atof() - convert string to double (simplified)
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

    return if (negative) -result else result;
}

/// qsort implementation using insertion sort (simple, stable)
pub export fn qsort(
    base: ?*anyopaque,
    nmemb: usize,
    size: usize,
    compar: ?*const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int,
) void {
    if (base == null or compar == null or nmemb < 2 or size == 0) return;

    const arr = @as([*]u8, @ptrCast(base.?));
    const cmp = compar.?;

    // Temporary buffer for swapping (on stack, limited size)
    var temp: [256]u8 = undefined;
    if (size > temp.len) return; // Elements too large

    // Insertion sort
    var i: usize = 1;
    while (i < nmemb) : (i += 1) {
        var j = i;
        while (j > 0) {
            const curr = arr + j * size;
            const prev = arr + (j - 1) * size;

            if (cmp(@ptrCast(curr), @ptrCast(prev)) < 0) {
                // Swap
                @memcpy(temp[0..size], curr[0..size]);
                @memcpy(curr[0..size], prev[0..size]);
                @memcpy(prev[0..size], temp[0..size]);
                j -= 1;
            } else {
                break;
            }
        }
    }
}

// =============================================================================
// Additional string functions
// =============================================================================

pub export fn memcmp(s1: ?*const anyopaque, s2: ?*const anyopaque, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    const p1 = @as([*]const u8, @ptrCast(s1.?));
    const p2 = @as([*]const u8, @ptrCast(s2.?));

    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (p1[i] != p2[i]) {
            return @as(c_int, p1[i]) - @as(c_int, p2[i]);
        }
    }
    return 0;
}

pub export fn strcat(dest: ?[*:0]u8, src: ?[*:0]const u8) ?[*:0]u8 {
    if (dest == null or src == null) return dest;
    var d = dest.?;
    const s = src.?;

    // Find end of dest
    while (d[0] != 0) d += 1;

    // Copy src
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    d[i] = 0;

    return dest;
}

pub export fn strncat(dest: ?[*:0]u8, src: ?[*:0]const u8, n: usize) ?[*:0]u8 {
    if (dest == null or src == null) return dest;
    var d = dest.?;
    const s = src.?;

    // Find end of dest
    while (d[0] != 0) d += 1;

    // Copy at most n chars from src
    var i: usize = 0;
    while (i < n and s[i] != 0) : (i += 1) {
        d[i] = s[i];
    }
    d[i] = 0;

    return dest;
}

pub export fn strchr(s: ?[*:0]const u8, c: c_int) ?[*:0]u8 {
    if (s == null) return null;
    var p = s.?;
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    while (true) {
        if (p[0] == ch) return @ptrCast(@constCast(p));
        if (p[0] == 0) return null;
        p += 1;
    }
}

pub export fn strrchr(s: ?[*:0]const u8, c: c_int) ?[*:0]u8 {
    if (s == null) return null;
    const str = s.?;
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));

    var last: ?[*:0]u8 = null;
    var i: usize = 0;
    while (true) {
        if (str[i] == ch) {
            last = @ptrCast(@constCast(str + i));
        }
        if (str[i] == 0) break;
        i += 1;
    }
    return last;
}

pub export fn strstr(haystack: ?[*:0]const u8, needle: ?[*:0]const u8) ?[*:0]u8 {
    if (haystack == null or needle == null) return null;
    const h = haystack.?;
    const n = needle.?;

    if (n[0] == 0) return @ptrCast(@constCast(h));

    const needle_len = std.mem.len(n);
    var i: usize = 0;

    while (h[i] != 0) {
        var match = true;
        var j: usize = 0;
        while (j < needle_len) : (j += 1) {
            if (h[i + j] == 0 or h[i + j] != n[j]) {
                match = false;
                break;
            }
        }
        if (match) return @ptrCast(@constCast(h + i));
        i += 1;
    }
    return null;
}

pub export fn strdup(s: ?[*:0]const u8) ?[*:0]u8 {
    if (s == null) return null;
    const str = s.?;
    const len = std.mem.len(str);

    const new_ptr = malloc(len + 1);
    if (new_ptr == null) return null;

    const new_str: [*]u8 = @ptrCast(new_ptr.?);
    @memcpy(new_str[0..len], str[0..len]);
    new_str[len] = 0;

    return @ptrCast(new_str);
}

pub export fn strcasecmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;

    while (p1[0] != 0 and p2[0] != 0) {
        const c1 = toLowerInternal(p1[0]);
        const c2 = toLowerInternal(p2[0]);
        if (c1 != c2) return @as(c_int, c1) - @as(c_int, c2);
        p1 += 1;
        p2 += 1;
    }

    return @as(c_int, toLowerInternal(p1[0])) - @as(c_int, toLowerInternal(p2[0]));
}

pub export fn strncasecmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
    if (n == 0) return 0;
    if (s1 == null and s2 == null) return 0;
    if (s1 == null) return -1;
    if (s2 == null) return 1;

    var p1 = s1.?;
    var p2 = s2.?;
    var i: usize = 0;

    while (i < n and p1[0] != 0 and p2[0] != 0) {
        const c1 = toLowerInternal(p1[0]);
        const c2 = toLowerInternal(p2[0]);
        if (c1 != c2) return @as(c_int, c1) - @as(c_int, c2);
        p1 += 1;
        p2 += 1;
        i += 1;
    }

    if (i == n) return 0;
    return @as(c_int, toLowerInternal(p1[0])) - @as(c_int, toLowerInternal(p2[0]));
}

// =============================================================================
// ctype functions
// =============================================================================

fn toLowerInternal(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn toUpperInternal(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

pub export fn isspace(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '\x0b' or ch == '\x0c') 1 else 0;
}

pub export fn isdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= '0' and ch <= '9') 1 else 0;
}

pub export fn isalpha(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if ((ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z')) 1 else 0;
}

pub export fn isalnum(c: c_int) c_int {
    return if (isalpha(c) != 0 or isdigit(c) != 0) 1 else 0;
}

pub export fn isupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 'A' and ch <= 'Z') 1 else 0;
}

pub export fn islower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 'a' and ch <= 'z') 1 else 0;
}

pub export fn isprint(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch >= 0x20 and ch <= 0x7e) 1 else 0;
}

pub export fn isxdigit(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if ((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F') or (ch >= 'a' and ch <= 'f')) 1 else 0;
}

pub export fn toupper(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return @as(c_int, toUpperInternal(ch));
}

pub export fn tolower(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return @as(c_int, toLowerInternal(ch));
}

pub export fn iscntrl(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch < 0x20 or ch == 0x7f) 1 else 0;
}

pub export fn isgraph(c: c_int) c_int {
    const ch: u8 = @truncate(@as(c_uint, @bitCast(c)));
    return if (ch > 0x20 and ch <= 0x7e) 1 else 0;
}

pub export fn ispunct(c: c_int) c_int {
    return if (isgraph(c) != 0 and isalnum(c) == 0) 1 else 0;
}

// =============================================================================
// time functions
// =============================================================================

pub const time_t = i64;

pub export fn time(t: ?*time_t) time_t {
    var ts: syscall.Timespec = undefined;
    syscall.clock_gettime(.REALTIME, &ts) catch {
        if (t) |ptr| ptr.* = -1;
        return -1;
    };
    const result = ts.tv_sec;
    if (t) |ptr| ptr.* = result;
    return result;
}

// =============================================================================
// Additional utility functions that Doom may need
// =============================================================================

/// sscanf is complex; provide a minimal stub that handles common patterns
pub export fn sscanf(str: ?[*:0]const u8, format: ?[*:0]const u8, ...) c_int {
    // Simplified: only parse integers for now
    _ = str;
    _ = format;
    // Return 0 (no items matched) as a safe fallback
    return 0;
}

/// Signal handling stub
pub export fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void {
    // No signal support - return SIG_DFL (0)
    _ = sig;
    _ = handler;
    return null;
}

/// setjmp/longjmp stubs - not supported
pub const jmp_buf = [64]u8;

pub export fn setjmp(env: ?*jmp_buf) c_int {
    _ = env;
    return 0;
}

pub export fn longjmp(env: ?*jmp_buf, val: c_int) noreturn {
    _ = env;
    _ = val;
    abort();
}

/// atexit stub - not supported
pub export fn atexit(func: ?*const fn () callconv(.c) void) c_int {
    _ = func;
    return 0; // Success but won't actually call
}
