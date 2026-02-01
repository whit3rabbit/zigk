//! Mock Process for unit testing
//! Provides simple process context for testing syscalls

const std = @import("std");
const uapi = @import("uapi");

/// Mock process context
pub const MockProcess = struct {
    cwd: [uapi.abi.MAX_PATH]u8,
    cwd_len: usize,
    pid: u32,
    uid: u32,
    gid: u32,

    pub fn init() MockProcess {
        var proc = MockProcess{
            .cwd = undefined,
            .cwd_len = 1,
            .pid = 1,
            .uid = 0,
            .gid = 0,
        };
        proc.cwd[0] = '/';
        return proc;
    }

    /// Set current working directory
    pub fn setCwd(self: *MockProcess, path: []const u8) !void {
        if (path.len == 0 or path.len > uapi.abi.MAX_PATH) {
            return error.InvalidPath;
        }
        @memcpy(self.cwd[0..path.len], path);
        self.cwd_len = path.len;
    }

    /// Get current working directory
    pub fn getCwd(self: *MockProcess) []const u8 {
        return self.cwd[0..self.cwd_len];
    }
};

test "MockProcess basic operations" {
    var proc = MockProcess.init();

    // Initial CWD should be "/"
    try std.testing.expectEqualSlices(u8, "/", proc.getCwd());

    // Change CWD
    try proc.setCwd("/mnt");
    try std.testing.expectEqualSlices(u8, "/mnt", proc.getCwd());

    // Change to longer path
    try proc.setCwd("/usr/local/bin");
    try std.testing.expectEqualSlices(u8, "/usr/local/bin", proc.getCwd());
}
