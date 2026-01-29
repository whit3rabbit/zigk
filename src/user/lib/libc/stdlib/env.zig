// Environment variables and filesystem operations (stdlib.h, unistd.h)
//
// Environment variables: getenv, setenv, unsetenv, putenv
// Directory operations: mkdir, rmdir, chdir, getcwd

const std = @import("std");
const syscall = @import("syscall");
const errno_mod = @import("../errno.zig");

// =============================================================================
// Environment Variable Storage
// =============================================================================

/// Maximum number of environment variables
const MAX_ENV_VARS = 256;

/// Maximum total storage for environment strings
const MAX_ENV_SIZE = 16384;

/// Static storage for environment variable strings
var env_storage: [MAX_ENV_SIZE]u8 = [_]u8{0} ** MAX_ENV_SIZE;

/// Current position in env_storage
var env_storage_used: usize = 0;

/// Array of pointers to environment strings (NAME=VALUE format)
/// Null-terminated array as required by POSIX
var environ_ptrs: [MAX_ENV_VARS + 1]?[*:0]u8 = [_]?[*:0]u8{null} ** (MAX_ENV_VARS + 1);

/// Number of environment variables currently set
var environ_count: usize = 0;

/// Find index of environment variable by name
/// Returns null if not found
fn findEnvVar(name: [*:0]const u8) ?usize {
    const name_len = strLen(name);
    if (name_len == 0) return null;

    for (0..environ_count) |i| {
        const entry = environ_ptrs[i] orelse continue;
        // Check if entry starts with "NAME="
        var j: usize = 0;
        while (j < name_len) : (j += 1) {
            if (entry[j] != name[j]) break;
        }
        if (j == name_len and entry[j] == '=') {
            return i;
        }
    }
    return null;
}

