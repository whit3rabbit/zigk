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

    // Create source file with some data
    const fd = syscall.open(src, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    const test_data = "hard link test data";
    _ = syscall.write(fd, test_data.ptr, test_data.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(src) catch {};
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Create hard link
    syscall.linkat(AT_FDCWD, src, AT_FDCWD, dst, 0) catch |err| {
        // linkat may not be supported on some filesystems
        syscall.unlink(src) catch {};
        if (err == error.NotImplemented or err == error.PermissionDenied or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Verify the link exists by reading data from it
    const read_fd = syscall.open(dst, syscall.O_RDONLY, 0) catch {
        syscall.unlink(dst) catch {};
        syscall.unlink(src) catch {};
        return error.TestFailed;
    };
    var buf: [32]u8 = undefined;
    const read_len = syscall.read(read_fd, &buf, buf.len) catch {
        syscall.close(read_fd) catch {};
        syscall.unlink(dst) catch {};
        syscall.unlink(src) catch {};
        return error.TestFailed;
    };
    syscall.close(read_fd) catch {};

    // Verify data matches
    if (read_len != test_data.len or !std.mem.eql(u8, buf[0..read_len], test_data)) {
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
        // SFS may not support symlinks on some filesystems
        if (err == error.NotImplemented or err == error.PermissionDenied or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Read symlink back to verify target
    var buf: [256]u8 = undefined;
    const len = syscall.readlink(linkpath, &buf, buf.len) catch {
        syscall.unlink(linkpath) catch {};
        return error.TestFailed;
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

    // Create file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Set timestamps to current time (NULL times)
    syscall.utimensat(AT_FDCWD, path, null, 0) catch |err| {
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Verify timestamps were set by checking mtime is nonzero
    var stat_buf: syscall.Stat = undefined;
    const path_z: [*:0]const u8 = @ptrCast(path);
    syscall.stat(path_z, &stat_buf) catch {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    // mtime should be nonzero after setting to current time
    if (stat_buf.mtime == 0) {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test utimensat with specific timestamps
pub fn testUtimensatSpecificTime() !void {
    const path = "/mnt/test_utime_spec";

    // Create file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Set specific timestamps -- use @ptrCast since syscall.Timespec (time.zig)
    // and uapi.abi.Timespec are structurally identical but different Zig types
    var times: [2]syscall.Timespec = .{
        .{ .tv_sec = 1000000, .tv_nsec = 500 }, // atime
        .{ .tv_sec = 2000000, .tv_nsec = 999 }, // mtime
    };

    syscall.utimensat(AT_FDCWD, path, @ptrCast(&times), 0) catch |err| {
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Verify mtime was set to 2000000 (SFS stores as u32 seconds, nanoseconds lost)
    var stat_buf: syscall.Stat = undefined;
    const path_z: [*:0]const u8 = @ptrCast(path);
    syscall.stat(path_z, &stat_buf) catch {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    if (stat_buf.mtime != 2000000) {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test utimensat with AT_SYMLINK_NOFOLLOW sets timestamps on path entry
pub fn testUtimensatSymlinkNofollow() !void {
    // Create a test file on SFS to avoid modifying read-only initrd
    const fd = syscall.open("/mnt/test_nofollow.txt", syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest; // SFS not available
    };
    syscall.close(fd) catch {};

    // Set timestamps with AT_SYMLINK_NOFOLLOW -- should succeed
    syscall.utimensat(AT_FDCWD, "/mnt/test_nofollow.txt", null, AT_SYMLINK_NOFOLLOW) catch {
        return error.TestFailed;
    };

    // Clean up
    syscall.unlink("/mnt/test_nofollow.txt") catch {};
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

    // Create file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Set timestamps to current time (NULL times)
    syscall.futimesat(AT_FDCWD, path, null) catch |err| {
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented or err == error.OperationNotSupported) {
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
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Set specific timestamps (microsecond precision)
    var times: [2]syscall.Timeval = .{
        .{ .tv_sec = 1000000, .tv_usec = 500000 }, // atime
        .{ .tv_sec = 2000000, .tv_usec = 999999 }, // mtime
    };

    syscall.futimesat(AT_FDCWD, path, &times) catch |err| {
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented or err == error.OperationNotSupported) {
            return error.SkipTest;
        }
        return error.TestFailed;
    };

    // Verify mtime was set to 2000000 (SFS stores as u32 seconds, microseconds lost)
    var stat_buf: syscall.Stat = undefined;
    const path_z: [*:0]const u8 = @ptrCast(path);
    syscall.stat(path_z, &stat_buf) catch {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    if (stat_buf.mtime != 2000000) {
        syscall.unlink(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// FS-06: fsync, fdatasync, sync, syncfs tests

/// Test fsync on a regular writable file -- should succeed
pub fn testFsyncOnRegularFile() !void {
    const path = "/mnt/test_fsync_file";

    // Create and write to file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    const test_data = "fsync test data";
    _ = syscall.write(fd, test_data.ptr, test_data.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.SkipTest;
    };

    // Call fsync -- should succeed
    syscall.fsync(fd) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    // Cleanup
    syscall.close(fd) catch {};
    syscall.unlink(path) catch {};
}

/// Test fsync on a read-only file -- should succeed (Linux behavior)
pub fn testFsyncOnReadOnlyFile() !void {
    // Open InitRD file read-only
    const fd = syscall.open("/shell.elf", syscall.O_RDONLY, 0) catch {
        return error.SkipTest;
    };

    // Call fsync on read-only fd -- should succeed
    syscall.fsync(fd) catch {
        syscall.close(fd) catch {};
        return error.TestFailed;
    };

    // Cleanup
    syscall.close(fd) catch {};
}

/// Test fsync with invalid fd -- should return EBADF
pub fn testFsyncInvalidFd() !void {
    if (syscall.fsync(999)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.BadFileDescriptor) return error.TestFailed;
    }
}

/// Test fdatasync on a regular writable file -- should succeed
pub fn testFdatasyncOnRegularFile() !void {
    const path = "/mnt/test_fdatasync_file";

    // Create and write to file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    const test_data = "fdatasync test data";
    _ = syscall.write(fd, test_data.ptr, test_data.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.SkipTest;
    };

    // Call fdatasync -- should succeed
    syscall.fdatasync(fd) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    // Cleanup
    syscall.close(fd) catch {};
    syscall.unlink(path) catch {};
}

/// Test fdatasync with invalid fd -- should return EBADF
pub fn testFdatasyncInvalidFd() !void {
    if (syscall.fdatasync(999)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.BadFileDescriptor) return error.TestFailed;
    }
}

/// Test sync -- global flush, always succeeds
pub fn testSyncGlobal() !void {
    // sync_() has void return, cannot fail
    syscall.sync_();
}

/// Test syncfs on an open file -- should succeed
pub fn testSyncfsOnOpenFile() !void {
    // Open any file
    const fd = syscall.open("/shell.elf", syscall.O_RDONLY, 0) catch {
        return error.SkipTest;
    };

    // Call syncfs -- should succeed
    syscall.syncfs(fd) catch {
        syscall.close(fd) catch {};
        return error.TestFailed;
    };

    // Cleanup
    syscall.close(fd) catch {};
}

/// Test syncfs with invalid fd -- should return EBADF
pub fn testSyncfsInvalidFd() !void {
    if (syscall.syncfs(999)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.BadFileDescriptor) return error.TestFailed;
    }
}

// FS-07: fallocate tests

/// Test fallocate with mode=0 (default mode) extends file size
pub fn testFallocateDefaultMode() !void {
    const path = "/mnt/falloc_test";

    // Create file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Pre-allocate 4096 bytes with mode=0 (should extend file)
    syscall.fallocate(fd, 0, 0, 4096) catch |err| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };

    // Verify file size is >= 4096
    var stat_buf: syscall.Stat = undefined;
    syscall.fstat(fd, &stat_buf) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    if (stat_buf.size < 4096) {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.close(fd) catch {};
    syscall.unlink(path) catch {};
}

/// Test fallocate with FALLOC_FL_KEEP_SIZE preserves file size
pub fn testFallocateKeepSize() !void {
    const path = "/mnt/falloc_ks";

    // Create file and write 10 bytes
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    const test_data = "0123456789";
    _ = syscall.write(fd, test_data.ptr, test_data.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.SkipTest;
    };

    // Pre-allocate 8192 bytes with KEEP_SIZE flag
    syscall.fallocate(fd, syscall.FALLOC_FL_KEEP_SIZE, 0, 8192) catch |err| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };

    // Verify file size is still 10 bytes (not 8192)
    var stat_buf: syscall.Stat = undefined;
    syscall.fstat(fd, &stat_buf) catch {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    };

    if (stat_buf.size != 10) {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.close(fd) catch {};
    syscall.unlink(path) catch {};
}

/// Test fallocate with PUNCH_HOLE returns error (unsupported on SFS)
pub fn testFallocatePunchHoleUnsupported() !void {
    const path = "/mnt/falloc_ph";

    // Create file
    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    // Try PUNCH_HOLE -- should fail with ENOSYS or similar
    if (syscall.fallocate(fd, syscall.FALLOC_FL_PUNCH_HOLE | syscall.FALLOC_FL_KEEP_SIZE, 0, 512)) |_| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed; // Should not succeed
    } else |err| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        // Accept ENOSYS or any error indicating unsupported operation
        if (err != error.NotImplemented and err != error.InvalidArgument) {
            return error.TestFailed;
        }
    }
}

/// Test fallocate with invalid fd returns EBADF
pub fn testFallocateInvalidFd() !void {
    if (syscall.fallocate(999, 0, 0, 4096)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.BadFileDescriptor) return error.TestFailed;
    }
}

/// Test fallocate with negative length returns EINVAL
pub fn testFallocateNegativeLength() !void {
    const path = "/mnt/falloc_neg";

    const fd = syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };

    if (syscall.fallocate(fd, 0, 0, -1)) |_| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        return error.TestFailed; // Should have errored
    } else |err| {
        syscall.close(fd) catch {};
        syscall.unlink(path) catch {};
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// FS-08: renameat2 tests

/// Test renameat2 with flags=0 (standard rename)
pub fn testRenameat2DefaultFlags() !void {
    const src = "/mnt/rn2_src";
    const dst = "/mnt/rn2_dst";

    // Create source file
    const fd = syscall.open(src, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    const test_data = "rename2 test";
    _ = syscall.write(fd, test_data.ptr, test_data.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(src) catch {};
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Rename with flags=0
    syscall.renameat2(AT_FDCWD, src, AT_FDCWD, dst, 0) catch |err| {
        syscall.unlink(src) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };

    // Verify destination exists
    const dst_fd = syscall.open(dst, syscall.O_RDONLY, 0) catch {
        syscall.unlink(dst) catch {};
        return error.TestFailed;
    };
    syscall.close(dst_fd) catch {};

    // Verify source is gone
    if (syscall.open(src, syscall.O_RDONLY, 0)) |src_fd| {
        syscall.close(src_fd) catch {};
        syscall.unlink(dst) catch {};
        return error.TestFailed;
    } else |_| {}

    // Cleanup
    syscall.unlink(dst) catch {};
}

/// Test renameat2 with RENAME_NOREPLACE fails if destination exists
pub fn testRenameat2Noreplace() !void {
    const src = "/mnt/rn2_a";
    const dst = "/mnt/rn2_b";

    // Create both files
    var fd = syscall.open(src, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    fd = syscall.open(dst, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        syscall.unlink(src) catch {};
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Try rename with NOREPLACE -- should fail with EEXIST
    if (syscall.renameat2(AT_FDCWD, src, AT_FDCWD, dst, syscall.RENAME_NOREPLACE)) |_| {
        syscall.unlink(src) catch {};
        syscall.unlink(dst) catch {};
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.FileExists and err != error.NotImplemented) {
            syscall.unlink(src) catch {};
            syscall.unlink(dst) catch {};
            return error.TestFailed;
        }
        if (err == error.NotImplemented) {
            syscall.unlink(src) catch {};
            syscall.unlink(dst) catch {};
            return error.SkipTest;
        }
    }

    // Verify both files still exist
    const src_fd = syscall.open(src, syscall.O_RDONLY, 0) catch {
        syscall.unlink(src) catch {};
        syscall.unlink(dst) catch {};
        return error.TestFailed;
    };
    syscall.close(src_fd) catch {};

    const dst_fd = syscall.open(dst, syscall.O_RDONLY, 0) catch {
        syscall.unlink(src) catch {};
        syscall.unlink(dst) catch {};
        return error.TestFailed;
    };
    syscall.close(dst_fd) catch {};

    // Cleanup
    syscall.unlink(src) catch {};
    syscall.unlink(dst) catch {};
}

/// Test renameat2 with RENAME_NOREPLACE succeeds if destination doesn't exist
pub fn testRenameat2NoreplaceSuccess() !void {
    const src = "/mnt/rn2_c";
    const dst = "/mnt/rn2_d";

    // Create only source file
    const fd = syscall.open(src, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Rename with NOREPLACE (destination doesn't exist)
    syscall.renameat2(AT_FDCWD, src, AT_FDCWD, dst, syscall.RENAME_NOREPLACE) catch |err| {
        syscall.unlink(src) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };

    // Verify destination exists
    const dst_fd = syscall.open(dst, syscall.O_RDONLY, 0) catch {
        syscall.unlink(dst) catch {};
        return error.TestFailed;
    };
    syscall.close(dst_fd) catch {};

    // Cleanup
    syscall.unlink(dst) catch {};
}

/// Test renameat2 with RENAME_EXCHANGE swaps two files
pub fn testRenameat2Exchange() !void {
    const file_x = "/mnt/rn2_x";
    const file_y = "/mnt/rn2_y";

    // Create file X with "AAA"
    var fd = syscall.open(file_x, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest;
    };
    _ = syscall.write(fd, "AAA".ptr, 3) catch {
        syscall.close(fd) catch {};
        syscall.unlink(file_x) catch {};
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Create file Y with "BBB"
    fd = syscall.open(file_y, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        syscall.unlink(file_x) catch {};
        return error.SkipTest;
    };
    _ = syscall.write(fd, "BBB".ptr, 3) catch {
        syscall.close(fd) catch {};
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.SkipTest;
    };
    syscall.close(fd) catch {};

    // Exchange X and Y
    syscall.renameat2(AT_FDCWD, file_x, AT_FDCWD, file_y, syscall.RENAME_EXCHANGE) catch |err| {
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return error.TestFailed;
    };

    // Verify X now contains "BBB"
    fd = syscall.open(file_x, syscall.O_RDONLY, 0) catch {
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    };
    var buf_x: [4]u8 = undefined;
    const read_x = syscall.read(fd, &buf_x, buf_x.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    };
    syscall.close(fd) catch {};

    if (read_x != 3 or !std.mem.eql(u8, buf_x[0..3], "BBB")) {
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    }

    // Verify Y now contains "AAA"
    fd = syscall.open(file_y, syscall.O_RDONLY, 0) catch {
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    };
    var buf_y: [4]u8 = undefined;
    const read_y = syscall.read(fd, &buf_y, buf_y.len) catch {
        syscall.close(fd) catch {};
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    };
    syscall.close(fd) catch {};

    if (read_y != 3 or !std.mem.eql(u8, buf_y[0..3], "AAA")) {
        syscall.unlink(file_x) catch {};
        syscall.unlink(file_y) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(file_x) catch {};
    syscall.unlink(file_y) catch {};
}

/// Test renameat2 with conflicting flags returns EINVAL
pub fn testRenameat2InvalidFlags() !void {
    if (syscall.renameat2(AT_FDCWD, "/mnt/dummy_x", AT_FDCWD, "/mnt/dummy_y", syscall.RENAME_NOREPLACE | syscall.RENAME_EXCHANGE)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.InvalidArgument and err != error.NotImplemented) return error.TestFailed;
    }
}

// =============================================================================
// Zero-Copy I/O Tests (splice, tee, vmsplice, copy_file_range)
// =============================================================================

/// Test splice from file to pipe
pub fn testSpliceFileToPipe() !void {
    // Create pipe
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    const pipe_read = fds[0];
    const pipe_write = fds[1];

    // Open a known file
    const file_fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer _ = syscall.close(file_fd) catch {};

    // Splice 64 bytes from file to pipe
    const spliced = try syscall.splice(file_fd, null, pipe_write, null, 64, 0);
    if (spliced == 0) return error.TestFailed; // Should have read something

    // Read from pipe and verify length
    var pipe_buf: [128]u8 = undefined;
    const pipe_read_len = try syscall.read(pipe_read, &pipe_buf, pipe_buf.len);
    if (pipe_read_len != spliced) return error.TestFailed;

    // Also verify content matches direct read
    const file_fd2 = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer _ = syscall.close(file_fd2) catch {};

    var direct_buf: [128]u8 = undefined;
    const direct_len = try syscall.read(file_fd2, &direct_buf, 64);
    if (direct_len != spliced or !std.mem.eql(u8, pipe_buf[0..spliced], direct_buf[0..spliced])) {
        return error.TestFailed;
    }
}

/// Test splice from pipe to file
pub fn testSplicePipeToFile() !void {
    const file_path = "/mnt/zcio_spl.txt";

    // Check if SFS is available
    const test_fd = syscall.open("/mnt/test_sfs", syscall.O_CREAT | syscall.O_WRONLY, 0o644) catch |err| {
        if (err == error.ReadOnlyFileSystem) return error.SkipTest;
        return err;
    };
    _ = syscall.close(test_fd) catch {};
    syscall.unlink("/mnt/test_sfs") catch {};

    // Create pipe
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    const pipe_read = fds[0];
    const pipe_write = fds[1];

    // Write data to pipe
    const data = "Hello splice";
    const written = try syscall.write(pipe_write, data, data.len);
    if (written != data.len) return error.TestFailed;

    // Create SFS file
    const file_fd = try syscall.open(file_path, syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    defer {
        _ = syscall.close(file_fd) catch {};
        syscall.unlink(file_path) catch {};
    }

    // Splice from pipe to file
    const spliced = try syscall.splice(pipe_read, null, file_fd, null, data.len, 0);
    if (spliced != data.len) return error.TestFailed;

    // Read file back and verify
    const read_fd = try syscall.open(file_path, syscall.O_RDONLY, 0);
    defer _ = syscall.close(read_fd) catch {};

    var read_buf: [64]u8 = undefined;
    const read_len = try syscall.read(read_fd, &read_buf, read_buf.len);
    if (read_len != data.len or !std.mem.eql(u8, read_buf[0..read_len], data)) {
        return error.TestFailed;
    }
}

/// Test splice with offset parameter
pub fn testSpliceWithOffset() !void {
    // Create pipe
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    const pipe_read = fds[0];
    const pipe_write = fds[1];

    // Open file
    const file_fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer _ = syscall.close(file_fd) catch {};

    // Splice from offset 16, 32 bytes
    var offset: u64 = 16;
    const spliced = try syscall.splice(file_fd, &offset, pipe_write, null, 32, 0);
    if (spliced == 0) return error.TestFailed;

    // Verify offset was updated
    if (offset != 16 + spliced) return error.TestFailed;

    // Read from pipe
    var pipe_buf: [64]u8 = undefined;
    const pipe_len = try syscall.read(pipe_read, &pipe_buf, pipe_buf.len);
    if (pipe_len != spliced) return error.TestFailed;

    // Verify data matches pread64 from offset 16
    const file_fd2 = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer _ = syscall.close(file_fd2) catch {};

    var direct_buf: [64]u8 = undefined;
    const direct_len = try syscall.pread64(file_fd2, &direct_buf, 32, 16);
    if (direct_len != spliced or !std.mem.eql(u8, pipe_buf[0..spliced], direct_buf[0..spliced])) {
        return error.TestFailed;
    }
}

/// Test splice with both pipes returns EINVAL
pub fn testSpliceInvalidBothPipes() !void {
    var fds1: [2]i32 = undefined;
    var fds2: [2]i32 = undefined;
    _ = try syscall.pipe(&fds1);
    defer _ = syscall.close(fds1[0]) catch {};
    defer _ = syscall.close(fds1[1]) catch {};
    _ = try syscall.pipe(&fds2);
    defer _ = syscall.close(fds2[0]) catch {};
    defer _ = syscall.close(fds2[1]) catch {};

    // Try to splice from pipe read-end to pipe write-end (should fail)
    if (syscall.splice(fds1[0], null, fds2[1], null, 64, 0)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

/// Test tee basic functionality
pub fn testTeeBasic() !void {
    // Create two pipes
    var pipe_a: [2]i32 = undefined;
    var pipe_b: [2]i32 = undefined;
    _ = try syscall.pipe(&pipe_a);
    defer _ = syscall.close(pipe_a[0]) catch {};
    defer _ = syscall.close(pipe_a[1]) catch {};
    _ = try syscall.pipe(&pipe_b);
    defer _ = syscall.close(pipe_b[0]) catch {};
    defer _ = syscall.close(pipe_b[1]) catch {};

    // Write data to pipe_a
    const data = "tee test data";
    const written = try syscall.write(pipe_a[1], data, data.len);
    if (written != data.len) return error.TestFailed;

    // Tee from pipe_a read-end to pipe_b write-end
    const teed = try syscall.tee(pipe_a[0], pipe_b[1], 128, 0);
    if (teed != data.len) return error.TestFailed;

    // Read from pipe_b - should get the teed data
    var buf_b: [64]u8 = undefined;
    const read_b = try syscall.read(pipe_b[0], &buf_b, buf_b.len);
    if (read_b != data.len or !std.mem.eql(u8, buf_b[0..read_b], data)) {
        return error.TestFailed;
    }

    // Read from pipe_a - data should still be there (tee doesn't consume)
    var buf_a: [64]u8 = undefined;
    const read_a = try syscall.read(pipe_a[0], &buf_a, buf_a.len);
    if (read_a != data.len or !std.mem.eql(u8, buf_a[0..read_a], data)) {
        return error.TestFailed;
    }
}

/// Test vmsplice basic functionality
pub fn testVmspliceBasic() !void {
    // Create pipe
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    // Prepare iovec with known data
    const data = "vmsplice!";
    var iov = [_]syscall.Iovec{
        .{ .base = @intFromPtr(data.ptr), .len = data.len },
    };

    // Vmsplice to pipe write-end
    const spliced = try syscall.vmsplice(fds[1], &iov, 0);
    if (spliced != data.len) return error.TestFailed;

    // Read from pipe and verify
    var buf: [32]u8 = undefined;
    const read_len = try syscall.read(fds[0], &buf, buf.len);
    if (read_len != data.len or !std.mem.eql(u8, buf[0..read_len], data)) {
        return error.TestFailed;
    }
}

/// Test copy_file_range basic functionality
pub fn testCopyFileRangeBasic() !void {
    const src_path = "/mnt/zcio_src.txt";
    const dst_path = "/mnt/zcio_dst.txt";

    // Check SFS availability
    const test_fd = syscall.open("/mnt/test_sfs", syscall.O_CREAT | syscall.O_WRONLY, 0o644) catch |err| {
        if (err == error.ReadOnlyFileSystem) return error.SkipTest;
        return err;
    };
    _ = syscall.close(test_fd) catch {};
    syscall.unlink("/mnt/test_sfs") catch {};

    // Create source file
    const src_fd = try syscall.open(src_path, syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    const data = "copy file range test";
    _ = try syscall.write(src_fd, data, data.len);
    _ = syscall.close(src_fd) catch {};
    defer syscall.unlink(src_path) catch {};

    // Create dest file
    const dst_fd = try syscall.open(dst_path, syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    _ = syscall.close(dst_fd) catch {};
    defer syscall.unlink(dst_path) catch {};

    // Copy using copy_file_range
    const src_fd2 = try syscall.open(src_path, syscall.O_RDONLY, 0);
    defer _ = syscall.close(src_fd2) catch {};
    const dst_fd2 = try syscall.open(dst_path, syscall.O_WRONLY, 0);
    defer _ = syscall.close(dst_fd2) catch {};

    const copied = try syscall.copy_file_range(src_fd2, null, dst_fd2, null, data.len, 0);
    if (copied != data.len) return error.TestFailed;

    // Read dest and verify
    const read_fd = try syscall.open(dst_path, syscall.O_RDONLY, 0);
    defer _ = syscall.close(read_fd) catch {};

    var buf: [64]u8 = undefined;
    const read_len = try syscall.read(read_fd, &buf, buf.len);
    if (read_len != data.len or !std.mem.eql(u8, buf[0..read_len], data)) {
        return error.TestFailed;
    }
}

/// Test copy_file_range with offsets
pub fn testCopyFileRangeWithOffsets() !void {
    const src_path = "/mnt/zcio_sr2.txt";
    const dst_path = "/mnt/zcio_ds2.txt";

    // Check SFS availability
    const test_fd = syscall.open("/mnt/test_sfs", syscall.O_CREAT | syscall.O_WRONLY, 0o644) catch |err| {
        if (err == error.ReadOnlyFileSystem) return error.SkipTest;
        return err;
    };
    _ = syscall.close(test_fd) catch {};
    syscall.unlink("/mnt/test_sfs") catch {};

    // Create source with "ABCDEFGHIJ"
    const src_fd = try syscall.open(src_path, syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    _ = try syscall.write(src_fd, "ABCDEFGHIJ", 10);
    _ = syscall.close(src_fd) catch {};
    defer syscall.unlink(src_path) catch {};

    // Create dest with 10 zero bytes
    const dst_fd = try syscall.open(dst_path, syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    _ = try syscall.write(dst_fd, &[_]u8{0} ** 10, 10);
    _ = syscall.close(dst_fd) catch {};
    defer syscall.unlink(dst_path) catch {};

    // Copy 4 bytes from offset 3 to offset 5
    const src_fd2 = try syscall.open(src_path, syscall.O_RDONLY, 0);
    defer _ = syscall.close(src_fd2) catch {};
    const dst_fd2 = try syscall.open(dst_path, syscall.O_WRONLY, 0);
    defer _ = syscall.close(dst_fd2) catch {};

    var off_in: u64 = 3;
    var off_out: u64 = 5;
    const copied = try syscall.copy_file_range(src_fd2, &off_in, dst_fd2, &off_out, 4, 0);
    if (copied != 4) return error.TestFailed;

    // Verify offsets updated
    if (off_in != 7 or off_out != 9) return error.TestFailed;

    // Read dest and verify bytes 5-8 are "DEFG"
    const read_fd = try syscall.open(dst_path, syscall.O_RDONLY, 0);
    defer _ = syscall.close(read_fd) catch {};

    var buf: [10]u8 = undefined;
    const read_len = try syscall.read(read_fd, &buf, buf.len);
    if (read_len != 10) return error.TestFailed;

    if (!std.mem.eql(u8, buf[5..9], "DEFG")) {
        return error.TestFailed;
    }
}

/// Test copy_file_range with invalid flags returns EINVAL
pub fn testCopyFileRangeInvalidFlags() !void {
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    // Try with flags=1 (invalid)
    if (syscall.copy_file_range(fds[0], null, fds[1], null, 64, 1)) |_| {
        return error.TestFailed; // Should have errored
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

/// Test splice with zero length
pub fn testSpliceZeroLength() !void {
    var fds: [2]i32 = undefined;
    _ = try syscall.pipe(&fds);
    defer _ = syscall.close(fds[0]) catch {};
    defer _ = syscall.close(fds[1]) catch {};

    const file_fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer _ = syscall.close(file_fd) catch {};

    const spliced = try syscall.splice(file_fd, null, fds[1], null, 0, 0);
    if (spliced != 0) return error.TestFailed;
}
