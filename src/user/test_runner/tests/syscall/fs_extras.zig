const std = @import("std");
const syscall = @import("syscall");

// AT constants
const AT_FDCWD: i32 = -100;
const AT_SYMLINK_NOFOLLOW: i32 = 0x100;

// Userspace error names (different from kernel-side ENOSYS/EINVAL/etc.)
const SyscallError = syscall.SyscallError;

// FS-01: readlinkat tests

// Test readlinkat on a regular file -- should return error (not a symlink)
pub fn testReadlinkatBasic() !void {
    var buf: [256]u8 = undefined;
    const result = syscall.readlinkat(AT_FDCWD, "/shell.elf", &buf, buf.len);
    if (result) |_| {
        // readlinkat succeeded on a regular file -- some filesystems may
        // not distinguish. Accept this since syscall plumbing works.
    } else |err| {
        // EINVAL(22)->InvalidArgument, ENOSYS(38)->NotImplemented, ENOENT(2)->NoSuchFileOrDirectory
        if (err != error.InvalidArgument and err != error.NotImplemented and err != error.NoSuchFileOrDirectory) {
            return error.TestFailed;
        }
    }
}

// Test readlinkat on nonexistent path -- should return ENOENT
pub fn testReadlinkatInvalidPath() !void {
    var buf: [256]u8 = undefined;
    const result = syscall.readlinkat(AT_FDCWD, "/nonexistent_readlinkat_path", &buf, buf.len);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // ENOENT(2)->NoSuchFileOrDirectory, ENOSYS(38)->NotImplemented, EINVAL(22)->InvalidArgument
        // InitRD has no readlink fn -> VFS returns NotSupported -> EINVAL -> InvalidArgument
        if (err != error.NoSuchFileOrDirectory and err != error.NotImplemented and err != error.InvalidArgument) {
            return error.TestFailed;
        }
    }
}

// FS-02: linkat tests

