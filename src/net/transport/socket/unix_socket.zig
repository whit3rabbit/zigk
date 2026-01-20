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

/// Maximum number of file descriptors that can be passed in a single SCM_RIGHTS message
pub const MAX_SCM_RIGHTS_FDS: usize = 8;

/// Maximum number of pending ancillary data messages per direction
pub const MAX_PENDING_ANCILLARY: usize = 4;

/// Maximum number of pending DGRAM messages per direction
pub const MAX_DGRAM_MESSAGES: usize = 32;

/// Pending ancillary data for SCM_RIGHTS FD passing
/// Each entry represents FDs attached to a specific data message
/// Note: FD pointers are stored as *anyopaque because the net module
/// doesn't have access to the kernel fd module. The syscall layer
/// casts these back to *FileDescriptor when processing.
pub const PendingAncillary = struct {
    /// File descriptors being passed (opaque pointers to FileDescriptor)
    fds: [MAX_SCM_RIGHTS_FDS]*anyopaque,
    /// Number of valid FDs in the array
    fd_count: usize,
    /// Byte offset in circular buffer where this ancillary data attaches
    data_offset: usize,
    /// Length of data message this is attached to
    data_len: usize,
    /// Whether this entry is valid/in-use
    valid: bool,
    /// Callback to release FD refs (set by syscall layer)
    release_fn: ?*const fn (*anyopaque) void,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .fds = undefined,
            .fd_count = 0,
            .data_offset = 0,
            .data_len = 0,
            .valid = false,
            .release_fn = null,
        };
    }

    /// Release all FD references held by this ancillary data
    /// Called when socket closes without receiving the FDs, or on error
    /// Uses the release callback set by the syscall layer
    pub fn releaseAll(self: *Self) void {
        if (!self.valid) return;

        if (self.release_fn) |release| {
            for (self.fds[0..self.fd_count]) |fd| {
                release(fd);
            }
        }
        self.fd_count = 0;
        self.valid = false;
        self.release_fn = null;
    }
};

/// Pending credentials data for SCM_CREDENTIALS
/// Each entry represents credentials attached to a specific data message
pub const PendingCredentials = struct {
    /// Process ID of sender
    pid: u32,
    /// User ID of sender
    uid: u32,
    /// Group ID of sender
    gid: u32,
    /// Byte offset in circular buffer where this credential attaches
    data_offset: usize,
    /// Length of data message this is attached to
    data_len: usize,
    /// Whether this entry is valid/in-use
    valid: bool,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .pid = 0,
            .uid = 0,
            .gid = 0,
            .data_offset = 0,
            .data_len = 0,
            .valid = false,
        };
    }
};

