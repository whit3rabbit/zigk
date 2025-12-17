// Epoll API Definitions (Linux x86_64 compatible)
//
// epoll is a scalable I/O event notification mechanism for Linux.
// These definitions match the Linux kernel ABI.

/// epoll_ctl operations
pub const EPOLL_CTL_ADD: u32 = 1; // Add a file descriptor to the interface
pub const EPOLL_CTL_DEL: u32 = 2; // Remove a file descriptor from the interface
pub const EPOLL_CTL_MOD: u32 = 3; // Change file descriptor settings

/// epoll_create1 flags
pub const EPOLL_CLOEXEC: u32 = 0x80000; // Set close-on-exec flag

/// epoll event types (can be combined)
pub const EPOLLIN: u32 = 0x001; // Data available for read
pub const EPOLLPRI: u32 = 0x002; // Urgent data available
pub const EPOLLOUT: u32 = 0x004; // Writing now will not block
pub const EPOLLERR: u32 = 0x008; // Error condition
pub const EPOLLHUP: u32 = 0x010; // Hung up
pub const EPOLLNVAL: u32 = 0x020; // Invalid request (fd not open)
pub const EPOLLRDNORM: u32 = 0x040; // Normal data available
pub const EPOLLRDBAND: u32 = 0x080; // Priority data available
pub const EPOLLWRNORM: u32 = 0x100; // Writing now will not block (normal)
pub const EPOLLWRBAND: u32 = 0x200; // Writing priority data will not block
pub const EPOLLMSG: u32 = 0x400; // Message available
pub const EPOLLRDHUP: u32 = 0x2000; // Stream socket peer closed connection

/// epoll flags (modify behavior)
pub const EPOLLET: u32 = 0x80000000; // Edge-triggered
pub const EPOLLONESHOT: u32 = 0x40000000; // One-shot notification
pub const EPOLLWAKEUP: u32 = 0x20000000; // Wake up system if autosleep
pub const EPOLLEXCLUSIVE: u32 = 0x10000000; // Exclusive wake-up mode

/// epoll_event structure (matches Linux x86_64 ABI)
/// On x86_64, this struct is 12 bytes with __attribute__((packed)).
/// We use a byte array to ensure exact ABI layout without padding.
pub const EpollEvent = extern struct {
    /// Event types to watch for (4 bytes)
    events: u32,
    /// User data as bytes (8 bytes, no alignment padding)
    data_bytes: [8]u8,

    /// Get data as u64
    pub fn getData(self: *const EpollEvent) u64 {
        return @as(*align(1) const u64, @ptrCast(&self.data_bytes)).*;
    }

    /// Set data as u64
    pub fn setData(self: *EpollEvent, val: u64) void {
        @as(*align(1) u64, @ptrCast(&self.data_bytes)).* = val;
    }

    /// Create from events and data
    pub fn init(events: u32, data: u64) EpollEvent {
        var ev = EpollEvent{ .events = events, .data_bytes = undefined };
        ev.setData(data);
        return ev;
    }

    comptime {
        const std = @import("std");
        // Verify struct layout matches Linux ABI (12 bytes exactly)
        std.debug.assert(@sizeOf(EpollEvent) == 12);
        std.debug.assert(@offsetOf(EpollEvent, "events") == 0);
        std.debug.assert(@offsetOf(EpollEvent, "data_bytes") == 4);
    }
};

/// epoll_data union - typically used as u64 or pointer
/// In C this is a union { void *ptr; int fd; uint32_t u32; uint64_t u64; }
/// We represent it as u64 which can hold any of these.
pub const EpollData = extern struct {
    val: u64,

    pub fn fromFd(fd: i32) EpollData {
        return .{ .val = @as(u64, @bitCast(@as(i64, fd))) };
    }

    pub fn toFd(self: EpollData) i32 {
        return @truncate(@as(i64, @bitCast(self.val)));
    }

    pub fn fromPtr(ptr: *anyopaque) EpollData {
        return .{ .val = @intFromPtr(ptr) };
    }

    pub fn toPtr(self: EpollData, comptime T: type) *T {
        return @ptrFromInt(self.val);
    }
};
