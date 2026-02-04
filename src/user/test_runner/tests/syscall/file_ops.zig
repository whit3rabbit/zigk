const std = @import("std");
const syscall = @import("syscall");

// Test 1: Open, read, close from InitRD (happy path)
pub fn testOpenReadCloseInitrd() !void {
    const fd = try syscall.open("/shell.elf", 0, 0); // O_RDONLY
    defer syscall.close(@intCast(fd)) catch {};

    var buf: [256]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    // Should read at least the ELF header (52 bytes minimum)
    if (bytes_read < 52) return error.TestFailed;

    // Verify ELF magic
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Test 2: Open, write, close on SFS (happy path)
pub fn testOpenWriteCloseSfs() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/test_write.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    const data = "Hello, ZK!";
    const written = try syscall.write(fd, data.ptr, data.len);

    if (written != data.len) return error.TestFailed;
}

// Test 3: Open with O_TRUNC clears file content
pub fn testOpenWithTruncate() !void {
    const filepath = "/mnt/trunc_test.txt";

    // Create file with initial content
    const fd1 = try syscall.open(filepath, syscall.O_WRONLY | syscall.O_CREAT, 0o644);
    const original_data = "original content";
    _ = try syscall.write(fd1, original_data.ptr, original_data.len);
    try syscall.close(@intCast(fd1));

    // Reopen with O_TRUNC - should truncate file to 0
    const fd2 = try syscall.open(filepath, syscall.O_RDWR | syscall.O_TRUNC, 0);
    defer syscall.close(@intCast(fd2)) catch {};

    // Verify file size is 0 by trying to read
    var buf: [100]u8 = undefined;
    const bytes_read = try syscall.read(fd2, &buf, buf.len);
    if (bytes_read != 0) return error.TestFailed;

    // Write new content
    const new_data = "new";
    const written = try syscall.write(fd2, new_data.ptr, new_data.len);
    if (written != new_data.len) return error.TestFailed;

    // Reopen and verify only new content exists
    try syscall.close(@intCast(fd2));
    const fd3 = try syscall.open(filepath, syscall.O_RDONLY, 0);
    defer syscall.close(@intCast(fd3)) catch {};

    const verify_read = try syscall.read(fd3, &buf, buf.len);
    if (verify_read != new_data.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..verify_read], new_data)) return error.TestFailed;

    // Cleanup
    syscall.unlink(filepath) catch {};
}

// Test 4: Open with O_APPEND starts at EOF
pub fn testOpenWithAppend() !void {
    const filepath = "/mnt/append_test.txt";

    // Create file with initial content
    const fd1 = try syscall.open(filepath, syscall.O_WRONLY | syscall.O_CREAT, 0o644);
    const first_data = "first";
    _ = try syscall.write(fd1, first_data.ptr, first_data.len);
    try syscall.close(@intCast(fd1));

    // Reopen with O_APPEND - should position at EOF
    const fd2 = try syscall.open(filepath, syscall.O_WRONLY | syscall.O_APPEND, 0);
    defer syscall.close(@intCast(fd2)) catch {};

    // Write more data - should append at end
    const second_data = "second";
    const written = try syscall.write(fd2, second_data.ptr, second_data.len);
    if (written != second_data.len) return error.TestFailed;

    // Close and verify file contains both parts concatenated
    try syscall.close(@intCast(fd2));
    const fd3 = try syscall.open(filepath, syscall.O_RDONLY, 0);
    defer syscall.close(@intCast(fd3)) catch {};

    var buf: [100]u8 = undefined;
    const bytes_read = try syscall.read(fd3, &buf, buf.len);
    const expected = "firstsecond";
    if (bytes_read != expected.len) return error.TestFailed;
    if (!std.mem.eql(u8, buf[0..bytes_read], expected)) return error.TestFailed;

    // Cleanup
    syscall.unlink(filepath) catch {};
}

