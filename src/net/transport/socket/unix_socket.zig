//! UNIX Domain Socket Implementation (socketpair MVP)
//!
//! Implements bidirectional in-kernel data channels for local IPC.
//! This MVP supports anonymous socket pairs created via socketpair().
//!
//! Features:
//! - Bidirectional circular buffer (4KB each direction)
//! - SOCK_STREAM (connection-oriented) and SOCK_DGRAM (datagram) support
//! - Blocking and non-blocking I/O
//! - Reference counting for proper cleanup
//!
//! Thread-safety:
//! - Protected by internal spinlock for buffer access
//! - SMP-safe wakeup flags to prevent lost wakeups
//!
//! Note: FD management is handled by the syscall layer (net.zig),
//! this module only provides the core socket pair data structures and operations.

const std = @import("std");
const heap = @import("heap");
const sync = @import("sync");
const types = @import("types.zig");

// Use the scheduler interface from types.zig for thread management
const scheduler = types.scheduler;

/// Buffer size for each direction (matches PIPE_BUF for consistency)
pub const UNIX_SOCKET_BUF_SIZE: usize = 4096;

/// Maximum number of concurrent unix socket pairs
pub const MAX_UNIX_SOCKET_PAIRS: usize = 256;

/// Unix socket pair - shared structure between both endpoints
pub const UnixSocketPair = struct {
    /// Buffer for data flowing from endpoint 0 to endpoint 1
    buffer_0_to_1: [UNIX_SOCKET_BUF_SIZE]u8,
    read_pos_0_to_1: usize,
    write_pos_0_to_1: usize,
    data_len_0_to_1: usize,

    /// Buffer for data flowing from endpoint 1 to endpoint 0
    buffer_1_to_0: [UNIX_SOCKET_BUF_SIZE]u8,
    read_pos_1_to_0: usize,
    write_pos_1_to_0: usize,
    data_len_1_to_0: usize,

    /// Socket type (SOCK_STREAM or SOCK_DGRAM)
    sock_type: i32,

    /// Reference count for endpoints (starts at 2 for the pair)
    refcount: usize,

    /// Lock for buffer access
    lock: sync.Spinlock,

    /// Blocked threads waiting for data (opaque pointers to kernel Thread)
    blocked_reader_0: scheduler.ThreadPtr, // Thread blocked reading on endpoint 0
    blocked_reader_1: scheduler.ThreadPtr, // Thread blocked reading on endpoint 1

    /// SMP-safe wakeup flags
    reader_0_woken: std.atomic.Value(bool),
    reader_1_woken: std.atomic.Value(bool),

    /// Shutdown flags
    shutdown_0: bool, // Endpoint 0 is shut down
    shutdown_1: bool, // Endpoint 1 is shut down

    /// Allocated flag
    allocated: bool,

    const Self = @This();

    pub fn init(sock_type: i32) Self {
        return Self{
            .buffer_0_to_1 = undefined,
            .read_pos_0_to_1 = 0,
            .write_pos_0_to_1 = 0,
            .data_len_0_to_1 = 0,
            .buffer_1_to_0 = undefined,
            .read_pos_1_to_0 = 0,
            .write_pos_1_to_0 = 0,
            .data_len_1_to_0 = 0,
            .sock_type = sock_type,
            .refcount = 2, // Both endpoints hold a reference
            .lock = .{},
            .blocked_reader_0 = null,
            .blocked_reader_1 = null,
            .reader_0_woken = std.atomic.Value(bool).init(false),
            .reader_1_woken = std.atomic.Value(bool).init(false),
            .shutdown_0 = false,
            .shutdown_1 = false,
            .allocated = true,
        };
    }

    /// Write data from endpoint to the peer's read buffer
    /// endpoint: 0 or 1 (which endpoint is writing)
    pub fn write(self: *Self, endpoint: u1, data: []const u8) usize {
        // Select the correct buffer based on which endpoint is writing
        const buf = if (endpoint == 0) &self.buffer_0_to_1 else &self.buffer_1_to_0;
        const write_pos = if (endpoint == 0) &self.write_pos_0_to_1 else &self.write_pos_1_to_0;
        const data_len = if (endpoint == 0) &self.data_len_0_to_1 else &self.data_len_1_to_0;

        const available = UNIX_SOCKET_BUF_SIZE - data_len.*;
        if (available == 0) return 0;

        const to_write = @min(data.len, available);
        var written: usize = 0;

        while (written < to_write) {
            buf[write_pos.*] = data[written];
            write_pos.* = (write_pos.* + 1) % UNIX_SOCKET_BUF_SIZE;
            written += 1;
        }
        data_len.* += written;

        return written;
    }

    /// Read data from the endpoint's read buffer (written by peer)
    /// endpoint: 0 or 1 (which endpoint is reading)
    pub fn read(self: *Self, endpoint: u1, buf: []u8) usize {
        // Select the correct buffer based on which endpoint is reading
        // Endpoint 0 reads from buffer_1_to_0 (data written by endpoint 1)
        // Endpoint 1 reads from buffer_0_to_1 (data written by endpoint 0)
        const src_buf = if (endpoint == 0) &self.buffer_1_to_0 else &self.buffer_0_to_1;
        const read_pos = if (endpoint == 0) &self.read_pos_1_to_0 else &self.read_pos_0_to_1;
        const data_len = if (endpoint == 0) &self.data_len_1_to_0 else &self.data_len_0_to_1;

        if (data_len.* == 0) return 0;

        const to_read = @min(buf.len, data_len.*);
        var bytes_read: usize = 0;

        while (bytes_read < to_read) {
            buf[bytes_read] = src_buf[read_pos.*];
            read_pos.* = (read_pos.* + 1) % UNIX_SOCKET_BUF_SIZE;
            bytes_read += 1;
        }
        data_len.* -= bytes_read;

        return bytes_read;
    }

    /// Check if there's data available to read for an endpoint
    pub fn hasData(self: *const Self, endpoint: u1) bool {
        if (endpoint == 0) {
            return self.data_len_1_to_0 > 0;
        } else {
            return self.data_len_0_to_1 > 0;
        }
    }

    /// Check if the peer endpoint is closed
    pub fn isPeerClosed(self: *const Self, endpoint: u1) bool {
        if (endpoint == 0) {
            return self.shutdown_1;
        } else {
            return self.shutdown_0;
        }
    }

    /// Get available write space for an endpoint
    pub fn writeSpace(self: *const Self, endpoint: u1) usize {
        if (endpoint == 0) {
            return UNIX_SOCKET_BUF_SIZE - self.data_len_0_to_1;
        } else {
            return UNIX_SOCKET_BUF_SIZE - self.data_len_1_to_0;
        }
    }
};

