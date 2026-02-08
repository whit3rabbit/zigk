const std = @import("std");
const syscall = @import("syscall");

// Signal constants (from uapi/process/signal.zig)
const SIG_BLOCK: usize = 0;
const SIG_SETMASK: usize = 2;
const SIGUSR1: usize = 10;

// =============================================================================
// eventfd tests
// =============================================================================

/// Test 1: Create and close eventfd
pub fn testEventfdCreateAndClose() !void {
    const fd = try syscall.eventfd2(0, 0);
    if (fd < 0) return error.TestFailed;
    try syscall.close(fd);
}

/// Test 2: Write and read from eventfd
pub fn testEventfdWriteAndRead() !void {
    const fd = try syscall.eventfd2(0, syscall.EFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Write value 5 to eventfd
    var write_val: u64 = 5;
    const written = try syscall.write(fd, @as([*]const u8, @ptrCast(&write_val)), 8);
    if (written != 8) return error.TestFailed;

    // Read value back (should be 5)
    var read_val: u64 = 0;
    const read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (read_val != 5) return error.TestFailed;

    // Read again - should fail with EAGAIN (counter is now 0)
    const read_result = syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_result) |_| {
        return error.TestFailed; // Should have returned EAGAIN
    } else |err| {
        if (err != error.EAGAIN) return error.TestFailed;
    }
}

/// Test 3: Eventfd semaphore mode
pub fn testEventfdSemaphoreMode() !void {
    const fd = try syscall.eventfd2(0, syscall.EFD_SEMAPHORE | syscall.EFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Write value 3 to eventfd (counter becomes 3)
    var write_val: u64 = 3;
    const written = try syscall.write(fd, @as([*]const u8, @ptrCast(&write_val)), 8);
    if (written != 8) return error.TestFailed;

    // Read 1 - should return 1 (semaphore mode)
    var read_val: u64 = 0;
    var read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (read_val != 1) return error.TestFailed;

    // Read 2 - should return 1 (counter now 1)
    read_val = 0;
    read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (read_val != 1) return error.TestFailed;

    // Read 3 - should return 1 (counter now 0)
    read_val = 0;
    read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (read_val != 1) return error.TestFailed;

    // Read 4 - should fail with EAGAIN (counter is 0)
    const read_result = syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_result) |_| {
        return error.TestFailed; // Should have returned EAGAIN
    } else |err| {
        if (err != error.EAGAIN) return error.TestFailed;
    }
}

/// Test 4: Eventfd with initial value
pub fn testEventfdInitialValue() !void {
    const fd = try syscall.eventfd2(42, syscall.EFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Read immediately - should return 42
    var read_val: u64 = 0;
    const read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&read_val)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (read_val != 42) return error.TestFailed;
}

/// Test 5: Eventfd integration with epoll
pub fn testEventfdEpollIntegration() !void {
    const efd = try syscall.eventfd2(0, syscall.EFD_NONBLOCK);
    defer syscall.close(efd) catch {};

    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Add eventfd to epoll with EPOLLIN
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, efd))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, efd, &event);

    // epoll_wait should return 0 (counter is 0, no EPOLLIN)
    var events: [4]syscall.EpollEvent = undefined;
    var nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 0) return error.TestFailed;

    // Write value 1 to eventfd
    var write_val: u64 = 1;
    _ = try syscall.write(efd, @as([*]const u8, @ptrCast(&write_val)), 8);

    // epoll_wait should now return 1 with EPOLLIN
    nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLIN) == 0) return error.TestFailed;

    // Read from eventfd (consume the counter)
    var read_val: u64 = 0;
    _ = try syscall.read(efd, @as([*]u8, @ptrCast(&read_val)), 8);

    // epoll_wait should now return 0 again
    nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 0) return error.TestFailed;
}

// =============================================================================
// timerfd tests
// =============================================================================

/// Test 6: Create and close timerfd
pub fn testTimerfdCreateAndClose() !void {
    const fd = try syscall.timerfd_create(syscall.CLOCK_MONOTONIC, 0);
    if (fd < 0) return error.TestFailed;
    try syscall.close(fd);
}

/// Test 7: Set and get timerfd time
pub fn testTimerfdSetAndGetTime() !void {
    const fd = try syscall.timerfd_create(syscall.CLOCK_MONOTONIC, syscall.TFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Set timer for 100ms relative, one-shot
    var new_value = syscall.ITimerSpec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 100_000_000 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };
    try syscall.timerfd_settime(fd, 0, &new_value, null);

    // Get time remaining - it_value should be non-zero
    var curr_value: syscall.ITimerSpec = undefined;
    try syscall.timerfd_gettime(fd, &curr_value);

    // Time remaining should be positive (not yet expired)
    if (curr_value.it_value.tv_sec == 0 and curr_value.it_value.tv_nsec == 0) {
        return error.TestFailed; // Timer already expired (unlikely)
    }
}

/// Test 8: Timerfd expiration
pub fn testTimerfdExpiration() !void {
    const fd = try syscall.timerfd_create(syscall.CLOCK_MONOTONIC, syscall.TFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Set timer for 50ms relative
    var new_value = syscall.ITimerSpec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 50_000_000 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };
    try syscall.timerfd_settime(fd, 0, &new_value, null);

    // Sleep for 100ms to give timer time to expire (use nanosleep)
    var sleep_time = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
    try syscall.nanosleep(&sleep_time, null);

    // Read from timerfd - should return expiration count >= 1
    var expirations: u64 = 0;
    const read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&expirations)), 8);
    if (read_bytes != 8) return error.TestFailed;
    if (expirations < 1) return error.TestFailed;
}

