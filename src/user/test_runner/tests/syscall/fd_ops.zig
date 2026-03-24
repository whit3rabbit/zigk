const std = @import("std");
const syscall = @import("syscall");

// fcntl commands
const F_DUPFD: i32 = 0;
const F_GETFD: i32 = 1;
const F_GETFL: i32 = 3;

// fcntl flags
const FD_CLOEXEC: i32 = 1;

// Test 1: dup() returns a new fd that reads the same file
pub fn testDupBasic() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    const new_fd = try syscall.dup(fd);
    defer syscall.close(new_fd) catch {};

    // New fd must be different
    if (new_fd == fd) return error.TestFailed;

    // Both should read the same data (ELF magic)
    var buf1: [4]u8 = undefined;
    var buf2: [4]u8 = undefined;
    const n1 = try syscall.read(fd, &buf1, 4);
    _ = try syscall.lseek(new_fd, 0, syscall.SEEK_SET);
    const n2 = try syscall.read(new_fd, &buf2, 4);

    if (n1 != 4 or n2 != 4) return error.TestFailed;
    if (!std.mem.eql(u8, &buf1, &buf2)) return error.TestFailed;
}

// Test 2: dup2() redirects new fd to same file
pub fn testDup2Basic() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Pick a high fd number unlikely to be in use
    const target_fd: i32 = 50;
    const result = try syscall.dup2(fd, target_fd);
    defer syscall.close(target_fd) catch {};

    if (result != target_fd) return error.TestFailed;

    // Read from the new fd
    var buf: [4]u8 = undefined;
    const n = try syscall.read(target_fd, &buf, 4);
    if (n != 4) return error.TestFailed;

    // Should be ELF magic
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 3: dup2(fd, fd) is a no-op, returns fd
pub fn testDup2SameFd() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    const result = try syscall.dup2(fd, fd);
    if (result != fd) return error.TestFailed;
}

// Test 4: dup2 closes the target fd if it was open
pub fn testDup2ClosesTarget() !void {
    const fd1 = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd1) catch {};

    // Open a second file to get another fd
    const fd2 = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);

    // dup2(fd1, fd2) should close fd2 and make it a dup of fd1
    const result = try syscall.dup2(fd1, fd2);
    defer syscall.close(fd2) catch {};

    if (result != fd2) return error.TestFailed;

    // fd2 should now work (not be a stale fd)
    var buf: [4]u8 = undefined;
    const n = try syscall.read(fd2, &buf, 4);
    if (n != 4) return error.TestFailed;
}

// Test 5: pipe() creates a read/write pair
pub fn testPipeBasic() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Write to write end
    const msg = "hello";
    const written = try syscall.write(pipefd[1], msg.ptr, msg.len);
    if (written != msg.len) return error.TestFailed;

    // Read from read end
    var buf: [16]u8 = undefined;
    const n = try syscall.read(pipefd[0], &buf, buf.len);
    if (n != msg.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..n], msg)) return error.TestFailed;
}

// Test 6: pipe direction - pipefd[0] is read, pipefd[1] is write
pub fn testPipeDirection() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Writing to read end should fail
    const msg = "x";
    const write_result = syscall.write(pipefd[0], msg.ptr, msg.len);
    if (write_result) |_| {
        return error.TestFailed; // Should have failed
    } else |_| {
        // Expected error (EBADF or similar)
    }
}

// Test 7: closing write end causes read to return 0 (EOF)
pub fn testPipeClose() !void {
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer syscall.close(pipefd[0]) catch {};

    // Close write end
    try syscall.close(pipefd[1]);

    // Read should return 0 (EOF)
    var buf: [16]u8 = undefined;
    const n = try syscall.read(pipefd[0], &buf, buf.len);
    if (n != 0) return error.TestFailed;
}

// Test 8: fcntl F_GETFL returns flags
pub fn testFcntlGetFlags() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    const flags = try syscall.fcntl(fd, F_GETFL, 0);
    // O_RDONLY is 0, so flags & 3 (access mode mask) should be 0
    if (flags & 3 != 0) return error.TestFailed;
}

// Test 9: fcntl F_DUPFD duplicates fd
pub fn testFcntlDupfd() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    const new_fd_raw = try syscall.fcntl(fd, F_DUPFD, 0);
    const new_fd: i32 = @intCast(new_fd_raw);
    defer syscall.close(new_fd) catch {};

    if (new_fd == fd) return error.TestFailed;

    // Should be able to read from the new fd
    var buf: [4]u8 = undefined;
    const n = try syscall.read(new_fd, &buf, 4);
    if (n != 4) return error.TestFailed;
}

// Test 10: pread64 reads without changing file position
pub fn testPread64Basic() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Read at offset 0 using pread64
    var buf: [4]u8 = undefined;
    const n = try syscall.pread64(fd, &buf, 4, 0);
    if (n != 4) return error.TestFailed;

    // Should be ELF magic
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }

    // File position should still be 0 (pread64 doesn't change it)
    const pos = try syscall.lseek(fd, 0, syscall.SEEK_CUR);
    if (pos != 0) return error.TestFailed;
}

// Test 11: dup3 with O_CLOEXEC sets close-on-exec flag
pub fn testDup3Cloexec() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // dup3 with O_CLOEXEC to a specific fd
    const target_fd: i32 = 55;
    const result = try syscall.dup3(fd, target_fd, syscall.O_CLOEXEC);
    defer syscall.close(target_fd) catch {};

    if (result != target_fd) return error.TestFailed;

    // fcntl(F_GETFD) should return FD_CLOEXEC (1)
    const fd_flags = try syscall.fcntl(target_fd, F_GETFD, 0);
    if ((fd_flags & FD_CLOEXEC) == 0) return error.TestFailed;
}

// Test 12: dup3 with same oldfd and newfd returns EINVAL
pub fn testDup3SameFdReturnsEinval() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // dup3 with oldfd == newfd should return EINVAL (unlike dup2)
    const result = syscall.dup3(fd, fd, 0);
    if (result != error.InvalidArgument) return error.TestFailed;
}

// Test 13: dup3 with invalid flags returns EINVAL
pub fn testDup3InvalidFlags() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Invalid flags beyond O_CLOEXEC should be rejected
    const target_fd: i32 = 56;
    const invalid_flags: usize = 0xFFFF;
    const result = syscall.dup3(fd, target_fd, invalid_flags);
    if (result != error.InvalidArgument) return error.TestFailed;
}
