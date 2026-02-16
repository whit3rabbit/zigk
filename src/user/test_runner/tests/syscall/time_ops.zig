const syscall = @import("syscall");

// Test 1: nanosleep with a short duration returns without error
pub fn testNanosleepBasic() !void {
    const req = syscall.Timespec{
        .tv_sec = 0,
        .tv_nsec = 10_000_000, // 10ms
    };
    try syscall.nanosleep(&req, null);
}

// Test 2: clock_gettime(MONOTONIC) returns non-negative time
pub fn testClockGettimeMonotonic() !void {
    var ts = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 0 };
    try syscall.clock_gettime(.MONOTONIC, &ts);

    if (ts.tv_sec < 0) return error.TestFailed;
    if (ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) return error.TestFailed;
}

// Test 3: clock_gettime(REALTIME) returns non-negative time
pub fn testClockGettimeRealtime() !void {
    var ts = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 0 };
    try syscall.clock_gettime(.REALTIME, &ts);

    if (ts.tv_sec < 0) return error.TestFailed;
    if (ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) return error.TestFailed;
}

// Test 4: second monotonic call >= first
pub fn testClockGettimeMonotonic2Calls() !void {
    var ts1 = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 0 };
    var ts2 = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 0 };

    try syscall.clock_gettime(.MONOTONIC, &ts1);
    try syscall.clock_gettime(.MONOTONIC, &ts2);

    // ts2 >= ts1
    if (ts2.tv_sec < ts1.tv_sec) return error.TestFailed;
    if (ts2.tv_sec == ts1.tv_sec and ts2.tv_nsec < ts1.tv_nsec) return error.TestFailed;
}

// Test 5: clock_getres returns valid resolution
pub fn testClockGetresMonotonic() !void {
    var res = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 0 };
    try syscall.clock_getres(.MONOTONIC, &res);

    // Resolution should be non-negative and reasonable
    if (res.tv_sec < 0 or res.tv_nsec < 0) return error.TestFailed;
    // At least nanosecond-level or better (tv_sec should be 0 for a fast clock)
    if (res.tv_sec > 1) return error.TestFailed;
}

// Test 6: gettimeofday returns valid tv_sec
pub fn testGettimeofdayBasic() !void {
    var tv = syscall.Timeval{ .tv_sec = 0, .tv_usec = 0 };
    try syscall.gettimeofday(&tv);

    // tv_sec should be non-negative
    if (tv.tv_sec < 0) return error.TestFailed;
    // tv_usec should be in range [0, 999999]
    if (tv.tv_usec < 0 or tv.tv_usec >= 1_000_000) return error.TestFailed;
}

// Test 7: sleep_ms returns ok
pub fn testSleepMsBasic() !void {
    try syscall.sleep_ms(10);
}

// Test 8: sched_yield returns without error
pub fn testSchedYield() !void {
    try syscall.sched_yield();
}

// =============================================================================
// settimeofday Tests
// =============================================================================

// Test 9: settimeofday basic (round-trip with gettimeofday)
pub fn testSettimeofdayBasic() !void {
    // Get current time
    var tv = syscall.Timeval{ .tv_sec = 0, .tv_usec = 0 };
    try syscall.gettimeofday(&tv);

    // Set time to same value (no actual change)
    syscall.settimeofday(&tv) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    // Success if no error
}

// Test 10: settimeofday privilege check (non-root fails with EPERM)
pub fn testSettimeofdayPrivilegeCheck() !void {
    const pid = syscall.fork() catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    if (pid == 0) {
        // Child: drop to uid 1000, try to settimeofday
        _ = syscall.setuid(1000) catch syscall.exit(1);

        var tv = syscall.Timeval{ .tv_sec = 1000, .tv_usec = 0 };
        const result = syscall.settimeofday(&tv);
        if (result) |_| {
            syscall.exit(1); // Should have failed
        } else |err| {
            if (err == error.PermissionDenied) {
                syscall.exit(0); // Success - got EPERM
            } else {
                syscall.exit(1); // Wrong error
            }
        }
        unreachable;
    }

    // Parent: wait for child
    var status: i32 = undefined;
    const waited = try syscall.waitpid(pid, &status, 0);
    if (waited != pid) return error.TestFailed;
    if ((status & 0x7F) != 0) return error.TestFailed;
    if (((status >> 8) & 0xFF) != 0) return error.TestFailed;
}

// Test 11: settimeofday invalid value (negative tv_sec or tv_usec >= 1000000)
pub fn testSettimeofdayInvalidValue() !void {
    // Try negative tv_usec
    var tv1 = syscall.Timeval{ .tv_sec = 1000, .tv_usec = -1 };
    const result1 = syscall.settimeofday(&tv1);
    if (result1) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        if (err != error.InvalidArgument) return error.TestFailed;
    }

    // Try tv_usec >= 1000000
    var tv2 = syscall.Timeval{ .tv_sec = 1000, .tv_usec = 1_000_000 };
    const result2 = syscall.settimeofday(&tv2);
    if (result2) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}
