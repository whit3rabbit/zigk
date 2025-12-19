// Stream I/O functions (stdio.h)
//
// Character and line I/O functions, plus standard streams.

const std = @import("std");
const syscall = @import("syscall.zig");
const file = @import("file.zig");
const errno_mod = @import("../errno.zig");

const FILE = file.FILE;
const EOF = file.EOF;

// =============================================================================
// Standard Streams
// =============================================================================

/// Static FILE structures for stdin, stdout, stderr
var stdin_file: FILE = .{ .fd = 0, .has_error = false, .eof = false, .unget_char = -1, .is_static = true };
var stdout_file: FILE = .{ .fd = 1, .has_error = false, .eof = false, .unget_char = -1, .is_static = true };
var stderr_file: FILE = .{ .fd = 2, .has_error = false, .eof = false, .unget_char = -1, .is_static = true };

pub export var stdin: ?*FILE = &stdin_file;
pub export var stdout: ?*FILE = &stdout_file;
pub export var stderr: ?*FILE = &stderr_file;

// =============================================================================
// Character I/O
// =============================================================================

/// Write character to stream
pub export fn fputc(c: c_int, stream: ?*FILE) c_int {
    if (stream == null) return EOF;
    const f = stream.?;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    const written = syscall.write(f.fd, @ptrCast(&byte), 1) catch {
        f.has_error = true;
        return EOF;
    };
    if (written == 0) return EOF;
    return c;
}

/// Write character to stdout
pub export fn putchar(c: c_int) c_int {
    return fputc(c, stdout);
}

/// Alias for fputc
pub export fn putc(c: c_int, stream: ?*FILE) c_int {
    return fputc(c, stream);
}

/// Read character from stream
pub export fn fgetc(stream: ?*FILE) c_int {
    if (stream == null) return EOF;
    const f = stream.?;

    // Check for pushed-back character
    if (f.unget_char >= 0) {
        const c = f.unget_char;
        f.unget_char = -1;
        return c;
    }

    var byte: u8 = undefined;
    const bytes_read = syscall.read(f.fd, @ptrCast(&byte), 1) catch {
        f.has_error = true;
        return EOF;
    };
    if (bytes_read == 0) {
        f.eof = true;
        return EOF;
    }
    return @as(c_int, byte);
}

/// Read character from stdin
pub export fn getchar() c_int {
    return fgetc(stdin);
}

/// Alias for fgetc
pub export fn getc(stream: ?*FILE) c_int {
    return fgetc(stream);
}

/// Push character back onto stream
pub export fn ungetc(c: c_int, stream: ?*FILE) c_int {
    if (stream == null or c == EOF) return EOF;
    const f = stream.?;

    // Can only push back one character
    if (f.unget_char >= 0) return EOF;

    f.unget_char = @as(i16, @truncate(c));
    f.eof = false;
    return c;
}

// =============================================================================
// String I/O
// =============================================================================

/// Write string to stream
pub export fn fputs(s: ?[*:0]const u8, stream: ?*FILE) c_int {
    if (s == null or stream == null) return EOF;
    const f = stream.?;
    const str = s.?;
    const len = std.mem.len(str);
    if (len == 0) return 0;
    const written = syscall.write(f.fd, str, len) catch {
        f.has_error = true;
        return EOF;
    };
    return @intCast(written);
}

/// Write string to stdout with newline
pub export fn puts(s: ?[*:0]const u8) c_int {
    if (s == null) return EOF;
    const result = fputs(s, stdout);
    if (result < 0) return EOF;
    _ = fputc('\n', stdout);
    return result + 1;
}

/// Read line from stream
pub export fn fgets(s: ?[*]u8, size: c_int, stream: ?*FILE) ?[*]u8 {
    if (s == null or stream == null or size <= 0) return null;
    const f = stream.?;
    const buf = s.?;
    const max_read: usize = @intCast(size - 1);

    var i: usize = 0;
    while (i < max_read) {
        const c = fgetc(stream);
        if (c == EOF) {
            if (i == 0) return null;
            break;
        }
        buf[i] = @truncate(@as(c_uint, @bitCast(c)));
        i += 1;
        if (c == '\n') break;
    }
    buf[i] = 0;
    _ = f;
    return s;
}

/// Read line from stdin (REMOVED - inherently unsafe)
/// This function was deprecated in C11 and removed in C17 due to
/// buffer overflow vulnerabilities. Always returns null.
/// Use fgets() instead with an explicit buffer size.
pub export fn gets(s: ?[*]u8) ?[*]u8 {
    // SECURITY: gets() cannot be made safe - there is no way to know the
    // destination buffer size. This stub prevents linking errors while
    // refusing to perform the unsafe operation.
    _ = s;
    errno_mod.errno = errno_mod.ENOSYS;
    return null;
}

// =============================================================================
// Status Functions
// =============================================================================

/// Check if end-of-file reached
pub export fn feof(stream: ?*FILE) c_int {
    if (stream == null) return 0;
    return if (stream.?.eof) 1 else 0;
}

/// Check if error occurred
pub export fn ferror(stream: ?*FILE) c_int {
    if (stream == null) return 0;
    return if (stream.?.has_error) 1 else 0;
}

/// Clear error and EOF flags
pub export fn clearerr(stream: ?*FILE) void {
    if (stream) |f| {
        f.eof = false;
        f.has_error = false;
    }
}

// =============================================================================
// File management stubs
// =============================================================================

/// Remove file (stub)
pub export fn remove(path: ?[*:0]const u8) c_int {
    _ = path;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Rename file (stub)
pub export fn rename(old: ?[*:0]const u8, new: ?[*:0]const u8) c_int {
    _ = old;
    _ = new;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Create temporary file (stub)
pub export fn tmpfile() ?*FILE {
    errno_mod.errno = errno_mod.ENOSYS;
    return null;
}

/// Generate temporary filename (stub)
pub export fn tmpnam(s: ?[*]u8) ?[*]u8 {
    _ = s;
    return null;
}

// =============================================================================
// perror implementation
// =============================================================================

/// Print error message to stderr
pub export fn perror(s: ?[*:0]const u8) void {
    const string = @import("../string/root.zig");

    if (s) |prefix| {
        if (prefix[0] != 0) {
            _ = fputs(prefix, stderr);
            _ = fputs(": ", stderr);
        }
    }

    const msg = string.strerror(errno_mod.errno);
    _ = fputs(msg, stderr);
    _ = fputc('\n', stderr);
}
