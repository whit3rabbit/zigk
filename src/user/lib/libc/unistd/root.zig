const std = @import("std");
const syscall = @import("syscall.zig");
const errno = @import("../errno.zig");

// Access mode flags
pub const F_OK: c_int = 0;
pub const X_OK: c_int = 1;
pub const W_OK: c_int = 2;
pub const R_OK: c_int = 4;

/// Check user's permissions for a file
pub export fn access(path: ?[*:0]const u8, mode: c_int) c_int {
    if (path == null) {
        errno.errno = errno.EFAULT;
        return -1;
    }

    syscall.access(path.?, mode) catch |err| {
        errno.errno = switch (err) {
            error.PermissionDenied => errno.EACCES,
            error.NoSuchFileOrDirectory => errno.ENOENT,
            error.AccessDenied => errno.EACCES,
            error.BadAddress => errno.EFAULT,
            error.IoError => errno.EIO,
            error.OutOfMemory => errno.ENOMEM,
            error.NameTooLong => 36, // ENAMETOOLONG
            else => errno.EINVAL,
        };
        return -1;
    };
    return 0;
}
