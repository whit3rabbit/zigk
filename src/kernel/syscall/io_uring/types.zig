//! IO Uring Types and Constants

const std = @import("std");

/// Maximum io_uring instances per process
pub const MAX_RINGS_PER_PROCESS: usize = 4;

/// Maximum SQ/CQ entries (must be power of 2)
pub const MAX_RING_ENTRIES: u32 = 256;
pub const MIN_RING_ENTRIES: u32 = 1;

/// SQ ring header layout (at start of sq_ring page)
pub const SqRingHeader = extern struct {
    head: u32, // Consumer index (kernel reads)
    tail: u32, // Producer index (user writes)
    ring_mask: u32, // entries - 1
    ring_entries: u32, // Number of entries
    flags: u32,
    dropped: u32,
    // Followed by u32[entries] array of SQE indices
};

/// CQ ring header layout (at start of cq_ring page)
pub const CqRingHeader = extern struct {
    head: u32, // Consumer index (user reads)
    tail: u32, // Producer index (kernel writes)
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    // Followed by CQE[entries] array
};

/// Data attached to the io_uring file descriptor
pub const IoUringFdData = struct {
    instance_idx: usize,
};
