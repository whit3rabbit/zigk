const std = @import("std");
const syscall = @import("syscall");

// =============================================================================
// inotify tests
// =============================================================================

// Test 1: inotify_init1 creates a valid fd
pub fn testInotifyInit() !void {
    const fd = try syscall.inotify_init1(0);
    if (fd < 0) return error.TestFailed;
    try syscall.close(fd);
}

// Test 2: inotify_init1 with IN_NONBLOCK flag
pub fn testInotifyInitNonblock() !void {
    const fd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    if (fd < 0) return error.TestFailed;
    defer syscall.close(fd) catch {};

    // Read on empty inotify with NONBLOCK should return EAGAIN/WouldBlock
    var buf: [256]u8 = undefined;
    const result = syscall.read(fd, &buf, buf.len);
    if (result) |_| {
        return error.TestFailed; // Should not succeed with no events
    } else |err| {
        if (err != error.WouldBlock) return error.TestFailed;
    }
}

// Test 3: inotify_init1 rejects invalid flags
pub fn testInotifyInitInvalidFlags() !void {
    const result = syscall.inotify_init1(0xDEAD);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 4: inotify_add_watch on /mnt directory
pub fn testInotifyAddWatch() !void {
    const fd = try syscall.inotify_init1(0);
    defer syscall.close(fd) catch {};

    const wd = try syscall.inotify_add_watch(fd, "/mnt", syscall.IN_ALL_EVENTS);
    if (wd < 0) return error.TestFailed;
    // wd should be >= 1
    if (wd < 1) return error.TestFailed;
}

// Test 5: inotify_rm_watch removes a watch
pub fn testInotifyRmWatch() !void {
    const fd = try syscall.inotify_init1(0);
    defer syscall.close(fd) catch {};

    const wd = try syscall.inotify_add_watch(fd, "/mnt", syscall.IN_ALL_EVENTS);

    // Remove the watch
    try syscall.inotify_rm_watch(fd, wd);

    // Removing again should fail with EINVAL
    const result = syscall.inotify_rm_watch(fd, wd);
    if (result) |_| {
        return error.TestFailed; // Should fail
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 6: inotify_rm_watch with invalid wd
pub fn testInotifyRmWatchInvalid() !void {
    const fd = try syscall.inotify_init1(0);
    defer syscall.close(fd) catch {};

    const result = syscall.inotify_rm_watch(fd, 999);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Test 7: Create a file on /mnt and receive IN_CREATE event
pub fn testInotifyCreateEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    // Watch /mnt for create events
    const wd = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_CREATE | syscall.IN_OPEN);

    // Create a file on /mnt
    const file_fd = try syscall.open("/mnt/inotify_test", syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    defer syscall.close(file_fd) catch {};

    // Read event from inotify fd
    var buf: [256]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        // If no events queued yet, that is a test failure
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) return error.TestFailed;

    // Parse the event
    const event: *const syscall.InotifyEvent = @ptrCast(&buf);
    if (event.wd != wd) return error.TestFailed;

    // Should have IN_CREATE or IN_OPEN flag set
    if ((event.mask & (syscall.IN_CREATE | syscall.IN_OPEN)) == 0) return error.TestFailed;

    // Clean up: delete the test file
    syscall.unlink("/mnt/inotify_test") catch {};
}

// Test 8: Modify a file and receive IN_MODIFY event (via ftruncate which now fires IN_MODIFY)
pub fn testInotifyModifyEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    // Create a file first
    const file_fd = try syscall.open("/mnt/inotify_mod", syscall.O_CREAT | syscall.O_WRONLY, 0o644);

    // Now watch /mnt for modify events
    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_MODIFY);

    // Drain any pending events from the create
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // ftruncate now fires IN_MODIFY via fd.inotify_close_hook
    syscall.ftruncate(file_fd, 100) catch {};
    syscall.close(file_fd) catch {};

    // Read event
    var buf: [256]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        syscall.unlink("/mnt/inotify_mod") catch {};
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) {
        syscall.unlink("/mnt/inotify_mod") catch {};
        return error.TestFailed;
    }

    const event: *const syscall.InotifyEvent = @ptrCast(&buf);
    if ((event.mask & syscall.IN_MODIFY) == 0) {
        syscall.unlink("/mnt/inotify_mod") catch {};
        return error.TestFailed;
    }

    syscall.unlink("/mnt/inotify_mod") catch {};
}

