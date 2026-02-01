//! Mock VFS for unit testing
//! Provides simple in-memory VFS for testing syscalls without booting kernel

const std = @import("std");
const fs = @import("fs");
const meta = fs.meta;

/// Simple mock file entry
pub const MockFile = struct {
    path: []const u8,
    mode: u32,
    size: u64,
    is_directory: bool,

    pub fn init(path: []const u8, is_dir: bool) MockFile {
        const mode: u32 = if (is_dir) 0o040755 else 0o100644;
        return .{
            .path = path,
            .mode = mode,
            .size = 0,
            .is_directory = is_dir,
        };
    }
};

/// Mock VFS state
pub const MockVfs = struct {
    files: std.ArrayListUnmanaged(MockFile),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockVfs {
        return .{
            .files = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockVfs) void {
        self.files.deinit(self.allocator);
    }

    /// Add a mock file or directory
    pub fn addFile(self: *MockVfs, path: []const u8, is_dir: bool) !void {
        try self.files.append(self.allocator, MockFile.init(path, is_dir));
    }

    /// Mock implementation of VFS statPath
    pub fn statPath(self: *MockVfs, path: []const u8) ?fs.meta.FileMeta {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) {
                return fs.meta.FileMeta{
                    .mode = file.mode,
                    .uid = 0,
                    .gid = 0,
                    .ino = 1,
                    .size = file.size,
                    // exists defaults to true
                    // readonly defaults to false
                    // dev defaults to 0
                };
            }
        }
        return null;
    }

    /// Check if path exists
    pub fn exists(self: *MockVfs, path: []const u8) bool {
        return self.statPath(path) != null;
    }

    /// Check if path is a directory
    pub fn isDirectory(self: *MockVfs, path: []const u8) bool {
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, path)) {
                return file.is_directory;
            }
        }
        return false;
    }
};

test "MockVfs basic operations" {
    var mock_vfs = MockVfs.init(std.testing.allocator);
    defer mock_vfs.deinit();

    try mock_vfs.addFile("/", true);
    try mock_vfs.addFile("/mnt", true);
    try mock_vfs.addFile("/bin/ls", false);

    try std.testing.expect(mock_vfs.exists("/"));
    try std.testing.expect(mock_vfs.exists("/mnt"));
    try std.testing.expect(mock_vfs.exists("/bin/ls"));
    try std.testing.expect(!mock_vfs.exists("/nonexistent"));

    try std.testing.expect(mock_vfs.isDirectory("/"));
    try std.testing.expect(mock_vfs.isDirectory("/mnt"));
    try std.testing.expect(!mock_vfs.isDirectory("/bin/ls"));
}
