// Environment and filesystem stubs (stdlib.h)
//
// Functions that require kernel features not yet implemented.

const errno_mod = @import("../errno.zig");

/// Get environment variable value (stub)
/// Returns null - no environment support
pub export fn getenv(name: ?[*:0]const u8) ?[*:0]u8 {
    _ = name;
    return null;
}

/// Set environment variable (stub)
pub export fn setenv(name: ?[*:0]const u8, value: ?[*:0]const u8, overwrite: c_int) c_int {
    _ = name;
    _ = value;
    _ = overwrite;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Unset environment variable (stub)
pub export fn unsetenv(name: ?[*:0]const u8) c_int {
    _ = name;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Put environment string (stub)
pub export fn putenv(string: ?[*:0]u8) c_int {
    _ = string;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Create directory (stub)
pub export fn mkdir(pathname: ?[*:0]const u8, mode: c_uint) c_int {
    _ = pathname;
    _ = mode;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Remove directory (stub)
pub export fn rmdir(pathname: ?[*:0]const u8) c_int {
    _ = pathname;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Change current directory (stub)
pub export fn chdir(path: ?[*:0]const u8) c_int {
    _ = path;
    errno_mod.errno = errno_mod.ENOSYS;
    return -1;
}

/// Get current directory (stub)
pub export fn getcwd(buf: ?[*]u8, size: usize) ?[*]u8 {
    _ = buf;
    _ = size;
    errno_mod.errno = errno_mod.ENOSYS;
    return null;
}