/// Handle for one end of a unix socket pair
pub const UnixSocketHandle = struct {
    pair: *UnixSocketPair,
    endpoint: u1, // 0 or 1
    blocking: bool,
};

/// Global pool of unix socket pairs
var unix_socket_pairs: [MAX_UNIX_SOCKET_PAIRS]UnixSocketPair = undefined;
var pairs_initialized: bool = false;
var pairs_lock: sync.Spinlock = .{};

fn initPairsIfNeeded() void {
    if (pairs_initialized) return;

    const held = pairs_lock.acquire();
    defer held.release();

    if (pairs_initialized) return; // Double-check after lock

    for (&unix_socket_pairs) |*pair| {
        pair.allocated = false;
    }
    pairs_initialized = true;
}

/// Allocate a new unix socket pair
pub fn allocatePair(sock_type: i32) ?*UnixSocketPair {
    initPairsIfNeeded();

    const held = pairs_lock.acquire();
    defer held.release();

    for (&unix_socket_pairs) |*pair| {
        if (!pair.allocated) {
            pair.* = UnixSocketPair.init(sock_type);
            return pair;
        }
    }
    return null; // No free pairs
}

/// Release a reference to a unix socket pair
pub fn releasePair(pair: *UnixSocketPair, endpoint: u1) void {
    const held = pair.lock.acquire();

    // Mark this endpoint as shut down
    if (endpoint == 0) {
        pair.shutdown_0 = true;
    } else {
        pair.shutdown_1 = true;
    }

    // Always decrement refcount (was previously skipped on early return - bug fix)
    pair.refcount -= 1;
    const should_free = pair.refcount == 0;
    if (should_free) {
        pair.allocated = false;
    }

    // Wake any blocked reader on the peer endpoint
    if (endpoint == 0) {
        if (pair.blocked_reader_1) |thread| {
            pair.reader_1_woken.store(true, .release);
            held.release();
            scheduler.wakeThread(thread);
            return;
        }
    } else {
        if (pair.blocked_reader_0) |thread| {
            pair.reader_0_woken.store(true, .release);
            held.release();
            scheduler.wakeThread(thread);
            return;
        }
    }

    held.release();
}