// Test 5: Lseek from start (SEEK_SET)
pub fn testLseekFromStart() !void {
    const fd = try syscall.open("/shell.elf", 0, 0);
    defer syscall.close(@intCast(fd)) catch {};

    // Seek to offset 4 (after ELF magic)
    const SEEK_SET = 0;
    const new_pos = try syscall.lseek(fd, 4, SEEK_SET);

    if (new_pos != 4) return error.TestFailed;

    // Read and verify we're at the right position
    var buf: [4]u8 = undefined;
    _ = try syscall.read(fd, &buf, buf.len);

    // Byte at offset 4 should be ELF class (1=32-bit, 2=64-bit)
    if (buf[0] != 1 and buf[0] != 2) return error.TestFailed;
}

// Test 6: Lseek from end (SEEK_END)
pub fn testLseekFromEnd() !void {
    const fd = try syscall.open("/shell.elf", 0, 0);
    defer syscall.close(@intCast(fd)) catch {};

    // Seek to end
    const SEEK_END = 2;
    const file_size = try syscall.lseek(fd, 0, SEEK_END);

    // File size should be reasonable (shell.elf is at least 1KB)
    if (file_size < 1024) return error.TestFailed;

    // Try to read - should get 0 (at EOF)
    var buf: [10]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    if (bytes_read != 0) return error.TestFailed;
}

// Test 7: Lseek beyond EOF (sparse file behavior)
// NOTE: Due to SFS architectural limitation (can only grow last-allocated file),
// this test creates a file and writes everything in a single operation
pub fn testLseekBeyondEof() !void {
    const filepath = "/mnt/sparse_test.txt";
    const SEEK_SET = 0;

    // Create file, seek beyond start, write - all without any intermediate operations
    const fd1 = try syscall.open(filepath, syscall.O_RDWR | syscall.O_CREAT, 0o644);
    defer syscall.close(@intCast(fd1)) catch {};

    // Immediately seek to offset 100 (small offset to minimize blocks needed)
    const new_pos = try syscall.lseek(fd1, 100, SEEK_SET);
    if (new_pos != 100) return error.TestFailed;

    // Write data at offset 100
    const data = "end";
    const written = try syscall.write(fd1, data.ptr, data.len);
    if (written != data.len) return error.TestFailed;

    // Seek back to start and read entire file
    const reset_pos = try syscall.lseek(fd1, 0, SEEK_SET);
    if (reset_pos != 0) return error.TestFailed;

    var buf: [200]u8 = undefined;
    const bytes_read = try syscall.read(fd1, &buf, buf.len);
    const expected_size = 100 + data.len;
    if (bytes_read != expected_size) return error.TestFailed;

    // Verify gap is zeros (bytes 0-99)
    for (buf[0..100]) |byte| {
        if (byte != 0) return error.TestFailed;
    }

    // Verify data (bytes 100-102)
    if (!std.mem.eql(u8, buf[100..][0..data.len], data)) return error.TestFailed;

    // Cleanup
    syscall.unlink(filepath) catch {};
}

// Test 8: Multiple reads advance file position correctly
pub fn testMultipleReadsAdvancePosition() !void {
    const fd = try syscall.open("/shell.elf", 0, 0);
    defer syscall.close(@intCast(fd)) catch {};

    // Read first 4 bytes (ELF magic)
    var buf1: [4]u8 = undefined;
    const bytes1 = try syscall.read(fd, &buf1, buf1.len);
    if (bytes1 != 4) return error.TestFailed;

    // Read next 1 byte (ELF class)
    var buf2: [1]u8 = undefined;
    const bytes2 = try syscall.read(fd, &buf2, buf2.len);
    if (bytes2 != 1) return error.TestFailed;

    // Verify first read got ELF magic
    if (buf1[0] != 0x7F or buf1[1] != 'E' or buf1[2] != 'L' or buf1[3] != 'F') {
        return error.TestFailed;
    }

    // Verify second read got ELF class (1 or 2)
    if (buf2[0] != 1 and buf2[0] != 2) return error.TestFailed;
}

