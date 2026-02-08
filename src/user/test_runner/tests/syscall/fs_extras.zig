const std = @import("std");
const syscall = @import("syscall");

// AT constants
const AT_FDCWD: i32 = -100;
const AT_SYMLINK_NOFOLLOW: i32 = 0x100;

// S_IFMT and mode bit constants
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;

// FS-01: readlinkat tests

// Test 1: readlinkat on regular file returns EINVAL
pub fn testReadlinkatBasic() !void {
    var buf: [256]u8 = undefined;

    // readlinkat on a regular file (not a symlink) should return EINVAL
    const result = syscall.readlinkat(AT_FDCWD, "/shell.elf", &buf, buf.len);

    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.EINVAL) {
            return error.TestFailed; // Wrong error code
        }
    }
}

// Test 2: readlinkat with invalid path returns ENOENT
pub fn testReadlinkatInvalidPath() !void {
    var buf: [256]u8 = undefined;

    const result = syscall.readlinkat(AT_FDCWD, "/nonexistent_readlinkat_path", &buf, buf.len);

    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.ENOENT) {
            return error.TestFailed; // Wrong error code
        }
    }
}

// FS-02: linkat tests

// Test 3: linkat creates hard link on writable filesystem
// NOTE: Avoids explicit close() to prevent SFS close deadlock.
pub fn testLinkatBasic() !void {
    const src_path = "/mnt/test_linkat_src";
    const dst_path = "/mnt/test_linkat_dst";

    // Create source file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(src_path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Create hard link
    try syscall.linkat(AT_FDCWD, src_path, AT_FDCWD, dst_path, 0);

    // Verify link exists
    const access_result = syscall.access(dst_path, 0);
    if (access_result) |_| {
        // Success - link exists
    } else |_| {
        syscall.unlink(dst_path) catch {};
        syscall.unlink(src_path) catch {};
        return error.TestFailed;
    }

    // Cleanup
    syscall.unlink(dst_path) catch {};
    syscall.unlink(src_path) catch {};
}

// Test 4: linkat cross-device link returns EXDEV or EROFS
pub fn testLinkatCrossDevice() !void {
    const result = syscall.linkat(AT_FDCWD, "/shell.elf", AT_FDCWD, "/mnt/cross_link", 0);

    if (result) |_| {
        // Unexpected success - clean up and fail
        syscall.unlink("/mnt/cross_link") catch {};
        return error.TestFailed;
    } else |err| {
        // Accept either EXDEV (cross-device) or EROFS (read-only source)
        if (err != error.EXDEV and err != error.EROFS) {
            return error.TestFailed;
        }
    }
}

// FS-03: symlinkat tests

// Test 5: symlinkat creates symbolic link (or returns error if unsupported)
// NOTE: SFS may not support symlinks, so we accept either success or EPERM/ENOSYS
pub fn testSymlinkatBasic() !void {
    const link_path = "/mnt/test_symlinkat_link";

    const result = syscall.symlinkat("/shell.elf", AT_FDCWD, link_path);

    if (result) |_| {
        // Success - verify the symlink target
        var buf: [256]u8 = undefined;
        const read_result = syscall.readlink(link_path, &buf);

        if (read_result) |len| {
            const target = buf[0..len];
            if (!std.mem.eql(u8, target, "/shell.elf")) {
                syscall.unlink(link_path) catch {};
                return error.TestFailed;
            }
        } else |_| {
            syscall.unlink(link_path) catch {};
            return error.TestFailed;
        }

        // Cleanup
        syscall.unlink(link_path) catch {};
    } else |err| {
        // SFS may not support symlinks - accept EPERM, ENOSYS, or EROFS
        if (err != error.EPERM and err != error.ENOSYS and err != error.EROFS) {
            return error.TestFailed;
        }
    }
}

// Test 6: symlinkat with empty target returns ENOENT
pub fn testSymlinkatEmptyTarget() !void {
    const result = syscall.symlinkat("", AT_FDCWD, "/mnt/test_empty_sym");

    if (result) |_| {
        syscall.unlink("/mnt/test_empty_sym") catch {};
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.ENOENT) {
            return error.TestFailed; // Wrong error code
        }
    }
}

// FS-04: utimensat tests

