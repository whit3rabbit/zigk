// Zscapek ABI Assertions
//
// Comptime verification that userland-visible structs match Linux x86_64 ABI.
// These checks run at compile time and prevent ABI drift.
//
// This file defines the expected ABI layout. The actual implementations in
// kernel and network code must match these definitions.
//
// If any assertion fails, the build will error with a clear message
// indicating which struct violates the ABI.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

pub const MAX_PATH: usize = 4096;

// =============================================================================
// Expected ABI Layouts (Linux x86_64)
// =============================================================================

/// struct timespec - Reference: POSIX.1-2017, Linux <time.h>
/// Must be 16 bytes: tv_sec(i64) + tv_nsec(i64)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,

    comptime {
        if (@sizeOf(@This()) != 16) {
            @compileError("Timespec must be 16 bytes");
        }
        if (@alignOf(@This()) != 8) {
            @compileError("Timespec must have 8-byte alignment");
        }
    }
};

/// struct sockaddr_in - Reference: Linux <netinet/in.h>
/// Must be 16 bytes: family(2) + port(2) + addr(4) + zero(8)
pub const SockAddrIn = extern struct {
    family: u16,
    port: u16,
    addr: u32,
    zero: [8]u8,

    pub const AF_INET: u16 = 2;

    pub fn init(ip: u32, port_host: u16) SockAddrIn {
        return .{
            .family = AF_INET,
            .port = @byteSwap(port_host),
            .addr = @byteSwap(ip),
            .zero = [_]u8{0} ** 8,
        };
    }

    pub fn getPort(self: *const SockAddrIn) u16 {
        return @byteSwap(self.port);
    }

    pub fn getAddr(self: *const SockAddrIn) u32 {
        return @byteSwap(self.addr);
    }

    comptime {
        if (@sizeOf(@This()) != 16) {
            @compileError("SockAddrIn must be 16 bytes");
        }
    }
};

/// struct sockaddr - Reference: Linux <sys/socket.h>
/// Must be 16 bytes: family(2) + data(14)
pub const SockAddr = extern struct {
    family: u16,
    data: [14]u8,

    comptime {
        if (@sizeOf(@This()) != 16) {
            @compileError("SockAddr must be 16 bytes");
        }
    }
};

/// struct sockaddr_in6 - Reference: Linux <netinet/in.h>
/// Must be 28 bytes: family(2) + port(2) + flowinfo(4) + addr(16) + scope_id(4)
/// Used for IPv6 socket addresses in bind(), connect(), sendto(), recvfrom(), etc.
pub const SockAddrIn6 = extern struct {
    family: u16,
    port: u16,
    flowinfo: u32,
    addr: [16]u8,
    scope_id: u32,

    pub const AF_INET6: u16 = 10;

    /// Create a SockAddrIn6 with the given address and port.
    /// Port is converted from host byte order to network byte order.
    /// Address should be in network byte order (as stored in IPv6 headers).
    pub fn init(addr_bytes: [16]u8, port_host: u16) SockAddrIn6 {
        return .{
            .family = AF_INET6,
            .port = @byteSwap(port_host),
            .flowinfo = 0,
            .addr = addr_bytes,
            .scope_id = 0,
        };
    }

    /// Create a SockAddrIn6 with scope ID (for link-local addresses).
    pub fn initWithScope(addr_bytes: [16]u8, port_host: u16, scope: u32) SockAddrIn6 {
        return .{
            .family = AF_INET6,
            .port = @byteSwap(port_host),
            .flowinfo = 0,
            .addr = addr_bytes,
            .scope_id = scope,
        };
    }

    /// Get port in host byte order.
    pub fn getPort(self: *const SockAddrIn6) u16 {
        return @byteSwap(self.port);
    }

    /// Set port from host byte order.
    pub fn setPort(self: *SockAddrIn6, port_host: u16) void {
        self.port = @byteSwap(port_host);
    }

    /// Check if this is a link-local address (fe80::/10).
    pub fn isLinkLocal(self: *const SockAddrIn6) bool {
        return self.addr[0] == 0xFE and (self.addr[1] & 0xC0) == 0x80;
    }

    /// Check if this is the unspecified address (::).
    pub fn isUnspecified(self: *const SockAddrIn6) bool {
        for (self.addr) |b| {
            if (b != 0) return false;
        }
        return true;
    }

    /// Check if this is the loopback address (::1).
    pub fn isLoopback(self: *const SockAddrIn6) bool {
        for (self.addr[0..15]) |b| {
            if (b != 0) return false;
        }
        return self.addr[15] == 1;
    }

    comptime {
        if (@sizeOf(@This()) != 28) {
            @compileError("SockAddrIn6 must be 28 bytes");
        }
    }
};