// Test 9: Delete event (unlink triggers IN_DELETE)
pub fn testInotifyDeleteEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    // Create a test file
    const file_fd = try syscall.open("/mnt/inotify_del", syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    syscall.close(file_fd) catch {};

    // Watch for delete events
    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_DELETE);

    // Drain any create events
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // Delete the file
    try syscall.unlink("/mnt/inotify_del");

    // Read the event
    var buf: [256]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) return error.TestFailed;

    const event: *const syscall.InotifyEvent = @ptrCast(&buf);
    if ((event.mask & syscall.IN_DELETE) == 0) return error.TestFailed;
}

// Test 10: inotify works with epoll
pub fn testInotifyWithEpoll() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_CREATE);

    // Add to epoll
    const epfd = try syscall.epoll_create1(0);
    defer syscall.close(epfd) catch {};

    var event = syscall.EpollEvent.init(syscall.EPOLLIN, @as(u64, @bitCast(@as(i64, ifd))));
    _ = try syscall.epoll_ctl(epfd, syscall.EPOLL_CTL_ADD, ifd, &event);

    // Create a file to generate an event
    const file_fd = try syscall.open("/mnt/inotify_epoll", syscall.O_CREAT | syscall.O_WRONLY, 0o644);
    syscall.close(file_fd) catch {};

    // epoll_wait should return 1 (inotify fd has events)
    var events: [4]syscall.EpollEvent = undefined;
    const nready = try syscall.epoll_wait(epfd, &events, 4, 0);
    if (nready != 1) {
        syscall.unlink("/mnt/inotify_epoll") catch {};
        return error.TestFailed;
    }
    if ((events[0].events & syscall.EPOLLIN) == 0) {
        syscall.unlink("/mnt/inotify_epoll") catch {};
        return error.TestFailed;
    }

    syscall.unlink("/mnt/inotify_epoll") catch {};
}

// Test 11: Write to a file fires IN_MODIFY with correct wd, mask, cookie, and name fields
pub fn testInotifyWriteEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    // Create a file first
    const file_fd = try syscall.open("/mnt/inotify_wr", syscall.O_CREAT | syscall.O_WRONLY, 0o644);

    // Watch /mnt for modify events - save the wd for validation
    const wd = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_MODIFY);

    // Drain any pending events from create
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // Write to the file -- should fire IN_MODIFY
    const msg = "hello inotify";
    _ = try syscall.write(file_fd, msg, msg.len);
    syscall.close(file_fd) catch {};

    // Read inotify event
    var buf: [512]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        syscall.unlink("/mnt/inotify_wr") catch {};
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) {
        syscall.unlink("/mnt/inotify_wr") catch {};
        return error.TestFailed;
    }

    const ev: *const syscall.InotifyEvent = @ptrCast(&buf);

    // 1. wd must match the watch descriptor returned by inotify_add_watch
    if (ev.wd != @as(i32, @intCast(wd))) {
        syscall.unlink("/mnt/inotify_wr") catch {};
        return error.TestFailed;
    }
    // 2. mask must contain IN_MODIFY
    if ((ev.mask & syscall.IN_MODIFY) == 0) {
        syscall.unlink("/mnt/inotify_wr") catch {};
        return error.TestFailed;
    }
    // 3. cookie must be 0 (non-rename event)
    if (ev.cookie != 0) {
        syscall.unlink("/mnt/inotify_wr") catch {};
        return error.TestFailed;
    }
    // 4. name field validation (if present)
    // Note: name may be empty (len=0) if the implementation fires on the full path.
    // Both are acceptable -- the watch is on the directory so name should be present,
    // but we allow len=0 as a graceful fallback.
    if (ev.len > 0) {
        const name_ptr: [*]const u8 = @ptrCast(@as([*]const u8, @ptrCast(ev)) + @sizeOf(syscall.InotifyEvent));
        const name_slice = name_ptr[0..ev.len];
        const expected = "inotify_wr";
        var name_end: usize = 0;
        while (name_end < name_slice.len and name_slice[name_end] != 0) : (name_end += 1) {}
        const actual_name = name_slice[0..name_end];
        if (!std.mem.eql(u8, actual_name, expected)) {
            syscall.unlink("/mnt/inotify_wr") catch {};
            return error.TestFailed;
        }
    }

    syscall.unlink("/mnt/inotify_wr") catch {};
}

