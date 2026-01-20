// File operations (stdio.h)
//
// FILE structure and basic file I/O functions.

const syscall = @import("syscall");
const memory = @import("../memory/root.zig");
const internal = @import("../internal.zig");
const errno_mod = @import("../errno.zig");

/// Opaque FILE structure
pub const FILE = extern struct {
    fd: i32,
    has_error: bool,
    eof: bool,
    // Buffer for ungetc (simplified - single char)
    unget_char: i16, // -1 if no unget char, otherwise the char
    // Flag for static streams (stdin/stdout/stderr)
    is_static: bool,
};

/// Seek origins
pub const SEEK_SET: c_int = 0;
pub const SEEK_CUR: c_int = 1;
pub const SEEK_END: c_int = 2;

/// EOF indicator
pub const EOF: c_int = -1;

/// Open a file
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

    const fd = syscall.open(filename, flags, access_mode) catch |err| {
        internal.setErrno(err);
        return null;
    };

    const f_ptr = memory.malloc(@sizeOf(FILE));
    if (f_ptr == null) {
        syscall.close(fd) catch {};
        return null;
    }

    const f: *FILE = @ptrCast(@alignCast(f_ptr));
    f.fd = fd;
    f.has_error = false;
    f.eof = false;
    f.unget_char = -1;
    f.is_static = false;

    return f;
}

/// Close a file
pub export fn fclose(stream: ?*FILE) c_int {
    if (stream == null) return EOF;
    const f = stream.?;
    
    // Always flush before closing (though our flush is no-op, good practice)
    _ = fflush(f);
    
    _ = syscall.close(f.fd) catch return EOF;
    
    // Only free if allocated on heap
    if (!f.is_static) {
        memory.free(stream);
    }
    return 0;
}

/// Read from file
pub export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
    if (stream == null or ptr == null) return 0;
    const f = stream.?;
    var dest_ptr = @as([*]u8, @ptrCast(ptr.?));

    // SECURITY: Check for multiplication overflow to prevent reading
    // an unintended small amount due to integer wrap-around.
    var total_bytes = internal.checkedMultiply(size, nmemb) orelse {
        errno_mod.errno = errno_mod.EOVERFLOW;
        return 0;
    };
    var total_read: usize = 0;

    if (total_bytes == 0) return 0;

    while (total_bytes > 0) {
        const bytes_read = syscall.read(f.fd, dest_ptr, total_bytes) catch {
            f.has_error = true;
            break;
        };

        if (bytes_read == 0) {
            f.eof = true;
            break;
        }

        total_read += bytes_read;
        total_bytes -= bytes_read;
        dest_ptr += bytes_read;
    }

    return total_read / size;
}

/// Write to file
pub export fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
    if (stream == null or ptr == null) return 0;
    const f = stream.?;
    const p = ptr.?;

    // SECURITY: Check for multiplication overflow
    const total_bytes = internal.checkedMultiply(size, nmemb) orelse {
        errno_mod.errno = errno_mod.EOVERFLOW;
        return 0;
    };
    if (total_bytes == 0) return 0;

    const bytes_written = syscall.write(f.fd, @ptrCast(p), total_bytes) catch {
        f.has_error = true;
        return 0;
    };

    return bytes_written / size;
}

/// Seek to position in file
pub export fn fseek(stream: ?*FILE, offset: c_long, whence: c_int) c_int {
    if (stream == null) return -1;
    const f = stream.?;

    _ = syscall.lseek(f.fd, @intCast(offset), @intCast(whence)) catch return -1;
    f.eof = false;
    f.unget_char = -1; // Clear unget buffer on seek
    return 0;
}

/// Get current position in file
pub export fn ftell(stream: ?*FILE) c_long {
    if (stream == null) return -1;
    const f = stream.?;

    const pos = syscall.lseek(f.fd, 0, SEEK_CUR) catch return -1;
    return @intCast(pos);
}

/// Rewind to beginning of file
pub export fn rewind(stream: ?*FILE) void {
    if (stream) |f| {
        _ = fseek(stream, 0, SEEK_SET);
        f.has_error = false;
    }
}

/// Flush file buffers (no-op for unbuffered I/O)
pub export fn fflush(stream: ?*FILE) c_int {
    _ = stream;
    // Our implementation is unbuffered
    return 0;
}

/// Get file descriptor from FILE
pub export fn fileno(stream: ?*FILE) c_int {
    if (stream == null) return -1;
    return stream.?.fd;
}

/// Set file position using fpos_t
pub const fpos_t = c_long;

pub export fn fgetpos(stream: ?*FILE, pos: ?*fpos_t) c_int {
    if (stream == null or pos == null) return -1;
    const p = ftell(stream);
    if (p < 0) return -1;
    pos.?.* = p;
    return 0;
}

pub export fn fsetpos(stream: ?*FILE, pos: ?*const fpos_t) c_int {
    if (stream == null or pos == null) return -1;
    return fseek(stream, pos.?.*, SEEK_SET);
}

/// Reopen file with different mode
pub export fn freopen(filename: ?[*:0]const u8, mode: [*:0]const u8, stream: ?*FILE) ?*FILE {
    if (stream == null) return null;

    // Validate filename (if provided) and mode BEFORE closing the old stream
    if (filename == null) {
        // Change mode of existing stream (not supported in this implementation)
        return null;
    }
    
    // Simple validation of mode string
    if (mode[0] != 'r' and mode[0] != 'w' and mode[0] != 'a') {
        return null;
    }

    // Determine flags first
    var flags: i32 = 0;
    const access_mode: u32 = 0o666;

    if (mode[0] == 'r') {
        flags = if (mode[1] == '+') syscall.O_RDWR else syscall.O_RDONLY;
    } else if (mode[0] == 'w') {
        flags = if (mode[1] == '+')
            syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC
        else
            syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC;
    } else if (mode[0] == 'a') {
        flags = if (mode[1] == '+')
            syscall.O_RDWR | syscall.O_CREAT | syscall.O_APPEND
        else
            syscall.O_WRONLY | syscall.O_CREAT | syscall.O_APPEND;
    }

    // Now safe to close old stream
    const f = stream.?;
    
     // Flush before closing
    _ = fflush(f);
    
    _ = syscall.close(f.fd) catch {};

    // Open new file
    const fd = syscall.open(filename.?, flags, access_mode) catch {
        // If open fails, the stream is closed and we return null.
        // We cannot restore the old stream.
        return null;
    };
    
    f.fd = fd;
    f.has_error = false;
    f.eof = false;
    f.unget_char = -1;

    return stream;
}