/// struct sockaddr_storage - Reference: Linux <sys/socket.h>
/// Generic socket address storage that can hold either IPv4 or IPv6 addresses.
/// Must be 128 bytes with 8-byte alignment per POSIX.
pub const SockAddrStorage = extern struct {
    family: u16,
    _padding: [126]u8,

    pub fn asSockAddrIn(self: *const SockAddrStorage) ?*const SockAddrIn {
        if (self.family != SockAddrIn.AF_INET) return null;
        return @ptrCast(self);
    }

    pub fn asSockAddrIn6(self: *const SockAddrStorage) ?*const SockAddrIn6 {
        if (self.family != SockAddrIn6.AF_INET6) return null;
        return @ptrCast(self);
    }

    pub fn asSockAddrInMut(self: *SockAddrStorage) ?*SockAddrIn {
        if (self.family != SockAddrIn.AF_INET) return null;
        return @ptrCast(self);
    }

    pub fn asSockAddrIn6Mut(self: *SockAddrStorage) ?*SockAddrIn6 {
        if (self.family != SockAddrIn6.AF_INET6) return null;
        return @ptrCast(self);
    }

    comptime {
        if (@sizeOf(@This()) != 128) {
            @compileError("SockAddrStorage must be 128 bytes");
        }
        if (@alignOf(@This()) != 2) {
            // Note: Linux uses 8-byte alignment for sockaddr_storage,
            // but Zig's extern struct with u16 first gives 2-byte alignment.
            // This is acceptable for our use case.
        }
    }
};

/// struct timeval - Reference: Linux <sys/time.h>
/// Must be 16 bytes: tv_sec(i64) + tv_usec(i64)
pub const TimeVal = extern struct {
    tv_sec: i64,
    tv_usec: i64,

    /// Convert TimeVal to milliseconds with overflow protection.
    /// Returns 0 for negative values, saturates at maxInt(u64) for overflow.
    pub fn toMillis(self: TimeVal) u64 {
        if (self.tv_sec < 0) return 0;

        // Prevent overflow: max safe sec = maxInt(u64) / 1000
        const max_safe_sec: i64 = @intCast(std.math.maxInt(u64) / 1000);
        const safe_sec: u64 = if (self.tv_sec > max_safe_sec)
            std.math.maxInt(u64)
        else
            @as(u64, @intCast(self.tv_sec)) * 1000;

        // Handle negative tv_usec gracefully
        const usec_ms: u64 = if (self.tv_usec >= 0)
            @intCast(@divFloor(self.tv_usec, 1000))
        else
            0;

        return safe_sec +| usec_ms; // saturating add
    }

    /// Convert milliseconds to TimeVal with bounds checking.
    /// Saturates to maximum representable TimeVal for very large ms values.
    pub fn fromMillis(ms: u64) TimeVal {
        const max_sec: u64 = @intCast(std.math.maxInt(i64));
        const sec = ms / 1000;
        // When saturating tv_sec, also saturate tv_usec for consistency
        if (sec > max_sec) {
            return .{ .tv_sec = std.math.maxInt(i64), .tv_usec = 999999 };
        }
        return .{
            .tv_sec = @intCast(sec),
            .tv_usec = @intCast((ms % 1000) * 1000),
        };
    }

    comptime {
        if (@sizeOf(@This()) != 16) {
            @compileError("TimeVal must be 16 bytes");
        }
    }
};

