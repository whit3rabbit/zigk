// Userspace Ring Buffer IPC Library
//
// Provides a high-level API for zero-copy ring buffer IPC between
// userspace processes. Uses shared memory for data transfer.
//
// Usage (Producer):
//   var ring = try Ring.create(256, "netstack");
//   if (ring.reserve()) |entry| {
//       @memcpy(entry.data[0..len], data);
//       entry.len = len;
//       ring.commit();
//       ring.notify();
//   }
//
// Usage (Consumer):
//   var ring = try Ring.attach(ring_id);
//   _ = try ring.wait(1, 0);
//   while (ring.peek()) |entry| {
//       processPacket(entry.data[0..entry.len]);
//       ring.advance();
//   }

const std = @import("std");
const syscall = @import("syscall");
pub const uapi = syscall.uapi;
const ring_uapi = uapi.ring;
const syscalls = uapi.syscalls;
pub const SyscallError = syscall.SyscallError;

/// Memory barrier for x86_64 userspace
inline fn acquireFence() void {
    asm volatile ("lfence" ::: .{ .memory = true });
}

inline fn releaseFence() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

// Re-export uapi types for convenience
pub const RingHeader = ring_uapi.RingHeader;
pub const PacketEntry = ring_uapi.PacketEntry;
pub const RingAttachResult = ring_uapi.RingAttachResult;