/// Validate socket type for socketpair
pub fn validateSocketType(sock_type: i32) bool {
    const type_masked = sock_type & 0xFF;
    return type_masked == types.SOCK_STREAM or type_masked == types.SOCK_DGRAM;
}

/// Check if SOCK_NONBLOCK flag is set
pub fn isNonBlocking(sock_type: i32) bool {
    return (sock_type & 0x800) != 0; // SOCK_NONBLOCK = 0x800
}

// =============================================================================
// Full UNIX Domain Socket Implementation
// =============================================================================
//
// Extends the socketpair MVP to support named UNIX sockets with:
// - socket() creating unbound UNIX sockets
// - bind() binding to abstract or filesystem paths
// - listen() enabling passive socket mode
// - accept() accepting incoming connections
// - connect() connecting to listening sockets
//
// Path binding uses a kernel-side registry since there's no persistent
// writable filesystem. Both abstract (\0-prefixed) and filesystem paths
// are supported, but both map to the same registry mechanism.

/// Maximum number of full UNIX sockets (separate from socketpair pool)
pub const MAX_UNIX_SOCKETS: usize = 256;

/// Maximum pending connections in accept queue
pub const FULL_ACCEPT_QUEUE_SIZE: usize = 8;

/// State machine for UNIX sockets
pub const UnixSocketState = enum {
    /// socket() called, not yet bound
    Unbound,
    /// bind() called, path registered
    Bound,
    /// listen() called, accepting connections
    Listening,
    /// Connected (client after connect(), or server socket from accept())
    Connected,
    /// Peer disconnected
    Disconnected,
};

/// Full UNIX socket structure for bind/listen/accept/connect
pub const UnixSocket = struct {
    /// Socket type (SOCK_STREAM or SOCK_DGRAM)
    sock_type: i32,
    /// Current state
    state: UnixSocketState,

    /// Bound path (heap-allocated copy, null if unbound)
    bound_path: ?[]u8,
    /// True if bound to abstract namespace (path starts with \0)
    is_abstract: bool,

    /// Accept queue for listening sockets (pending connected pairs)
    accept_queue: [FULL_ACCEPT_QUEUE_SIZE]?*UnixSocketPair,
    accept_head: usize,
    accept_tail: usize,
    accept_count: usize,
    backlog: u16,

    /// Data channel for connected sockets (set after connect/accept)
    pair: ?*UnixSocketPair,
    /// Which endpoint of the pair this socket owns (0 or 1)
    endpoint: u1,

    /// Blocking mode
    blocking: bool,
    /// Reference count
    refcount: usize,
    /// Generation counter for stale reference detection
    generation: u32,
    /// Per-socket lock
    lock: sync.Spinlock,

    /// Thread blocked waiting on accept
    blocked_thread: scheduler.ThreadPtr,
    /// SMP-safe wakeup flag
    woken: std.atomic.Value(bool),

    /// Peer credentials (for SO_PEERCRED)
    peer_pid: u32,
    peer_uid: u32,
    peer_gid: u32,

    /// Slot is allocated
    allocated: bool,

    const Self = @This();

    pub fn init(sock_type: i32) Self {
        return Self{
            .sock_type = sock_type,
            .state = .Unbound,
            .bound_path = null,
            .is_abstract = false,
            .accept_queue = [_]?*UnixSocketPair{null} ** FULL_ACCEPT_QUEUE_SIZE,
            .accept_head = 0,
            .accept_tail = 0,
            .accept_count = 0,
            .backlog = 0,
            .pair = null,
            .endpoint = 0,
            .blocking = true,
            .refcount = 1,
            .generation = 0,
            .lock = .{},
            .blocked_thread = null,
            .woken = std.atomic.Value(bool).init(false),
            .peer_pid = 0,
            .peer_uid = 0,
            .peer_gid = 0,
            .allocated = true,
        };
    }
};

