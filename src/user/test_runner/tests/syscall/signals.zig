const syscall = @import("syscall");

// Global state for signal handlers (handlers run in kernel context)
var sigusr1_called: bool = false;
var sigusr2_called: bool = false;

// Signal handler for SIGUSR1
fn handleSigusr1(sig: i32) callconv(.c) void {
    _ = sig;
    sigusr1_called = true;
}

// Signal handler for SIGUSR2
fn handleSigusr2(sig: i32) callconv(.c) void {
    _ = sig;
    sigusr2_called = true;
}

// Test 1: Install SIGUSR1 handler and verify it executes
pub fn testSigactionInstallHandler() !void {
    const SIGUSR1 = 10;

    // Reset flag
    sigusr1_called = false;

    // Install handler
    var act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };

    try syscall.sigaction(SIGUSR1, &act, null);

    // Send signal to self
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Give the handler a chance to run (brief yield)
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Verify handler was called
    if (!sigusr1_called) return error.TestFailed;
}

// Test 2: Block signal, send it, verify it doesn't arrive until unblocked
pub fn testSigprocmaskBlockSignal() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Reset flag
    sigusr1_called = false;

    // Install handler
    var act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(SIGUSR1, &act, null);

    // Block SIGUSR1
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal (should be blocked)
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Give time for signal to arrive (it shouldn't execute yet)
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Handler should NOT have been called
    if (sigusr1_called) return error.TestFailed;

    // Unblock the signal
    try syscall.sigprocmask(SIG_UNBLOCK, &set, null);

    // Give time for blocked signal to be delivered
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Now handler should have been called
    if (!sigusr1_called) return error.TestFailed;
}

// Test 3: Check pending signals after blocking
pub fn testSigpendingAfterBlock() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Reset flag
    sigusr1_called = false;

    // Block SIGUSR1
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal (should be blocked)
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Check pending signals
    var pending: syscall.SigSet = 0;
    syscall.sigpending(&pending) catch |err| {
        // Unblock before returning error
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // SIGUSR1 should be pending
    if (!syscall.uapi.signal.sigismember(pending, SIGUSR1)) {
        // Unblock before failing
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        return error.TestFailed;
    }

    // Unblock (signal will be delivered)
    try syscall.sigprocmask(SIG_UNBLOCK, &set, null);

    // Give time for delivery
    syscall.sched_yield() catch {};
}

// Test 4: kill(getpid(), sig) delivers to self
pub fn testKillSelf() !void {
    const SIGUSR1 = 10;

    // Reset flag
    sigusr1_called = false;

    // Install handler
    var act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(SIGUSR1, &act, null);

    // Get own PID and send signal
    const pid = syscall.getpid();
    try syscall.kill(pid, SIGUSR1);

    // Give time for delivery
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Handler should have been called
    if (!sigusr1_called) return error.TestFailed;
}

// Test 5: Set alternate signal stack
pub fn testSigaltstackSetup() !void {
    // Allocate alternate stack (must be at least MINSIGSTKSZ, typically 2KB)
    const stack_size: usize = 8192; // 8KB to be safe
    const stack_addr = syscall.mmap(
        null,
        stack_size,
        syscall.PROT_READ | syscall.PROT_WRITE,
        syscall.MAP_PRIVATE | syscall.MAP_ANONYMOUS,
        0,
        0
    ) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(stack_addr, stack_size) catch {};

    // Set up alternate stack
    var ss = syscall.uapi.signal.StackT{
        .sp = @intFromPtr(stack_addr),
        .flags = 0,
        .size = stack_size,
    };

    syscall.sigaltstack(&ss, null) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify by reading it back
    var old_ss: syscall.uapi.signal.StackT = undefined;
    try syscall.sigaltstack(null, &old_ss);

    if (old_ss.sp != @intFromPtr(stack_addr) or old_ss.size != stack_size) {
        return error.TestFailed;
    }

    // Disable alternate stack (cleanup)
    var disable_ss = syscall.uapi.signal.StackT{
        .sp = 0,
        .flags = syscall.uapi.signal.SS_DISABLE,
        .size = 0,
    };
    _ = syscall.sigaltstack(&disable_ss, null) catch {};
}

// Test 6: Install handlers for multiple signals
pub fn testMultipleHandlers() !void {
    const SIGUSR1 = 10;
    const SIGUSR2 = 12;

    // Reset flags
    sigusr1_called = false;
    sigusr2_called = false;

    // Install SIGUSR1 handler
    var act1 = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(SIGUSR1, &act1, null);

    // Install SIGUSR2 handler
    var act2 = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr2),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(SIGUSR2, &act2, null);

    // Send both signals
    try syscall.kill(syscall.getpid(), SIGUSR1);
    try syscall.kill(syscall.getpid(), SIGUSR2);

    // Give time for delivery
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Both handlers should have been called
    if (!sigusr1_called or !sigusr2_called) return error.TestFailed;
}

// =============================================================================
// Phase 20: Signal Handling Extension Tests
// =============================================================================

// Test 7: rt_sigtimedwait with already-pending signal (immediate dequeue)
pub fn testRtSigtimedwaitImmediate() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Block SIGUSR1 so it stays pending
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal to self (becomes pending since blocked)
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // rt_sigtimedwait should immediately dequeue it
    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    var info: syscall.SignalSigInfo = .{};
    const signo = syscall.rt_sigtimedwait(&set, &info, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Unblock
    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};

    // Should return SIGUSR1
    if (signo != SIGUSR1) return error.TestFailed;
    // siginfo should have correct signo
    if (info.si_signo != @as(i32, SIGUSR1)) return error.TestFailed;
}

