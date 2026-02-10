const syscall = @import("syscall");

// Test 1: getrlimit returns meaningful values for RLIMIT_NOFILE
pub fn testGetrlimitNofile() !void {
    var limit: syscall.Rlimit = undefined;
    try syscall.getrlimit(syscall.RLIMIT_NOFILE, &limit);

    // Verify non-zero limits (kernel should have defaults)
    if (limit.rlim_cur == 0 or limit.rlim_max == 0) return error.TestFailed;
    // Verify soft <= hard
    if (limit.rlim_cur > limit.rlim_max) return error.TestFailed;
}

// Test 2: getrlimit returns meaningful values for RLIMIT_AS
pub fn testGetrlimitAs() !void {
    var limit: syscall.Rlimit = undefined;
    try syscall.getrlimit(syscall.RLIMIT_AS, &limit);

    // Address space limit should be set (even if unlimited)
    // Just verify the syscall works and returns something
    if (limit.rlim_cur == 0 and limit.rlim_max == 0) return error.TestFailed;
}

// Test 3: setrlimit accepts valid limit (lowering soft limit)
pub fn testSetrlimitLowerSoft() !void {
    // Get current limit
    var old_limit: syscall.Rlimit = undefined;
    try syscall.getrlimit(syscall.RLIMIT_NOFILE, &old_limit);

    // Try to lower soft limit (non-root can do this)
    if (old_limit.rlim_cur > 10) {
        var new_limit: syscall.Rlimit = .{
            .rlim_cur = old_limit.rlim_cur - 1,
            .rlim_max = old_limit.rlim_max,
        };

        // This should succeed (lowering soft limit)
        syscall.setrlimit(syscall.RLIMIT_NOFILE, &new_limit) catch |err| {
            // If we can't set it, that's okay - just verify the call doesn't crash
            if (err != error.EPERM) return err;
            return;
        };

        // Verify it was set
        var check_limit: syscall.Rlimit = undefined;
        try syscall.getrlimit(syscall.RLIMIT_NOFILE, &check_limit);
        if (check_limit.rlim_cur != new_limit.rlim_cur) return error.TestFailed;

        // Restore original limit
        _ = syscall.setrlimit(syscall.RLIMIT_NOFILE, &old_limit) catch {};
    }
}

// Test 4: setrlimit rejects soft > hard
pub fn testSetrlimitRejectsSoftGreaterThanHard() !void {
    var bad_limit: syscall.Rlimit = .{
        .rlim_cur = 2000,
        .rlim_max = 1000,
    };

    // This should fail with EINVAL
    const result = syscall.setrlimit(syscall.RLIMIT_NOFILE, &bad_limit);
    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        if (err != error.EINVAL) return error.TestFailed;
    }
}

// Test 5: getrlimit works for multiple resource types
pub fn testGetrlimitMultipleResources() !void {
    const resources = [_]c_int{
        syscall.RLIMIT_NOFILE,
        syscall.RLIMIT_AS,
        syscall.RLIMIT_STACK,
        syscall.RLIMIT_CORE,
    };

    for (resources) |resource| {
        var limit: syscall.Rlimit = undefined;
        try syscall.getrlimit(resource, &limit);
        // Just verify each call succeeds
        if (limit.rlim_cur == 0 and limit.rlim_max == 0) return error.TestFailed;
    }
}
