//! Ring Buffer Manager for Zero-Copy IPC
//!
//! Manages shared memory ring buffers for high-performance IPC between
//! userspace processes (e.g., VirtIO-Net driver <-> Netstack).
//!
//! Architecture:
//!   - Decomposed SPSC: Each producer gets a dedicated ring
//!   - Consumer polls multiple rings for MPSC semantics
//!   - 128-byte cache line alignment prevents false sharing
//!   - Futex integration for sleep/wake when rings are empty
//!
//! Memory Layout:
//!   - Ring header (384 bytes): indices + metadata
//!   - Data entries follow at offset 384
//!   - Physical pages mapped via HHDM (kernel) and mmap (userspace)
//!
//! SECURITY NOTES:
//!   - Ring header indices are in shared memory, so both producer and consumer
//!     can modify them. This is an intentional design choice for SPSC rings.
//!   - The kernel MUST validate that available entries never exceeds entry_count
//!     to prevent a malicious producer from causing consumer out-of-bounds reads.
//!   - The ring_mask (entry_count - 1) ensures index wrapping is always safe
//!     as long as we cap available entries at entry_count.
//!   - Trust model: Producer and consumer must cooperate for correctness.
//!     A malicious producer can send garbage data but cannot cause consumer
//!     memory corruption due to bounds checking in availableEntries().

const std = @import("std");
const uapi = @import("uapi");
const ring_uapi = uapi.ring;
const sync = @import("sync");
const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");
const futex = @import("futex");
const sched = @import("sched");
const console = @import("console");
const service = @import("ipc_service");

// =============================================================================
// Configuration
// =============================================================================

/// Maximum rings system-wide
const MAX_RINGS: usize = ring_uapi.MAX_RINGS;

// =============================================================================
// Ring Descriptor (Kernel-side metadata)
// =============================================================================

/// Ring state
pub const RingState = enum(u8) {
    /// Ring slot is free
    free = 0,
    /// Ring created, producer attached
    created = 1,
    /// Both producer and consumer attached
    attached = 2,
    /// Ring is being torn down
    closing = 3,
};

/// Kernel-side ring descriptor
pub const RingDescriptor = struct {
    /// Physical address of ring buffer
    ring_phys: u64,
    /// Kernel virtual address (via HHDM)
    ring_virt: u64,
    /// Total ring size in bytes (header + data)
    ring_size: usize,
    /// Number of physical pages
    page_count: usize,
    /// Entry size in bytes
    entry_size: u32,
    /// Number of entries
    entry_count: u32,
    /// Producer PID
    producer_pid: u32,
    /// Consumer PID
    consumer_pid: u32,
    /// Ring ID
    ring_id: u32,
    /// Current state
    state: RingState,
    /// Producer has mapped the ring
    producer_mapped: bool,
    /// Consumer has mapped the ring
    consumer_mapped: bool,

    /// Get the ring header (via HHDM)
    pub fn getHeader(self: *const RingDescriptor) *volatile ring_uapi.RingHeader {
        return @ptrFromInt(self.ring_virt);
    }

    /// Get pointer to entry data array
    pub fn getEntries(self: *const RingDescriptor, comptime T: type) [*]volatile T {
        return @ptrFromInt(self.ring_virt + ring_uapi.RingHeader.DATA_OFFSET);
    }

    /// Check if ring has available entries (for consumer)
    pub fn hasEntries(self: *const RingDescriptor) bool {
        const header = self.getHeader();
        return header.prod_idx != header.cons_idx;
    }

    /// Get number of available entries
    ///
    /// SECURITY: Caps the result at entry_count to prevent a malicious producer
    /// from setting prod_idx to cause consumer out-of-bounds reads. The wrapping
    /// subtraction handles index wraparound correctly, and the min() ensures
    /// we never return more entries than the ring can hold.
    pub fn availableEntries(self: *const RingDescriptor) u32 {
        const header = self.getHeader();
        // Wrapping subtraction handles index wraparound (u64 indices, power-of-2 ring)
        const raw_available: u64 = header.prod_idx -% header.cons_idx;
        // SECURITY: Cap at entry_count to prevent OOB if producer lies about prod_idx
        return @intCast(@min(raw_available, self.entry_count));
    }

    /// Get number of free slots (for producer)
    ///
    /// SECURITY: Uses saturating subtraction to prevent underflow if a malicious
    /// consumer sets cons_idx ahead of prod_idx.
    pub fn freeSlots(self: *const RingDescriptor) u32 {
        const header = self.getHeader();
        const used: u64 = header.prod_idx -% header.cons_idx;
        // SECURITY: Cap used at entry_count, then use saturating subtraction
        const capped_used: u32 = @intCast(@min(used, self.entry_count));
        return self.entry_count -| capped_used;
    }
};