// =============================================================================
// Path Registry
// =============================================================================

/// Entry in the path registry mapping paths to listening sockets
const PathEntry = struct {
    path: [108]u8,
    path_len: usize,
    is_abstract: bool,
    socket_idx: usize,
    generation: u32,
    allocated: bool,
};

var path_registry: [MAX_UNIX_SOCKETS]PathEntry = undefined;
var path_registry_lock: sync.Spinlock = .{};
var path_registry_initialized: bool = false;

fn initRegistryIfNeeded() void {
    if (path_registry_initialized) return;

    const held = path_registry_lock.acquire();
    defer held.release();

    if (path_registry_initialized) return;

    for (&path_registry) |*entry| {
        entry.allocated = false;
        entry.path_len = 0;
        entry.is_abstract = false;
    }
    path_registry_initialized = true;
}

// =============================================================================
// Full UNIX Socket Pool
// =============================================================================

var unix_sockets: [MAX_UNIX_SOCKETS]UnixSocket = undefined;
var unix_sockets_lock: sync.Spinlock = .{};
var unix_sockets_initialized: bool = false;
var next_generation: u32 = 1;

fn initSocketsIfNeeded() void {
    if (unix_sockets_initialized) return;

    const held = unix_sockets_lock.acquire();
    defer held.release();

    if (unix_sockets_initialized) return;

    for (&unix_sockets) |*sock| {
        sock.allocated = false;
    }
    unix_sockets_initialized = true;
}

/// Allocate a new full UNIX socket
pub fn allocateSocket(sock_type: i32) ?struct { sock: *UnixSocket, idx: usize } {
    initSocketsIfNeeded();

    const held = unix_sockets_lock.acquire();
    defer held.release();

    for (&unix_sockets, 0..) |*sock, idx| {
        if (!sock.allocated) {
            sock.* = UnixSocket.init(sock_type);
            sock.generation = next_generation;
            next_generation +%= 1;
            return .{ .sock = sock, .idx = idx };
        }
    }
    return null;
}

/// Acquire a reference to a socket by index
pub fn acquireSocket(idx: usize) ?*UnixSocket {
    if (idx >= MAX_UNIX_SOCKETS) return null;

    const sock = &unix_sockets[idx];
    const held = sock.lock.acquire();
    defer held.release();

    if (!sock.allocated) return null;
    sock.refcount += 1;
    return sock;
}

/// Get a socket pointer without incrementing refcount (for internal use)
pub fn getSocketByIdx(idx: usize) ?*UnixSocket {
    if (idx >= MAX_UNIX_SOCKETS) return null;
    const sock = &unix_sockets[idx];
    if (!sock.allocated) return null;
    return sock;
}

/// Release a reference to a socket
pub fn releaseSocket(sock: *UnixSocket) void {
    const held = sock.lock.acquire();

    sock.refcount -= 1;
    if (sock.refcount == 0) {
        // Cleanup: unregister path, free pair, etc.
        const bound_path = sock.bound_path;
        const is_abstract = sock.is_abstract;

        sock.allocated = false;
        held.release();

        // Cleanup outside lock
        if (bound_path) |path| {
            unregisterPath(path, is_abstract);
            heap.allocator().free(path);
        }
        return;
    }

    held.release();
}

// =============================================================================
// Path Registry Functions
// =============================================================================

/// Error set for path registry operations
pub const PathError = error{
    AddressInUse,
    NoSpace,
};

/// Register a path binding
pub fn registerPath(path: []const u8, is_abstract: bool, sock_idx: usize, gen: u32) PathError!void {
    initRegistryIfNeeded();

    const held = path_registry_lock.acquire();
    defer held.release();

    // Check for existing binding with same path
    for (&path_registry) |*entry| {
        if (entry.allocated and entry.is_abstract == is_abstract and
            entry.path_len == path.len and
            std.mem.eql(u8, entry.path[0..entry.path_len], path))
        {
            return error.AddressInUse;
        }
    }

    // Find free slot
    for (&path_registry) |*entry| {
        if (!entry.allocated) {
            @memcpy(entry.path[0..path.len], path);
            entry.path_len = path.len;
            entry.is_abstract = is_abstract;
            entry.socket_idx = sock_idx;
            entry.generation = gen;
            entry.allocated = true;
            return;
        }
    }
    return error.NoSpace;
}

