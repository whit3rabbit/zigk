// Socket types, constants, and helpers.
// Split out so UDP/TCP helpers can share a single definition surface.

const std = @import("std");
const packet = @import("../../core/packet.zig");
const tcp_types = @import("../tcp/types.zig");
const scheduler = @import("scheduler.zig");
const uapi = @import("uapi");
const sync = @import("../../sync.zig");

// Re-export ABI types (canonical definitions with comptime size checks)
pub const IpMreq = uapi.abi.IpMreq;
pub const TimeVal = uapi.abi.TimeVal;
pub const SockAddrIn = uapi.abi.SockAddrIn;
pub const SockAddrIn6 = uapi.abi.SockAddrIn6;
pub const SockAddr = uapi.abi.SockAddr;

// Import IpAddr tagged union for dual-stack support
const addr_mod = @import("../../core/addr.zig");
pub const IpAddr = addr_mod.IpAddr;

// Network byte order helpers (x86_64 is little-endian, network is big-endian)
pub fn htons(v: u16) u16 {
    return @byteSwap(v);
}

pub fn htonl(v: u32) u32 {
    return @byteSwap(v);
}

/// Socket address families
pub const AF_INET: i32 = 2;
pub const AF_INET6: i32 = 10;

/// Socket types
pub const SOCK_STREAM: i32 = 1; // TCP
pub const SOCK_DGRAM: i32 = 2; // UDP

// =============================================================================
// Socket Option Constants (Linux-compatible)
// =============================================================================

/// Socket option levels
pub const SOL_SOCKET: i32 = 1;
pub const IPPROTO_IP: i32 = 0;
pub const IPPROTO_TCP: i32 = 6;

/// IPPROTO_TCP options
pub const TCP_NODELAY: i32 = 1;

/// SOL_SOCKET options
pub const SO_REUSEADDR: i32 = 2;
pub const SO_BROADCAST: i32 = 6;
pub const SO_RCVTIMEO: i32 = 20;
pub const SO_SNDTIMEO: i32 = 21;

/// IPPROTO_IP options
pub const IP_TOS: i32 = 1;
pub const IP_TTL: i32 = 2;
pub const IP_ADD_MEMBERSHIP: i32 = 35;
pub const IP_DROP_MEMBERSHIP: i32 = 36;
pub const IP_MULTICAST_IF: i32 = 32;
pub const IP_MULTICAST_TTL: i32 = 33;
pub const IP_RECVTOS: i32 = 13;

/// Maximum multicast group memberships per socket
pub const MAX_MULTICAST_GROUPS: usize = 8;

/// Default soft limit (table grows dynamically)
pub const MAX_SOCKETS: usize = 1024;

/// Maximum packets in socket receive queue
pub const SOCKET_RX_QUEUE_SIZE: usize = 8;

/// Maximum pending connections for listen()
pub const ACCEPT_QUEUE_SIZE: usize = 8;

/// Received packet entry in queue
const RxQueueEntry = struct {
    data: [packet.MAX_PACKET_SIZE]u8,
    len: usize,
    src_addr: IpAddr, // Source IP (IPv4 or IPv6)
    src_port: u16, // Source port (host byte order)
    valid: bool,
};