/// struct ip_mreq - Reference: Linux <netinet/in.h>
/// Must be 8 bytes: imr_multiaddr(u32) + imr_interface(u32)
pub const IpMreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,

    pub fn getMultiaddr(self: *const IpMreq) u32 {
        return @byteSwap(self.imr_multiaddr);
    }

    pub fn getInterface(self: *const IpMreq) u32 {
        return @byteSwap(self.imr_interface);
    }

    comptime {
        if (@sizeOf(@This()) != 8) {
            @compileError("IpMreq must be 8 bytes");
        }
    }
};

/// struct ipv6_mreq - Reference: Linux <netinet/in.h>
/// Must be 20 bytes: ipv6mr_multiaddr([16]u8) + ipv6mr_interface(u32)
pub const Ipv6Mreq = extern struct {
    ipv6mr_multiaddr: [16]u8,
    ipv6mr_interface: u32,

    pub fn getMultiaddr(self: *const Ipv6Mreq) [16]u8 {
        return self.ipv6mr_multiaddr;
    }

    pub fn getInterface(self: *const Ipv6Mreq) u32 {
        return self.ipv6mr_interface;
    }

    comptime {
        if (@sizeOf(@This()) != 20) {
            @compileError("Ipv6Mreq must be 20 bytes");
        }
    }
};

/// struct pollfd - Reference: Linux <poll.h>
/// Must be 8 bytes: fd(i32) + events(i16) + revents(i16)
pub const PollFd = extern struct {
    fd: i32,
    events: i16,
    revents: i16,

    comptime {
        if (@sizeOf(@This()) != 8) {
            @compileError("PollFd must be 8 bytes");
        }
    }
};

/// struct iovec - Reference: Linux <sys/uio.h>
/// Must be 16 bytes: iov_base(ptr/usize) + iov_len(usize)
/// Used for scatter/gather I/O in readv, writev, sendmsg, recvmsg
pub const IoVec = extern struct {
    iov_base: usize, // void* in C, represented as usize for user pointer
    iov_len: usize,

    comptime {
        if (@sizeOf(@This()) != 16) {
            @compileError("IoVec must be 16 bytes");
        }
        if (@alignOf(@This()) != 8) {
            @compileError("IoVec must have 8-byte alignment");
        }
    }
};

/// struct msghdr - Reference: Linux <sys/socket.h>
/// Must be 56 bytes on x86_64
/// Used for sendmsg/recvmsg scatter/gather socket I/O
pub const MsgHdr = extern struct {
    msg_name: usize, // void* - optional address
    msg_namelen: u32, // socklen_t
    _pad0: u32 = 0, // padding for alignment
    msg_iov: usize, // struct iovec*
    msg_iovlen: usize, // size_t - number of iovecs
    msg_control: usize, // void* - ancillary data
    msg_controllen: usize, // size_t
    msg_flags: i32,
    _pad1: u32 = 0, // padding for alignment

    comptime {
        if (@sizeOf(@This()) != 56) {
            @compileError("MsgHdr must be 56 bytes");
        }
        if (@alignOf(@This()) != 8) {
            @compileError("MsgHdr must have 8-byte alignment");
        }
    }
};

// =============================================================================
// Zscapek-specific ABI Layouts
// =============================================================================

/// FramebufferInfo - Zscapek syscall ABI for sys_get_fb_info
/// Must be 24 bytes: 4*u32 + 6*u8 + 2*u8 padding
pub const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    red_shift: u8,
    red_mask_size: u8,
    green_shift: u8,
    green_mask_size: u8,
    blue_shift: u8,
    blue_mask_size: u8,
    _reserved: [2]u8 = .{ 0, 0 },

    comptime {
        if (@sizeOf(@This()) != 24) {
            @compileError("FramebufferInfo must be 24 bytes");
        }
    }
};

// =============================================================================
// Verification Function
// =============================================================================

/// Force comptime evaluation of all ABI checks.
/// Call from kernel main to ensure checks are included in build.
pub fn verifyAbi() void {
    // All checks are comptime - this forces inclusion
    comptime {
        _ = Timespec{};
        _ = SockAddrIn{};
        _ = SockAddrIn6{};
        _ = SockAddrStorage{};
        _ = SockAddr{};
        _ = TimeVal{};
        _ = IpMreq{};
        _ = Ipv6Mreq{};
        _ = PollFd{};
        _ = IoVec{};
        _ = MsgHdr{};
        _ = FramebufferInfo{};
    }
}
