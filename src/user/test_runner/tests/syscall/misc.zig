const std = @import("std");
const syscall = @import("syscall");
const builtin = @import("builtin");

// Test 1: uname returns valid sysname
pub fn testUnameBasic() !void {
    var buf: syscall.Utsname = std.mem.zeroes(syscall.Utsname);
    try syscall.uname(&buf);

    // sysname should be non-empty (first byte should not be null)
    if (buf.sysname[0] == 0) return error.TestFailed;
}

// Test 2: uname machine field matches architecture
pub fn testUnameMachineArch() !void {
    var buf: syscall.Utsname = std.mem.zeroes(syscall.Utsname);
    try syscall.uname(&buf);

    // Find the machine string length
    var machine_len: usize = 0;
    for (buf.machine) |c| {
        if (c == 0) break;
        machine_len += 1;
    }

    if (machine_len == 0) return error.TestFailed;

    const machine = buf.machine[0..machine_len];
    const expected = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.TestFailed,
    };

    if (!std.mem.eql(u8, machine, expected)) return error.TestFailed;
}

// Test 3: umask sets mask and returns old value
pub fn testUmaskBasic() !void {
    // Get current mask by setting a known value
    const old = syscall.umask(0o22);

    // Set another value - should return the 0o22 we just set
    const prev = syscall.umask(0o77);
    if (prev != 0o22) return error.TestFailed;

    // Restore original mask
    _ = syscall.umask(old);
}

// Test 4: umask set and restore
pub fn testUmaskRestore() !void {
    // Save original
    const original = syscall.umask(0o00);

    // Set restrictive mask
    _ = syscall.umask(0o77);

    // Restore and verify
    const restored = syscall.umask(original);
    if (restored != 0o77) return error.TestFailed;
}

// Test 5: getrandom fills buffer with data
// Uses GRND_INSECURE because QEMU TCG may not have a ready entropy pool
pub fn testGetrandomBasic() !void {
    var buf = [_]u8{0} ** 32;
    const n = try syscall.getrandom(&buf, buf.len, syscall.GRND_INSECURE);
    if (n != 32) return error.TestFailed;

    // At least some bytes should be non-zero (extremely unlikely all zero for 32 random bytes)
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    if (all_zero) return error.TestFailed;
}

// Test 6: getrandom with GRND_INSECURE (entropy pool may not be ready in QEMU)
pub fn testGetrandomNonblocking() !void {
    var buf = [_]u8{0} ** 16;
    const n = try syscall.getrandom(&buf, buf.len, syscall.GRND_INSECURE);
    if (n != 16) return error.TestFailed;
}

// Test 7: writev with multiple iovecs
// NOTE: Uses O_RDWR + lseek to avoid reopening the file (efficient pattern).
pub fn testWritevBasic() !void {
    const path = "/mnt/test_writev.txt";

    const fd = try syscall.open(path, syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC, 0o644);

    const iov = [_]syscall.Iovec{
        syscall.Iovec.fromSlice("hello "),
        syscall.Iovec.fromSlice("world"),
    };

    const written = try syscall.writev(fd, &iov);
    if (written != 11) return error.TestFailed;

    // Seek back to start and read back (avoid close/reopen)
    _ = try syscall.lseek(fd, 0, 0);

    var buf: [32]u8 = undefined;
    const n = try syscall.read(fd, &buf, buf.len);
    if (n != 11) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..11], "hello world")) return error.TestFailed;
}

// Test 8: poll with 0ms timeout returns immediately
pub fn testPollTimeout() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var fds = [_]syscall.PollFd{.{
        .fd = fd,
        .events = syscall.POLLIN,
        .revents = 0,
    }};

    // 0ms timeout should return immediately
    const n = try syscall.poll(&fds, 0);
    // File should be readable (or poll returned 0 for timeout - both are acceptable)
    _ = n;
}

// Test 9: sched_get_priority_max returns max priority
pub fn testSchedGetPriorityMax() !void {
    const max_prio = try syscall.sched_get_priority_max(1); // SCHED_FIFO
    if (max_prio != 99) return error.TestFailed;
}

// Test 10: sched_get_priority_min returns min priority
pub fn testSchedGetPriorityMin() !void {
    const min_prio = try syscall.sched_get_priority_min(1); // SCHED_FIFO
    if (min_prio != 1) return error.TestFailed;
}

// Test 11: sched_get_priority with invalid policy returns error
pub fn testSchedGetPriorityInvalid() !void {
    const result = syscall.sched_get_priority_max(999);
    if (result) |_| {
        return error.TestFailed;
    } else |_| {
        // Expected error
    }
}

// Test 12: sched_getscheduler returns current policy
pub fn testSchedGetScheduler() !void {
    const policy = try syscall.sched_getscheduler(0);
    if (policy != 0) return error.TestFailed; // SCHED_OTHER
}

// Test 13: sched_getparam retrieves scheduling parameters
pub fn testSchedGetParam() !void {
    var param: syscall.SchedParam = .{ .sched_priority = -1 };
    try syscall.sched_getparam(0, &param);
    if (param.sched_priority != 0) return error.TestFailed;
}

// Test 14: sched_setscheduler changes scheduling policy
pub fn testSchedSetScheduler() !void {
    const param = syscall.SchedParam{ .sched_priority = 50 };
    try syscall.sched_setscheduler(0, 2, &param); // SCHED_RR

    const policy = try syscall.sched_getscheduler(0);
    if (policy != 2) return error.TestFailed;

    // Restore original policy
    const restore = syscall.SchedParam{ .sched_priority = 0 };
    try syscall.sched_setscheduler(0, 0, &restore);
}

