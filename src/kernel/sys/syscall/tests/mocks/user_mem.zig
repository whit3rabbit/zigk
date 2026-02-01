//! Mock UserPtr for unit testing
//! Provides simple memory operations for testing without actual page tables

const std = @import("std");

/// Mock user memory - just uses host heap
pub const MockUserMem = struct {
    allocator: std.mem.Allocator,
    buffers: std.AutoHashMap(usize, []u8),

    pub fn init(allocator: std.mem.Allocator) MockUserMem {
        return .{
            .allocator = allocator,
            .buffers = std.AutoHashMap(usize, []u8).init(allocator),
        };
    }

    pub fn deinit(self: *MockUserMem) void {
        var it = self.buffers.valueIterator();
        while (it.next()) |buf| {
            self.allocator.free(buf.*);
        }
        self.buffers.deinit();
    }

    /// Allocate a mock user buffer
    pub fn allocate(self: *MockUserMem, size: usize) !usize {
        const buf = try self.allocator.alloc(u8, size);
        @memset(buf, 0);
        const ptr = @intFromPtr(buf.ptr);
        try self.buffers.put(ptr, buf);
        return ptr;
    }

    /// Free a mock user buffer
    pub fn free(self: *MockUserMem, ptr: usize) void {
        if (self.buffers.get(ptr)) |buf| {
            self.allocator.free(buf);
            _ = self.buffers.remove(ptr);
        }
    }

    /// Get buffer from pointer (for testing)
    pub fn getBuffer(self: *MockUserMem, ptr: usize) ?[]u8 {
        return self.buffers.get(ptr);
    }

    /// Validate user memory access (simplified)
    pub fn isValid(self: *MockUserMem, ptr: usize, len: usize) bool {
        _ = len;
        return self.buffers.contains(ptr);
    }

    /// Copy from kernel to user (simplified)
    pub fn copyToUser(self: *MockUserMem, user_ptr: usize, kernel_data: []const u8) !void {
        if (self.buffers.get(user_ptr)) |buf| {
            if (kernel_data.len > buf.len) return error.EFAULT;
            @memcpy(buf[0..kernel_data.len], kernel_data);
        } else {
            return error.EFAULT;
        }
    }

    /// Copy from user to kernel (simplified)
    pub fn copyFromUser(self: *MockUserMem, kernel_buf: []u8, user_ptr: usize) ![]u8 {
        if (self.buffers.get(user_ptr)) |buf| {
            const len = @min(kernel_buf.len, buf.len);
            @memcpy(kernel_buf[0..len], buf[0..len]);
            return kernel_buf[0..len];
        } else {
            return error.EFAULT;
        }
    }
};

test "MockUserMem basic operations" {
    var mock = MockUserMem.init(std.testing.allocator);
    defer mock.deinit();

    // Allocate buffer
    const ptr = try mock.allocate(256);
    try std.testing.expect(mock.isValid(ptr, 256));

    // Copy to user
    const data = "Hello, World!";
    try mock.copyToUser(ptr, data);

    // Verify copy
    const buf = mock.getBuffer(ptr).?;
    try std.testing.expectEqualSlices(u8, data, buf[0..data.len]);

    // Copy from user
    var kernel_buf: [128]u8 = undefined;
    const copied = try mock.copyFromUser(&kernel_buf, ptr);
    try std.testing.expectEqualSlices(u8, data, copied[0..data.len]);

    // Free
    mock.free(ptr);
    try std.testing.expect(!mock.isValid(ptr, 256));
}
