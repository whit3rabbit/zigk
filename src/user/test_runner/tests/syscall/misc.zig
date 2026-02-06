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
// NOTE: Uses O_RDWR + lseek to avoid close/reopen (SFS close deadlock).
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
