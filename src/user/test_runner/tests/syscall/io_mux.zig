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
