const std = @import("std");
const syscall = @import("syscall");

// Test 1: readv basic - scatter-gather read
pub fn testReadvBasic() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Create 2 buffers to read ELF magic split across them
    var buf1: [4]u8 = undefined;
    var buf2: [12]u8 = undefined;

    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf1), .len = buf1.len },
        .{ .base = @intFromPtr(&buf2), .len = buf2.len },
    };

    const total = try syscall.readv(fd, &iovecs);
    if (total < 16) return error.TestFailed;

    // Verify ELF magic in first buffer
    if (buf1[0] != 0x7F or buf1[1] != 'E' or buf1[2] != 'L' or buf1[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 2: readv with empty vector - should return 0
pub fn testReadvEmptyVec() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var iovecs: [0]syscall.Iovec = .{};
    const total = try syscall.readv(fd, &iovecs);
    if (total != 0) return error.TestFailed;
}

// Test 3: writev then readv roundtrip on SFS
pub fn testWritevReadv() !void {
    const fd = syscall.open("/mnt/test_vio.txt", syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest; // SFS may not be available
    };
    defer syscall.close(fd) catch {};

    // Write two buffers
    const msg1 = "Hello";
    const msg2 = " World";
    var write_iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(msg1.ptr), .len = msg1.len },
        .{ .base = @intFromPtr(msg2.ptr), .len = msg2.len },
    };

    const written = try syscall.writev(fd, &write_iovecs);
    if (written != 11) return error.TestFailed;

    // Seek back to start
    _ = try syscall.lseek(fd, 0, syscall.SEEK_SET);

    // Read back into two buffers
    var buf1: [5]u8 = undefined;
    var buf2: [6]u8 = undefined;
    var read_iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf1), .len = buf1.len },
        .{ .base = @intFromPtr(&buf2), .len = buf2.len },
    };

    const total = try syscall.readv(fd, &read_iovecs);
    if (total != 11) return error.TestFailed;

    // Verify data
    if (!std.mem.eql(u8, &buf1, "Hello")) return error.TestFailed;
    if (!std.mem.eql(u8, &buf2, " World")) return error.TestFailed;
}

// Test 4: preadv basic - positional vectored read
pub fn testPreadvBasic() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Advance position
    var dummy: [4]u8 = undefined;
    _ = try syscall.read(fd, &dummy, 4);

    // preadv from offset 0 (should not change position)
    var buf: [4]u8 = undefined;
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    };

    const total = try syscall.preadv(fd, &iovecs, 0);
    if (total != 4) return error.TestFailed;

    // Verify ELF magic read from offset 0
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }

    // Verify position is still 4 (not changed by preadv)
    const pos = try syscall.lseek(fd, 0, syscall.SEEK_CUR);
    if (pos != 4) return error.TestFailed;
}

// Test 5: pwritev basic - positional vectored write
pub fn testPwritevBasic() !void {
    const fd = syscall.open("/mnt/test_pwv.txt", syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest; // SFS may not be available
    };
    defer syscall.close(fd) catch {};

    // Write 10 A's
    const initial = "AAAAAAAAAA";
    _ = try syscall.write(fd, initial.ptr, initial.len);

    // pwritev at offset 3: write "XX"
    const patch = "XX";
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(patch.ptr), .len = patch.len },
    };

    _ = try syscall.pwritev(fd, &iovecs, 3);

    // Verify position still 10 (not changed by pwritev)
    const pos = try syscall.lseek(fd, 0, syscall.SEEK_CUR);
    if (pos != 10) return error.TestFailed;

    // Read back and verify
    _ = try syscall.lseek(fd, 0, syscall.SEEK_SET);
    var buf: [10]u8 = undefined;
    const n = try syscall.read(fd, &buf, buf.len);
    if (n != 10) return error.TestFailed;

    // Should be "AAAXXAAAAA"
    if (buf[3] != 'X' or buf[4] != 'X') return error.TestFailed;
    if (buf[0] != 'A' or buf[2] != 'A' or buf[5] != 'A') return error.TestFailed;
}