/// Socket structure
pub const Socket = struct {
    /// Socket is allocated
    allocated: bool,
    /// Address family (AF_INET)
    family: i32,
    /// Socket type (SOCK_DGRAM or SOCK_STREAM)
    sock_type: i32,
    /// Protocol (0 = default for type)
    protocol: i32,
    /// Local port (host byte order, 0 = not bound)
    local_port: u16,
    /// Local address (IPv4 or IPv6, .none = INADDR_ANY / in6addr_any)
    local_addr: IpAddr,

    // UDP-specific: receive queue
    rx_queue: [SOCKET_RX_QUEUE_SIZE]RxQueueEntry,
    rx_head: usize, // Next slot to write
    rx_tail: usize, // Next slot to read
    rx_count: usize, // Number of packets in queue

    // TCP-specific
    tcb: ?*tcp_types.Tcb, // TCP Control Block (for connected sockets)
    accept_queue: [ACCEPT_QUEUE_SIZE]?*tcp_types.Tcb, // Completed connections (listening sockets)
    accept_head: usize,
    accept_tail: usize,
    accept_count: usize,
    backlog: u16, // Max pending connections

    /// Blocking mode (true = blocking, false = non-blocking)
    blocking: bool,

    /// Shutdown flags (set by shutdown syscall)
    shutdown_read: bool, // SHUT_RD - no more receives
    shutdown_write: bool, // SHUT_WR - no more sends

    /// Thread blocked waiting on this socket (for accept/recv)
    /// Set by syscall layer, woken by packet processing
    blocked_thread: scheduler.ThreadPtr,

    // =========================================================================
    // Async I/O Pending Requests (Phase 2)
    // =========================================================================
    // These are set when an async operation is submitted via io_uring or
    // the internal KernelIo API. Completed by packet processing or state changes.

    /// Pending accept request (waiting for incoming connection)
    pending_accept: ?*anyopaque,

    /// Pending recv request (waiting for incoming data)
    pending_recv: ?*anyopaque,

    /// Pending send request (waiting for buffer space)
    pending_send: ?*anyopaque,

    /// Pending connect request (waiting for handshake completion)
    pending_connect: ?*anyopaque,

    /// Per-socket lock for protecting RX queue and state
    lock: sync.Spinlock,

    /// Reference count for lifetime management.
    /// SECURITY: Uses atomic operations to prevent TOCTOU races.
    /// 1 is held by the socket table entry; operations take additional refs.
    refcount: sync.AtomicRefcount,

    /// Socket is closing; prevents new references.
    /// SECURITY: Once set, tryRetain() will fail atomically.
    closing: std.atomic.Value(bool),

    // =========================================================================
    // Socket Options
    // =========================================================================

    /// Receive timeout in milliseconds (0 = infinite, default)
    rcv_timeout_ms: u64,

    /// Send timeout in milliseconds (0 = infinite, default)
    snd_timeout_ms: u64,

    /// Type of Service for outgoing IP packets (default: 0)
    tos: u8,

    /// Allow sending to broadcast addresses (SO_BROADCAST)
    so_broadcast: bool,

    /// Allow address reuse (SO_REUSEADDR)
    so_reuseaddr: bool,
    /// Disable Nagle's algorithm (TCP_NODELAY)
    tcp_nodelay: bool,

    /// Multicast group memberships (IP addresses in host byte order)
    /// 0 = unused slot
    multicast_groups: [MAX_MULTICAST_GROUPS]u32,
    multicast_count: usize,

    /// Multicast TTL (default 1 = local subnet only)
    multicast_ttl: u8,

    const Self = @This();

    pub fn init() Self {
        return .{
            .allocated = false,
            .family = 0,
            .sock_type = 0,
            .protocol = 0,
            .local_port = 0,
            .local_addr = .none,
            .rx_queue = [_]RxQueueEntry{.{
                .data = undefined,
                .len = 0,
                .src_addr = .none,
                .src_port = 0,
                .valid = false,
            }} ** SOCKET_RX_QUEUE_SIZE,
            .rx_head = 0,
            .rx_tail = 0,
            .rx_count = 0,
            .tcb = null,
            .accept_queue = [_]?*tcp_types.Tcb{null} ** ACCEPT_QUEUE_SIZE,
            .accept_head = 0,
            .accept_tail = 0,
            .accept_count = 0,
            .backlog = 0,
            .blocking = true,
            .shutdown_read = false,
            .shutdown_write = false,
            .blocked_thread = null,
            .pending_accept = null,
            .pending_recv = null,
            .pending_send = null,
            .pending_connect = null,
            .lock = .{},
            .refcount = .{ .count = .{ .raw = 1 } }, // Start with 1 ref for table entry
            .closing = .{ .raw = false },
            // Socket options - defaults
            .rcv_timeout_ms = 0, // Infinite timeout (blocking forever)
            .snd_timeout_ms = 0,
            .tos = 0, // Normal service
            .so_broadcast = false,
            .so_reuseaddr = false,
            .tcp_nodelay = false,
            // Multicast
            .multicast_groups = [_]u32{0} ** MAX_MULTICAST_GROUPS,
            .multicast_count = 0,
            .multicast_ttl = 1, // Default: local subnet only
        };
    }

    /// Check if socket is a member of a multicast group
    pub fn isMulticastMember(self: *const Self, group_ip: u32) bool {
        for (self.multicast_groups) |group| {
            if (group == group_ip) {
                return true;
            }
        }
        return false;
    }

    /// Add multicast group membership
    pub fn addMulticastGroup(self: *Self, group_ip: u32) bool {
        // Check if already a member
        if (self.isMulticastMember(group_ip)) {
            return true; // Already joined
        }

        // Find empty slot
        for (&self.multicast_groups) |*slot| {
            if (slot.* == 0) {
                slot.* = group_ip;
                self.multicast_count += 1;
                return true;
            }
        }
        return false; // No slots available
    }

    /// Remove multicast group membership
    pub fn dropMulticastGroup(self: *Self, group_ip: u32) bool {
        for (&self.multicast_groups) |*slot| {
            if (slot.* == group_ip) {
                slot.* = 0;
                if (self.multicast_count > 0) {
                    self.multicast_count -= 1;
                }
                return true;
            }
        }
        return false; // Not a member
    }

    /// Enqueue a received packet (IPv4 version for compatibility)
    pub fn enqueuePacket(self: *Self, data: []const u8, src_addr: u32, src_port: u16) bool {
        return self.enqueuePacketIp(data, IpAddr{ .v4 = src_addr }, src_port);
    }

    /// Enqueue a received packet (dual-stack version)
    pub fn enqueuePacketIp(self: *Self, data: []const u8, src_addr: IpAddr, src_port: u16) bool {
        if (self.rx_count >= SOCKET_RX_QUEUE_SIZE) {
            // Queue full - drop packet
            return false;
        }

        const entry = &self.rx_queue[self.rx_head];
        const copy_len = @min(data.len, entry.data.len);
        @memcpy(entry.data[0..copy_len], data[0..copy_len]);
        entry.len = copy_len;
        entry.src_addr = src_addr;
        entry.src_port = src_port;
        entry.valid = true;

        self.rx_head = (self.rx_head + 1) % SOCKET_RX_QUEUE_SIZE;
        self.rx_count += 1;

        // Wake any blocked thread
        scheduler.wakeThread(self.blocked_thread);

        return true;
    }

    /// Dequeue a received packet (IPv4 version for compatibility)
    pub fn dequeuePacket(self: *Self, buf: []u8, src_addr: ?*u32, src_port: ?*u16) ?usize {
        var ip_addr: IpAddr = .none;
        const result = self.dequeuePacketIp(buf, &ip_addr, src_port);
        if (result != null and src_addr != null) {
            switch (ip_addr) {
                .v4 => |v4| src_addr.?.* = v4,
                else => src_addr.?.* = 0, // IPv6 addresses can't fit in u32
            }
        }
        return result;
    }

    /// Dequeue a received packet (dual-stack version)
    pub fn dequeuePacketIp(self: *Self, buf: []u8, src_addr: ?*IpAddr, src_port: ?*u16) ?usize {
        if (self.rx_count == 0) {
            return null;
        }

        const entry = &self.rx_queue[self.rx_tail];
        if (!entry.valid) {
            return null;
        }

        const copy_len = @min(entry.len, buf.len);
        @memcpy(buf[0..copy_len], entry.data[0..copy_len]);

        if (src_addr) |addr| {
            addr.* = entry.src_addr;
        }
        if (src_port) |port| {
            port.* = entry.src_port;
        }

        entry.valid = false;
        self.rx_tail = (self.rx_tail + 1) % SOCKET_RX_QUEUE_SIZE;
        self.rx_count -= 1;

        return copy_len;
    }

    /// Check if there are packets waiting
    pub fn hasData(self: *const Self) bool {
        return self.rx_count > 0;
    }
};