/// Message descriptor for SOCK_DGRAM boundary tracking
/// Each entry represents a complete datagram message in the buffer
pub const MessageDescriptor = struct {
    /// Start offset in circular buffer
    offset: usize,
    /// Message length in bytes
    length: usize,
    /// Whether this entry is valid/in-use
    valid: bool,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .offset = 0,
            .length = 0,
            .valid = false,
        };
    }
};

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

    /// Credentials of endpoint 0 (connecting client) - peer of endpoint 1
    peer_cred_0_pid: u32,
    peer_cred_0_uid: u32,
    peer_cred_0_gid: u32,
    /// Credentials of endpoint 1 (accepting server) - peer of endpoint 0
    peer_cred_1_pid: u32,
    peer_cred_1_uid: u32,
    peer_cred_1_gid: u32,

    /// Allocated flag
    allocated: bool,

    /// Ancillary data queue for FDs flowing from endpoint 0 to endpoint 1
    ancillary_0_to_1: [MAX_PENDING_ANCILLARY]PendingAncillary,
    ancillary_0_to_1_count: usize,

    /// Ancillary data queue for FDs flowing from endpoint 1 to endpoint 0
    ancillary_1_to_0: [MAX_PENDING_ANCILLARY]PendingAncillary,
    ancillary_1_to_0_count: usize,

    /// Credentials queue for SCM_CREDENTIALS flowing from endpoint 0 to endpoint 1
    credentials_0_to_1: [MAX_PENDING_ANCILLARY]PendingCredentials,
    credentials_0_to_1_count: usize,

    /// Credentials queue for SCM_CREDENTIALS flowing from endpoint 1 to endpoint 0
    credentials_1_to_0: [MAX_PENDING_ANCILLARY]PendingCredentials,
    credentials_1_to_0_count: usize,

    /// Message descriptor ring for SOCK_DGRAM boundary tracking (endpoint 0 to 1)
    msg_ring_0_to_1: [MAX_DGRAM_MESSAGES]MessageDescriptor,
    msg_head_0_to_1: usize, // Next slot to write
    msg_tail_0_to_1: usize, // Next slot to read
    msg_count_0_to_1: usize,

    /// Message descriptor ring for SOCK_DGRAM boundary tracking (endpoint 1 to 0)
    msg_ring_1_to_0: [MAX_DGRAM_MESSAGES]MessageDescriptor,
    msg_head_1_to_0: usize, // Next slot to write
    msg_tail_1_to_0: usize, // Next slot to read
    msg_count_1_to_0: usize,

    const Self = @This();

    pub fn init(sock_type: i32) Self {
        return Self{
            // SECURITY: Zero-initialize buffers to prevent kernel memory leaks.
            // In ReleaseFast builds, `undefined` would retain heap/stack garbage that could
            // leak to userspace via read() if data_len is corrupted or across socket
            // pair reallocations.
            .buffer_0_to_1 = [_]u8{0} ** UNIX_SOCKET_BUF_SIZE,
            .read_pos_0_to_1 = 0,
            .write_pos_0_to_1 = 0,
            .data_len_0_to_1 = 0,
            .buffer_1_to_0 = [_]u8{0} ** UNIX_SOCKET_BUF_SIZE,
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
            .peer_cred_0_pid = 0,
            .peer_cred_0_uid = 0,
            .peer_cred_0_gid = 0,
            .peer_cred_1_pid = 0,
            .peer_cred_1_uid = 0,
            .peer_cred_1_gid = 0,
            .allocated = true,
            .ancillary_0_to_1 = [_]PendingAncillary{PendingAncillary.init()} ** MAX_PENDING_ANCILLARY,
            .ancillary_0_to_1_count = 0,
            .ancillary_1_to_0 = [_]PendingAncillary{PendingAncillary.init()} ** MAX_PENDING_ANCILLARY,
            .ancillary_1_to_0_count = 0,
            .credentials_0_to_1 = [_]PendingCredentials{PendingCredentials.init()} ** MAX_PENDING_ANCILLARY,
            .credentials_0_to_1_count = 0,
            .credentials_1_to_0 = [_]PendingCredentials{PendingCredentials.init()} ** MAX_PENDING_ANCILLARY,
            .credentials_1_to_0_count = 0,
            .msg_ring_0_to_1 = [_]MessageDescriptor{MessageDescriptor.init()} ** MAX_DGRAM_MESSAGES,
            .msg_head_0_to_1 = 0,
            .msg_tail_0_to_1 = 0,
            .msg_count_0_to_1 = 0,
            .msg_ring_1_to_0 = [_]MessageDescriptor{MessageDescriptor.init()} ** MAX_DGRAM_MESSAGES,
            .msg_head_1_to_0 = 0,
            .msg_tail_1_to_0 = 0,
            .msg_count_1_to_0 = 0,
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

    /// Write a complete datagram (SOCK_DGRAM)
    /// Returns the write offset and bytes written, or null if message ring is full or buffer full
    pub fn writeDgram(self: *Self, endpoint: u1, data: []const u8) ?struct { offset: usize, written: usize } {
        // Select the correct buffer and message ring based on endpoint
        const buf = if (endpoint == 0) &self.buffer_0_to_1 else &self.buffer_1_to_0;
        const write_pos = if (endpoint == 0) &self.write_pos_0_to_1 else &self.write_pos_1_to_0;
        const data_len = if (endpoint == 0) &self.data_len_0_to_1 else &self.data_len_1_to_0;
        const msg_ring = if (endpoint == 0) &self.msg_ring_0_to_1 else &self.msg_ring_1_to_0;
        const msg_head = if (endpoint == 0) &self.msg_head_0_to_1 else &self.msg_head_1_to_0;
        const msg_count = if (endpoint == 0) &self.msg_count_0_to_1 else &self.msg_count_1_to_0;

        // Check if message ring is full
        if (msg_count.* >= MAX_DGRAM_MESSAGES) {
            return null;
        }

        // Check if buffer has space for the entire message
        const available = UNIX_SOCKET_BUF_SIZE - data_len.*;
        if (data.len > available) {
            return null; // EMSGSIZE - message too large
        }

        // Record start offset
        const start_offset = write_pos.*;

        // Write the complete message
        for (data) |byte| {
            buf[write_pos.*] = byte;
            write_pos.* = (write_pos.* + 1) % UNIX_SOCKET_BUF_SIZE;
        }
        data_len.* += data.len;

        // Record message descriptor
        msg_ring[msg_head.*] = MessageDescriptor{
            .offset = start_offset,
            .length = data.len,
            .valid = true,
        };
        msg_head.* = (msg_head.* + 1) % MAX_DGRAM_MESSAGES;
        msg_count.* += 1;

        return .{ .offset = start_offset, .written = data.len };
    }

    /// Read a complete datagram (SOCK_DGRAM)
    /// Returns the start offset, message length, and actual bytes copied, or null if no message
    /// Note: If user buffer is smaller than message, remainder is discarded (datagram semantics)
    pub fn readDgram(self: *Self, endpoint: u1, buf: []u8) ?struct { offset: usize, msg_len: usize, copied: usize } {
        // Select the correct buffer and message ring based on endpoint
        // Endpoint 0 reads from messages sent by endpoint 1
        const src_buf = if (endpoint == 0) &self.buffer_1_to_0 else &self.buffer_0_to_1;
        const read_pos = if (endpoint == 0) &self.read_pos_1_to_0 else &self.read_pos_0_to_1;
        const data_len = if (endpoint == 0) &self.data_len_1_to_0 else &self.data_len_0_to_1;
        const msg_ring = if (endpoint == 0) &self.msg_ring_1_to_0 else &self.msg_ring_0_to_1;
        const msg_tail = if (endpoint == 0) &self.msg_tail_1_to_0 else &self.msg_tail_0_to_1;
        const msg_count = if (endpoint == 0) &self.msg_count_1_to_0 else &self.msg_count_0_to_1;

        // Check if there's a message to read
        if (msg_count.* == 0) {
            return null;
        }

        // Get next message descriptor
        const msg = &msg_ring[msg_tail.*];
        if (!msg.valid) {
            return null;
        }

        const msg_len = msg.length;
        const start_offset = msg.offset;

        // Copy data to user buffer (up to buffer size)
        const to_copy = @min(buf.len, msg_len);
        var copied: usize = 0;
        var pos = read_pos.*;

        while (copied < to_copy) {
            buf[copied] = src_buf[pos];
            pos = (pos + 1) % UNIX_SOCKET_BUF_SIZE;
            copied += 1;
        }

        // Advance read position past entire message (even if we didn't copy it all)
        // This implements datagram discard semantics
        read_pos.* = (read_pos.* + msg_len) % UNIX_SOCKET_BUF_SIZE;
        data_len.* -= msg_len;

        // Mark message as consumed
        msg.valid = false;
        msg_tail.* = (msg_tail.* + 1) % MAX_DGRAM_MESSAGES;
        msg_count.* -= 1;

        return .{ .offset = start_offset, .msg_len = msg_len, .copied = copied };
    }

    /// Check if there's a complete datagram to read
    pub fn hasDgram(self: *const Self, endpoint: u1) bool {
        if (endpoint == 0) {
            return self.msg_count_1_to_0 > 0;
        } else {
            return self.msg_count_0_to_1 > 0;
        }
    }

    /// Check if the message ring has space for a new datagram
    pub fn canWriteDgram(self: *const Self, endpoint: u1) bool {
        if (endpoint == 0) {
            return self.msg_count_0_to_1 < MAX_DGRAM_MESSAGES;
        } else {
            return self.msg_count_1_to_0 < MAX_DGRAM_MESSAGES;
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

        // SECURITY: Clean up any unretrieved ancillary data to prevent FD leaks
        // Release FD refs for any pending SCM_RIGHTS messages that were never received
        for (&pair.ancillary_0_to_1) |*anc| {
            anc.releaseAll();
        }
        pair.ancillary_0_to_1_count = 0;

        for (&pair.ancillary_1_to_0) |*anc| {
            anc.releaseAll();
        }
        pair.ancillary_1_to_0_count = 0;
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

/// Queue ancillary data (FDs) for a message being sent
/// Called by sendmsg when SCM_RIGHTS control data is present
/// Returns error if ancillary queue is full
/// SECURITY: Caller must already hold refs on all FDs in the array
/// The fds parameter contains opaque pointers to FileDescriptor structs
pub fn queueAncillary(
    pair: *UnixSocketPair,
    endpoint: u1,
    fds: []const *anyopaque,
    data_offset: usize,
    data_len: usize,
    release_fn: *const fn (*anyopaque) void,
) error{QueueFull}!void {
    // Select the correct queue based on which endpoint is sending
    // endpoint 0 sends to endpoint 1, so use ancillary_0_to_1
    const queue = if (endpoint == 0) &pair.ancillary_0_to_1 else &pair.ancillary_1_to_0;
    const count = if (endpoint == 0) &pair.ancillary_0_to_1_count else &pair.ancillary_1_to_0_count;

    // Find a free slot
    for (queue) |*slot| {
        if (!slot.valid) {
            // Copy FD pointers to the slot
            for (fds, 0..) |fd, i| {
                slot.fds[i] = fd;
            }
            slot.fd_count = fds.len;
            slot.data_offset = data_offset;
            slot.data_len = data_len;
            slot.valid = true;
            slot.release_fn = release_fn;
            count.* += 1;
            return;
        }
    }

    return error.QueueFull;
}

/// Dequeue ancillary data for a received message
/// Called by recvmsg when data is read from the buffer
/// Returns the ancillary data if it matches the read position, or null
/// The caller takes ownership of the FD refs (no ref change here)
pub fn dequeueAncillary(
    pair: *UnixSocketPair,
    endpoint: u1,
    read_offset: usize,
) ?*PendingAncillary {
    // Select the correct queue based on which endpoint is receiving
    // endpoint 0 reads from buffer_1_to_0 (sent by endpoint 1)
    // so use ancillary_1_to_0
    const queue = if (endpoint == 0) &pair.ancillary_1_to_0 else &pair.ancillary_0_to_1;

    // Find ancillary data matching this read position
    for (queue) |*slot| {
        if (slot.valid and slot.data_offset == read_offset) {
            return slot;
        }
    }

    return null;
}

/// Mark ancillary data as consumed (after FDs have been installed in receiver)
pub fn consumeAncillary(
    pair: *UnixSocketPair,
    endpoint: u1,
    anc: *PendingAncillary,
) void {
    const count = if (endpoint == 0) &pair.ancillary_1_to_0_count else &pair.ancillary_0_to_1_count;

    anc.valid = false;
    anc.fd_count = 0;
    if (count.* > 0) {
        count.* -= 1;
    }
}

/// Queue credentials (SCM_CREDENTIALS) to be delivered with a data message
/// Called by sendmsg when SCM_CREDENTIALS control message is present
pub fn queueCredentials(
    pair: *UnixSocketPair,
    endpoint: u1,
    pid: u32,
    uid: u32,
    gid: u32,
    data_offset: usize,
    data_len: usize,
) error{QueueFull}!void {
    // Select the correct queue based on which endpoint is sending
    const queue = if (endpoint == 0) &pair.credentials_0_to_1 else &pair.credentials_1_to_0;
    const count = if (endpoint == 0) &pair.credentials_0_to_1_count else &pair.credentials_1_to_0_count;

    // Find a free slot
    for (queue) |*slot| {
        if (!slot.valid) {
            slot.pid = pid;
            slot.uid = uid;
            slot.gid = gid;
            slot.data_offset = data_offset;
            slot.data_len = data_len;
            slot.valid = true;
            count.* += 1;
            return;
        }
    }

    return error.QueueFull;
}

/// Dequeue credentials for a received message
/// Called by recvmsg when data is read from the buffer
/// Returns the credentials if they match the read position, or null
pub fn dequeueCredentials(
    pair: *UnixSocketPair,
    endpoint: u1,
    read_offset: usize,
) ?*PendingCredentials {
    // Select the correct queue based on which endpoint is receiving
    const queue = if (endpoint == 0) &pair.credentials_1_to_0 else &pair.credentials_0_to_1;

    // Find credentials matching this read position
    for (queue) |*slot| {
        if (slot.valid and slot.data_offset == read_offset) {
            return slot;
        }
    }

    return null;
}

/// Mark credentials as consumed
pub fn consumeCredentials(
    pair: *UnixSocketPair,
    endpoint: u1,
    cred: *PendingCredentials,
) void {
    const count = if (endpoint == 0) &pair.credentials_1_to_0_count else &pair.credentials_0_to_1_count;

    cred.valid = false;
    if (count.* > 0) {
        count.* -= 1;
    }
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

    /// Peer's bound path (for getpeername, heap-allocated copy)
    peer_path: ?[]u8,
    /// True if peer used abstract namespace
    peer_is_abstract: bool,

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
            .peer_path = null,
            .peer_is_abstract = false,
            .allocated = true,
        };
    }
};

// =============================================================================
// Path Registry
// =============================================================================

/// Hook for VFS to unlink socket files on cleanup
/// Set by VFS init to avoid circular dependency between net and fs modules
pub var vfs_unlink_hook: ?*const fn ([]const u8) void = null;

/// Entry in the path registry mapping paths to listening sockets
const PathEntry = struct {
    path: [108]u8,
    path_len: usize,
    is_abstract: bool,
    socket_idx: usize,
    generation: u32,
    allocated: bool,
    /// Whether we created a filesystem entry for this socket (non-abstract paths)
    /// Used to determine if unlink should be called on cleanup
    is_fs_created: bool,
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
        entry.is_fs_created = false;
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
        const peer_path = sock.peer_path;

        sock.allocated = false;
        held.release();

        // Cleanup outside lock
        if (bound_path) |path| {
            unregisterPath(path, is_abstract);
            heap.allocator().free(path);
        }
        if (peer_path) |path| {
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
/// is_fs_created: true if caller created a filesystem entry that should be unlinked on cleanup
pub fn registerPath(path: []const u8, is_abstract: bool, sock_idx: usize, gen: u32, is_fs_created: bool) PathError!void {
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
            entry.is_fs_created = is_fs_created;
            return;
        }
    }
    return error.NoSpace;
}

/// Unregister a path binding
/// Calls vfs_unlink_hook if the entry was filesystem-created (non-abstract)
pub fn unregisterPath(path: []const u8, is_abstract: bool) void {
    var should_unlink = false;
    var unlink_path: [108]u8 = undefined;
    var unlink_len: usize = 0;

    {
        const held = path_registry_lock.acquire();
        defer held.release();

        for (&path_registry) |*entry| {
            if (entry.allocated and entry.is_abstract == is_abstract and
                entry.path_len == path.len and
                std.mem.eql(u8, entry.path[0..entry.path_len], path))
            {
                // Check if we need to unlink the filesystem entry
                if (!entry.is_abstract and entry.is_fs_created) {
                    should_unlink = true;
                    @memcpy(unlink_path[0..entry.path_len], entry.path[0..entry.path_len]);
                    unlink_len = entry.path_len;
                }
                entry.allocated = false;
                entry.is_fs_created = false;
                break;
            }
        }
    }

    // Call unlink hook outside the lock to avoid potential deadlock
    if (should_unlink) {
        if (vfs_unlink_hook) |hook| {
            hook(unlink_path[0..unlink_len]);
        }
    }
}

/// Mark a path entry as having a filesystem socket file created
/// Called by sys_bind after creating the socket file in the filesystem
pub fn markPathFsCreated(path: []const u8) void {
    const held = path_registry_lock.acquire();
    defer held.release();

    for (&path_registry) |*entry| {
        if (entry.allocated and !entry.is_abstract and
            entry.path_len == path.len and
            std.mem.eql(u8, entry.path[0..entry.path_len], path))
        {
            entry.is_fs_created = true;
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
///
/// SECURITY: Uses scoped locking to prevent lock leaks and re-verifies state after
/// reacquiring lock to prevent TOCTOU races where two threads bind the same socket.
pub fn bindSocket(sock: *UnixSocket, path: []const u8, is_abstract: bool, sock_idx: usize) UnixSocketError!void {
    // Phase 1: Check state under lock
    {
        const held = sock.lock.acquire();
        defer held.release();

        if (sock.state != .Unbound) return error.InvalidArg;
    }

    // Phase 2: Register path (without socket lock - uses path_registry_lock internally)
    // Note: is_fs_created is false here since filesystem socket file creation
    // is handled by the syscall layer (sys_bind in net.zig)
    registerPath(path, is_abstract, sock_idx, sock.generation, false) catch |e| {
        return switch (e) {
            error.AddressInUse => error.AddressInUse,
            error.NoSpace => error.NoSpace,
        };
    };

    // Phase 3: Re-verify state and update under lock (TOCTOU protection)
    {
        const held = sock.lock.acquire();
        defer held.release();

        // Re-verify state to prevent race where another thread bound while we were registering
        if (sock.state != .Unbound) {
            // Another thread won the race - unregister our path and fail
            unregisterPath(path, is_abstract);
            return error.InvalidArg;
        }

        // Duplicate the path
        const path_copy = heap.allocator().dupe(u8, path) catch {
            unregisterPath(path, is_abstract);
            return error.NoMemory;
        };

        sock.bound_path = path_copy;
        sock.is_abstract = is_abstract;
        sock.state = .Bound;
    }
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
/// cred_pid/uid/gid: credentials of the accepting process (for SO_PEERCRED on client side)
pub fn acceptSocket(sock: *UnixSocket, cred_pid: u32, cred_uid: u32, cred_gid: u32) UnixSocketError!struct { new_sock: *UnixSocket, new_idx: usize } {
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

            // SECURITY FIX: Release the queue's reference (added in connectSocket).
            // The accepted socket will hold endpoint 1's reference.
            {
                const pair_held = pair.lock.acquire();
                pair.refcount -= 1;
                pair_held.release();
            }

            // Store accepting server's credentials in the pair (for SO_PEERCRED on client side)
            pair.peer_cred_1_pid = cred_pid;
            pair.peer_cred_1_uid = cred_uid;
            pair.peer_cred_1_gid = cred_gid;

            // Create new connected socket for the server side
            const result = allocateSocket(types.SOCK_STREAM) orelse {
                releasePair(pair, 1);
                return error.NoMemory;
            };
            result.sock.pair = pair;
            result.sock.endpoint = 1;
            result.sock.state = .Connected;
            result.sock.blocking = sock.blocking;

            // Copy client's credentials to the accepted socket's peer_* fields
            result.sock.peer_pid = pair.peer_cred_0_pid;
            result.sock.peer_uid = pair.peer_cred_0_uid;
            result.sock.peer_gid = pair.peer_cred_0_gid;

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
/// cred_pid/uid/gid: credentials of the connecting process (for SO_PEERCRED)
pub fn connectSocket(sock: *UnixSocket, path: []const u8, is_abstract: bool, cred_pid: u32, cred_uid: u32, cred_gid: u32) UnixSocketError!void {
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

    // Store connecting client's credentials in the pair (for SO_PEERCRED on server side)
    pair.peer_cred_0_pid = cred_pid;
    pair.peer_cred_0_uid = cred_uid;
    pair.peer_cred_0_gid = cred_gid;

    // Queue pair in target's accept queue
    target.accept_queue[target.accept_head] = pair;
    target.accept_head = (target.accept_head + 1) % FULL_ACCEPT_QUEUE_SIZE;
    target.accept_count += 1;

    // SECURITY FIX: Accept queue holds its own reference to the pair.
    // This prevents use-after-free if the listening socket closes before accept().
    // Refcount is now 3: client endpoint 0 + future server endpoint 1 + queue.
    {
        const pair_held = pair.lock.acquire();
        pair.refcount += 1;
        pair_held.release();
    }

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

    // Store the peer's path (the path we connected to) for getpeername
    sock.peer_path = heap.allocator().dupe(u8, path) catch null;
    sock.peer_is_abstract = is_abstract;

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
    // SECURITY FIX: Only release the queue's reference, not both endpoints.
    // The client (endpoint 0) still holds its reference from connectSocket.
    // We mark endpoint 1 as shutdown to notify the client of connection refused/EOF.
    while (sock.accept_count > 0) {
        if (sock.accept_queue[sock.accept_tail]) |pair| {
            const pair_held = pair.lock.acquire();

            // Mark server endpoint as shutdown to signal EOF to client
            pair.shutdown_1 = true;

            // Release only the queue's reference (decrement refcount once)
            pair.refcount -= 1;
            const should_free = pair.refcount == 0;
            if (should_free) {
                pair.allocated = false;
            }

            // Wake blocked reader on client side so they see EOF
            if (pair.blocked_reader_0) |t| {
                pair.reader_0_woken.store(true, .release);
                pair_held.release();
                scheduler.wakeThread(t);
            } else {
                pair_held.release();
            }
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

/// Get the peer address for a connected UNIX socket (getpeername)
/// Returns a SockAddrUn with the peer's path, or an unnamed address if peer was anonymous
pub fn getpeernameSocket(sock: *UnixSocket, addr: *uapi.abi.SockAddrUn) UnixSocketError!usize {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.state != .Connected and sock.state != .Disconnected) {
        return error.NotConnected;
    }

    addr.* = uapi.abi.SockAddrUn.init();

    if (sock.peer_path) |path| {
        // Peer had a bound path
        if (sock.peer_is_abstract) {
            // Abstract socket: leading null byte followed by path
            addr.sun_path[0] = 0;
            const copy_len = @min(path.len, uapi.abi.SockAddrUn.PATH_MAX - 1);
            @memcpy(addr.sun_path[1 .. 1 + copy_len], path[0..copy_len]);
            return 2 + 1 + copy_len; // family(2) + null(1) + path
        } else {
            // Filesystem socket: path is null-terminated
            const copy_len = @min(path.len, uapi.abi.SockAddrUn.PATH_MAX - 1);
            @memcpy(addr.sun_path[0..copy_len], path[0..copy_len]);
            addr.sun_path[copy_len] = 0;
            return 2 + copy_len + 1; // family(2) + path + null
        }
    }

    // Peer was anonymous (unnamed socket) - return just the family
    return 2;
}

/// Get the local (bound) address for a UNIX socket
/// Returns a SockAddrUn with the bound path, or an unnamed address if not bound
pub fn getsocknameSocket(sock: *UnixSocket, addr: *uapi.abi.SockAddrUn) usize {
    const held = sock.lock.acquire();
    defer held.release();

    addr.* = uapi.abi.SockAddrUn.init();

    if (sock.bound_path) |path| {
        // Socket is bound to a path
        if (sock.is_abstract) {
            // Abstract socket: leading null byte followed by path
            addr.sun_path[0] = 0;
            const copy_len = @min(path.len, uapi.abi.SockAddrUn.PATH_MAX - 1);
            @memcpy(addr.sun_path[1 .. 1 + copy_len], path[0..copy_len]);
            return 2 + 1 + copy_len; // family(2) + null(1) + path
        } else {
            // Filesystem socket: path is null-terminated
            const copy_len = @min(path.len, uapi.abi.SockAddrUn.PATH_MAX - 1);
            @memcpy(addr.sun_path[0..copy_len], path[0..copy_len]);
            addr.sun_path[copy_len] = 0;
            return 2 + copy_len + 1; // family(2) + path + null
        }
    }

    // Unbound or unnamed socket - return just the family
    return 2; // Just the family field (unnamed socket)
}

/// Shutdown constants (POSIX standard)
pub const SHUT_RD: i32 = 0; // No more receives
pub const SHUT_WR: i32 = 1; // No more sends
pub const SHUT_RDWR: i32 = 2; // No more receives or sends

/// Shutdown a connected UNIX socket
/// how: SHUT_RD (0), SHUT_WR (1), or SHUT_RDWR (2)
pub fn shutdownSocket(sock: *UnixSocket, how: i32) UnixSocketError!void {
    if (how < 0 or how > 2) return error.InvalidArg;

    const held = sock.lock.acquire();

    if (sock.state != .Connected) {
        held.release();
        return error.NotConnected;
    }

    const pair = sock.pair orelse {
        held.release();
        return error.NotConnected;
    };

    const pair_held = pair.lock.acquire();

    // Set appropriate shutdown flags on the pair
    if (sock.endpoint == 0) {
        if (how == SHUT_RD or how == SHUT_RDWR) {
            // Shutdown read on endpoint 0 means we won't read from buffer_1_to_0
            // This doesn't affect the peer's ability to write
        }
        if (how == SHUT_WR or how == SHUT_RDWR) {
            // Shutdown write on endpoint 0 means we signal EOF to endpoint 1
            pair.shutdown_0 = true;
            // Wake blocked reader on endpoint 1
            if (pair.blocked_reader_1) |t| {
                pair.reader_1_woken.store(true, .release);
                pair_held.release();
                held.release();
                scheduler.wakeThread(t);
                return;
            }
        }
    } else {
        if (how == SHUT_RD or how == SHUT_RDWR) {
            // Shutdown read on endpoint 1 means we won't read from buffer_0_to_1
        }
        if (how == SHUT_WR or how == SHUT_RDWR) {
            // Shutdown write on endpoint 1 means we signal EOF to endpoint 0
            pair.shutdown_1 = true;
            // Wake blocked reader on endpoint 0
            if (pair.blocked_reader_0) |t| {
                pair.reader_0_woken.store(true, .release);
                pair_held.release();
                held.release();
                scheduler.wakeThread(t);
                return;
            }
        }
    }

    pair_held.release();
    held.release();
}

/// Get peer credentials for SO_PEERCRED
/// Returns (pid, uid, gid) of the peer process, or error if not connected
pub fn getPeerCredentials(sock: *UnixSocket) UnixSocketError!struct { pid: u32, uid: u32, gid: u32 } {
    const held = sock.lock.acquire();
    defer held.release();

    if (sock.state != .Connected) {
        return error.NotConnected;
    }

    const pair = sock.pair orelse return error.NotConnected;

    // Endpoint 0 (client) gets endpoint 1's (server's) credentials
    // Endpoint 1 (server) gets endpoint 0's (client's) credentials
    if (sock.endpoint == 0) {
        return .{
            .pid = pair.peer_cred_1_pid,
            .uid = pair.peer_cred_1_uid,
            .gid = pair.peer_cred_1_gid,
        };
    } else {
        return .{
            .pid = pair.peer_cred_0_pid,
            .uid = pair.peer_cred_0_uid,
            .gid = pair.peer_cred_0_gid,
        };
    }
}

// Import Errno for return codes
const uapi = @import("uapi");
const Errno = uapi.errno.Errno;