// =============================================================================
// Global Ring Table
// =============================================================================

var rings: [MAX_RINGS]RingDescriptor = undefined;
var rings_lock: sync.Spinlock = .{};
var initialized: bool = false;

/// Initialize the ring subsystem
pub fn init() void {
    if (initialized) return;

    for (&rings, 0..) |*ring, idx| {
        ring.* = std.mem.zeroes(RingDescriptor);
        ring.state = .free;
        ring.ring_id = @intCast(idx);
    }

    initialized = true;
    console.info("Ring IPC subsystem initialized ({} max rings)", .{MAX_RINGS});
}

/// Ensure initialization
fn ensureInit() void {
    if (!initialized) init();
}

// =============================================================================
// Ring Allocation
// =============================================================================

/// Allocate a new ring buffer
///
/// Arguments:
///   entry_size: Size of each entry in bytes
///   entry_count: Number of entries (must be power of 2)
///   producer_pid: PID of the producer process
///   consumer_pid: PID of the consumer process
///
/// Returns: Pointer to RingDescriptor on success, error otherwise
pub fn allocateRing(
    entry_size: u32,
    entry_count: u32,
    producer_pid: u32,
    consumer_pid: u32,
) !*RingDescriptor {
    ensureInit();

    // Validate parameters
    if (entry_size < ring_uapi.MIN_ENTRY_SIZE or entry_size > ring_uapi.MAX_ENTRY_SIZE) {
        return error.InvalidEntrySize;
    }
    if (entry_count < ring_uapi.MIN_RING_ENTRIES or entry_count > ring_uapi.MAX_RING_ENTRIES) {
        return error.InvalidEntryCount;
    }
    if (!ring_uapi.isPowerOf2(entry_count)) {
        return error.NotPowerOfTwo;
    }

    // Calculate total size
    const total_size = ring_uapi.RingHeader.totalSize(entry_count, entry_size);
    const page_count = (total_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

    // Allocate zeroed physical pages
    const phys = pmm.allocZeroedPages(page_count) orelse {
        return error.OutOfMemory;
    };
    errdefer pmm.freePages(phys, page_count);

    // Get kernel virtual address via HHDM
    const virt: u64 = @intFromPtr(hal.paging.physToVirt(phys));

    // Find free slot
    const held = rings_lock.acquire();
    defer held.release();

    for (&rings) |*ring| {
        if (ring.state == .free) {
            // Initialize descriptor
            ring.ring_phys = phys;
            ring.ring_virt = virt;
            ring.ring_size = page_count * pmm.PAGE_SIZE;
            ring.page_count = page_count;
            ring.entry_size = entry_size;
            ring.entry_count = entry_count;
            ring.producer_pid = producer_pid;
            ring.consumer_pid = consumer_pid;
            ring.state = .created;
            ring.producer_mapped = false;
            ring.consumer_mapped = false;

            // Initialize ring header
            const header = ring.getHeader();
            header.prod_idx = 0;
            header.cons_idx = 0;
            header.ring_mask = entry_count - 1;
            header.entry_size = entry_size;
            header.entry_count = entry_count;
            header.flags = ring_uapi.RING_FLAG_ACTIVE;
            header.futex_offset = @offsetOf(ring_uapi.RingHeader, "cons_idx");
            header.ring_id = ring.ring_id;
            header.producer_pid = producer_pid;
            header.consumer_pid = consumer_pid;

            // Memory barrier to ensure header is visible
            if (comptime @import("builtin").cpu.arch == .x86_64) { @import("hal").mmio.memoryBarrier(); }

            console.debug("Ring {}: allocated {} entries x {} bytes = {} pages", .{
                ring.ring_id,
                entry_count,
                entry_size,
                page_count,
            });

            return ring;
        }
    }

    // No free slots - free the pages we allocated
    pmm.freePages(phys, page_count);
    return error.TooManyRings;
}

/// Get ring by ID
pub fn getRing(ring_id: u32) ?*RingDescriptor {
    ensureInit();

    if (ring_id >= MAX_RINGS) return null;

    const held = rings_lock.acquire();
    defer held.release();

    const ring = &rings[ring_id];
    if (ring.state == .free) return null;
    return ring;
}

/// Get ring by ID (unsafe, no lock - use only when lock already held)
fn getRingUnsafe(ring_id: u32) ?*RingDescriptor {
    if (ring_id >= MAX_RINGS) return null;
    const ring = &rings[ring_id];
    if (ring.state == .free) return null;
    return ring;
}

// =============================================================================
// Ring Attachment
// =============================================================================

/// Attach consumer to ring
///
/// Called when consumer maps the ring into their address space.
/// Transitions ring from .created to .attached state.
pub fn attachConsumer(ring: *RingDescriptor, consumer_pid: u32) !void {
    const held = rings_lock.acquire();
    defer held.release();

    // Verify consumer PID matches
    if (ring.consumer_pid != consumer_pid) {
        return error.PermissionDenied;
    }

    // Check state
    if (ring.state != .created) {
        return error.InvalidState;
    }

    ring.state = .attached;
    ring.consumer_mapped = true;

    console.debug("Ring {}: consumer {} attached", .{ ring.ring_id, consumer_pid });
}

/// Detach from ring (producer or consumer)
pub fn detach(ring: *RingDescriptor, pid: u32) !void {
    const held = rings_lock.acquire();
    defer held.release();

    if (ring.producer_pid != pid and ring.consumer_pid != pid) {
        return error.PermissionDenied;
    }

    // Mark as closing
    ring.state = .closing;
    ring.getHeader().flags |= ring_uapi.RING_FLAG_CLOSING;

    // Check if we can free the ring
    if (ring.producer_pid == pid) {
        ring.producer_mapped = false;
    }
    if (ring.consumer_pid == pid) {
        ring.consumer_mapped = false;
    }

    // If both detached, free the ring
    if (!ring.producer_mapped and !ring.consumer_mapped) {
        freeRingLocked(ring);
    }
}

/// Free ring resources (must hold rings_lock)
fn freeRingLocked(ring: *RingDescriptor) void {
    if (ring.ring_phys != 0) {
        pmm.freePages(ring.ring_phys, ring.page_count);
    }

    const ring_id = ring.ring_id;
    ring.* = std.mem.zeroes(RingDescriptor);
    ring.state = .free;
    ring.ring_id = ring_id;

    console.debug("Ring {}: freed", .{ring_id});
}

/// Free ring (public, acquires lock)
pub fn freeRing(ring: *RingDescriptor) void {
    const held = rings_lock.acquire();
    defer held.release();
    freeRingLocked(ring);
}

// =============================================================================
// Wait/Notify (Futex Integration)
// =============================================================================

/// Wait for entries on a single ring
///
/// Blocks via futex if no entries available.
///
/// Arguments:
///   ring: Ring to wait on
///   min_entries: Minimum entries to wait for
///   timeout_ns: Timeout in nanoseconds (null = infinite)
///
/// Returns: Number of available entries, or error
pub fn waitForEntries(ring: *RingDescriptor, min_entries: u32, timeout_ns: ?u64) !u32 {
    // Fast path: check if entries already available
    var available = ring.availableEntries();
    if (available >= min_entries) {
        return available;
    }

    // Slow path: yield and poll until entries available or timeout
    // (Future: integrate with futex for proper blocking)

    // Loop until we have enough entries or timeout
    while (available < min_entries) {
        // Verify we have a valid thread context
        _ = sched.getCurrentThread() orelse return error.NoThread;

        // Set up wait with timeout
        if (timeout_ns) |ns| {
            const timeout_ticks = (ns + 999_999) / 1_000_000;
            if (timeout_ticks > 0) {
                sched.sleepForTicks(timeout_ticks);
            }
        } else {
            // Yield and check again
            sched.yield();
        }

        // Re-check
        available = ring.availableEntries();

        // Check for timeout (simplified - just one iteration with timeout)
        if (timeout_ns != null and available < min_entries) {
            return error.TimedOut;
        }
    }

    return available;
}

/// Wait for entries on any of multiple rings (MPSC pattern)
///
/// Polls all rings, returns first ring with entries or sleeps if all empty.
///
/// Arguments:
///   ring_ids: Array of ring IDs to poll
///   min_entries: Minimum entries to wait for
///   timeout_ns: Timeout in nanoseconds (null = infinite)
///
/// Returns: Ring ID with entries, or error
pub fn waitForEntriesAny(ring_ids: []const u32, min_entries: u32, timeout_ns: ?u64) !u32 {
    ensureInit();

    const held = rings_lock.acquire();

    // Fast path: check all rings
    for (ring_ids) |ring_id| {
        if (getRingUnsafe(ring_id)) |ring| {
            if (ring.availableEntries() >= min_entries) {
                held.release();
                return ring_id;
            }
        }
    }

    held.release();

    // Slow path: sleep and retry
    // Verify we have a valid thread context
    _ = sched.getCurrentThread() orelse return error.NoThread;

    if (timeout_ns) |ns| {
        const timeout_ticks = (ns + 999_999) / 1_000_000;
        if (timeout_ticks > 0) {
            sched.sleepForTicks(timeout_ticks);
        }
    } else {
        sched.yield();
    }

    // Re-check after wake
    const held2 = rings_lock.acquire();
    defer held2.release();

    for (ring_ids) |ring_id| {
        if (getRingUnsafe(ring_id)) |ring| {
            if (ring.availableEntries() >= min_entries) {
                return ring_id;
            }
        }
    }

    if (timeout_ns != null) {
        return error.TimedOut;
    }

    return error.WouldBlock;
}

/// Notify consumer that entries are available
///
/// Called by producer after committing entries.
/// Wakes any thread waiting on the ring via futex.
pub fn notifyConsumer(ring: *RingDescriptor) !void {
    // For kernel-internal notification, we would wake via scheduler
    // For user-facing notification, producer calls futex_wake on prod_idx

    // Memory barrier to ensure writes are visible
    if (comptime @import("builtin").cpu.arch == .x86_64) { @import("hal").mmio.memoryBarrier(); }

    // In a full implementation, we would track waiting threads per-ring
    // and wake them directly. For now, rely on userspace futex.
    _ = ring;
}

// =============================================================================
// Process Cleanup
// =============================================================================

/// Clean up all rings owned by a process (on exit)
pub fn cleanupByPid(pid: u32) void {
    ensureInit();

    const held = rings_lock.acquire();
    defer held.release();

    for (&rings) |*ring| {
        if (ring.state == .free) continue;

        var should_free = false;

        if (ring.producer_pid == pid) {
            ring.producer_mapped = false;
            ring.state = .closing;
            if (!ring.consumer_mapped) should_free = true;
        }

        if (ring.consumer_pid == pid) {
            ring.consumer_mapped = false;
            ring.state = .closing;
            if (!ring.producer_mapped) should_free = true;
        }

        if (should_free) {
            freeRingLocked(ring);
        }
    }
}

// =============================================================================
// Debug/Stats
// =============================================================================

/// Get ring statistics
pub fn getStats() struct { total: usize, active: usize, attached: usize } {
    ensureInit();

    const held = rings_lock.acquire();
    defer held.release();

    var active: usize = 0;
    var attached: usize = 0;

    for (&rings) |*ring| {
        switch (ring.state) {
            .created => active += 1,
            .attached => {
                active += 1;
                attached += 1;
            },
            else => {},
        }
    }

    return .{
        .total = MAX_RINGS,
        .active = active,
        .attached = attached,
    };
}