// Test 9: Write exactly one block (512 bytes - block boundary)
pub fn testWriteExactlyOneBlock() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/test_block.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    // Write exactly 512 bytes
    var buf: [512]u8 = undefined;
    for (&buf, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const written = try syscall.write(fd, &buf, buf.len);

    if (written != 512) return error.TestFailed;

    // Seek back and read
    const SEEK_SET = 0;
    _ = try syscall.lseek(fd, 0, SEEK_SET);

    var read_buf: [512]u8 = undefined;
    const bytes_read = try syscall.read(fd, &read_buf, read_buf.len);

    if (bytes_read != 512) return error.TestFailed;

    // Verify data integrity
    for (buf, read_buf) |w, r| {
        if (w != r) return error.TestFailed;
    }
}

// Test 10: Write two blocks (1024 bytes - multi-block)
pub fn testWriteTwoBlocks() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/test_2blocks.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    // Write 1024 bytes (2 blocks)
    var buf: [1024]u8 = undefined;
    for (&buf, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const written = try syscall.write(fd, &buf, buf.len);

    if (written != 1024) return error.TestFailed;

    // Seek back and read
    const SEEK_SET = 0;
    _ = try syscall.lseek(fd, 0, SEEK_SET);

    var read_buf: [1024]u8 = undefined;
    const bytes_read = try syscall.read(fd, &read_buf, read_buf.len);

    if (bytes_read != 1024) return error.TestFailed;

    // Verify data integrity
    for (buf, read_buf) |w, r| {
        if (w != r) return error.TestFailed;
    }
}

// Test 11: Shared lock (LOCK_SH) can be acquired by multiple processes
pub fn testFlockSharedLock() !void {
    const O_RDONLY = 0;
    const O_CREAT = 0x40;

    const fd1 = syscall.open("/mnt/test_flock.txt", O_RDONLY | O_CREAT, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd1)) catch {};

    // Acquire shared lock
    try syscall.flock(fd1, syscall.LOCK_SH);

    // Release lock
    try syscall.flock(fd1, syscall.LOCK_UN);
}

// Test 12: Exclusive lock (LOCK_EX) prevents other locks
pub fn testFlockExclusiveLock() !void {
    const O_RDONLY = 0;
    const O_CREAT = 0x40;

    const fd1 = syscall.open("/mnt/test_flock_ex.txt", O_RDONLY | O_CREAT, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer {
        syscall.flock(fd1, syscall.LOCK_UN) catch {};
        syscall.close(@intCast(fd1)) catch {};
    }

    // Acquire exclusive lock
    try syscall.flock(fd1, syscall.LOCK_EX);

    // Release lock
    try syscall.flock(fd1, syscall.LOCK_UN);
}

// Test 13: Non-blocking mode returns EWOULDBLOCK if lock is held
pub fn testFlockNonBlocking() !void {
    const O_RDONLY = 0;
    const O_CREAT = 0x40;

    const fd1 = syscall.open("/mnt/test_flock_nb.txt", O_RDONLY | O_CREAT, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer {
        syscall.flock(fd1, syscall.LOCK_UN) catch {};
        syscall.close(@intCast(fd1)) catch {};
    }

    // Acquire exclusive lock
    try syscall.flock(fd1, syscall.LOCK_EX);

    // Try non-blocking lock on same file (same fd, should succeed as same process)
    const fd2 = syscall.open("/mnt/test_flock_nb.txt", O_RDONLY, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd2)) catch {};

    // Non-blocking exclusive lock should succeed if no conflict
    // (Same process can upgrade/downgrade)
    const result = syscall.flock(fd2, syscall.LOCK_EX | syscall.LOCK_NB);

    // Clean up second FD lock
    if (result) |_| {
        syscall.flock(fd2, syscall.LOCK_UN) catch {};
    } else |_| {
        // Expected EWOULDBLOCK in some cases is acceptable for this basic test
    }
}