/// Test 9: Timerfd disarm
pub fn testTimerfdDisarm() !void {
    const fd = try syscall.timerfd_create(syscall.CLOCK_MONOTONIC, syscall.TFD_NONBLOCK);
    defer syscall.close(fd) catch {};

    // Set timer for 100ms
    var new_value = syscall.ITimerSpec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 100_000_000 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };
    try syscall.timerfd_settime(fd, 0, &new_value, null);

    // Immediately disarm by setting it_value to {0, 0}
    var disarm_value = syscall.ITimerSpec{
        .it_value = .{ .tv_sec = 0, .tv_nsec = 0 },
        .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
    };
    try syscall.timerfd_settime(fd, 0, &disarm_value, null);

    // Sleep for 150ms
    var sleep_time = syscall.Timespec{ .tv_sec = 0, .tv_nsec = 150_000_000 };
    try syscall.nanosleep(&sleep_time, null);

    // Read should fail with EAGAIN (timer was disarmed)
    var expirations: u64 = 0;
    const read_result = syscall.read(fd, @as([*]u8, @ptrCast(&expirations)), 8);
    if (read_result) |_| {
        return error.TestFailed; // Should have returned EAGAIN
    } else |err| {
        if (err != error.EAGAIN) return error.TestFailed;
    }
}

// =============================================================================
// signalfd tests
// =============================================================================

/// Test 10: Create and close signalfd
pub fn testSignalfdCreateAndClose() !void {
    // Create mask with SIGUSR1 (signal 10, mask = 1 << 9)
    var mask: u64 = @as(u64, 1) << (SIGUSR1 - 1);
    const fd = try syscall.signalfd4(-1, &mask, 0);
    if (fd < 0) return error.TestFailed;
    try syscall.close(fd);
}

/// Test 11: Read signal from signalfd
pub fn testSignalfdReadSignal() !void {
    // Block SIGUSR1 to prevent default handler from running
    var mask: u64 = @as(u64, 1) << (SIGUSR1 - 1);
    var oldmask: u64 = 0;

    // Use rt_sigprocmask wrapper via sigprocmask
    // Note: sigprocmask takes SigSet pointer, so we need to cast u64 as SigSet
    try syscall.sigprocmask(@intCast(SIG_BLOCK), @ptrCast(&mask), @ptrCast(&oldmask));

    // Create signalfd with SIGUSR1 in mask
    const fd = try syscall.signalfd4(-1, &mask, syscall.SFD_NONBLOCK);
    defer {
        syscall.close(fd) catch {};
        // Restore old signal mask
        _ = syscall.sigprocmask(@intCast(SIG_SETMASK), @ptrCast(&oldmask), null) catch {};
    }

    // Send SIGUSR1 to self
    const pid = syscall.getpid();
    try syscall.kill(pid, @intCast(SIGUSR1));

    // Read signal from signalfd
    var siginfo: syscall.SignalFdSigInfo = undefined;
    const read_bytes = try syscall.read(fd, @as([*]u8, @ptrCast(&siginfo)), @sizeOf(syscall.SignalFdSigInfo));
    if (read_bytes != @sizeOf(syscall.SignalFdSigInfo)) return error.TestFailed;
    if (siginfo.ssi_signo != SIGUSR1) return error.TestFailed;

    // Read again - should fail with EAGAIN (signal consumed)
    const read_result = syscall.read(fd, @as([*]u8, @ptrCast(&siginfo)), @sizeOf(syscall.SignalFdSigInfo));
    if (read_result) |_| {
        return error.TestFailed; // Should have returned EAGAIN
    } else |err| {
        if (err != error.EAGAIN) return error.TestFailed;
    }
}

/// Test 12: Signalfd integration with epoll
pub fn testSignalfdEpollIntegration() !void {
    // Block SIGUSR1
    var mask: u64 = @as(u64, 1) << (SIGUSR1 - 1);
    var oldmask: u64 = 0;
    try syscall.sigprocmask(@intCast(SIG_BLOCK), @ptrCast(&mask), @ptrCast(&oldmask));

    // Create signalfd
    const sfd = try syscall.signalfd4(-1, &mask, syscall.SFD_NONBLOCK);
    defer {
        syscall.close(sfd) catch {};
        _ = syscall.sigprocmask(@intCast(SIG_SETMASK), @ptrCast(&oldmask), null) catch {};
    }

    // Create epoll instance
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Add signalfd to epoll with EPOLLIN
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, sfd))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, sfd, &event);

    // epoll_wait should return 0 (no pending signal)
    var events: [4]syscall.EpollEvent = undefined;
    var nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 0) return error.TestFailed;

    // Send SIGUSR1 to self
    const pid = syscall.getpid();
    try syscall.kill(pid, @intCast(SIGUSR1));

    // epoll_wait should now return 1 with EPOLLIN
    nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLIN) == 0) return error.TestFailed;

    // Read from signalfd (consume signal)
    var siginfo: syscall.SignalFdSigInfo = undefined;
    _ = try syscall.read(sfd, @as([*]u8, @ptrCast(&siginfo)), @sizeOf(syscall.SignalFdSigInfo));

    // epoll_wait should now return 0 again
    nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 0) return error.TestFailed;
}
