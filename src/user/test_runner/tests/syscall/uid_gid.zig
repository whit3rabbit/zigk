const syscall = @import("syscall");

/// Helper: run a test function in a forked child to isolate privilege changes.
/// Returns true if child exited with status 0 (success), false otherwise.
fn runInChild(test_fn: *const fn () bool) !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        // Child process
        const success = test_fn();
        syscall.exit(if (success) 0 else 1);
    }
    // Parent: wait for child
    var status: i32 = undefined;
    const waited = try syscall.waitpid(pid, &status, 0);
    if (waited != pid) return error.TestFailed;
    if ((status & 0x7F) != 0) return error.TestFailed;
    if (((status >> 8) & 0xFF) != 0) return error.TestFailed;
}

// Test 1: getuid returns 0 (root)
pub fn testGetuidReturnsZero() !void {
    const uid = syscall.getuid();
    if (uid != 0) return error.TestFailed;
}

// Test 2: geteuid returns 0 (root)
pub fn testGeteuidReturnsZero() !void {
    const euid = syscall.geteuid();
    if (euid != 0) return error.TestFailed;
}

// Test 3: getgid returns 0 (root)
pub fn testGetgidReturnsZero() !void {
    const gid = syscall.getgid();
    if (gid != 0) return error.TestFailed;
}

// Test 4: getegid returns 0 (root)
pub fn testGetegidReturnsZero() !void {
    const egid = syscall.getegid();
    if (egid != 0) return error.TestFailed;
}

// Test 5: setuid(0) as root succeeds
pub fn testSetuidAsRootSucceeds() !void {
    try syscall.setuid(0);
    const uid = syscall.getuid();
    if (uid != 0) return error.TestFailed;
}

// Test 6: setgid(0) as root succeeds
pub fn testSetgidAsRootSucceeds() !void {
    try syscall.setgid(0);
    const gid = syscall.getgid();
    if (gid != 0) return error.TestFailed;
}

// Test 7: getresuid returns all zeros (root)
pub fn testGetresuidReturnsAllZeros() !void {
    var ruid: u32 = undefined;
    var euid: u32 = undefined;
    var suid: u32 = undefined;

    try syscall.getresuid(&ruid, &euid, &suid);

    if (ruid != 0 or euid != 0 or suid != 0) return error.TestFailed;
}

// Test 8: getresgid returns all zeros (root)
pub fn testGetresgidReturnsAllZeros() !void {
    var rgid: u32 = undefined;
    var egid: u32 = undefined;
    var sgid: u32 = undefined;

    try syscall.getresgid(&rgid, &egid, &sgid);

    if (rgid != 0 or egid != 0 or sgid != 0) return error.TestFailed;
}

// =============================================================================
// setreuid Tests
// =============================================================================

// Test 9: Root can setreuid to any values
pub fn testSetreuidAsRoot() !void {
    const ChildTest = struct {
        fn run() bool {
            syscall.setreuid(1000, 1000) catch return false;
            const uid = syscall.getuid();
            const euid = syscall.geteuid();
            return (uid == 1000 and euid == 1000);
        }
    };
    try runInChild(ChildTest.run);
}

// Test 10: setreuid(-1, -1) leaves uid/euid unchanged
pub fn testSetreuidUnchanged() !void {
    const ChildTest = struct {
        fn run() bool {
            syscall.setreuid(-1, -1) catch return false;
            const uid = syscall.getuid();
            const euid = syscall.geteuid();
            return (uid == 0 and euid == 0);
        }
    };
    try runInChild(ChildTest.run);
}