/// Unregister a path binding
pub fn unregisterPath(path: []const u8, is_abstract: bool) void {
    const held = path_registry_lock.acquire();
    defer held.release();

    for (&path_registry) |*entry| {
        if (entry.allocated and entry.is_abstract == is_abstract and
            entry.path_len == path.len and
            std.mem.eql(u8, entry.path[0..entry.path_len], path))
        {
            entry.allocated = false;
            return;
        }
    }
}

/// Lookup a path and return the socket index and generation
pub fn lookupPath(path: []const u8, is_abstract: bool) ?struct { idx: usize, gen: u32 } {
    const held = path_registry_lock.acquire();
    defer held.release();

    for (&path_registry) |*entry| {
        if (entry.allocated and entry.is_abstract == is_abstract and
            entry.path_len == path.len and
            std.mem.eql(u8, entry.path[0..entry.path_len], path))
        {
            return .{ .idx = entry.socket_idx, .gen = entry.generation };
        }
    }
    return null;
}

// =============================================================================
// UNIX Socket Operations
// =============================================================================

/// Error set for UNIX socket operations
pub const UnixSocketError = error{
    InvalidArg,
    AddressInUse,
    NoMemory,
    NoSpace,
    NotSupported,
    WouldBlock,
    ConnectionRefused,
    AlreadyConnected,
    NotConnected,
    BadState,
};

/// Bind a socket to a path
pub fn bindSocket(sock: *UnixSocket, path: []const u8, is_abstract: bool, sock_idx: usize) UnixSocketError!void {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.state != .Unbound) return error.InvalidArg;

    // Register path (releases and reacquires lock internally via path_registry_lock)
    held.release();
    registerPath(path, is_abstract, sock_idx, sock.generation) catch |e| {
        _ = sock.lock.acquire();
        return switch (e) {
            error.AddressInUse => error.AddressInUse,
            error.NoSpace => error.NoSpace,
        };
    };

    // Reacquire socket lock for state update
    const held2 = sock.lock.acquire();
    _ = held2;

    // Duplicate the path
    const path_copy = heap.allocator().dupe(u8, path) catch {
        unregisterPath(path, is_abstract);
        return error.NoMemory;
    };

    sock.bound_path = path_copy;
    sock.is_abstract = is_abstract;
    sock.state = .Bound;
}

/// Start listening for connections
pub fn listenSocket(sock: *UnixSocket, backlog: usize) UnixSocketError!void {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.sock_type != types.SOCK_STREAM) return error.NotSupported;
    if (sock.state != .Bound) return error.InvalidArg;

    sock.backlog = @intCast(@min(backlog, FULL_ACCEPT_QUEUE_SIZE));
    if (sock.backlog == 0) sock.backlog = 1;
    sock.state = .Listening;
}

/// Accept a connection on a listening socket
/// Returns a new UnixSocket that is connected to the client
pub fn acceptSocket(sock: *UnixSocket) UnixSocketError!struct { new_sock: *UnixSocket, new_idx: usize } {
    while (true) {
        const held = sock.lock.acquire();

        if (sock.state != .Listening) {
            held.release();
            return error.InvalidArg;
        }

        if (sock.accept_count > 0) {
            const pair = sock.accept_queue[sock.accept_tail].?;
            sock.accept_queue[sock.accept_tail] = null;
            sock.accept_tail = (sock.accept_tail + 1) % FULL_ACCEPT_QUEUE_SIZE;
            sock.accept_count -= 1;
            held.release();

            // Create new connected socket for the server side
            const result = allocateSocket(types.SOCK_STREAM) orelse {
                releasePair(pair, 1);
                return error.NoMemory;
            };
            result.sock.pair = pair;
            result.sock.endpoint = 1;
            result.sock.state = .Connected;
            result.sock.blocking = sock.blocking;
            return .{ .new_sock = result.sock, .new_idx = result.idx };
        }

        if (!sock.blocking) {
            held.release();
            return error.WouldBlock;
        }

        // Block waiting for connection
        const get_current = scheduler.currentThreadFn() orelse {
            held.release();
            return error.WouldBlock;
        };
        sock.blocked_thread = get_current();
        sock.woken.store(false, .release);
        held.release();

        if (!sock.woken.load(.acquire)) {
            if (scheduler.blockFn()) |block_fn| {
                block_fn();
            }
        }

        // Loop back to try accepting again
    }
}

