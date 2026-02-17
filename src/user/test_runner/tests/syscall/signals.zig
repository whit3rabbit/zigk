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

// Test 17: rt_sigsuspend unblocks signal and delivers it (returns EINTR)
pub fn testRtSigsuspendBasic() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Reset flag
    sigusr1_called = false;

    // Install SIGUSR1 handler
    var act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(SIGUSR1, &act, null);

    // Block SIGUSR1
    var block_set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&block_set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &block_set, null);

    // Send SIGUSR1 to self (it becomes pending because it's blocked)
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Verify signal is pending but NOT delivered yet
    if (sigusr1_called) {
        // Cleanup
        _ = syscall.sigprocmask(SIG_UNBLOCK, &block_set, null) catch {};
        return error.TestFailed;
    }

    // Call rt_sigsuspend with a mask that UNBLOCKS SIGUSR1.
    // This should atomically swap the mask and deliver the pending signal.
    // The empty mask (0) unblocks everything.
    var suspend_mask: syscall.SigSet = 0; // Unblock all signals

    // rt_sigsuspend always returns EINTR (per POSIX) after signal delivery
    const result = syscall.rt_sigsuspend(&suspend_mask);
    if (result) |_| {
        // Should not succeed -- rt_sigsuspend always returns EINTR
        _ = syscall.sigprocmask(SIG_UNBLOCK, &block_set, null) catch {};
        return error.TestFailed;
    } else |err| {
        // EINTR maps to error.Interrupted in userspace
        if (err != error.Interrupted) {
            _ = syscall.sigprocmask(SIG_UNBLOCK, &block_set, null) catch {};
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }

    // The signal handler should have been called during rt_sigsuspend
    if (!sigusr1_called) {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &block_set, null) catch {};
        return error.TestFailed;
    }

    // Cleanup: unblock SIGUSR1
    _ = syscall.sigprocmask(SIG_UNBLOCK, &block_set, null) catch {};
}

// =============================================================================
// Phase 29: Siginfo Queue Tests (Tests 18-21)
// =============================================================================

// Shared state for SA_SIGINFO handler tests
var siginfo_received_signo: i32 = 0;
var siginfo_received_code: i32 = 0;
var siginfo_received_pid: i32 = 0;
var siginfo_handler_called: bool = false;

// SA_SIGINFO handler: receives (signum, *siginfo_t, *ucontext_t)
// siginfo_t layout: si_signo@0, si_errno@4, si_code@8, _pad@12, si_pid@16, si_uid@20
fn handleSigusr1WithInfo(sig: i32, info_ptr: usize, _ucontext: usize) callconv(.c) void {
    _ = _ucontext;
    _ = sig;
    siginfo_handler_called = true;
    if (info_ptr != 0) {
        const info: *const syscall.SignalSigInfo = @ptrFromInt(info_ptr);
        siginfo_received_signo = info.si_signo;
        siginfo_received_code = info.si_code;
        siginfo_received_pid = info.si_pid;
    }
}

// Test 18: SA_SIGINFO handler receives correct metadata from kill()
pub fn testSiginfoPidUid() !void {
    const SIGUSR1: i32 = 10;
    const SA_SIGINFO: u64 = 0x00000004;

    // Reset state
    siginfo_handler_called = false;
    siginfo_received_signo = 0;
    siginfo_received_code = 0;
    siginfo_received_pid = 0;

    // Install SA_SIGINFO handler
    var act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1WithInfo),
        .flags = SA_SIGINFO,
        .restorer = 0,
        .mask = 0,
    };
    try syscall.sigaction(@intCast(SIGUSR1), &act, null);

    // Send signal to self via kill()
    const my_pid = syscall.getpid();
    try syscall.kill(my_pid, SIGUSR1);

    // Give handler time to execute
    syscall.sched_yield() catch {};
    syscall.sched_yield() catch {};

    // Verify handler was called
    if (!siginfo_handler_called) return error.TestFailed;

    // Verify siginfo fields
    if (siginfo_received_signo != SIGUSR1) return error.TestFailed;
    // si_code should be SI_USER (0) since sent via kill()
    if (siginfo_received_code != 0) return error.TestFailed;
    // si_pid should be our own PID
    if (siginfo_received_pid != my_pid) return error.TestFailed;

    // Restore default handler (plain single-arg handler)
    var default_act = syscall.SigAction{
        .handler = @intFromPtr(&handleSigusr1),
        .flags = 0,
        .restorer = 0,
        .mask = 0,
    };
    _ = syscall.sigaction(@intCast(SIGUSR1), &default_act, null) catch {};
}