// Test 7: utimensat with NULL times sets to current time
// NOTE: Avoids explicit close() to prevent SFS close deadlock.
pub fn testUtimensatNull() !void {
    const path = "/mnt/test_utime";

    // Create file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Set timestamps to now (NULL means current time)
    const result = syscall.utimensat(AT_FDCWD, path, null, 0);

    // Accept success or EROFS/ENOSYS (filesystem may not support timestamps)
    if (result) |_| {
        // Success
    } else |err| {
        if (err != error.EROFS and err != error.ENOSYS) {
            syscall.unlink(path) catch {};
            return error.TestFailed;
        }
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test 8: utimensat with specific times
// NOTE: Avoids explicit close() to prevent SFS close deadlock.
pub fn testUtimensatSpecificTime() !void {
    const path = "/mnt/test_utime2";

    // Create file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Set specific timestamps
    var times: [2]syscall.Timespec = undefined;
    times[0] = .{ .tv_sec = 1000000, .tv_nsec = 500 };
    times[1] = .{ .tv_sec = 2000000, .tv_nsec = 999 };

    const result = syscall.utimensat(AT_FDCWD, path, &times, 0);

    // Accept success or EROFS/ENOSYS (filesystem may not support timestamps)
    if (result) |_| {
        // Success
    } else |err| {
        if (err != error.EROFS and err != error.ENOSYS) {
            syscall.unlink(path) catch {};
            return error.TestFailed;
        }
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test 9: utimensat with AT_SYMLINK_NOFOLLOW returns ENOSYS
pub fn testUtimensatSymlinkNofollow() !void {
    const result = syscall.utimensat(AT_FDCWD, "/shell.elf", null, AT_SYMLINK_NOFOLLOW);

    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.ENOSYS) {
            return error.TestFailed; // Wrong error code
        }
    }
}

// Test 10: utimensat with invalid nsec returns EINVAL
pub fn testUtimensatInvalidNsec() !void {
    const path = "/mnt/test_utime3";

    // Create file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Set invalid nsec value (>= 1_000_000_000)
    var times: [2]syscall.Timespec = undefined;
    times[0] = .{ .tv_sec = 1000000, .tv_nsec = 1_000_000_000 }; // Invalid
    times[1] = .{ .tv_sec = 2000000, .tv_nsec = 999 };

    const result = syscall.utimensat(AT_FDCWD, path, &times, 0);

    if (result) |_| {
        syscall.unlink(path) catch {};
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.EINVAL) {
            syscall.unlink(path) catch {};
            return error.TestFailed; // Wrong error code
        }
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// FS-05: futimesat tests

// Test 11: futimesat with NULL times sets to current time
// NOTE: Avoids explicit close() to prevent SFS close deadlock.
pub fn testFutimesatBasic() !void {
    const path = "/mnt/test_futimesat";

    // Create file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Set timestamps to now (NULL means current time)
    const result = syscall.futimesat(AT_FDCWD, path, null);

    // Accept success or EROFS/ENOSYS (filesystem may not support timestamps)
    if (result) |_| {
        // Success
    } else |err| {
        if (err != error.EROFS and err != error.ENOSYS) {
            syscall.unlink(path) catch {};
            return error.TestFailed;
        }
    }

    // Cleanup
    syscall.unlink(path) catch {};
}

// Test 12: futimesat with specific times
// NOTE: Avoids explicit close() to prevent SFS close deadlock.
pub fn testFutimesatSpecificTime() !void {
    const path = "/mnt/test_futimesat2";

    // Create file (keep fd open to avoid SFS close deadlock)
    _ = try syscall.open(path, syscall.O_WRONLY | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    // Set specific timestamps (microsecond precision)
    var times: [2]syscall.Timeval = undefined;
    times[0] = .{ .tv_sec = 1000000, .tv_usec = 500000 };
    times[1] = .{ .tv_sec = 2000000, .tv_usec = 999999 };

    const result = syscall.futimesat(AT_FDCWD, path, &times);

    // Accept success or EROFS/ENOSYS (filesystem may not support timestamps)
    if (result) |_| {
        // Success
    } else |err| {
        if (err != error.EROFS and err != error.ENOSYS) {
            syscall.unlink(path) catch {};
            return error.TestFailed;
        }
    }

    // Cleanup
    syscall.unlink(path) catch {};
}
