const std = @import("std");
const syscall = @import("syscall");

// Helper functions for fd_set manipulation (select tests)
fn fdSet(set: *[128]u8, fd_val: i32) void {
    const ufd: u32 = @intCast(fd_val);
    set[ufd / 8] |= @as(u8, 1) << @truncate(ufd % 8);
}

fn fdIsSet(set: *const [128]u8, fd_val: i32) bool {
    const ufd: u32 = @intCast(fd_val);
    return (set[ufd / 8] & (@as(u8, 1) << @truncate(ufd % 8))) != 0;
}

fn fdZero(set: *[128]u8) void {
    @memset(set, 0);
}

// =============================================================================
// epoll tests
// =============================================================================

// Test 1: Create epoll instance and close it
pub fn testEpollCreateAndClose() !void {
    const epfd = try syscall.epoll_create1(0);
    if (epfd < 0) return error.TestFailed;
    try syscall.close(epfd);
}

// Test 2: epoll_ctl add and epoll_wait with pipe
pub fn testEpollCtlAddAndWait() !void {
    // Create epoll instance
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Create pipe
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Add read end to epoll with EPOLLIN
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // Write data to pipe
    const msg = "test";
    const written = try syscall.write(pipefd[1], msg.ptr, msg.len);
    if (written != msg.len) return error.TestFailed;

    // epoll_wait should return 1 event with EPOLLIN
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLIN) == 0) return error.TestFailed;
    if (events[0].getData() != @as(u64, @bitCast(@as(i64, pipefd[0])))) return error.TestFailed;
}

// Test 3: epoll_wait with no events (empty epoll)
pub fn testEpollWaitNoEvents() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 0) return error.TestFailed;
}

// Test 4: epoll detects EPOLLHUP when pipe write end is closed
pub fn testEpollPipeHup() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer syscall.close(pipefd[0]) catch {};

    // Add read end to epoll
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // Close write end
    try syscall.close(pipefd[1]);

    // epoll_wait should return EPOLLHUP (and possibly EPOLLIN)
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready < 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLHUP) == 0) return error.TestFailed;
}

// Test 5: epoll on regular file always ready
pub fn testEpollRegularFileAlwaysReady() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Open a regular file from initrd
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Add to epoll with EPOLLIN | EPOLLOUT
    var event = syscall.EpollEvent.init(syscall.EPOLLIN | syscall.EPOLLOUT, @as(u64, @bitCast(@as(i64, fd))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, fd, &event);

    // epoll_wait should return immediately with both flags
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLIN) == 0) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLOUT) == 0) return error.TestFailed;
}

// =============================================================================
// select tests
// =============================================================================

// Test 6: select detects readable pipe
pub fn testSelectPipeReadable() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Write data to pipe
    const msg = "x";
    const written = try syscall.write(pipefd[1], msg.ptr, msg.len);
    if (written != msg.len) return error.TestFailed;

    // Set up fd_set for reading
    var readfds: [128]u8 = undefined;
    fdZero(&readfds);
    fdSet(&readfds, pipefd[0]);

    // select with timeout=0 (immediate return)
    var timeout: extern struct { tv_sec: i64, tv_usec: i64 } = .{ .tv_sec = 0, .tv_usec = 0 };
    const nready = try syscall.select(pipefd[0] + 1, &readfds, null, null, @ptrCast(&timeout));

    if (nready != 1) return error.TestFailed;
    if (!fdIsSet(&readfds, pipefd[0])) return error.TestFailed;
}

// Test 7: select detects writable pipe
pub fn testSelectPipeWritable() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Set up fd_set for writing
    var writefds: [128]u8 = undefined;
    fdZero(&writefds);
    fdSet(&writefds, pipefd[1]);

    // select with timeout=0
    var timeout: extern struct { tv_sec: i64, tv_usec: i64 } = .{ .tv_sec = 0, .tv_usec = 0 };
    const nready = try syscall.select(pipefd[1] + 1, null, &writefds, null, @ptrCast(&timeout));

    if (nready != 1) return error.TestFailed;
    if (!fdIsSet(&writefds, pipefd[1])) return error.TestFailed;
}

// Test 8: select with timeout=0 returns immediately when no fds ready
pub fn testSelectTimeout() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Set up fd_set for reading (pipe is empty)
    var readfds: [128]u8 = undefined;
    fdZero(&readfds);
    fdSet(&readfds, pipefd[0]);

    // select with timeout=0 should return 0 (no ready fds)
    var timeout: extern struct { tv_sec: i64, tv_usec: i64 } = .{ .tv_sec = 0, .tv_usec = 0 };
    const nready = try syscall.select(pipefd[0] + 1, &readfds, null, null, @ptrCast(&timeout));

    if (nready != 0) return error.TestFailed;
}

// =============================================================================
// poll tests
// =============================================================================