/// Connect to a listening socket
pub fn connectSocket(sock: *UnixSocket, path: []const u8, is_abstract: bool) UnixSocketError!void {
    {
        const held = sock.lock.acquire();
        defer held.release();

        if (sock.sock_type != types.SOCK_STREAM) return error.NotSupported;
        if (sock.state != .Unbound and sock.state != .Bound) return error.AlreadyConnected;
    }

    // Lookup target socket
    const target_info = lookupPath(path, is_abstract) orelse return error.ConnectionRefused;
    const target = acquireSocket(target_info.idx) orelse return error.ConnectionRefused;
    defer releaseSocket(target);

    const target_held = target.lock.acquire();

    // Verify target is still listening and generation matches
    if (target.state != .Listening or target.generation != target_info.gen) {
        target_held.release();
        return error.ConnectionRefused;
    }

    // Check accept queue capacity
    if (target.accept_count >= target.backlog) {
        target_held.release();
        return error.WouldBlock;
    }

    // Allocate a pair for the connection
    const pair = allocatePair(types.SOCK_STREAM) orelse {
        target_held.release();
        return error.NoMemory;
    };

    // Queue pair in target's accept queue
    target.accept_queue[target.accept_head] = pair;
    target.accept_head = (target.accept_head + 1) % FULL_ACCEPT_QUEUE_SIZE;
    target.accept_count += 1;

    // Wake blocked acceptor if any
    if (target.blocked_thread) |t| {
        target.woken.store(true, .release);
        target_held.release();
        scheduler.wakeThread(t);
    } else {
        target_held.release();
    }

    // Setup client side
    const client_held = sock.lock.acquire();
    sock.pair = pair;
    sock.endpoint = 0;
    sock.state = .Connected;
    client_held.release();
}

/// Read from a connected UNIX socket
pub fn readSocket(sock: *UnixSocket, buf: []u8) isize {
    while (true) {
        const held = sock.lock.acquire();

        if (sock.state != .Connected and sock.state != .Disconnected) {
            held.release();
            return Errno.ENOTCONN.toReturn();
        }

        const pair = sock.pair orelse {
            held.release();
            return Errno.ENOTCONN.toReturn();
        };

        const pair_held = pair.lock.acquire();
        const bytes_read = pair.read(sock.endpoint, buf);

        if (bytes_read > 0) {
            pair_held.release();
            held.release();
            return @intCast(bytes_read);
        }

        // Check if peer is closed
        if (pair.isPeerClosed(sock.endpoint)) {
            pair_held.release();
            held.release();
            return 0; // EOF
        }

        pair_held.release();

        if (!sock.blocking) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Block waiting for data
        const get_current = scheduler.currentThreadFn() orelse {
            held.release();
            return Errno.EAGAIN.toReturn();
        };
        const current = get_current();
        if (current == null) {
            held.release();
            return Errno.EAGAIN.toReturn();
        }

        // Setup blocking on the pair
        const pair_held2 = pair.lock.acquire();
        if (sock.endpoint == 0) {
            pair.blocked_reader_0 = current;
            pair.reader_0_woken.store(false, .release);
        } else {
            pair.blocked_reader_1 = current;
            pair.reader_1_woken.store(false, .release);
        }
        pair_held2.release();
        held.release();

        // Check woken flag before blocking
        const pair_held3 = pair.lock.acquire();
        const woken = if (sock.endpoint == 0)
            pair.reader_0_woken.load(.acquire)
        else
            pair.reader_1_woken.load(.acquire);
        pair_held3.release();

        if (!woken) {
            if (scheduler.blockFn()) |block_fn| {
                block_fn();
            }
        }

        // Loop back to try reading again
    }
}