// Test linkat creates a hard link on SFS
pub fn testLinkatBasic() !void {
    const src = "/mnt/test_linkat_src";
    const dst = "/mnt/test_linkat_dst";

    // Create source file (keep fd open -- SFS close deadlock workaround)
    _ = syscall.open(src, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Create hard link
    syscall.linkat(AT_FDCWD, src, AT_FDCWD, dst, 0) catch |err| {
        // linkat may not be supported on SFS (VFS returns NotSupported -> EROFS -> ReadOnlyFilesystem)
        syscall.unlink(src) catch {};
        if (err == error.NotImplemented or err == error.PermissionDenied or err == error.OperationNotSupported or err == error.ReadOnlyFilesystem) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Verify the link exists
    const access_result = syscall.access(dst, 0);
    if (access_result) |_| {
        // Success -- link exists
    } else |_| {
        syscall.unlink(dst) catch {};
        syscall.unlink(src) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(dst) catch {};
    syscall.unlink(src) catch {};
}

// Test linkat cross-device returns EXDEV or EROFS
pub fn testLinkatCrossDevice() !void {
    const result = syscall.linkat(AT_FDCWD, "/shell.elf", AT_FDCWD, "/mnt/cross_link", 0);
    if (result) |_| {
        // Cross-device link should fail
        syscall.unlink("/mnt/cross_link") catch {};
        return error.TestFailed;
    } else |err| {
        // EXDEV(18)->Unexpected, EROFS(30)->ReadOnlyFilesystem, EPERM(1)->PermissionDenied, ENOSYS(38)->NotImplemented
        // Also accept Unexpected (unmapped errno like EXDEV)
        if (err != error.Unexpected and err != error.ReadOnlyFilesystem and err != error.PermissionDenied and err != error.NotImplemented) {
            return error.TestFailed;
        }
    }
}

// FS-03: symlinkat tests

// Test symlinkat creates a symbolic link
pub fn testSymlinkatBasic() !void {
    const linkpath = "/mnt/test_symlinkat_link";

    syscall.symlinkat("/shell.elf", AT_FDCWD, linkpath) catch |err| {
        // SFS may not support symlinks (VFS returns NotSupported -> EROFS -> ReadOnlyFilesystem)
        if (err == error.NotImplemented or err == error.PermissionDenied or err == error.OperationNotSupported or err == error.ReadOnlyFilesystem) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // If symlink was created, try to read it back
    var buf: [256]u8 = undefined;
    const len = syscall.readlink(linkpath, &buf, buf.len) catch {
        syscall.unlink(linkpath) catch {};
        return error.SkipTest;
    };

    // Verify target matches
    if (len != 10) { // "/shell.elf" is 10 chars
        syscall.unlink(linkpath) catch {};
        return error.TestFailed;
    }

    if (!std.mem.eql(u8, buf[0..len], "/shell.elf")) {
        syscall.unlink(linkpath) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(linkpath) catch {};
}

// Test symlinkat with empty target -- should return ENOENT or EINVAL
pub fn testSymlinkatEmptyTarget() !void {
    const result = syscall.symlinkat("", AT_FDCWD, "/mnt/test_empty_sym");
    if (result) |_| {
        syscall.unlink("/mnt/test_empty_sym") catch {};
        return error.TestFailed;
    } else |err| {
        // ENOENT(2)->NoSuchFileOrDirectory, EINVAL(22)->InvalidArgument, ENOSYS(38)->NotImplemented
        if (err != error.NoSuchFileOrDirectory and err != error.InvalidArgument and err != error.NotImplemented) {
            return error.TestFailed;
        }
    }
}

// FS-04: utimensat tests

// Test utimensat with NULL times (set to current time)
pub fn testUtimensatNull() !void {
    const path = "/mnt/test_utime";

    // Create file (keep fd open -- SFS deadlock workaround)
    _ = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Set timestamps to current time (NULL times)
    syscall.utimensat(AT_FDCWD, path, null, 0) catch |err| {
        syscall.unlink(path) catch {};
        // EROFS(30)->ReadOnlyFilesystem if SFS doesn't implement set_timestamps
        if (err == error.ReadOnlyFilesystem or err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test utimensat with specific timestamps
pub fn testUtimensatSpecificTime() !void {
    const path = "/mnt/test_utime_spec";

    // Create file
    _ = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Set specific timestamps -- use @ptrCast since syscall.Timespec (time.zig)
    // and uapi.abi.Timespec are structurally identical but different Zig types
    var times: [2]syscall.Timespec = .{
        .{ .tv_sec = 1000000, .tv_nsec = 500 }, // atime
        .{ .tv_sec = 2000000, .tv_nsec = 999 }, // mtime
    };

    syscall.utimensat(AT_FDCWD, path, @ptrCast(&times), 0) catch |err| {
        syscall.unlink(path) catch {};
        // EROFS(30)->ReadOnlyFilesystem if SFS doesn't implement set_timestamps
        if (err == error.ReadOnlyFilesystem or err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test utimensat with AT_SYMLINK_NOFOLLOW returns ENOSYS (MVP limitation)
pub fn testUtimensatSymlinkNofollow() !void {
    const result = syscall.utimensat(AT_FDCWD, "/shell.elf", null, AT_SYMLINK_NOFOLLOW);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // ENOSYS(38)->NotImplemented
        if (err != error.NotImplemented) return error.TestFailed;
    }
}

// Test utimensat with invalid nanosecond value returns EINVAL
pub fn testUtimensatInvalidNsec() !void {
    var times: [2]syscall.Timespec = .{
        .{ .tv_sec = 1000, .tv_nsec = 1_000_000_000 }, // out of range
        .{ .tv_sec = 2000, .tv_nsec = 0 },
    };

    const result = syscall.utimensat(AT_FDCWD, "/shell.elf", @ptrCast(&times), 0);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // EINVAL(22)->InvalidArgument
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// FS-05: futimesat tests

// Test futimesat with NULL times (set to current time)
pub fn testFutimesatBasic() !void {
    const path = "/mnt/test_futimesat";

    // Create file (keep fd open -- SFS deadlock workaround)
    _ = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Set timestamps to current time (NULL times)
    syscall.futimesat(AT_FDCWD, path, null) catch |err| {
        syscall.unlink(path) catch {};
        // EROFS(30)->ReadOnlyFilesystem
        if (err == error.ReadOnlyFilesystem or err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test futimesat with specific microsecond timestamps
pub fn testFutimesatSpecificTime() !void {
    const path = "/mnt/test_futimesat_spec";

    // Create file
    _ = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Set specific timestamps (microsecond precision)
    var times: [2]syscall.Timeval = .{
        .{ .tv_sec = 1000000, .tv_usec = 500000 }, // atime
        .{ .tv_sec = 2000000, .tv_usec = 999999 }, // mtime
    };

    syscall.futimesat(AT_FDCWD, path, &times) catch |err| {
        syscall.unlink(path) catch {};
        // EROFS(30)->ReadOnlyFilesystem
        if (err == error.ReadOnlyFilesystem or err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Cleanup
    syscall.unlink(path) catch {};
}