// Test 9: poll detects POLLIN on pipe with data
pub fn testPollPipeEvents() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Write data to pipe
    const msg = "test";
    const written = try syscall.write(pipefd[1], msg.ptr, msg.len);
    if (written != msg.len) return error.TestFailed;

    // poll for POLLIN
    var pollfd: [1]syscall.PollFd = undefined;
    pollfd[0] = .{ .fd = pipefd[0], .events = syscall.POLLIN, .revents = 0 };
    const nready = try syscall.poll(&pollfd, 0);

    if (nready != 1) return error.TestFailed;
    if ((pollfd[0].revents & syscall.POLLIN) == 0) return error.TestFailed;
}

// Test 10: poll detects POLLHUP when pipe write end is closed
pub fn testPollPipeHup() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer syscall.close(pipefd[0]) catch {};

    // Close write end
    try syscall.close(pipefd[1]);

    // poll for POLLIN (but should also get POLLHUP)
    var pollfd: [1]syscall.PollFd = undefined;
    pollfd[0] = .{ .fd = pipefd[0], .events = syscall.POLLIN, .revents = 0 };
    const nready = try syscall.poll(&pollfd, 0);

    if (nready != 1) return error.TestFailed;
    if ((pollfd[0].revents & syscall.POLLHUP) == 0) return error.TestFailed;
}

// =============================================================================
// epoll_pwait tests
// =============================================================================

// Test 11: epoll_pwait with NULL sigmask behaves like epoll_wait
pub fn testEpollPwaitNullMask() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Create pipe and write data
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Add read end to epoll
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // Write data
    const msg = "test";
    _ = try syscall.write(pipefd[1], msg.ptr, msg.len);

    // epoll_pwait with NULL sigmask should work like epoll_wait
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_pwait(epfd, &events, 4, 0, null, 0);
    if (nready != 1) return error.TestFailed;
    if ((events[0].events & syscall.EPOLLIN) == 0) return error.TestFailed;
}

// Test 12: epoll_pwait with signal mask applied during wait
pub fn testEpollPwaitWithMask() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Create pipe
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Add read end to epoll
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // Write data so we get immediate return
    const msg = "x";
    _ = try syscall.write(pipefd[1], msg.ptr, msg.len);

    // Save current sigmask
    var old_mask: u64 = 0;
    try syscall.sigprocmask(2, null, &old_mask); // SIG_SETMASK=2, just query

    // Call epoll_pwait with a mask that blocks SIGUSR1 (bit 9, signal 10)
    var wait_mask: u64 = old_mask | (@as(u64, 1) << 9); // Block SIGUSR1
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_pwait(epfd, &events, 4, 0, &wait_mask, 8);

    // Should still return 1 event (pipe is readable)
    if (nready != 1) return error.TestFailed;

    // After epoll_pwait returns, original mask should be restored
    // Verify by querying current mask
    var current_mask: u64 = 0;
    try syscall.sigprocmask(2, null, &current_mask); // Query again
    if (current_mask != old_mask) return error.TestFailed;
}

// Test 13: epoll_pwait timeout with no events returns 0
pub fn testEpollPwaitTimeoutNoEvents() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    // Create pipe but don't write anything
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Add read end to epoll
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // epoll_pwait with timeout=0 and mask should return immediately with 0
    var mask: u64 = 0; // Empty mask (unblock all signals)
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_pwait(epfd, &events, 4, 0, &mask, 8);
    if (nready != 0) return error.TestFailed;
}

// Test 14: epoll_pwait with invalid sigsetsize returns EINVAL
pub fn testEpollPwaitInvalidSigsetsize() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    var mask: u64 = 0;
    var events: [4]syscall.EpollEvent = undefined;

    // sigsetsize must be 8; passing 4 should return EINVAL
    const result = syscall.epoll_pwait(epfd, &events, 4, 0, &mask, 4);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 15: epoll_pwait mask is restored even when events are returned
pub fn testEpollPwaitMaskRestoredOnSuccess() !void {
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Add read end to epoll
    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, pipefd[0]))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, pipefd[0], &event);

    // Write to make pipe readable
    const msg = "hi";
    _ = try syscall.write(pipefd[1], msg.ptr, msg.len);

    // Set a known sigmask before epoll_pwait
    var pre_mask: u64 = @as(u64, 1) << 14; // Block signal 15 (SIGTERM)
    try syscall.sigprocmask(2, &pre_mask, null); // SIG_SETMASK

    // Call epoll_pwait with a different mask
    var pwait_mask: u64 = @as(u64, 1) << 9; // Block SIGUSR1 during wait
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_pwait(epfd, &events, 4, 0, &pwait_mask, 8);
    if (nready != 1) {
        // Restore mask before failing
        var zero: u64 = 0;
        _ = syscall.sigprocmask(2, &zero, null) catch {};
        return error.TestFailed;
    }

    // After return, mask should be back to pre_mask (SIGTERM blocked)
    var post_mask: u64 = 0;
    try syscall.sigprocmask(2, null, &post_mask); // Query

    // Clean up: unblock all
    var zero: u64 = 0;
    _ = syscall.sigprocmask(2, &zero, null) catch {};

    if (post_mask != pre_mask) return error.TestFailed;
}