/// Write to a connected UNIX socket
pub fn writeSocket(sock: *UnixSocket, data: []const u8) isize {
    const held = sock.lock.acquire();

    if (sock.state != .Connected) {
        held.release();
        return Errno.ENOTCONN.toReturn();
    }

    const pair = sock.pair orelse {
        held.release();
        return Errno.ENOTCONN.toReturn();
    };

    const pair_held = pair.lock.acquire();

    // Check if peer is closed
    if (pair.isPeerClosed(sock.endpoint)) {
        pair_held.release();
        held.release();
        return Errno.EPIPE.toReturn();
    }

    const written = pair.write(sock.endpoint, data);

    // Wake peer if blocked
    if (sock.endpoint == 0) {
        if (pair.blocked_reader_1) |t| {
            pair.reader_1_woken.store(true, .release);
            pair_held.release();
            held.release();
            scheduler.wakeThread(t);
            return @intCast(written);
        }
    } else {
        if (pair.blocked_reader_0) |t| {
            pair.reader_0_woken.store(true, .release);
            pair_held.release();
            held.release();
            scheduler.wakeThread(t);
            return @intCast(written);
        }
    }

    pair_held.release();
    held.release();

    if (written == 0 and !sock.blocking) {
        return Errno.EAGAIN.toReturn();
    }

    return @intCast(written);
}

/// Close a UNIX socket
pub fn closeSocket(sock: *UnixSocket) void {
    const held = sock.lock.acquire();

    // If connected, release the pair endpoint
    if (sock.pair) |pair| {
        releasePair(pair, sock.endpoint);
        sock.pair = null;
    }

    // If listening, drain accept queue
    while (sock.accept_count > 0) {
        if (sock.accept_queue[sock.accept_tail]) |pair| {
            releasePair(pair, 0);
            releasePair(pair, 1);
        }
        sock.accept_queue[sock.accept_tail] = null;
        sock.accept_tail = (sock.accept_tail + 1) % FULL_ACCEPT_QUEUE_SIZE;
        sock.accept_count -= 1;
    }

    sock.state = .Disconnected;
    held.release();

    // Release our reference (may free the socket)
    releaseSocket(sock);
}

/// Check if socket has data to read
pub fn hasDataSocket(sock: *UnixSocket) bool {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.state != .Connected) return false;
    const pair = sock.pair orelse return false;

    const pair_held = pair.lock.acquire();
    defer pair_held.release();

    return pair.hasData(sock.endpoint);
}

/// Check if socket is writable
pub fn canWriteSocket(sock: *UnixSocket) bool {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.state != .Connected) return false;
    const pair = sock.pair orelse return false;

    const pair_held = pair.lock.acquire();
    defer pair_held.release();

    return pair.writeSpace(sock.endpoint) > 0 and !pair.isPeerClosed(sock.endpoint);
}

/// Poll socket for events
pub fn pollSocket(sock: *UnixSocket, requested_events: u32) u32 {
    _ = requested_events;
    var events: u32 = 0;

    const held = sock.lock.acquire();
    defer held.release();

    switch (sock.state) {
        .Listening => {
            // Listening socket: readable means accept queue has connections
            if (sock.accept_count > 0) {
                events |= 0x0001; // POLLIN
            }
        },
        .Connected => {
            const pair = sock.pair orelse return events;
            const pair_held = pair.lock.acquire();
            defer pair_held.release();

            if (pair.hasData(sock.endpoint) or pair.isPeerClosed(sock.endpoint)) {
                events |= 0x0001; // POLLIN
            }
            if (pair.writeSpace(sock.endpoint) > 0 and !pair.isPeerClosed(sock.endpoint)) {
                events |= 0x0004; // POLLOUT
            }
            if (pair.isPeerClosed(sock.endpoint)) {
                events |= 0x0010; // POLLHUP
            }
        },
        .Disconnected => {
            events |= 0x0010; // POLLHUP
        },
        else => {},
    }

    return events;
}

// Import Errno for return codes
const uapi = @import("uapi");
const Errno = uapi.errno.Errno;
