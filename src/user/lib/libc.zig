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

export fn malloc(size: usize) ?*anyopaque {
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

export fn free(ptr: ?*anyopaque) void {
    if (ptr == null) return;

    const header_ptr = @as([*]u8, @ptrCast(ptr.?)) - @sizeOf(BlockHeader);
    const header: *BlockHeader = @ptrCast(@alignCast(header_ptr));
    header.free = true;
}

export fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
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
    error: bool,
    eof: bool,
};

export fn fopen(filename: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    var flags: i32 = 0;
    var access_mode: u32 = 0o666;

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
    f.error = false;
    f.eof = false;

    return f;
}

export fn fclose(stream: ?*FILE) i32 {
    if (stream == null) return -1;
    const f = stream.?;
    _ = syscall.close(f.fd) catch return -1;
    free(stream);
    return 0;
}

export fn fread(ptr: ?*anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
    if (stream == null or ptr == null) return 0;
    const f = stream.?;
    const p = ptr.?;

    const total_bytes = size * nmemb;
    if (total_bytes == 0) return 0;

    const bytes_read = syscall.read(f.fd, @ptrCast(p), total_bytes) catch |err| {
        f.error = true;
        return 0;
    };

    if (bytes_read == 0) {
        f.eof = true;
        return 0;
    }

    return bytes_read / size;
}

export fn fwrite(ptr: ?*const anyopaque, size: usize, nmemb: usize, stream: ?*FILE) usize {
     if (stream == null or ptr == null) return 0;
    const f = stream.?;
    const p = ptr.?;

    const total_bytes = size * nmemb;
    if (total_bytes == 0) return 0;

    // cast to [*]const u8 as expected by syscall.write
    const bytes_written = syscall.write(f.fd, @ptrCast(p), total_bytes) catch |err| {
        f.error = true;
        return 0;
    };

    return bytes_written / size;
}

export fn fseek(stream: ?*FILE, offset: c_long, whence: c_int) i32 {
    if (stream == null) return -1;
    const f = stream.?;

    _ = syscall.lseek(f.fd, @intCast(offset), @intCast(whence)) catch return -1;
    f.eof = false;
    return 0;
}

export fn ftell(stream: ?*FILE) c_long {
    if (stream == null) return -1;
    const f = stream.?;

    const pos = syscall.lseek(f.fd, 0, syscall.SEEK_CUR) catch return -1;
    return @intCast(pos);
}

export fn fflush(stream: ?*FILE) i32 {
    return 0;
}

// =============================================================================
// String & Memory Operations
// =============================================================================

export fn memcpy(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
    if (n == 0) return dest;
    const d = @as([*]u8, @ptrCast(dest.?));
    const s = @as([*]const u8, @ptrCast(src.?));
    @memcpy(d[0..n], s[0..n]);
    return dest;
}

export fn memset(s: ?*anyopaque, c: c_int, n: usize) ?*anyopaque {
    if (n == 0) return s;
    const d = @as([*]u8, @ptrCast(s.?));
    @memset(d[0..n], @as(u8, @truncate(@as(c_uint, @bitCast(c)))));
    return s;
}

export fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque {
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

export fn strlen(s: ?[*:0]const u8) usize {
    if (s == null) return 0;
    return std.mem.len(s.?);
}

export fn strcmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8) c_int {
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

export fn strcpy(dest: ?[*:0]u8, src: ?[*:0]const u8) ?[*:0]u8 {
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

export fn strncpy(dest: ?[*]u8, src: ?[*:0]const u8, n: usize) ?[*]u8 {
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

export fn strncmp(s1: ?[*:0]const u8, s2: ?[*:0]const u8, n: usize) c_int {
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

export fn printf(format: [*:0]const u8, ...) c_int {
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