// Test 19: rt_sigqueueinfo metadata preserved through kernel queue to rt_sigtimedwait
pub fn testSiginfoQueueRoundTrip() !void {
    const SIGUSR2: i32 = 12;
    const SIG_BLOCK: i32 = 0;
    const SIG_UNBLOCK: i32 = 1;

    // Block SIGUSR2 so it stays pending
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, @intCast(SIGUSR2));
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal with SI_QUEUE code and our PID
    const my_pid = syscall.getpid();
    var send_info = syscall.SignalSigInfo{
        .si_signo = SIGUSR2,
        .si_code = syscall.SI_QUEUE,
        .si_pid = my_pid,
        .si_uid = 0,
    };

    syscall.rt_sigqueueinfo(my_pid, SIGUSR2, &send_info) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Dequeue via rt_sigtimedwait with zero timeout (immediate)
    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    var recv_info: syscall.SignalSigInfo = .{};
    const signo = syscall.rt_sigtimedwait(&set, &recv_info, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Unblock
    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};

    // Verify signal number
    if (signo != @as(u32, @intCast(SIGUSR2))) return error.TestFailed;

    // Verify siginfo fields preserved through queue
    if (recv_info.si_signo != SIGUSR2) return error.TestFailed;
    if (recv_info.si_code != syscall.SI_QUEUE) return error.TestFailed;
    if (recv_info.si_pid != my_pid) return error.TestFailed;
}

// Test 20: Standard signal coalescing (second send while pending is a no-op)
pub fn testSiginfoStandardCoalescing() !void {
    const SIGUSR1: i32 = 10;
    const SIG_BLOCK: i32 = 0;
    const SIG_UNBLOCK: i32 = 1;

    // Block SIGUSR1
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, @intCast(SIGUSR1));
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send SIGUSR1 twice while blocked
    try syscall.kill(syscall.getpid(), SIGUSR1);
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Dequeue via rt_sigtimedwait -- should get exactly one
    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };
    _ = syscall.rt_sigtimedwait(&set, null, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Second dequeue should fail (no more pending)
    const result2 = syscall.rt_sigtimedwait(&set, null, &timeout);
    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
    if (result2) |_| {
        // Should NOT succeed -- signal was consumed, only one was pending
        return error.TestFailed;
    } else |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        if (err != error.WouldBlock) return error.TestFailed;
        // WouldBlock: correct -- no more pending signals
    }
}

// Test 21: RT signal queuing -- multiple instances of same RT signal are queued
pub fn testSiginfoRtSignalQueuing() !void {
    const SIGRTMIN: i32 = 32;
    const SIG_BLOCK: i32 = 0;
    const SIG_UNBLOCK: i32 = 1;

    // Block SIGRTMIN so signals stay pending
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, @intCast(SIGRTMIN));
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send SIGRTMIN twice via rt_sigqueueinfo
    const my_pid = syscall.getpid();

    var send_info1 = syscall.SignalSigInfo{
        .si_signo = SIGRTMIN,
        .si_code = syscall.SI_QUEUE,
        .si_pid = my_pid,
        .si_uid = 0,
    };
    syscall.rt_sigqueueinfo(my_pid, SIGRTMIN, &send_info1) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    var send_info2 = syscall.SignalSigInfo{
        .si_signo = SIGRTMIN,
        .si_code = syscall.SI_QUEUE,
        .si_pid = my_pid,
        .si_uid = 0,
    };
    syscall.rt_sigqueueinfo(my_pid, SIGRTMIN, &send_info2) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    var timeout = syscall.SignalTimespec{ .tv_sec = 0, .tv_nsec = 0 };

    // Dequeue first instance -- should succeed
    const signo1 = syscall.rt_sigtimedwait(&set, null, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    if (signo1 != @as(u32, @intCast(SIGRTMIN))) {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        return error.TestFailed;
    }

    // Dequeue second instance -- should ALSO succeed (RT signals queue, not coalesce)
    const signo2 = syscall.rt_sigtimedwait(&set, null, &timeout) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        // WouldBlock here means RT signal queuing is broken (only one was delivered)
        if (err == error.WouldBlock) return error.TestFailed;
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    if (signo2 != @as(u32, @intCast(SIGRTMIN))) {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        return error.TestFailed;
    }

    // Third dequeue should fail (only sent two)
    const result3 = syscall.rt_sigtimedwait(&set, null, &timeout);
    _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
    if (result3) |_| {
        return error.TestFailed;
    } else |_| {
        // Expected: WouldBlock or similar -- no more pending
    }
}
