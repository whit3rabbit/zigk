// Virtual PCI Event Ring Types
//
// Event ring structures for MMIO interception and device communication.
// Follows the ring.zig pattern for zero-copy IPC.
//
// Architecture:
//   - Producer: Kernel (generates MMIO events)
//   - Consumer: Userspace (handles MMIO events, sends responses)
//   - Uses cache-line aligned header for performance

const std = @import("std");

// =============================================================================
// Event Types
// =============================================================================

/// Event type enumeration
pub const VPciEventType = enum(u8) {
    /// MMIO read request (userspace must respond with data)
    mmio_read = 0,
    /// MMIO write notification (data included)
    mmio_write = 1,
    /// Config space read (standard header handled by kernel)
    config_read = 2,
    /// Config space write (for capability registers)
    config_write = 3,
    /// Device reset notification
    reset = 4,
    /// MSI/MSI-X configuration changed
    msi_config = 5,
    /// Power state change request
    power_state = 6,
    /// Device removed notification
    removed = 7,
};

// =============================================================================
// Event Ring Header (follows ring.zig pattern)
// =============================================================================

/// Event ring header structure
///
/// Memory layout (384 bytes total):
///   - Producer cache line (0-127): prod_idx + padding
///   - Consumer cache line (128-255): cons_idx + padding
///   - Metadata cache line (256-383): configuration
///   - Event entries follow at offset 384
pub const VPciRingHeader = extern struct {
    // =========================================================================
    // Producer cache line (offset 0, 128 bytes)
    // Written by kernel, read by userspace
    // =========================================================================

    /// Producer write index (monotonically increasing)
    prod_idx: u64 align(1),

    /// Padding to fill cache line
    _prod_pad: [120]u8,

    // =========================================================================
    // Consumer cache line (offset 128, 128 bytes)
    // Written by userspace, read by kernel
    // =========================================================================

    /// Consumer read index (monotonically increasing)
    cons_idx: u64 align(1),

    /// Padding to fill cache line
    _cons_pad: [120]u8,

    // =========================================================================
    // Metadata cache line (offset 256, 128 bytes)
    // =========================================================================

    /// Ring mask (entry_count - 1)
    ring_mask: u32,

    /// Number of entries
    entry_count: u32,

    /// Device ID this ring belongs to
    device_id: u32,

    /// Ring flags
    flags: u32,

    /// Pending response count (atomically updated)
    pending_responses: u32,

    /// Reserved
    _reserved: [108]u8,

    comptime {
        if (@sizeOf(@This()) != 384) @compileError("VPciRingHeader must be 384 bytes");
    }

    /// Offset where event entries begin
    pub const DATA_OFFSET: usize = 384;

    /// Calculate total ring size
    pub fn totalSize(entry_count: u32) usize {
        return DATA_OFFSET + @as(usize, entry_count) * @sizeOf(VPciEvent);
    }

    /// Get number of available events
    pub fn availableEvents(self: *const volatile VPciRingHeader) u32 {
        const prod = @atomicLoad(u64, &self.prod_idx, .acquire);
        const cons = @atomicLoad(u64, &self.cons_idx, .acquire);
        const raw_available: u64 = prod -% cons;
        return @intCast(@min(raw_available, self.entry_count));
    }

    /// Get number of free slots
    pub fn freeSlots(self: *const volatile VPciRingHeader) u32 {
        const prod = @atomicLoad(u64, &self.prod_idx, .acquire);
        const cons = @atomicLoad(u64, &self.cons_idx, .acquire);
        const used: u64 = prod -% cons;
        const capped_used: u32 = @intCast(@min(used, self.entry_count));
        return self.entry_count -| capped_used;
    }
};

// =============================================================================
// Event Structure (48 bytes, cache-line friendly)
// =============================================================================

/// MMIO/Config event delivered to userspace
///
/// For mmio_read events, userspace must call sys_vpci_respond with matching seq.
/// For mmio_write events, data contains the written value (no response needed).
pub const VPciEvent = extern struct {
    /// Sequence number for request/response correlation
    seq: u64,

    /// Event type
    event_type: VPciEventType,

    /// BAR index (for MMIO events)
    bar: u8,

    /// Access size in bytes (1, 2, 4, or 8)
    size: u8,

    /// Reserved
    _reserved: u8 = 0,

    /// Offset within BAR or config space
    offset: u32,

    /// Data (write value for mmio_write, response placeholder for mmio_read)
    data: u64,

    /// Timestamp (monotonic, in ticks)
    timestamp: u64,

    /// Additional flags
    flags: u32,

    /// Reserved for alignment
    _pad: u32 = 0,

    comptime {
        if (@sizeOf(@This()) != 48) @compileError("VPciEvent must be 48 bytes");
    }

    /// Event flags
    pub const FLAG_NEEDS_RESPONSE: u32 = 1 << 0;
    pub const FLAG_TIMEOUT: u32 = 1 << 1;
    pub const FLAG_ERROR: u32 = 1 << 2;
};

/// Response to an MMIO read event
pub const VPciResponse = extern struct {
    /// Sequence number (must match event seq)
    seq: u64,

    /// Response data
    data: u64,

    /// Status (0 = success, negative = error)
    status: i32,

    /// Reserved
    _pad: u32 = 0,

    comptime {
        if (@sizeOf(@This()) != 24) @compileError("VPciResponse must be 24 bytes");
    }

    pub const STATUS_OK: i32 = 0;
    pub const STATUS_ERROR: i32 = -1;
    pub const STATUS_TIMEOUT: i32 = -2;
    pub const STATUS_INVALID: i32 = -3;
};

// =============================================================================
// Ring Configuration
// =============================================================================

/// Default number of event ring entries
pub const DEFAULT_RING_ENTRIES: u32 = 256;

/// Maximum ring entries
pub const MAX_RING_ENTRIES: u32 = 4096;

/// Minimum ring entries
pub const MIN_RING_ENTRIES: u32 = 16;

/// Ring flags
pub const RING_FLAG_ACTIVE: u32 = 1 << 0;
pub const RING_FLAG_CLOSING: u32 = 1 << 1;

// =============================================================================
// Wait Event Result
// =============================================================================

/// Result from sys_vpci_wait_event
pub const VPciWaitResult = extern struct {
    /// Number of events available
    event_count: u32,
    /// First event index
    first_idx: u32,
    /// Timestamp of oldest event
    oldest_timestamp: u64,

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("VPciWaitResult must be 16 bytes");
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Check if value is power of 2
pub fn isPowerOf2(n: u32) bool {
    return n > 0 and (n & (n - 1)) == 0;
}

/// Calculate pages needed for event ring
pub fn ringPageCount(entry_count: u32) usize {
    const total_size = VPciRingHeader.totalSize(entry_count);
    const page_size = 4096;
    return (total_size + page_size - 1) / page_size;
}

// =============================================================================
// Tests
// =============================================================================

test "VPciRingHeader size" {
    try std.testing.expectEqual(@as(usize, 384), @sizeOf(VPciRingHeader));
}

test "VPciEvent size" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(VPciEvent));
}

test "VPciResponse size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(VPciResponse));
}

test "ring total size" {
    // 256 entries * 48 bytes + 384 header = 12672 bytes
    const size = VPciRingHeader.totalSize(256);
    try std.testing.expectEqual(@as(usize, 12672), size);
}
