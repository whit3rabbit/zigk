// Ring Buffer User API Structures
//
// Shared between kernel and userspace for zero-copy IPC.
// Uses decomposed SPSC (Single-Producer Single-Consumer) rings
// with MPSC (Multi-Producer) semantics via per-producer rings.
//
// Reference: https://github.com/boonzy00/ringmpsc
//
// ABI Compatibility:
//   - All structures use extern for C-compatible layout
//   - Cache line alignment (128 bytes) for producer/consumer indices
//   - Matches x86_64 memory model requirements

const std = @import("std");

// =============================================================================
// Ring Header - Shared Memory Layout
// =============================================================================

/// Ring buffer header structure
///
/// Memory layout (384 bytes total):
///   - Producer cache line (0-127): prod_idx + padding
///   - Consumer cache line (128-255): cons_idx + padding
///   - Metadata cache line (256-383): ring_mask, entry_size, etc.
///   - Data entries follow at offset 384
///
/// Cache line separation prevents false sharing between producer and consumer.
pub const RingHeader = extern struct {
    // =========================================================================
    // Producer cache line (offset 0, 128 bytes)
    // Written by producer, read by consumer
    // =========================================================================

    /// Producer write index (monotonically increasing)
    /// Use: prod_idx & ring_mask to get actual slot
    prod_idx: u64 align(1),

    /// Padding to fill cache line
    _prod_pad: [120]u8,

    // =========================================================================
    // Consumer cache line (offset 128, 128 bytes)
    // Written by consumer, read by producer
    // =========================================================================

    /// Consumer read index (monotonically increasing)
    /// Use: cons_idx & ring_mask to get actual slot
    cons_idx: u64 align(1),

    /// Padding to fill cache line
    _cons_pad: [120]u8,

    // =========================================================================
    // Metadata cache line (offset 256, 128 bytes)
    // Written once at creation, read by both
    // =========================================================================

    /// Ring mask (entry_count - 1, for efficient modulo)
    ring_mask: u32,

    /// Size of each entry in bytes
    entry_size: u32,

    /// Number of entries (must be power of 2)
    entry_count: u32,

    /// Ring flags (RING_FLAG_*)
    flags: u32,

    /// Offset for futex wait (relative to ring start)
    /// Typically points to cons_idx for producer wait, prod_idx for consumer wait
    futex_offset: u32,

    /// Ring ID (for syscall identification)
    ring_id: u32,

    /// Producer PID (for validation)
    producer_pid: u32,

    /// Consumer PID (for validation)
    consumer_pid: u32,

    /// Reserved for future use
    _meta_reserved: [96]u8,

    // Data entries follow at offset 384

    comptime {
        if (@sizeOf(RingHeader) != 384) {
            @compileError("RingHeader must be 384 bytes (3 cache lines)");
        }
    }

    /// Offset where data entries begin
    pub const DATA_OFFSET: usize = 384;

    /// Calculate total ring size in bytes
    pub fn totalSize(entry_count: u32, entry_size: u32) usize {
        return DATA_OFFSET + @as(usize, entry_count) * @as(usize, entry_size);
    }
};

// =============================================================================
// Packet Entry - Network Packet Format
// =============================================================================

/// Network packet entry for VirtIO-Net <-> Netstack communication
///
/// Size: 1552 bytes (fits standard MTU + metadata)
pub const PacketEntry = extern struct {
    /// Packet length in bytes (0 = empty slot)
    len: u32,

    /// Packet flags (PACKET_FLAG_*)
    flags: u32,

    /// Timestamp (TSC or monotonic clock)
    timestamp: u64,

    /// Packet data (MTU-sized)
    data: [MAX_PACKET_DATA]u8,

    pub const MAX_PACKET_DATA: usize = 1536;

    /// Entry size in bytes (for syscall parameters)
    pub const SIZE: usize = 1552;

    comptime {
        if (@sizeOf(PacketEntry) != SIZE) {
            @compileError("PacketEntry must be 1552 bytes");
        }
    }

    /// Check if entry contains valid data
    pub fn isValid(self: *const volatile PacketEntry) bool {
        return self.len > 0 and self.len <= MAX_PACKET_DATA;
    }

    /// Clear entry (mark as consumed)
    pub fn clear(self: *volatile PacketEntry) void {
        self.len = 0;
        self.flags = 0;
    }
};

// =============================================================================
// Syscall Result Structures
// =============================================================================

/// Result from sys_ring_create
pub const RingCreateResult = extern struct {
    /// Assigned ring ID
    ring_id: u32,

    /// Reserved for alignment
    _pad: u32,

    /// Virtual address where ring is mapped
    virt_addr: u64,

    /// Number of entries in ring
    entry_count: u32,

    /// Size of each entry
    entry_size: u32,

    comptime {
        if (@sizeOf(RingCreateResult) != 24) {
            @compileError("RingCreateResult must be 24 bytes");
        }
    }
};

