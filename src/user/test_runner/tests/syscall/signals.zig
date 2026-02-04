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
