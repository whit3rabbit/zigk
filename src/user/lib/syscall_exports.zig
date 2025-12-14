// C-Callable Syscall Exports
//
// Provides C ABI exports for doomgeneric platform code.
// These functions wrap the Zig syscall interface for use from C.

const syscall = @import("syscall.zig");

// Re-export types for C
pub const FramebufferInfo = syscall.FramebufferInfo;
pub const Timespec = syscall.Timespec;

/// Get framebuffer info
/// Returns 0 on success, negative errno on failure
export fn zsc_get_fb_info(info: *FramebufferInfo) c_int {
    syscall.get_framebuffer_info(info) catch |err| {
        return -@as(c_int, @intCast(errnoFromError(err)));
    };
    return 0;
}

/// Map framebuffer into process address space
/// Returns pointer on success, null on failure
export fn zsc_map_fb() ?*anyopaque {
    return @ptrCast(syscall.map_framebuffer() catch return null);
}

/// Read raw keyboard scancode (non-blocking)
/// Returns scancode on success, -11 (EAGAIN) if no key available
export fn zsc_read_scancode() c_int {
    return @as(c_int, syscall.read_scancode() catch |err| {
        if (err == error.WouldBlock) return -11; // EAGAIN
        return -@as(c_int, @intCast(errnoFromError(err)));
    });
}

/// High-resolution sleep
export fn zsc_nanosleep(sec: c_long, nsec: c_long) void {
    const req = syscall.Timespec{
        .tv_sec = sec,
        .tv_nsec = nsec,
    };
    syscall.nanosleep(&req, null) catch {};
}

/// Get time from clock
/// Returns 0 on success, negative errno on failure
export fn zsc_clock_gettime(clk_id: c_int, tp: *Timespec) c_long {
    const clock_id: syscall.ClockId = @enumFromInt(clk_id);
    syscall.clock_gettime(clock_id, tp) catch |err| {
        return -@as(c_long, @intCast(errnoFromError(err)));
    };
    return 0;
}

/// Open a file
/// Returns fd on success, negative errno on failure
export fn zsc_open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int {
    return syscall.open(path, flags, mode) catch |err| {
        return -@as(c_int, @intCast(errnoFromError(err)));
    };
}

/// Close a file descriptor
/// Returns 0 on success, negative errno on failure
export fn zsc_close(fd: c_int) c_int {
    syscall.close(fd) catch |err| {
        return -@as(c_int, @intCast(errnoFromError(err)));
    };
    return 0;
}

/// Read from file descriptor
/// Returns bytes read on success, negative errno on failure
export fn zsc_read(fd: c_int, buf: [*]u8, count: usize) isize {
    return @intCast(syscall.read(fd, buf, count) catch |err| {
        return -@as(isize, @intCast(errnoFromError(err)));
    });
}

/// Write to file descriptor
/// Returns bytes written on success, negative errno on failure
export fn zsc_write(fd: c_int, buf: [*]const u8, count: usize) isize {
    return @intCast(syscall.write(fd, buf, count) catch |err| {
        return -@as(isize, @intCast(errnoFromError(err)));
    });
}

/// Seek in file
/// Returns new position on success, negative errno on failure
export fn zsc_lseek(fd: c_int, offset: isize, whence: c_int) isize {
    return @intCast(syscall.lseek(fd, offset, whence) catch |err| {
        return -@as(isize, @intCast(errnoFromError(err)));
    });
}

/// Exit process
export fn zsc_exit(status: c_int) noreturn {
    syscall.exit(status);
}

/// Get process ID
export fn zsc_getpid() c_int {
    return syscall.getpid();
}

// Convert Zig error to errno value
fn errnoFromError(err: syscall.SyscallError) u32 {
    return switch (err) {
        error.PermissionDenied => 1,
        error.NoSuchFileOrDirectory => 2,
        error.NoSuchProcess => 3,
        error.Interrupted => 4,
        error.IoError => 5,
        error.NoSuchDevice => 6,
        error.ArgumentListTooLong => 7,
        error.ExecFormatError => 8,
        error.BadFileDescriptor => 9,
        error.NoChildProcesses => 10,
        error.WouldBlock => 11,
        error.OutOfMemory => 12,
        error.AccessDenied => 13,
        error.BadAddress => 14,
        error.DeviceBusy => 16,
        error.FileExists => 17,
        error.InvalidArgument => 22,
        error.TooManyOpenFiles => 24,
        error.NotImplemented => 38,
        error.Unexpected => 22,
    };
}
