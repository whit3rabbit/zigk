// Poll API Definitions (Linux x86_64 compatible)
//
// SECURITY NOTE: poll uses 16-bit event flags while epoll uses 32-bit.
// High bits in epoll (EPOLLET, EPOLLONESHOT, etc.) cannot be represented
// in poll. Use the conversion functions below to safely convert between them.

const epoll = @import("epoll.zig");

pub const POLLIN: u16 = 0x0001;
pub const POLLPRI: u16 = 0x0002;
pub const POLLOUT: u16 = 0x0004;
pub const POLLERR: u16 = 0x0008;
pub const POLLHUP: u16 = 0x0010;
pub const POLLNVAL: u16 = 0x0020;
pub const POLLRDNORM: u16 = 0x0040;
pub const POLLRDBAND: u16 = 0x0080;
pub const POLLWRNORM: u16 = 0x0100;
pub const POLLWRBAND: u16 = 0x0200;
pub const POLLMSG: u16 = 0x0400;
pub const POLLREMOVE: u16 = 0x1000; // Linux-specific, deprecated
pub const POLLRDHUP: u16 = 0x2000;

/// Mask for epoll high bits that cannot be represented in poll events.
/// Includes: EPOLLET, EPOLLONESHOT, EPOLLWAKEUP, EPOLLEXCLUSIVE, EPOLL_CLOEXEC
const EPOLL_HIGH_BITS: u32 = 0xFFFF0000;

/// Convert epoll events to poll events.
/// SECURITY: Returns null if epoll_events contains high bits (EPOLLET, EPOLLONESHOT, etc.)
/// that cannot be represented in 16-bit poll events. Caller must handle this case
/// to prevent silent truncation that could cause event storms or race conditions.
pub fn epollToPollEvents(epoll_events: u32) ?u16 {
    if ((epoll_events & EPOLL_HIGH_BITS) != 0) return null;
    return @truncate(epoll_events);
}

/// Convert poll events to epoll events. Always safe (widening conversion).
pub fn pollToEpollEvents(poll_events: u16) u32 {
    return @as(u32, poll_events);
}

// Comptime verification that poll and epoll low-bit flags are compatible.
// SECURITY: Mismatched flags would cause incorrect event routing.
comptime {
    // Verify all common flags match between poll (u16) and epoll (u32 low bits)
    if (POLLIN != epoll.EPOLLIN) @compileError("POLLIN/EPOLLIN mismatch");
    if (POLLPRI != epoll.EPOLLPRI) @compileError("POLLPRI/EPOLLPRI mismatch");
    if (POLLOUT != epoll.EPOLLOUT) @compileError("POLLOUT/EPOLLOUT mismatch");
    if (POLLERR != epoll.EPOLLERR) @compileError("POLLERR/EPOLLERR mismatch");
    if (POLLHUP != epoll.EPOLLHUP) @compileError("POLLHUP/EPOLLHUP mismatch");
    if (POLLNVAL != epoll.EPOLLNVAL) @compileError("POLLNVAL/EPOLLNVAL mismatch");
    if (POLLRDNORM != epoll.EPOLLRDNORM) @compileError("POLLRDNORM/EPOLLRDNORM mismatch");
    if (POLLRDBAND != epoll.EPOLLRDBAND) @compileError("POLLRDBAND/EPOLLRDBAND mismatch");
    if (POLLWRNORM != epoll.EPOLLWRNORM) @compileError("POLLWRNORM/EPOLLWRNORM mismatch");
    if (POLLWRBAND != epoll.EPOLLWRBAND) @compileError("POLLWRBAND/EPOLLWRBAND mismatch");
    if (POLLMSG != epoll.EPOLLMSG) @compileError("POLLMSG/EPOLLMSG mismatch");
    if (POLLRDHUP != epoll.EPOLLRDHUP) @compileError("POLLRDHUP/EPOLLRDHUP mismatch");
}

pub const PollFd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("PollFd must be 8 bytes");
    }
};
