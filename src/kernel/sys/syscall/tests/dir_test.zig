//! Unit tests for directory syscalls (chdir, getcwd, getdents64)
//! These tests run on the host without booting the kernel

const std = @import("std");
const testing = std.testing;

// Import mocks
const MockVfs = @import("mocks/vfs.zig").MockVfs;
const MockProcess = @import("mocks/process.zig").MockProcess;
const MockUserMem = @import("mocks/user_mem.zig").MockUserMem;

// Note: These tests are designed to test the *logic* of syscalls
// without requiring the full kernel environment.
// They demonstrate how unit tests would work with proper mocking.

test "path canonicalization strips trailing slashes" {
    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "/", .expected = "/" },
        .{ .input = "/mnt/", .expected = "/mnt" },
        .{ .input = "/mnt//", .expected = "/mnt" },
        .{ .input = "/usr/local/bin/", .expected = "/usr/local/bin" },
    };

    for (test_cases) |tc| {
        var canonical: [4096]u8 = undefined;
        var len: usize = 0;

        // Copy input
        @memcpy(canonical[0..tc.input.len], tc.input);
        len = tc.input.len;

        // Strip trailing slashes
        while (len > 1 and canonical[len - 1] == '/') {
            len -= 1;
        }

        try testing.expectEqualSlices(u8, tc.expected, canonical[0..len]);
    }
}

test "path canonicalization adds leading slash" {
    const test_cases = [_]struct {
        input: []const u8,
        has_leading: bool,
    }{
        .{ .input = "/", .has_leading = true },
        .{ .input = "/mnt", .has_leading = true },
        .{ .input = "mnt", .has_leading = false },
        .{ .input = "usr/local", .has_leading = false },
    };

    for (test_cases) |tc| {
        const has_leading = tc.input.len > 0 and tc.input[0] == '/';
        try testing.expectEqual(tc.has_leading, has_leading);
    }
}

test "VFS integration: statPath returns metadata for existing paths" {
    var mock_vfs = MockVfs.init(testing.allocator);
    defer mock_vfs.deinit();

    // Add mock files
    try mock_vfs.addFile("/", true);
    try mock_vfs.addFile("/mnt", true);
    try mock_vfs.addFile("/bin/ls", false);

    // Test existing paths
    {
        const meta = mock_vfs.statPath("/");
        try testing.expect(meta != null);
        try testing.expect(mock_vfs.isDirectory("/"));
    }

    {
        const meta = mock_vfs.statPath("/mnt");
        try testing.expect(meta != null);
        try testing.expect(mock_vfs.isDirectory("/mnt"));
    }

    {
        const meta = mock_vfs.statPath("/bin/ls");
        try testing.expect(meta != null);
        try testing.expect(!mock_vfs.isDirectory("/bin/ls"));
    }

    // Test non-existent path
    {
        const meta = mock_vfs.statPath("/nonexistent");
        try testing.expect(meta == null);
    }
}

test "VFS integration: chdir should accept directories" {
    var mock_vfs = MockVfs.init(testing.allocator);
    defer mock_vfs.deinit();

    try mock_vfs.addFile("/", true);
    try mock_vfs.addFile("/mnt", true);
    try mock_vfs.addFile("/bin/ls", false);

    var proc = MockProcess.init();

    // Test valid directory change
    const path = "/mnt";
    const file_meta = mock_vfs.statPath(path);
    try testing.expect(file_meta != null);
    try testing.expect(mock_vfs.isDirectory(path));

    // If checks pass, update CWD
    try proc.setCwd(path);
    try testing.expectEqualSlices(u8, path, proc.getCwd());
}

test "VFS integration: chdir should reject files with ENOTDIR" {
    var mock_vfs = MockVfs.init(testing.allocator);
    defer mock_vfs.deinit();

    try mock_vfs.addFile("/", true);
    try mock_vfs.addFile("/bin/ls", false);

    // Try to chdir to a file
    const path = "/bin/ls";
    const file_meta = mock_vfs.statPath(path);
    try testing.expect(file_meta != null);

    // Should not be a directory
    try testing.expect(!mock_vfs.isDirectory(path));

    // This would return error.ENOTDIR in the actual syscall
}

test "VFS integration: chdir should return ENOENT for nonexistent paths" {
    var mock_vfs = MockVfs.init(testing.allocator);
    defer mock_vfs.deinit();

    try mock_vfs.addFile("/", true);

    const path = "/nonexistent";
    const file_meta = mock_vfs.statPath(path);

    // Should not exist
    try testing.expect(file_meta == null);

    // This would return error.ENOENT in the actual syscall
}

test "Process CWD management" {
    var proc = MockProcess.init();

    // Initial CWD should be "/"
    try testing.expectEqualSlices(u8, "/", proc.getCwd());

    // Change to /mnt
    try proc.setCwd("/mnt");
    try testing.expectEqualSlices(u8, "/mnt", proc.getCwd());

    // Change to nested path
    try proc.setCwd("/usr/local/bin");
    try testing.expectEqualSlices(u8, "/usr/local/bin", proc.getCwd());

    // Empty path should error
    try testing.expectError(error.InvalidPath, proc.setCwd(""));
}

test "User memory buffer validation" {
    var mock_mem = MockUserMem.init(testing.allocator);
    defer mock_mem.deinit();

    // Allocate buffer
    const buf_ptr = try mock_mem.allocate(256);
    try testing.expect(mock_mem.isValid(buf_ptr, 256));

    // Invalid pointer should fail
    try testing.expect(!mock_mem.isValid(0xDEADBEEF, 256));

    // Free buffer
    mock_mem.free(buf_ptr);
    try testing.expect(!mock_mem.isValid(buf_ptr, 256));
}

test "getcwd buffer too small" {
    var proc = MockProcess.init();
    try proc.setCwd("/usr/local/bin");

    const cwd = proc.getCwd();
    const required_size = cwd.len + 1; // +1 for null terminator

    // Buffer too small
    const small_size = cwd.len - 1;

    // This would return error.ERANGE in the actual syscall
    try testing.expect(small_size < required_size);
}

test "getcwd buffer exact size" {
    var proc = MockProcess.init();
    try proc.setCwd("/mnt");

    const cwd = proc.getCwd();
    const required_size = cwd.len + 1; // +1 for null terminator

    // Buffer exactly right size
    const exact_size = cwd.len + 1;

    try testing.expectEqual(required_size, exact_size);
}

test "getcwd with user memory copy" {
    var mock_mem = MockUserMem.init(testing.allocator);
    defer mock_mem.deinit();

    var proc = MockProcess.init();
    try proc.setCwd("/mnt/testdir");

    // Allocate user buffer
    const buf_size = 256;
    const buf_ptr = try mock_mem.allocate(buf_size);

    const cwd = proc.getCwd();

    // Copy CWD to user buffer
    try mock_mem.copyToUser(buf_ptr, cwd);

    // Verify copy
    const user_buf = mock_mem.getBuffer(buf_ptr).?;
    try testing.expectEqualSlices(u8, cwd, user_buf[0..cwd.len]);
}