/// Result from sys_ring_attach
pub const RingAttachResult = extern struct {
    /// Virtual address where ring is mapped
    virt_addr: u64,

    /// Number of entries in ring
    entry_count: u32,

    /// Size of each entry
    entry_size: u32,

    comptime {
        if (@sizeOf(RingAttachResult) != 16) {
            @compileError("RingAttachResult must be 16 bytes");
        }
    }
};

// =============================================================================
// Ring Flags
// =============================================================================

/// Ring is active and accepting entries
pub const RING_FLAG_ACTIVE: u32 = 1 << 0;

/// Ring supports batch operations
pub const RING_FLAG_BATCH: u32 = 1 << 1;

/// Ring uses timestamps
pub const RING_FLAG_TIMESTAMP: u32 = 1 << 2;

/// Ring is closing (no new entries accepted)
pub const RING_FLAG_CLOSING: u32 = 1 << 3;

// =============================================================================
// Packet Flags
// =============================================================================

/// Packet is RX (received from network)
pub const PACKET_FLAG_RX: u32 = 1 << 0;

/// Packet is TX (to be transmitted)
pub const PACKET_FLAG_TX: u32 = 1 << 1;

/// Packet has valid checksum
pub const PACKET_FLAG_CSUM_VALID: u32 = 1 << 2;

/// Packet needs checksum offload
pub const PACKET_FLAG_CSUM_OFFLOAD: u32 = 1 << 3;

/// Packet is a broadcast
pub const PACKET_FLAG_BROADCAST: u32 = 1 << 4;

/// Packet is a multicast
pub const PACKET_FLAG_MULTICAST: u32 = 1 << 5;

// =============================================================================
// Ring State (kernel-side only, included for documentation)
// =============================================================================

/// Ring state enumeration
pub const RingState = enum(u8) {
    /// Ring slot is free (not allocated)
    free = 0,
    /// Ring created, producer attached
    created = 1,
    /// Both producer and consumer attached
    attached = 2,
    /// Ring is being torn down
    closing = 3,
};

// =============================================================================
// Configuration Constants
// =============================================================================

/// Maximum number of rings system-wide
pub const MAX_RINGS: usize = 256;

/// Maximum number of rings a consumer can attach to (for MPSC)
pub const MAX_RINGS_PER_CONSUMER: usize = 16;

/// Default ring capacity (entries)
pub const DEFAULT_RING_ENTRIES: u32 = 256;

/// Maximum ring capacity (entries)
pub const MAX_RING_ENTRIES: u32 = 4096;

/// Minimum ring capacity (entries)
pub const MIN_RING_ENTRIES: u32 = 2;

/// Maximum entry size
pub const MAX_ENTRY_SIZE: u32 = 64 * 1024; // 64KB

/// Minimum entry size
pub const MIN_ENTRY_SIZE: u32 = 16;

// Security: Ensure MAX_RING_ENTRIES * MAX_ENTRY_SIZE cannot overflow usize.
// This guards totalSize() against integer overflow if these constants are ever increased.
// See: CLAUDE.md Integer Safety guidelines.
comptime {
    const max_data = @as(u64, MAX_RING_ENTRIES) * @as(u64, MAX_ENTRY_SIZE);
    const max_total = max_data + RingHeader.DATA_OFFSET;
    if (max_total > std.math.maxInt(usize)) {
        @compileError("MAX_RING_ENTRIES * MAX_ENTRY_SIZE + DATA_OFFSET exceeds usize");
    }
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Check if a value is a power of 2
pub fn isPowerOf2(n: u32) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

/// Calculate number of pages needed for a ring
pub fn ringPageCount(entry_count: u32, entry_size: u32) usize {
    const total_size = RingHeader.totalSize(entry_count, entry_size);
    const page_size = 4096;
    return (total_size + page_size - 1) / page_size;
}

// =============================================================================
// Tests
// =============================================================================

test "RingHeader size and alignment" {
    try std.testing.expectEqual(@as(usize, 384), @sizeOf(RingHeader));
    try std.testing.expectEqual(@as(usize, 384), RingHeader.DATA_OFFSET);
}

test "PacketEntry size" {
    try std.testing.expectEqual(@as(usize, 1552), @sizeOf(PacketEntry));
}

test "RingCreateResult size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(RingCreateResult));
}

test "RingAttachResult size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RingAttachResult));
}

test "isPowerOf2" {
    try std.testing.expect(isPowerOf2(1));
    try std.testing.expect(isPowerOf2(2));
    try std.testing.expect(isPowerOf2(4));
    try std.testing.expect(isPowerOf2(256));
    try std.testing.expect(!isPowerOf2(0));
    try std.testing.expect(!isPowerOf2(3));
    try std.testing.expect(!isPowerOf2(100));
}

test "ring total size calculation" {
    // 256 entries * 1552 bytes + 384 header = 397696 bytes
    const size = RingHeader.totalSize(256, 1552);
    try std.testing.expectEqual(@as(usize, 397696), size);

    // Page count: ceil(397696 / 4096) = 98 pages
    const pages = ringPageCount(256, 1552);
    try std.testing.expectEqual(@as(usize, 98), pages);
}
