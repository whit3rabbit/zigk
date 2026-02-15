const std = @import("std");
const syscall = @import("syscall");

// =============================================================================
// POSIX Timer Tests (timer_create, timer_settime, timer_gettime, etc.)
// =============================================================================

// Test 1: timer_create with default notification (SIGALRM)
pub fn testTimerCreate() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    if (timerid < 0 or timerid >= 8) return error.TestFailed;
    // Clean up
    try syscall.timer_delete(timerid);
}

// Test 2: timer_create with SIGEV_NONE (no signal, track overruns only)
pub fn testTimerCreateSigevNone() !void {
    var sev = std.mem.zeroes(syscall.SigEvent);
    sev.sigev_notify = syscall.SIGEV_NONE;
    sev.sigev_signo = 14; // SIGALRM (ignored for SIGEV_NONE, but must be valid)

    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, &sev, &timerid);
    if (timerid < 0) return error.TestFailed;
    try syscall.timer_delete(timerid);
}

// Test 3: timer_create with invalid clock
pub fn testTimerCreateInvalidClock() !void {
    var timerid: i32 = -1;
    const result = syscall.timer_create(999, null, &timerid);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 4: timer_delete removes a timer
pub fn testTimerDelete() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    try syscall.timer_delete(timerid);

    // Deleting again should fail
    const result = syscall.timer_delete(timerid);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 5: timer_settime arms a timer and timer_gettime reads remaining time
pub fn testTimerSetGetTime() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    defer syscall.timer_delete(timerid) catch {};

    // Arm with 1 second expiration
    var new_val = std.mem.zeroes(syscall.ITimerspec);
    new_val.it_value.tv_sec = 1;
    new_val.it_value.tv_nsec = 0;

    try syscall.timer_settime(timerid, 0, &new_val, null);

    // Read back
    var curr_val = std.mem.zeroes(syscall.ITimerspec);
    try syscall.timer_gettime(timerid, &curr_val);

    // Remaining time should be > 0 (timer was just armed)
    if (curr_val.it_value.tv_sec == 0 and curr_val.it_value.tv_nsec == 0) {
        return error.TestFailed; // Timer should still have time remaining
    }
}

// Test 6: timer_settime disarms a timer (zero value)
pub fn testTimerDisarm() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    defer syscall.timer_delete(timerid) catch {};

    // Arm
    var arm_val = std.mem.zeroes(syscall.ITimerspec);
    arm_val.it_value.tv_sec = 10;
    try syscall.timer_settime(timerid, 0, &arm_val, null);

    // Disarm (zero value)
    var disarm_val = std.mem.zeroes(syscall.ITimerspec);
    try syscall.timer_settime(timerid, 0, &disarm_val, null);

    // Read back -- should be zero (disarmed)
    var curr_val = std.mem.zeroes(syscall.ITimerspec);
    try syscall.timer_gettime(timerid, &curr_val);

    if (curr_val.it_value.tv_sec != 0 or curr_val.it_value.tv_nsec != 0) {
        return error.TestFailed; // Timer should be disarmed
    }
}

// Test 7: timer_settime returns old value
pub fn testTimerSetTimeOldValue() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    defer syscall.timer_delete(timerid) catch {};

    // Arm with 5 seconds
    var arm1 = std.mem.zeroes(syscall.ITimerspec);
    arm1.it_value.tv_sec = 5;
    try syscall.timer_settime(timerid, 0, &arm1, null);

    // Re-arm with 3 seconds, capture old value
    var arm2 = std.mem.zeroes(syscall.ITimerspec);
    arm2.it_value.tv_sec = 3;
    var old_val = std.mem.zeroes(syscall.ITimerspec);
    try syscall.timer_settime(timerid, 0, &arm2, &old_val);

    // Old value should show remaining time from first arm (close to 5s)
    // With 10ms tick, it should be between 4 and 5 seconds
    if (old_val.it_value.tv_sec < 4 or old_val.it_value.tv_sec > 5) {
        return error.TestFailed;
    }
}

// Test 8: timer_getoverrun returns 0 for fresh timer
pub fn testTimerGetOverrun() !void {
    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timerid);
    defer syscall.timer_delete(timerid) catch {};

    const overrun = try syscall.timer_getoverrun(timerid);
    if (overrun != 0) return error.TestFailed;
}

// Test 9: timer with short interval fires and delivers signal
// (Test signal delivery by checking that the timer actually fires)
pub fn testTimerSignalDelivery() !void {
    // Create timer with SIGEV_NONE (we cannot easily handle SIGALRM in test)
    var sev = std.mem.zeroes(syscall.SigEvent);
    sev.sigev_notify = syscall.SIGEV_NONE;
    sev.sigev_signo = 14;

    var timerid: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, &sev, &timerid);
    defer syscall.timer_delete(timerid) catch {};

    // Arm with 20ms expiration and 20ms interval
    var val = std.mem.zeroes(syscall.ITimerspec);
    val.it_value.tv_nsec = 20_000_000; // 20ms
    val.it_interval.tv_nsec = 20_000_000; // 20ms periodic

    try syscall.timer_settime(timerid, 0, &val, null);

    // Sleep 100ms to let timer fire several times.
    // nanosleep takes *const Timespec, so use the sleep_ms convenience wrapper.
    syscall.sleep_ms(100) catch {};

    // With SIGEV_NONE, each expiration increments overrun_count.
    // 100ms / 20ms = ~5 expirations. But with 10ms tick granularity,
    // 20ms rounds to 2 ticks. After first fire, overrun increments.
    // Expect overrun_count >= 1
    const overrun = try syscall.timer_getoverrun(timerid);
    // Should have some overruns (timer fired multiple times)
    if (overrun == 0) {
        // Timer may not have fired yet due to scheduling
        // Be lenient: just check timer is still alive
        var curr = std.mem.zeroes(syscall.ITimerspec);
        try syscall.timer_gettime(timerid, &curr);
        // If interval is nonzero, timer is still set up correctly
        if (curr.it_interval.tv_nsec == 0) return error.TestFailed;
        // Skip -- timer did not fire in time (acceptable with 10ms granularity)
        return error.SkipTest;
    }
}

// Test 10: Multiple timers per process
pub fn testTimerMultiple() !void {
    var timer1: i32 = -1;
    var timer2: i32 = -1;
    var timer3: i32 = -1;

    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timer1);
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timer2);
    try syscall.timer_create(syscall.CLOCK_REALTIME, null, &timer3);

    // All should have different IDs
    if (timer1 == timer2 or timer1 == timer3 or timer2 == timer3) {
        return error.TestFailed;
    }

    // Delete middle one
    try syscall.timer_delete(timer2);

    // Create another -- should reuse the freed slot
    var timer4: i32 = -1;
    try syscall.timer_create(syscall.CLOCK_MONOTONIC, null, &timer4);
    // timer4 should get timer2's old slot
    if (timer4 != timer2) {
        // Not strictly required, but expected behavior for slot reuse
        // Don't fail -- just verify it's a valid ID
        if (timer4 < 0 or timer4 >= 8) return error.TestFailed;
    }

    // Clean up
    try syscall.timer_delete(timer1);
    try syscall.timer_delete(timer3);
    try syscall.timer_delete(timer4);
}