// Test 6: preadv2 with flags=0 - should behave like preadv
pub fn testPreadv2FlagsZero() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var buf: [4]u8 = undefined;
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    };

    const total = try syscall.preadv2(fd, &iovecs, 0, 0);
    if (total != 4) return error.TestFailed;

    // Verify ELF magic
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 7: pwritev2 with flags=0 - should behave like pwritev
pub fn testPwritev2FlagsZero() !void {
    const fd = syscall.open("/mnt/test_pwv2.txt", syscall.O_RDWR | syscall.O_CREAT | syscall.O_TRUNC, 0o644) catch {
        return error.SkipTest; // SFS may not be available
    };
    defer syscall.close(fd) catch {};

    // Write 10 B's
    const initial = "BBBBBBBBBB";
    _ = try syscall.write(fd, initial.ptr, initial.len);

    // pwritev2 at offset 5: write "YY"
    const patch = "YY";
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(patch.ptr), .len = patch.len },
    };

    _ = try syscall.pwritev2(fd, &iovecs, 5, 0);

    // Read back and verify
    _ = try syscall.lseek(fd, 0, syscall.SEEK_SET);
    var buf: [10]u8 = undefined;
    const n = try syscall.read(fd, &buf, buf.len);
    if (n != 10) return error.TestFailed;

    // Should be "BBBBBYYYYY" - wait, offset 5 means positions 5,6 become YY
    // So: BBBBBYYБBB
    if (buf[5] != 'Y' or buf[6] != 'Y') return error.TestFailed;
}

// Test 8: preadv2 with offset=-1 - should use current position
pub fn testPreadv2OffsetNeg1() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Explicit seek to start
    _ = try syscall.lseek(fd, 0, syscall.SEEK_SET);

    var buf: [4]u8 = undefined;
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    };

    const total = try syscall.preadv2(fd, &iovecs, -1, 0);
    if (total != 4) return error.TestFailed;

    // Verify ELF magic (read from current position 0)
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 9: preadv2 with RWF_HIPRI flag - should return NotImplemented
pub fn testPreadv2HipriFlag() !void {
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    var buf: [4]u8 = undefined;
    var iovecs = [_]syscall.Iovec{
        .{ .base = @intFromPtr(&buf), .len = buf.len },
    };

    // RWF_HIPRI should return ENOSYS (NotImplemented)
    const result = syscall.preadv2(fd, &iovecs, 0, syscall.RWF_HIPRI);
    if (result) |_| {
        return error.TestFailed; // Should have returned error
    } else |err| {
        if (err != error.NotImplemented) return error.TestFailed;
    }
}

// Test 10: sendfile basic - transfer file data through pipe
pub fn testSendfileBasic() !void {
    // Create pipe
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Open source file
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // sendfile 64 bytes from file to pipe
    const sent = try syscall.sendfile(pipefd[1], fd, null, 64);
    if (sent != 64) return error.TestFailed;

    // Read from pipe and verify ELF magic
    var buf: [64]u8 = undefined;
    const n = try syscall.read(pipefd[0], &buf, buf.len);
    if (n != 64) return error.TestFailed;

    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 11: sendfile with offset pointer - should update offset
pub fn testSendfileWithOffset() !void {
    // Create pipe
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Open source file
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // sendfile with offset pointer
    var offset: u64 = 0;
    const sent = try syscall.sendfile(pipefd[1], fd, &offset, 16);
    if (sent != 16) return error.TestFailed;

    // Offset should be updated to 16
    if (offset != 16) return error.TestFailed;

    // in_fd position should still be 0 (sendfile with offset doesn't change it)
    const pos = try syscall.lseek(fd, 0, syscall.SEEK_CUR);
    if (pos != 0) return error.TestFailed;
}

// Test 12: sendfile with invalid in_fd - should return BadFileDescriptor
pub fn testSendfileInvalidFd() !void {
    // Create pipe
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Invalid in_fd (999)
    const result = syscall.sendfile(pipefd[1], 999, null, 64);
    if (result) |_| {
        return error.TestFailed; // Should have returned error
    } else |err| {
        if (err != error.BadFileDescriptor) return error.TestFailed;
    }
}

// Test 13: sendfile large transfer - verify multi-page transfer works
pub fn testSendfileLargeTransfer() !void {
    // Open a large source file (shell.elf is >4KB)
    const fd = try syscall.open("/shell.elf", syscall.O_RDONLY, 0);
    defer syscall.close(fd) catch {};

    // Create a pipe for destination
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);
    defer {
        syscall.close(pipefd[0]) catch {};
        syscall.close(pipefd[1]) catch {};
    }

    // Transfer 8KB (larger than old 4KB buffer, exercises multi-chunk path)
    const transfer_size: usize = 8192;
    var offset: u64 = 0;
    const sent = try syscall.sendfile(pipefd[1], fd, &offset, transfer_size);

    // Should have sent the requested amount (shell.elf is large enough)
    if (sent != transfer_size) return error.TestFailed;

    // Verify offset was updated
    if (offset != transfer_size) return error.TestFailed;

    // Read back from pipe and verify first bytes match ELF magic
    var verify_buf: [4]u8 = undefined;
    const read_bytes = try syscall.read(pipefd[0], &verify_buf, verify_buf.len);
    if (read_bytes != 4) return error.TestFailed;
    if (verify_buf[0] != 0x7F or verify_buf[1] != 'E' or verify_buf[2] != 'L' or verify_buf[3] != 'F') {
        return error.TestFailed;
    }
}