/// Get string length of null-terminated string
fn strLen(s: [*:0]const u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

/// Check if name contains '=' character (invalid for env var names)
fn containsEquals(name: [*:0]const u8) bool {
    var i: usize = 0;
    while (name[i] != 0) : (i += 1) {
        if (name[i] == '=') return true;
    }
    return false;
}

/// Check if a pointer falls within env_storage
fn isInStorage(ptr: [*]const u8) bool {
    const storage_start = @intFromPtr(&env_storage[0]);
    const storage_end = storage_start + MAX_ENV_SIZE;
    const p = @intFromPtr(ptr);
    return p >= storage_start and p < storage_end;
}

/// Get length of a null-terminated entry (including the null byte)
fn entryLen(ptr: [*:0]const u8) usize {
    return strLen(ptr) + 1;
}

/// Compact env_storage by removing bytes at a given offset and shifting remaining data down.
/// Fixes all environ_ptrs that point past the removed region.
/// Security: Zeros reclaimed space to prevent data leaks.
fn compactStorage(remove_start: usize, remove_len: usize) void {
    if (remove_len == 0) return;
    if (remove_start + remove_len > env_storage_used) return;

    // Shift bytes after the removed region down (manual loop for overlapping regions)
    const remaining = env_storage_used - (remove_start + remove_len);
    var i: usize = 0;
    while (i < remaining) : (i += 1) {
        env_storage[remove_start + i] = env_storage[remove_start + remove_len + i];
    }

    // Zero reclaimed space
    const new_used = env_storage_used - remove_len;
    i = new_used;
    while (i < env_storage_used) : (i += 1) {
        env_storage[i] = 0;
    }

    // Fix environ_ptrs that point past the removed region
    const storage_base = @intFromPtr(&env_storage[0]);
    for (0..environ_count) |idx| {
        if (environ_ptrs[idx]) |ptr| {
            const ptr_addr = @intFromPtr(ptr);
            // Only fix pointers within env_storage that are past the removed region
            if (ptr_addr >= storage_base and ptr_addr < storage_base + MAX_ENV_SIZE) {
                const offset = ptr_addr - storage_base;
                if (offset > remove_start) {
                    // This pointer needs to shift back by remove_len
                    const new_offset = offset - remove_len;
                    environ_ptrs[idx] = @ptrCast(&env_storage[new_offset]);
                }
            }
        }
    }

    env_storage_used = new_used;
}

// =============================================================================
// Environment Variable Functions
// =============================================================================

/// Get environment variable value
/// Returns pointer to value after '=', or null if not found
pub export fn getenv(name: ?[*:0]const u8) ?[*:0]u8 {
    if (name == null) return null;
    const n = name.?;
    if (n[0] == 0) return null; // Empty name

    if (findEnvVar(n)) |idx| {
        const entry = environ_ptrs[idx] orelse return null;
        // Skip past "NAME=" to return value
        var pos: usize = 0;
        while (entry[pos] != 0 and entry[pos] != '=') : (pos += 1) {}
        if (entry[pos] == '=') {
            return @ptrCast(&entry[pos + 1]);
        }
    }
    return null;
}

/// Set environment variable
/// If overwrite is 0 and variable exists, does nothing
/// Returns 0 on success, -1 on error
pub export fn setenv(name: ?[*:0]const u8, value: ?[*:0]const u8, overwrite: c_int) c_int {
    if (name == null or value == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    const n = name.?;
    const v = value.?;

    // Reject empty names or names containing '='
    if (n[0] == 0 or containsEquals(n)) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    const name_len = strLen(n);
    const value_len = strLen(v);

    // Check for existing variable
    if (findEnvVar(n)) |idx| {
        if (overwrite == 0) return 0; // Don't overwrite, success

        // Compact storage for old entry if it's in our storage
        if (environ_ptrs[idx]) |old_ptr| {
            if (isInStorage(@ptrCast(old_ptr))) {
                const old_len = entryLen(old_ptr);
                const storage_base = @intFromPtr(&env_storage[0]);
                const old_offset = @intFromPtr(old_ptr) - storage_base;
                // Remove from pointer array first (before compaction fixes pointers)
                var i = idx;
                while (i < environ_count - 1) : (i += 1) {
                    environ_ptrs[i] = environ_ptrs[i + 1];
                }
                environ_ptrs[environ_count - 1] = null;
                environ_count -= 1;
                compactStorage(old_offset, old_len);
            } else {
                // External pointer (from putenv) - just remove from array
                var i = idx;
                while (i < environ_count - 1) : (i += 1) {
                    environ_ptrs[i] = environ_ptrs[i + 1];
                }
                environ_ptrs[environ_count - 1] = null;
                environ_count -= 1;
            }
        }
    }

    // Calculate required space: name + '=' + value + '\0'
    const required = std.math.add(usize, name_len, value_len) catch {
        errno_mod.errno = errno_mod.ENOMEM;
        return -1;
    };
    const total_required = std.math.add(usize, required, 2) catch { // +2 for '=' and '\0'
        errno_mod.errno = errno_mod.ENOMEM;
        return -1;
    };

    // Check storage space
    if (env_storage_used + total_required > MAX_ENV_SIZE) {
        errno_mod.errno = errno_mod.ENOMEM;
        return -1;
    }

    // Check slot availability
    if (environ_count >= MAX_ENV_VARS) {
        errno_mod.errno = errno_mod.ENOMEM;
        return -1;
    }

    // Copy "NAME=VALUE\0" to storage
    const start = env_storage_used;
    for (0..name_len) |i| {
        env_storage[start + i] = n[i];
    }
    env_storage[start + name_len] = '=';
    for (0..value_len) |i| {
        env_storage[start + name_len + 1 + i] = v[i];
    }
    env_storage[start + total_required - 1] = 0;

    // Add pointer to environ array
    environ_ptrs[environ_count] = @ptrCast(&env_storage[start]);
    environ_count += 1;
    environ_ptrs[environ_count] = null; // Keep null-terminated

    env_storage_used += total_required;
    return 0;
}

/// Unset (remove) environment variable
/// Returns 0 on success, -1 on error
pub export fn unsetenv(name: ?[*:0]const u8) c_int {
    if (name == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    const n = name.?;

    // Reject empty names or names containing '='
    if (n[0] == 0 or containsEquals(n)) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    if (findEnvVar(n)) |idx| {
        // Compact storage if entry is in our storage
        if (environ_ptrs[idx]) |old_ptr| {
            const do_compact = isInStorage(@ptrCast(old_ptr));
            const old_len = if (do_compact) entryLen(old_ptr) else @as(usize, 0);
            const storage_base = @intFromPtr(&env_storage[0]);
            const old_offset = if (do_compact) @intFromPtr(old_ptr) - storage_base else @as(usize, 0);

            // Remove from pointer array
            var i = idx;
            while (i < environ_count - 1) : (i += 1) {
                environ_ptrs[i] = environ_ptrs[i + 1];
            }
            environ_ptrs[environ_count - 1] = null;
            environ_count -= 1;

            if (do_compact) {
                compactStorage(old_offset, old_len);
            }
        }
    }

    return 0; // Success even if not found (POSIX behavior)
}

/// Put environment string directly (must be in "NAME=VALUE" format)
/// The string becomes part of the environment - caller must not free/modify it
/// Returns 0 on success, -1 on error
pub export fn putenv(string: ?[*:0]u8) c_int {
    if (string == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    const s = string.?;
    if (s[0] == 0) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    // Find '=' in string
    var eq_pos: usize = 0;
    while (s[eq_pos] != 0 and s[eq_pos] != '=') : (eq_pos += 1) {}

    if (s[eq_pos] != '=') {
        // No '=' found - unset the variable (GNU extension)
        return unsetenv(s);
    }

    if (eq_pos == 0) {
        // Empty name (string starts with '=')
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    // Extract name for lookup
    var name_buf: [256]u8 = undefined;
    if (eq_pos >= name_buf.len) {
        errno_mod.errno = errno_mod.ENAMETOOLONG;
        return -1;
    }
    for (0..eq_pos) |i| {
        name_buf[i] = s[i];
    }
    name_buf[eq_pos] = 0;

    // Remove existing variable if present
    if (findEnvVar(@ptrCast(&name_buf))) |idx| {
        var i = idx;
        while (i < environ_count - 1) : (i += 1) {
            environ_ptrs[i] = environ_ptrs[i + 1];
        }
        environ_ptrs[environ_count - 1] = null;
        environ_count -= 1;
    }

    // Check slot availability
    if (environ_count >= MAX_ENV_VARS) {
        errno_mod.errno = errno_mod.ENOMEM;
        return -1;
    }

    // Add the string directly (no copy - caller's responsibility)
    environ_ptrs[environ_count] = s;
    environ_count += 1;
    environ_ptrs[environ_count] = null;

    return 0;
}

// =============================================================================
// Error Translation Helper
// =============================================================================

/// Convert SyscallError to errno value
fn syscallErrorToErrno(err: syscall.SyscallError) c_int {
    return switch (err) {
        error.PermissionDenied => errno_mod.EPERM,
        error.NoSuchFileOrDirectory => errno_mod.ENOENT,
        error.NoSuchProcess => errno_mod.ESRCH,
        error.Interrupted => errno_mod.EINTR,
        error.IoError => errno_mod.EIO,
        error.NoSuchDevice => errno_mod.ENXIO,
        error.ArgumentListTooLong => errno_mod.E2BIG,
        error.ExecFormatError => errno_mod.ENOEXEC,
        error.BadFileDescriptor => errno_mod.EBADF,
        error.NoChildProcesses => errno_mod.ECHILD,
        error.WouldBlock => errno_mod.EAGAIN,
        error.OutOfMemory => errno_mod.ENOMEM,
        error.AccessDenied => errno_mod.EACCES,
        error.BadAddress => errno_mod.EFAULT,
        error.DeviceBusy => errno_mod.EBUSY,
        error.FileExists => errno_mod.EEXIST,
        error.NotADirectory => errno_mod.ENOTDIR,
        error.IsADirectory => errno_mod.EISDIR,
        error.InvalidArgument => errno_mod.EINVAL,
        error.TooManyOpenFiles => errno_mod.EMFILE,
        error.NoSpace => errno_mod.ENOSPC,
        error.IllegalSeek => errno_mod.ESPIPE,
        error.ReadOnlyFilesystem => errno_mod.EROFS,
        error.TooManyLinks => errno_mod.EMLINK,
        error.FilenameTooLong => errno_mod.ENAMETOOLONG,
        error.NotImplemented => errno_mod.ENOSYS,
        error.DirectoryNotEmpty => errno_mod.ENOTEMPTY,
        error.TooManySymbolicLinks => errno_mod.ELOOP,
        error.Unexpected => errno_mod.EIO, // Map unexpected to I/O error
    };
}

// =============================================================================
// Directory Operations
// =============================================================================

/// Create a directory
/// Returns 0 on success, -1 on error (errno set)
pub export fn mkdir(pathname: ?[*:0]const u8, mode: c_uint) c_int {
    if (pathname == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    syscall.mkdir(pathname.?, @truncate(mode)) catch |err| {
        errno_mod.errno = syscallErrorToErrno(err);
        return -1;
    };

    return 0;
}

/// Remove a directory
/// Returns 0 on success, -1 on error (errno set)
pub export fn rmdir(pathname: ?[*:0]const u8) c_int {
    if (pathname == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    syscall.rmdir(pathname.?) catch |err| {
        errno_mod.errno = syscallErrorToErrno(err);
        return -1;
    };

    return 0;
}

/// Change current working directory
/// Returns 0 on success, -1 on error (errno set)
pub export fn chdir(path: ?[*:0]const u8) c_int {
    if (path == null) {
        errno_mod.errno = errno_mod.EINVAL;
        return -1;
    }

    syscall.chdir(path.?) catch |err| {
        errno_mod.errno = syscallErrorToErrno(err);
        return -1;
    };

    return 0;
}

/// Get current working directory
/// Returns buf on success, null on error (errno set)
pub export fn getcwd(buf: ?[*]u8, size: usize) ?[*]u8 {
    if (buf == null or size == 0) {
        errno_mod.errno = errno_mod.EINVAL;
        return null;
    }

    const len = syscall.getcwd(buf.?, size) catch |err| {
        errno_mod.errno = syscallErrorToErrno(err);
        return null;
    };

    // Ensure null termination
    if (len < size) {
        buf.?[len] = 0;
    }

    return buf;
}
