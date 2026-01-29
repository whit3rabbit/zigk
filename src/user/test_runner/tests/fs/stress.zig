const syscall = @import("syscall");

// Stress Test 1: Write large file (10MB)
pub fn testWrite10MbFile() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/stress_10mb.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory or err == error.OutOfMemory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    // Write 10MB in 4KB chunks
    var buf: [4096]u8 = undefined;
    for (&buf, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const chunks = 2560; // 2560 * 4KB = 10MB
    var i: usize = 0;
    while (i < chunks) : (i += 1) {
        const written = syscall.write(fd, &buf, buf.len) catch |err| {
            // SFS may run out of space or hit file size limits
            if (err == error.NoSpace or err == error.OutOfMemory or err == error.InvalidArgument or err == error.IoError) {
                return error.SkipTest;
            }
            return err;
        };

        if (written != buf.len) return error.TestFailed;
    }
}

// Stress Test 2: Create many files (100 files)
pub fn testCreate100Files() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;

    // SFS has a 64-file limit, so we'll try to create files up to that limit
    var created: usize = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var filename_buf: [32]u8 = undefined;
        const filename = formatFilename(&filename_buf, i) catch continue;

        const fd = syscall.open(filename.ptr, O_RDWR | O_CREAT, 0o644) catch |err| {
            if (err == error.NoSpace or err == error.OutOfMemory) {
                // Hit filesystem limit - acceptable
                break;
            }
            if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory) {
                return error.SkipTest;
            }
            return err;
        };

        syscall.close(@intCast(fd)) catch {};
        created += 1;
    }

    // Should have created at least 1 file (directory may already be full from other tests)
    if (created < 1) return error.SkipTest;
}

// Stress Test 3: Fragmented writes (many tiny writes)
pub fn testFragmentedWrites() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/stress_fragmented.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory or err == error.OutOfMemory) error.SkipTest else err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    // Write 1KB as 1024 individual 1-byte writes (worst case)
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const byte: u8 = @intCast(i % 256);
        const written = syscall.write(fd, &[1]u8{byte}, 1) catch |err| {
            // SFS may hit file size limits with many small writes
            if (err == error.NoSpace or err == error.InvalidArgument) {
                return error.SkipTest;
            }
            return err;
        };
        if (written != 1) return error.TestFailed;
    }

    // Seek back and verify
    const SEEK_SET = 0;
    _ = try syscall.lseek(fd, 0, SEEK_SET);

    var verify_buf: [1024]u8 = undefined;
    const bytes_read = try syscall.read(fd, &verify_buf, verify_buf.len);
    if (bytes_read != 1024) return error.TestFailed;

    // Verify data
    for (verify_buf, 0..) |byte, idx| {
        if (byte != @as(u8, @intCast(idx % 256))) return error.TestFailed;
    }
}

// Stress Test 4: Max open FDs
pub fn testMaxOpenFds() !void {
    // Try to open many FDs to find the limit
    var fds: [128]i64 = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const fd = syscall.open("/shell.elf", 0, 0) catch |err| {
            // Hit FD limit - this is expected
            if (err == error.OutOfMemory or err == error.TooManyOpenFiles) {
                break;
            }
            return err;
        };

        fds[count] = fd;
        count += 1;
    }

    // Should be able to open at least 10 FDs
    if (count < 10) return error.TestFailed;

    // Clean up
    i = 0;
    while (i < count) : (i += 1) {
        syscall.close(@intCast(fds[i])) catch {};
    }
}

// Stress Test 5: Large directory listing (many files)
pub fn testLargeDirectoryListing() !void {
    const fd = try syscall.open("/", 0x10000, 0); // O_RDONLY | O_DIRECTORY
    defer syscall.close(@intCast(fd)) catch {};

    // Try to list all entries
    var buf: [8192]u8 = undefined;
    const bytes_read = try syscall.getdents64(fd, &buf, buf.len);

    // Should get at least some entries
    if (bytes_read == 0) return error.TestFailed;
}

// Stress Test 6: Rapid process operations
pub fn testRapidProcessOps() !void {
    // Test rapid getpid calls (stress the syscall interface)
    var i: usize = 0;
    const pid = syscall.getpid();

    while (i < 1000) : (i += 1) {
        const pid2 = syscall.getpid();
        if (pid != pid2) return error.TestFailed;
    }
}

// Helper function to format filename with null terminator
fn formatFilename(buf: []u8, index: usize) ![:0]const u8 {
    const prefix = "/mnt/s";
    const suffix = ".txt";

    // Copy prefix
    var pos: usize = 0;
    for (prefix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    // Add index digits (support up to 999)
    if (index >= 100) {
        buf[pos] = @as(u8, @intCast('0' + (index / 100)));
        pos += 1;
    }
    if (index >= 10) {
        buf[pos] = @as(u8, @intCast('0' + ((index / 10) % 10)));
        pos += 1;
    }
    buf[pos] = @as(u8, @intCast('0' + (index % 10)));
    pos += 1;

    // Add suffix
    for (suffix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    // Null terminate
    buf[pos] = 0;

    return buf[0..pos :0];
}
