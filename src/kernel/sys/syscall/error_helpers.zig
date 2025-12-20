// Error Helpers for Syscall Handlers
//
// Provides comptime error mapping utilities to consolidate repetitive
// error conversion code across syscall handlers.
//
// The device layer uses legacy isize returns (negative errno values).
// These helpers map them to modern SyscallError unions.

const std = @import("std");
const uapi = @import("uapi");

pub const SyscallError = uapi.errno.SyscallError;

/// Linux errno values for reference (device layer uses these)
pub const LINUX_EIO: i32 = 5;
pub const LINUX_EAGAIN: i32 = 11;
pub const LINUX_EFAULT: i32 = 14;
pub const LINUX_EPIPE: i32 = 32;

/// Maps device layer negative errno returns to SyscallError.
///
/// The device layer (fd ops) returns isize where negative values
/// are -errno. This function converts those to proper Zig error unions.
///
/// Usage:
/// ```zig
/// const result = try mapDeviceError(device_fn(fd, buf));
/// ```
pub inline fn mapDeviceError(ret: isize) SyscallError!usize {
    if (ret >= 0) {
        return @intCast(ret);
    }

    const errno_val: i32 = @intCast(-ret);
    return switch (errno_val) {
        LINUX_EIO => error.EIO,
        LINUX_EAGAIN => error.EAGAIN,
        LINUX_EFAULT => error.EFAULT,
        LINUX_EPIPE => error.EPIPE,
        else => error.EIO, // Default to I/O error for unknown
    };
}

/// Maps device layer errors for read operations (no EPIPE).
/// Use mapDeviceError for write operations which can get EPIPE.
pub inline fn mapReadError(ret: isize) SyscallError!usize {
    return mapDeviceError(ret);
}

/// Maps device layer errors for write operations (includes EPIPE).
pub inline fn mapWriteError(ret: isize) SyscallError!usize {
    return mapDeviceError(ret);
}

// Comptime validation
comptime {
    // Verify our errno constants match Linux x86_64 ABI
    std.debug.assert(LINUX_EIO == 5);
    std.debug.assert(LINUX_EAGAIN == 11);
    std.debug.assert(LINUX_EFAULT == 14);
    std.debug.assert(LINUX_EPIPE == 32);
}

// Tests
test "mapDeviceError positive returns value" {
    const result = try mapDeviceError(42);
    try std.testing.expectEqual(@as(usize, 42), result);
}

test "mapDeviceError zero returns zero" {
    const result = try mapDeviceError(0);
    try std.testing.expectEqual(@as(usize, 0), result);
}

test "mapDeviceError negative EIO" {
    const result = mapDeviceError(-5);
    try std.testing.expectError(error.EIO, result);
}

test "mapDeviceError negative EAGAIN" {
    const result = mapDeviceError(-11);
    try std.testing.expectError(error.EAGAIN, result);
}

test "mapDeviceError negative EPIPE" {
    const result = mapDeviceError(-32);
    try std.testing.expectError(error.EPIPE, result);
}