/// Ring buffer wrapper for userspace IPC
pub const Ring = struct {
    /// Pointer to the shared ring header
    header: *volatile RingHeader,
    /// Pointer to entry data array
    entries: [*]volatile PacketEntry,
    /// Ring ID
    ring_id: u32,
    /// Entry count (cached from header)
    entry_count: u32,
    /// Entry size (cached from header)
    entry_size: u32,
    /// Ring mask for index wrapping
    ring_mask: u32,
    /// Whether this is the producer (vs consumer)
    is_producer: bool,
    /// Local producer index (for producer side)
    local_prod_idx: u64,
    /// Local consumer index (for consumer side)
    local_cons_idx: u64,

    // =========================================================================
    // Producer API
    // =========================================================================

    /// Create a new ring buffer for producing entries
    ///
    /// Args:
    ///   entry_count: Number of entries (must be power of 2, 2-4096)
    ///   consumer_service: Service name of the consumer (e.g., "netstack")
    ///
    /// Returns: Ring on success, error on failure
    pub fn create(entry_count: u32, consumer_service: []const u8) SyscallError!Ring {
        const ring_id = try ringCreate(
            ring_uapi.PacketEntry.SIZE,
            entry_count,
            0, // Look up by service name
            consumer_service.ptr,
            consumer_service.len,
        );

        // The ring is mapped at the returned ring_id's address
        // For now, we need to attach to get the mapping
        // In the full implementation, create would return the mapping directly
        return Ring{
            .header = undefined, // Will be set by producer after mmap
            .entries = undefined,
            .ring_id = ring_id,
            .entry_count = entry_count,
            .entry_size = ring_uapi.PacketEntry.SIZE,
            .ring_mask = entry_count - 1,
            .is_producer = true,
            .local_prod_idx = 0,
            .local_cons_idx = 0,
        };
    }

    /// Create ring with explicit consumer PID
    pub fn createForPid(entry_count: u32, consumer_pid: u32) SyscallError!Ring {
        const ring_id = try ringCreate(
            ring_uapi.PacketEntry.SIZE,
            entry_count,
            consumer_pid,
            undefined,
            0,
        );

        return Ring{
            .header = undefined,
            .entries = undefined,
            .ring_id = ring_id,
            .entry_count = entry_count,
            .entry_size = ring_uapi.PacketEntry.SIZE,
            .ring_mask = entry_count - 1,
            .is_producer = true,
            .local_prod_idx = 0,
            .local_cons_idx = 0,
        };
    }

    /// Reserve a slot for writing (producer only)
    ///
    /// Returns: Pointer to entry to fill, or null if ring is full
    pub fn reserve(self: *Ring) ?*volatile PacketEntry {
        if (!self.is_producer) return null;

        // Check if ring is full
        // Use volatile read with fence for acquire semantics on x86_64
        acquireFence();
        const cons_idx = self.header.cons_idx;
        const used = self.local_prod_idx -% cons_idx;
        if (used >= self.entry_count) {
            return null; // Ring full
        }

        // Return pointer to next slot
        const idx = self.local_prod_idx & self.ring_mask;
        return &self.entries[idx];
    }

    /// Commit the reserved entry (producer only)
    ///
    /// Must be called after filling the entry returned by reserve()
    pub fn commit(self: *Ring) void {
        if (!self.is_producer) return;

        // Ensure writes are visible before updating index
        releaseFence();

        // Advance producer index
        self.local_prod_idx += 1;
        self.header.prod_idx = self.local_prod_idx;
        // Release fence to ensure store is visible
        releaseFence();
    }

    /// Notify consumer that entries are available (producer only)
    pub fn notify(self: *Ring) SyscallError!void {
        if (!self.is_producer) return;
        try ringNotify(self.ring_id);
    }

    /// Get number of free slots available for producing
    pub fn freeSlots(self: *const Ring) u32 {
        acquireFence();
        const cons_idx = self.header.cons_idx;
        const used = self.local_prod_idx -% cons_idx;
        if (used >= self.entry_count) return 0;
        return @intCast(self.entry_count - used);
    }

    // =========================================================================
    // Consumer API
    // =========================================================================

    /// Attach to an existing ring as consumer
    ///
    /// Args:
    ///   ring_id: Ring ID from producer
    ///
    /// Returns: Ring on success, error on failure
    pub fn attach(ring_id: u32) SyscallError!Ring {
        var result: ring_uapi.RingAttachResult = undefined;
        try ringAttach(ring_id, &result);

        const header: *volatile RingHeader = @ptrFromInt(result.virt_addr);
        const entries: [*]volatile PacketEntry = @ptrFromInt(result.virt_addr + RingHeader.DATA_OFFSET);

        return Ring{
            .header = header,
            .entries = entries,
            .ring_id = ring_id,
            .entry_count = result.entry_count,
            .entry_size = result.entry_size,
            .ring_mask = result.entry_count - 1,
            .is_producer = false,
            .local_prod_idx = 0,
            .local_cons_idx = header.cons_idx,
        };
    }

    /// Peek at the next available entry (consumer only)
    ///
    /// Returns: Pointer to entry to read, or null if ring is empty
    pub fn peek(self: *Ring) ?*volatile PacketEntry {
        if (self.is_producer) return null;

        // Check if entries available
        // Use volatile read with fence for acquire semantics on x86_64
        acquireFence();
        const prod_idx = self.header.prod_idx;
        if (self.local_cons_idx >= prod_idx) {
            return null; // Ring empty
        }

        // Return pointer to next entry
        const idx = self.local_cons_idx & self.ring_mask;
        return &self.entries[idx];
    }

    /// Advance past the peeked entry (consumer only)
    ///
    /// Must be called after processing the entry returned by peek()
    pub fn advance(self: *Ring) void {
        if (self.is_producer) return;

        // Advance consumer index
        self.local_cons_idx += 1;
        // Release fence before store to ensure reads are complete
        releaseFence();
        self.header.cons_idx = self.local_cons_idx;
        releaseFence();
    }

    /// Wait for entries to become available (consumer only)
    ///
    /// Args:
    ///   min_entries: Minimum number of entries to wait for
    ///   timeout_ns: Timeout in nanoseconds (0 = infinite)
    ///
    /// Returns: Number of available entries
    pub fn wait(self: *Ring, min_entries: u32, timeout_ns: u64) SyscallError!u32 {
        if (self.is_producer) return error.InvalidArgument;
        return ringWait(self.ring_id, min_entries, timeout_ns);
    }

    /// Get number of entries available for consuming
    pub fn available(self: *const Ring) u32 {
        acquireFence();
        const prod_idx = self.header.prod_idx;
        const diff = prod_idx -% self.local_cons_idx;
        if (diff > self.entry_count) return self.entry_count;
        return @intCast(diff);
    }

    // =========================================================================
    // Common API
    // =========================================================================

    /// Detach from the ring
    pub fn detach(self: *Ring) SyscallError!void {
        try ringDetach(self.ring_id);
        self.header = undefined;
        self.entries = undefined;
    }

    /// Check if ring is active
    pub fn isActive(self: *const Ring) bool {
        return (self.header.flags & ring_uapi.RING_FLAG_ACTIVE) != 0;
    }

    /// Check if ring is closing
    pub fn isClosing(self: *const Ring) bool {
        return (self.header.flags & ring_uapi.RING_FLAG_CLOSING) != 0;
    }
};