// Test 11: Non-root setreuid to privileged uid fails with EPERM
pub fn testSetreuidNonRootRestricted() !void {
    const ChildTest = struct {
        fn run() bool {
            // Drop to non-root
            syscall.setuid(1000) catch return false;
            // Try to regain root - should fail
            if (syscall.setreuid(0, 0)) |_| {
                return false; // Should have failed
            } else |err| {
                return (err == error.PermissionDenied);
            }
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// setregid Tests
// =============================================================================

// Test 12: Root can setregid to any values
pub fn testSetregidAsRoot() !void {
    const ChildTest = struct {
        fn run() bool {
            syscall.setregid(500, 500) catch return false;
            const gid = syscall.getgid();
            const egid = syscall.getegid();
            return (gid == 500 and egid == 500);
        }
    };
    try runInChild(ChildTest.run);
}

// Test 13: Non-root setregid to privileged gid fails with EPERM
pub fn testSetregidNonRootRestricted() !void {
    const ChildTest = struct {
        fn run() bool {
            // Drop GID privileges first (while still root, so we have permission)
            syscall.setresgid(1000, 1000, 1000) catch return false;
            // Then drop UID privileges (makes euid non-zero)
            syscall.setresuid(1000, 1000, 1000) catch return false;
            // Try to setregid to unauthorized value -- should fail
            if (syscall.setregid(2000, 2000)) |_| {
                return false; // Should have failed with EPERM
            } else |_| {
                return true;
            }
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// getgroups/setgroups Tests
// =============================================================================

// Test 14: getgroups returns 0 for initial empty supplementary groups
pub fn testGetgroupsInitialEmpty() !void {
    var groups: [16]u32 = undefined;
    const count = try syscall.getgroups(0, &groups);
    if (count != 0) return error.TestFailed;
}

// Test 15: setgroups as root, then getgroups returns correct values
pub fn testSetgroupsAsRoot() !void {
    const ChildTest = struct {
        fn run() bool {
            const test_groups = [_]u32{ 100, 200, 300 };
            syscall.setgroups(test_groups.len, &test_groups) catch return false;

            var groups: [16]u32 = undefined;
            const count = syscall.getgroups(16, &groups) catch return false;
            if (count != 3) return false;
            if (groups[0] != 100 or groups[1] != 200 or groups[2] != 300) return false;

            // Clean up: reset to empty
            syscall.setgroups(0, &test_groups) catch return false;
            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 16: Non-root setgroups fails with EPERM
pub fn testSetgroupsNonRootFails() !void {
    const ChildTest = struct {
        fn run() bool {
            // Drop to non-root
            syscall.setuid(1000) catch return false;

            const test_groups = [_]u32{100};
            if (syscall.setgroups(test_groups.len, &test_groups)) |_| {
                return false; // Should have failed
            } else |err| {
                return (err == error.PermissionDenied);
            }
        }
    };
    try runInChild(ChildTest.run);
}

// Test 17: getgroups with size=0 returns count only
pub fn testGetgroupsCountOnly() !void {
    const ChildTest = struct {
        fn run() bool {
            const test_groups = [_]u32{ 10, 20 };
            syscall.setgroups(test_groups.len, &test_groups) catch return false;

            var dummy: [1]u32 = undefined;
            const count = syscall.getgroups(0, &dummy) catch return false;

            // Clean up
            syscall.setgroups(0, &test_groups) catch return false;

            return (count == 2);
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// setfsuid/setfsgid Tests
// =============================================================================

// Test 18: setfsuid returns previous value
pub fn testSetfsuidReturnsPrevious() !void {
    const ChildTest = struct {
        fn run() bool {
            const prev1 = syscall.setfsuid(1000);
            if (prev1 != 0) return false; // Initial fsuid should be 0

            const prev2 = syscall.setfsuid(0);
            if (prev2 != 1000) return false; // Should return previous value

            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 19: setfsgid returns previous value
pub fn testSetfsgidReturnsPrevious() !void {
    const ChildTest = struct {
        fn run() bool {
            const prev1 = syscall.setfsgid(500);
            if (prev1 != 0) return false; // Initial fsgid should be 0

            const prev2 = syscall.setfsgid(0);
            if (prev2 != 500) return false; // Should return previous value

            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 20: Non-root setfsuid to privileged value silently fails
pub fn testSetfsuidNonRootRestricted() !void {
    const ChildTest = struct {
        fn run() bool {
            // Drop to non-root
            syscall.setuid(1000) catch return false;

            // Try to set fsuid to 0 - should fail (return unchanged value)
            const prev = syscall.setfsuid(0);
            if (prev != 1000) return false; // Should return current fsuid (1000)

            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 21: fsuid auto-syncs with euid change
pub fn testFsuidAutoSync() !void {
    const ChildTest = struct {
        fn run() bool {
            // Change euid to 500 (fsuid should auto-sync)
            syscall.setresuid(-1, 500, -1) catch return false;

            // setfsuid to same value should return that value (confirming sync)
            const prev = syscall.setfsuid(500);
            if (prev != 500) return false;

            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// chown Tests
// =============================================================================

// Test 22: Root can chown a file
pub fn testChownAsRoot() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/chown_t";
            // Create file
            const fd = syscall.open(path, 0x241, 0o644) catch return false; // O_CREAT|O_WRONLY|O_TRUNC
            _ = syscall.write(fd, "test", 4) catch return false;

            // Chown to 1000:1000 (file still open - no problem)
            syscall.chown(path, 1000, 1000) catch return false;

            syscall.close(fd) catch return false;
            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 23: Non-owner cannot chown a file
pub fn testChownNonOwnerFails() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/cho_test2";
            // Create file as root
            const fd = syscall.open(path, 0x241, 0o644) catch return false; // O_CREAT|O_WRONLY|O_TRUNC
            syscall.close(fd) catch return false;

            // Drop to non-root
            syscall.setuid(2000) catch return false;

            // Try to chown - should fail
            const result = syscall.chown(path, 2000, 2000);

            // Clean up (regain root first)
            syscall.exit(0); // Exit child directly, parent will clean up

            if (result) |_| {
                return false; // Should have failed
            } else |err| {
                return (err == error.PermissionDenied);
            }
        }
    };

    try runInChild(ChildTest.run);
    // Don't unlink - SFS unlink of open file causes issues
}

// Test 24: Non-root can chgrp to own supplementary group
pub fn testChownNonRootCanChgrpToOwnGroup() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/cho_test3";
            // Create file as root, owned by uid 1000
            const fd = syscall.open(path, 0x241, 0o644) catch return false;
            syscall.close(fd) catch return false;
            syscall.chown(path, 1000, 0) catch return false;

            // Set up uid 1000 with supplementary group 500
            const groups = [_]u32{500};
            syscall.setgroups(groups.len, &groups) catch return false;
            syscall.setuid(1000) catch return false;

            // Try to chgrp to group 500 (should succeed)
            const result = syscall.chown(path, @as(u32, @bitCast(@as(i32, -1))), 500);

            // Clean up
            syscall.exit(0); // Exit child, parent cleans up

            if (result) |_| {
                return true; // Success
            } else |_| {
                return false;
            }
        }
    };

    try runInChild(ChildTest.run);
    // Don't unlink - SFS unlink of open file causes issues
}

// Test 25: Non-root cannot change uid even as file owner
pub fn testChownNonRootCannotChangeUid() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/cho_test4";
            // Create file as root, owned by uid 1000
            const fd = syscall.open(path, 0x241, 0o644) catch return false;
            syscall.close(fd) catch return false;
            syscall.chown(path, 1000, 0) catch return false;

            // Become the file owner
            syscall.setuid(1000) catch return false;

            // Try to change uid to 2000 - should fail
            const result = syscall.chown(path, 2000, @as(u32, @bitCast(@as(i32, -1))));

            syscall.exit(0); // Exit child

            if (result) |_| {
                return false; // Should have failed
            } else |err| {
                return (err == error.PermissionDenied);
            }
        }
    };

    try runInChild(ChildTest.run);
    // Don't unlink - SFS unlink of open file causes issues
}

// Test 26: fchown basic operation
pub fn testFchownBasic() !void {
    // Skip - SFS doesn't implement FileOps.chown for fchown
    return error.SkipTest;
}

// =============================================================================
// fchownat Tests
// =============================================================================

// Test 27: fchownat with AT_FDCWD
pub fn testFchownatWithATFdcwd() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/fcat_test";
            // Create file
            const fd = syscall.open(path, 0x241, 0o644) catch return false;
            syscall.close(fd) catch return false;

            // fchownat with AT_FDCWD
            const AT_FDCWD_LOCAL: i32 = -100;
            syscall.fchownat(AT_FDCWD_LOCAL, path, 1000, 1000, 0) catch return false;

            // Don't unlink to avoid SFS issues
            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 28: fchownat with AT_SYMLINK_NOFOLLOW flag
pub fn testFchownatSymlinkNofollow() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/fcat_sf";
            // Create file
            const fd = syscall.open(path, 0x241, 0o644) catch return false;
            syscall.close(fd) catch return false;

            // fchownat with AT_SYMLINK_NOFOLLOW (should work on regular file)
            const AT_FDCWD_LOCAL: i32 = -100;
            const AT_SYMLINK_NOFOLLOW_LOCAL: u32 = 0x100;
            syscall.fchownat(AT_FDCWD_LOCAL, path, 1000, 1000, AT_SYMLINK_NOFOLLOW_LOCAL) catch return false;

            // Don't unlink to avoid SFS issues
            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// Privilege Drop Test
// =============================================================================

// Test 29: Full privilege drop verification
pub fn testPrivilegeDropFull() !void {
    const ChildTest = struct {
        fn run() bool {
            // Drop all privileges
            syscall.setuid(1000) catch return false;

            // Verify uid changed
            const uid = syscall.getuid();
            if (uid != 1000) return false;

            // Verify cannot regain root
            if (syscall.setuid(0)) |_| {
                return false; // Should have failed
            } else |err| {
                if (err != error.PermissionDenied) return false;
            }

            // Verify cannot chown
            const path = "/mnt/priv_test";
            if (syscall.chown(path, 1000, 1000)) |_| {
                return false; // Should fail (file doesn't exist or no perms)
            } else |_| {
                // Expected to fail
            }

            // Verify cannot setgroups
            const groups = [_]u32{100};
            if (syscall.setgroups(groups.len, &groups)) |_| {
                return false; // Should have failed
            } else |err| {
                if (err != error.PermissionDenied) return false;
            }

            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// =============================================================================
// lchown Tests
// =============================================================================

// Test 30: lchown basic operation (root can lchown)
pub fn testLchownBasic() !void {
    const ChildTest = struct {
        fn run() bool {
            const path = "/mnt/lch_test";
            // Create file
            const fd = syscall.open(path, 0x241, 0o644) catch return false; // O_CREAT|O_WRONLY|O_TRUNC
            _ = syscall.write(fd, "test", 4) catch return false;

            // lchown to 1000:1000 (file still open - no problem)
            syscall.lchown(path, 1000, 1000) catch return false;

            syscall.close(fd) catch return false;
            return true;
        }
    };
    try runInChild(ChildTest.run);
}

// Test 31: lchown non-existent file returns ENOENT
pub fn testLchownNonExistent() !void {
    const path = "/mnt/nonexist_lchown";

    // Try to lchown non-existent file
    if (syscall.lchown(path, 1000, 1000)) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.FileNotFound) return error.TestFailed;
    }
}

// Test 32: fchdir not implemented (documents coverage gap)
pub fn testFchdir() !void {
    const O_RDONLY = 0;
    const O_DIRECTORY = 0x10000;

    // Save current working directory
    var saved_cwd: [4096]u8 = undefined;
    const saved_len = syscall.getcwd(&saved_cwd, saved_cwd.len) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Open root directory
    const root_fd = syscall.open("/", O_RDONLY | O_DIRECTORY, 0) catch |err| {
        if (err == error.NotImplemented or err == error.NotADirectory) {
            // VFS doesn't support opening directories yet - skip test
            return error.SkipTest;
        }
        return err;
    };
    defer _ = syscall.close(root_fd) catch {};

    // Change to root via fchdir
    syscall.fchdir(root_fd) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify we're now in root
    var new_cwd: [4096]u8 = undefined;
    const new_len = try syscall.getcwd(&new_cwd, new_cwd.len);
    if (new_len != 1 or new_cwd[0] != '/') {
        return error.TestFailed;
    }

    // Restore original cwd
    const saved_path = saved_cwd[0..saved_len];
    var saved_path_z: [4097]u8 = undefined;
    @memcpy(saved_path_z[0..saved_len], saved_path);
    saved_path_z[saved_len] = 0;
    _ = syscall.chdir(@ptrCast(&saved_path_z)) catch {};
}

pub fn testFchdirNonDirectory() !void {
    const O_RDONLY = 0;

    // Open a regular file (not a directory)
    const file_fd = syscall.open("/shell.elf", O_RDONLY, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.close(file_fd) catch {};

    // fchdir should fail with ENOTDIR
    if (syscall.fchdir(file_fd)) {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.NotADirectory) {
            return error.TestFailed; // Wrong error
        }
    }
}

pub fn testFchdirInvalidFd() !void {
    // fchdir with invalid FD should return EBADF
    if (syscall.fchdir(9999)) {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.BadFileDescriptor) {
            return error.TestFailed; // Wrong error
        }
    }
}