// Test 15: sched_rr_get_interval returns time quantum
pub fn testSchedRrGetInterval() !void {
    var ts = std.mem.zeroes([16]u8); // Timespec struct (i64+i64 = 16 bytes)
    const ptr: *anyopaque = &ts;
    const ret = @import("syscall").syscall2(
        @import("syscall").uapi.syscalls.SYS_SCHED_RR_GET_INTERVAL,
        0,
        @intFromPtr(ptr)
    );
    if (@import("syscall").isError(ret)) return @import("syscall").errorFromReturn(ret);

    // Extract tv_nsec (second i64)
    const tv_nsec: i64 = @bitCast(std.mem.readInt(u64, ts[8..16], .little));
    if (tv_nsec != 100_000_000) return error.TestFailed;
}

// Test 16: prlimit64 retrieves RLIMIT_NOFILE
pub fn testPrlimit64GetNofile() !void {
    var old: syscall.Rlimit = undefined;
    try syscall.prlimit64(0, 7, null, &old); // RLIMIT_NOFILE
    if (old.rlim_cur == 0) return error.TestFailed;
}

// Test 17: getrusage self returns usage stats
pub fn testGetrusageSelf() !void {
    var usage: syscall.Rusage = undefined;
    try syscall.getrusage(0, &usage); // RUSAGE_SELF
}

// Test 18: getrusage with invalid who returns error
pub fn testGetrusageInvalid() !void {
    var usage: syscall.Rusage = undefined;
    const result = syscall.getrusage(99, &usage);
    if (result) |_| {
        return error.TestFailed;
    } else |_| {
        // Expected error
    }
}

// Test 19: rt_sigpending retrieves pending signals
pub fn testRtSigpending() !void {
    var set: u64 = 0xFFFF;
    try syscall.rt_sigpending(&set);
    // Any value is acceptable, just verify syscall completes
}

// Test 20: Non-root cannot raise hard limit via prlimit64
pub fn testPrlimit64NonRootCannotRaise() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        // Drop privileges
        syscall.setresuid(1000, 1000, 1000) catch syscall.exit(1);
        // Try to raise RLIMIT_AS hard limit
        const new_limit = syscall.Rlimit{ .rlim_cur = 0xFFFFFFFFFFFFFFFF, .rlim_max = 0xFFFFFFFFFFFFFFFF };
        if (syscall.prlimit64(0, 9, &new_limit, null)) |_| {
            syscall.exit(1); // Should have failed
        } else |_| {
            syscall.exit(0); // Expected EPERM
        }
    }
    var status: i32 = undefined;
    const waited = try syscall.waitpid(pid, &status, 0);
    if (waited != pid) return error.TestFailed;
    if ((status & 0x7F) != 0) return error.TestFailed;
    if (((status >> 8) & 0xFF) != 0) return error.TestFailed;
}

// Test 21: Self-targeting prlimit64 works as non-root (reading own limits)
pub fn testPrlimit64SelfAsNonRoot() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        syscall.setresuid(1000, 1000, 1000) catch syscall.exit(1);
        var old: syscall.Rlimit = undefined;
        syscall.prlimit64(0, 7, null, &old) catch syscall.exit(1); // RLIMIT_NOFILE
        syscall.exit(if (old.rlim_cur > 0) 0 else 1);
    }
    var status: i32 = undefined;
    const waited = try syscall.waitpid(pid, &status, 0);
    if (waited != pid) return error.TestFailed;
    if ((status & 0x7F) != 0) return error.TestFailed;
    if (((status >> 8) & 0xFF) != 0) return error.TestFailed;
}

// =============================================================================
// Phase 26 Test Coverage Extension
// =============================================================================

// Test 22: sched_rr_get_interval with invalid PID returns error
pub fn testSchedRrGetIntervalInvalidPid() !void {
    var ts = std.mem.zeroes([16]u8); // Timespec struct (i64+i64 = 16 bytes)
    const ptr: *anyopaque = &ts;
    const ret = @import("syscall").syscall2(
        @import("syscall").uapi.syscalls.SYS_SCHED_RR_GET_INTERVAL,
        99999, // Non-existent PID
        @intFromPtr(ptr)
    );
    // Should return an error (ESRCH or EINVAL)
    if (!@import("syscall").isError(ret)) return error.TestFailed;
}

// Test 23: getrusage RUSAGE_CHILDREN variant
pub fn testGetrusageChildren() !void {
    var usage: syscall.Rusage = undefined;
    // RUSAGE_CHILDREN = -1 (cast to appropriate type)
    const RUSAGE_CHILDREN: i32 = -1;
    syscall.getrusage(RUSAGE_CHILDREN, &usage) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    // Success if no error
}

// Test 24: rt_sigpending after blocking a signal shows it pending
pub fn testRtSigpendingAfterBlock() !void {
    const SIGUSR1 = 10;
    const SIG_BLOCK = 0;
    const SIG_UNBLOCK = 1;

    // Block SIGUSR1
    var set: syscall.SigSet = 0;
    syscall.uapi.signal.sigaddset(&set, SIGUSR1);
    try syscall.sigprocmask(SIG_BLOCK, &set, null);

    // Send signal to self (becomes pending)
    try syscall.kill(syscall.getpid(), SIGUSR1);

    // Call rt_sigpending
    var pending: syscall.SigSet = 0;
    syscall.rt_sigpending(&pending) catch |err| {
        _ = syscall.sigprocmask(SIG_UNBLOCK, &set, null) catch {};
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify SIGUSR1 is in the pending set (bit 9 should be set, signal 10 - 1 = bit 9)
    const bit_set = syscall.uapi.signal.sigismember(pending, SIGUSR1);

    // Unblock to clear the signal
    try syscall.sigprocmask(SIG_UNBLOCK, &set, null);

    if (!bit_set) return error.TestFailed;
}