// =============================================================================
// MPSC Consumer Helper
// =============================================================================

/// Multi-Producer Single-Consumer ring set
///
/// Manages multiple rings for MPSC pattern where multiple producers
/// send to a single consumer.
pub const RingSet = struct {
    rings: [ring_uapi.MAX_RINGS_PER_CONSUMER]?Ring,
    ring_ids: [ring_uapi.MAX_RINGS_PER_CONSUMER]u32,
    count: usize,

    /// Initialize an empty ring set
    pub fn init() RingSet {
        return RingSet{
            .rings = .{null} ** ring_uapi.MAX_RINGS_PER_CONSUMER,
            .ring_ids = undefined,
            .count = 0,
        };
    }

    /// Add a ring to the set
    pub fn add(self: *RingSet, ring: Ring) !void {
        if (self.count >= ring_uapi.MAX_RINGS_PER_CONSUMER) {
            return error.TooManyRings;
        }
        self.rings[self.count] = ring;
        self.ring_ids[self.count] = ring.ring_id;
        self.count += 1;
    }

    /// Wait for entries on any ring
    ///
    /// Returns: Index of ring with entries
    pub fn waitAny(self: *RingSet, min_entries: u32, timeout_ns: u64) SyscallError!usize {
        if (self.count == 0) return error.InvalidArgument;

        const ring_id = try ringWaitAny(
            self.ring_ids[0..self.count],
            min_entries,
            timeout_ns,
        );

        // Find index of returned ring
        for (self.ring_ids[0..self.count], 0..) |id, i| {
            if (id == ring_id) return i;
        }

        return error.Unexpected;
    }

    /// Poll all rings without blocking
    ///
    /// Returns: Index of first ring with entries, or null if all empty
    pub fn pollAny(self: *RingSet) ?usize {
        for (self.rings[0..self.count], 0..) |maybe_ring, i| {
            if (maybe_ring) |*ring| {
                if (ring.available() > 0) return i;
            }
        }
        return null;
    }

    /// Get ring by index
    pub fn get(self: *RingSet, index: usize) ?*Ring {
        if (index >= self.count) return null;
        if (self.rings[index]) |*ring| return ring;
        return null;
    }
};

// =============================================================================
// Low-Level Syscall Wrappers
// =============================================================================

/// Create a new ring buffer
fn ringCreate(
    entry_size: usize,
    entry_count: usize,
    consumer_pid: usize,
    service_name_ptr: [*]const u8,
    service_name_len: usize,
) SyscallError!u32 {
    const ret = syscall.syscall5(
        syscalls.SYS_RING_CREATE,
        entry_size,
        entry_count,
        consumer_pid,
        @intFromPtr(service_name_ptr),
        service_name_len,
    );
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
    return @intCast(ret);
}

/// Attach to an existing ring as consumer
fn ringAttach(ring_id: u32, result: *ring_uapi.RingAttachResult) SyscallError!void {
    const ret = syscall.syscall2(
        syscalls.SYS_RING_ATTACH,
        ring_id,
        @intFromPtr(result),
    );
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
}

/// Detach from a ring
fn ringDetach(ring_id: u32) SyscallError!void {
    const ret = syscall.syscall1(syscalls.SYS_RING_DETACH, ring_id);
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
}

/// Wait for entries on a single ring
fn ringWait(ring_id: u32, min_entries: u32, timeout_ns: u64) SyscallError!u32 {
    const ret = syscall.syscall3(
        syscalls.SYS_RING_WAIT,
        ring_id,
        min_entries,
        timeout_ns,
    );
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
    return @intCast(ret);
}

/// Notify consumer of new entries
fn ringNotify(ring_id: u32) SyscallError!void {
    const ret = syscall.syscall1(syscalls.SYS_RING_NOTIFY, ring_id);
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
}

/// Wait for entries on any of multiple rings
fn ringWaitAny(ring_ids: []const u32, min_entries: u32, timeout_ns: u64) SyscallError!u32 {
    const ret = syscall.syscall4(
        syscalls.SYS_RING_WAIT_ANY,
        @intFromPtr(ring_ids.ptr),
        ring_ids.len,
        min_entries,
        timeout_ns,
    );
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
    return @intCast(ret);
}