// Test 8: rt_sigtimedwait with timeout (no signal pending) returns EAGAIN
pub fn testRtSigtimedwaitTimeout() !void {
    const SIGUSR2 = 12;

    // Wait for SIGUSR2 with zero timeout (should return EAGAIN immediately)
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR2);

    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    const result = syscall.rt_sigtimedwait(&set, null, &timeout);
    if (result) |_| {
        return error.TestFailed; // Should not succeed
    } else |err| {
        // Should get EAGAIN (maps to WouldBlock in userspace errno mapping)
        if (err != error.WouldBlock) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Test 9: rt_sigtimedwait dequeues signal (clears pending bit)
pub fn testRtSigtimedwaitClearsPending() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Block SIGUSR1
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Dequeue it via rt_sigtimedwait
    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    _ = syscall.rt_sigtimedwait(&set, null, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Signal should no longer be pending
    var pending: syscall.SigSet = 0;
    syscall.sigpending(&pending) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // SIGUSR1 should NOT be in pending set (it was consumed)
    if (syscall.uapi.signal.sigismember(pending, SIGUSR1)) {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        return error.TestFailed;
    }

    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
}

// Test 10: rt_sigqueueinfo sends signal to self
pub fn testRtSigqueueinfoSelf() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Block SIGUSR1 so we can check it's pending after
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal with SI_QUEUE si_code
    var info = syscall.SignalSigInfo{
        .si_signo = SIGUSR1,
        .si_code = syscall.SI_QUEUE, // -1 (negative, allowed)
    };

    const pid = syscall.getpid();
    syscall.rt_sigqueueinfo(@intCast(pid), SIGUSR1, &info) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Signal should be pending
    var pending: syscall.SigSet = 0;
    syscall.sigpending(&pending) catch {};

    if (!syscall.uapi.signal.sigismember(pending, SIGUSR1)) {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        return error.TestFailed;
    }

    // Consume the signal to clean up
    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    _ = syscall.rt_sigtimedwait(&set, null, &timeout) catch {};

    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
}

// Test 11: rt_sigqueueinfo rejects si_code >= 0 (kernel impersonation)
pub fn testRtSigqueueinfoRejectsPositiveCode() !void {
    const SIGUSR1 = 10;

    // Try sending with si_code = SI_USER (0) -- should be rejected with EPERM
    var info = syscall.SignalSigInfo{
        .si_signo = SIGUSR1,
        .si_code = syscall.SI_USER, // 0 (non-negative, should be rejected)
    };

    const pid = syscall.getpid();
    const result = syscall.rt_sigqueueinfo(@intCast(pid), SIGUSR1, &info);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        if (err != error.PermissionDenied) return error.TestFailed; // Should be EPERM
    }
}

// Test 12: rt_sigqueueinfo to forked child process
pub fn testRtSigqueueinfoToChild() !void {
    const SIGUSR1 = 10;

    const pid = syscall.fork() catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    if (pid == 0) {
        // Child: block SIGUSR1, sleep, exit
        var set: syscall.SigSet = 0;
        syscall.uapi.signal.sigaddset(&set, SIGUSR1);
        _ = syscall.sigprocmask(0, &set, null) catch {}; // SIG_BLOCK

        // Sleep briefly to give parent time to send signal
        const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 50_000_000 }; // 50ms
        _ = syscall.clock_nanosleep(syscall.CLOCK_MONOTONIC, 0, &req, null) catch {};

        syscall.exit(42);
        unreachable;
    }

    // Parent: send signal to child
    var info = syscall.SignalSigInfo{
        .si_signo = SIGUSR1,
        .si_code = syscall.SI_QUEUE,
    };

    // Small delay to let child set up
    const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 10_000_000 }; // 10ms
    _ = syscall.clock_nanosleep(syscall.CLOCK_MONOTONIC, 0, &req, null) catch {};

    syscall.rt_sigqueueinfo(@intCast(pid), SIGUSR1, &info) catch |err| {
        // Wait for child anyway
        _ = syscall.wait4(-1, null, 0) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Wait for child to exit
    var status: i32 = 0;
    _ = syscall.wait4(-1, &status, 0) catch {};
}

// Test 13: clock_nanosleep with CLOCK_MONOTONIC relative mode
pub fn testClockNanosleepRelative() !void {
    // Sleep 20ms with CLOCK_MONOTONIC
    const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 20_000_000 }; // 20ms
    var rem = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };

    syscall.clock_nanosleep(syscall.CLOCK_MONOTONIC, 0, &req, &rem) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Remaining should be 0 (sleep completed)
    if (rem.tv_sec != 0 or rem.tv_nsec != 0) return error.TestFailed;
}

// Test 14: clock_nanosleep with CLOCK_REALTIME
pub fn testClockNanosleepRealtime() !void {
    // Sleep 10ms with CLOCK_REALTIME
    const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 10_000_000 }; // 10ms

    syscall.clock_nanosleep(syscall.CLOCK_REALTIME, 0, &req, null) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    // If we get here, it worked
}

// Test 15: clock_nanosleep with invalid clock returns EINVAL
pub fn testClockNanosleepInvalidClock() !void {
    const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 10_000_000 };
    const CLOCK_INVALID: usize = 999;

    const result = syscall.clock_nanosleep(CLOCK_INVALID, 0, &req, null);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 16: clock_nanosleep with TIMER_ABSTIME (absolute time in the past returns immediately)
pub fn testClockNanosleepAbstimePast() !void {
    // Set absolute time to 0 (the past) -- should return immediately
    const req = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };

    syscall.clock_nanosleep(syscall.CLOCK_MONOTONIC, syscall.TIMER_ABSTIME, &req, null) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    // If we get here, it returned immediately (deadline in the past)
}