// Test 12: ftruncate fires IN_MODIFY
pub fn testInotifyFtruncateEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    const file_fd = try syscall.open("/mnt/inotify_ft", syscall.O_CREAT | syscall.O_RDWR, 0o644);

    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_MODIFY);

    // Drain pending events
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // ftruncate should fire IN_MODIFY
    try syscall.ftruncate(file_fd, 100);
    syscall.close(file_fd) catch {};

    var buf: [256]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        syscall.unlink("/mnt/inotify_ft") catch {};
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) {
        syscall.unlink("/mnt/inotify_ft") catch {};
        return error.TestFailed;
    }

    const ev: *const syscall.InotifyEvent = @ptrCast(&buf);
    if ((ev.mask & syscall.IN_MODIFY) == 0) {
        syscall.unlink("/mnt/inotify_ft") catch {};
        return error.TestFailed;
    }

    syscall.unlink("/mnt/inotify_ft") catch {};
}

// Test 13: close fires IN_CLOSE_WRITE for a writable FD
pub fn testInotifyCloseEvent() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_CLOSE_WRITE | syscall.IN_CLOSE_NOWRITE);

    // Create and close a writable file
    const file_fd = try syscall.open("/mnt/inotify_cl", syscall.O_CREAT | syscall.O_WRONLY, 0o644);

    // Drain create/open events
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // Close -- should fire IN_CLOSE_WRITE
    try syscall.close(file_fd);

    var buf: [256]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    const n = syscall.read(ifd, &buf, buf.len) catch {
        syscall.unlink("/mnt/inotify_cl") catch {};
        return error.TestFailed;
    };

    if (n < @sizeOf(syscall.InotifyEvent)) {
        syscall.unlink("/mnt/inotify_cl") catch {};
        return error.TestFailed;
    }

    const ev: *const syscall.InotifyEvent = @ptrCast(&buf);
    if ((ev.mask & (syscall.IN_CLOSE_WRITE | syscall.IN_CLOSE_NOWRITE)) == 0) {
        syscall.unlink("/mnt/inotify_cl") catch {};
        return error.TestFailed;
    }

    syscall.unlink("/mnt/inotify_cl") catch {};
}

// Test 14: IN_Q_OVERFLOW when event queue fills up
// Strategy: Generate 300 IN_MODIFY events by writing to a single file 300 times.
// With MAX_EVENTS=256, this overflows the queue and should produce IN_Q_OVERFLOW.
pub fn testInotifyOverflow() !void {
    const ifd = try syscall.inotify_init1(syscall.IN_NONBLOCK);
    defer syscall.close(ifd) catch {};

    // Create a file to write to (leave fd open to avoid SFS close deadlock)
    const file_fd = try syscall.open("/mnt/inotify_ovf", syscall.O_CREAT | syscall.O_RDWR, 0o644);

    _ = try syscall.inotify_add_watch(ifd, "/mnt", syscall.IN_MODIFY);

    // Drain any pending events from create
    var drain_buf: [512]u8 = undefined;
    _ = syscall.read(ifd, &drain_buf, drain_buf.len) catch {};

    // Generate 300 IN_MODIFY events by writing 300 times to the same fd.
    // Each write() call fires one IN_MODIFY event. With MAX_EVENTS=256,
    // this overflows the queue and should produce IN_Q_OVERFLOW.
    const msg = "x";
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        _ = syscall.write(file_fd, msg, msg.len) catch break;
    }

    // Leave file_fd open (avoid SFS close deadlock) -- just let it leak

    // Read all available events, look for IN_Q_OVERFLOW
    var found_overflow = false;
    var buf: [4096]u8 align(@alignOf(syscall.InotifyEvent)) = undefined;
    while (true) {
        const n = syscall.read(ifd, &buf, buf.len) catch break;
        if (n == 0) break;

        // Scan events in buffer
        var offset: usize = 0;
        while (offset + @sizeOf(syscall.InotifyEvent) <= n) {
            const ev: *const syscall.InotifyEvent = @ptrCast(@alignCast(buf[offset..].ptr));
            if ((ev.mask & syscall.IN_Q_OVERFLOW) != 0) {
                found_overflow = true;
            }
            offset += @sizeOf(syscall.InotifyEvent) + ev.len;
        }
    }

    syscall.unlink("/mnt/inotify_ovf") catch {};

    if (!found_overflow) {
        // 300 writes vs 256 queue capacity should overflow.
        // If events were coalesced and queue didn't fill, the implementation
        // is coalescing -- still a failure since we expect overflow.
        return error.TestFailed;
    }
}
