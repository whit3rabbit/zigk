// NVMe Queue Structures
//
// Defines Submission Queue Entry (SQE), Completion Queue Entry (CQE),
// and QueuePair management for NVMe command submission and completion.
//
// Reference: NVM Express Base Specification 2.0, Section 4

const std = @import("std");
const hal = @import("hal");
const io = @import("io");
const sync = @import("sync");
const dma = @import("dma");

// ============================================================================
// Constants
// ============================================================================

/// Maximum entries per queue (from CAP.MQES, typically 65536)
pub const MAX_QUEUE_ENTRIES: u16 = 256;

/// Submission Queue Entry size (always 64 bytes)
pub const SQE_SIZE: usize = 64;

/// Completion Queue Entry size (always 16 bytes)
pub const CQE_SIZE: usize = 16;

// ============================================================================
// Submission Queue Entry (SQE)
// ============================================================================

/// Common Submission Queue Entry structure (64 bytes)
/// Used for both Admin and I/O commands
pub const SubmissionEntry = extern struct {
    /// Command Dword 0: Opcode, Fused, PSDT, CID
    cdw0: Cdw0,

    /// Namespace ID (for I/O commands) or reserved
    nsid: u32,

    /// Command Dword 2 (command-specific or reserved)
    cdw2: u32,

    /// Command Dword 3 (command-specific or reserved)
    cdw3: u32,

    /// Metadata Pointer (MPTR)
    mptr: u64,

    /// Data Pointer - PRP Entry 1 or SGL Entry 1
    prp1: u64,

    /// Data Pointer - PRP Entry 2 or SGL Entry 2
    prp2: u64,

    /// Command Dword 10 (command-specific)
    cdw10: u32,

    /// Command Dword 11 (command-specific)
    cdw11: u32,

    /// Command Dword 12 (command-specific)
    cdw12: u32,

    /// Command Dword 13 (command-specific)
    cdw13: u32,

    /// Command Dword 14 (command-specific)
    cdw14: u32,

    /// Command Dword 15 (command-specific)
    cdw15: u32,

    /// Command Dword 0 structure
    pub const Cdw0 = packed struct(u32) {
        /// Opcode
        opc: u8,
        /// Fused Operation (00 = normal, 01 = first, 10 = second)
        fuse: u2,
        /// Reserved
        _reserved: u4,
        /// PRP or SGL for Data Transfer
        /// 00 = PRP, 01 = SGL (MPTR contains address), 10 = SGL (MPTR contains segment descriptor)
        psdt: u2,
        /// Command Identifier
        cid: u16,
    };

    /// Zero-initialize an entry
    pub fn init() SubmissionEntry {
        return std.mem.zeroes(SubmissionEntry);
    }

    /// Set command identifier (supports volatile pointers)
    pub fn setCid(self: anytype, cid: u16) void {
        self.cdw0.cid = cid;
    }

    /// Get command identifier
    pub fn getCid(self: *const SubmissionEntry) u16 {
        return self.cdw0.cid;
    }

    /// Set opcode
    pub fn setOpcode(self: *SubmissionEntry, opcode: u8) void {
        self.cdw0.opc = opcode;
    }

    /// Set PRP1 and PRP2
    pub fn setPrp(self: *SubmissionEntry, prp1: u64, prp2: u64) void {
        self.prp1 = prp1;
        self.prp2 = prp2;
    }
};

// Compile-time size verification
comptime {
    if (@sizeOf(SubmissionEntry) != SQE_SIZE) {
        @compileError("SubmissionEntry must be exactly 64 bytes");
    }
}

// ============================================================================
// Completion Queue Entry (CQE)
// ============================================================================

/// Completion Queue Entry structure (16 bytes)
pub const CompletionEntry = extern struct {
    /// Command Specific result (DW0)
    dw0: u32,

    /// Reserved (DW1)
    dw1: u32,

    /// SQ Head Pointer and SQ Identifier (DW2)
    dw2: Dw2,

    /// Status and Command Identifier (DW3)
    dw3: Dw3,

    pub const Dw2 = packed struct(u32) {
        /// Submission Queue Head Pointer
        sqhd: u16,
        /// Submission Queue Identifier
        sqid: u16,
    };

    pub const Dw3 = packed struct(u32) {
        /// Command Identifier
        cid: u16,
        /// Phase Tag
        p: bool,
        /// Status Code
        sc: u8,
        /// Status Code Type
        sct: u3,
        /// Command Retry Delay
        crd: u2,
        /// More (indicates more status available)
        m: bool,
        /// Do Not Retry
        dnr: bool,
    };

    /// Get command identifier (supports volatile pointers)
    pub fn getCid(self: anytype) u16 {
        return self.dw3.cid;
    }

    /// Get phase bit (supports volatile pointers)
    pub fn getPhase(self: anytype) bool {
        return self.dw3.p;
    }

    /// Get submission queue head pointer (supports volatile pointers)
    pub fn getSqHead(self: anytype) u16 {
        return self.dw2.sqhd;
    }

    /// Get submission queue identifier (supports volatile pointers)
    pub fn getSqId(self: anytype) u16 {
        return self.dw2.sqid;
    }

    /// Check if command completed successfully (supports volatile pointers)
    pub fn succeeded(self: anytype) bool {
        return self.dw3.sc == 0 and self.dw3.sct == 0;
    }

    /// Check if error is retryable (supports volatile pointers)
    pub fn isRetryable(self: anytype) bool {
        return !self.dw3.dnr;
    }

    /// Get full status field for error reporting (supports volatile pointers)
    pub fn getStatus(self: anytype) u16 {
        // SCT (3 bits) | SC (8 bits) = 11 bits total in upper half of dw3
        return (@as(u16, self.dw3.sct) << 8) | @as(u16, self.dw3.sc);
    }

    /// Status Code Types
    pub const StatusCodeType = enum(u3) {
        generic = 0,
        command_specific = 1,
        media_and_data_integrity = 2,
        path_related = 3,
        vendor_specific = 7,
    };

    /// Generic Status Codes (SCT = 0)
    pub const GenericStatus = enum(u8) {
        success = 0x00,
        invalid_opcode = 0x01,
        invalid_field = 0x02,
        command_id_conflict = 0x03,
        data_transfer_error = 0x04,
        aborted_power_loss = 0x05,
        internal_error = 0x06,
        aborted_by_request = 0x07,
        aborted_sq_deletion = 0x08,
        aborted_fused_fail = 0x09,
        aborted_fused_missing = 0x0A,
        invalid_namespace = 0x0B,
        command_sequence_error = 0x0C,
        invalid_sgl_segment = 0x0D,
        invalid_sgl_count = 0x0E,
        data_sgl_length = 0x0F,
        metadata_sgl_length = 0x10,
        sgl_type = 0x11,
        invalid_use_cmb = 0x12,
        prp_offset = 0x13,
        atomic_write_exceeded = 0x14,
        // ... more status codes
        lba_out_of_range = 0x80,
        capacity_exceeded = 0x81,
        namespace_not_ready = 0x82,
        reservation_conflict = 0x83,
        format_in_progress = 0x84,
    };
};

// Compile-time size verification
comptime {
    if (@sizeOf(CompletionEntry) != CQE_SIZE) {
        @compileError("CompletionEntry must be exactly 16 bytes");
    }
}

// ============================================================================
// Queue Pair (SQ + CQ)
// ============================================================================

/// Maximum pending requests per queue
pub const MAX_PENDING_REQUESTS: usize = MAX_QUEUE_ENTRIES;

/// Queue Pair - manages a paired Submission/Completion queue
pub const QueuePair = struct {
    /// Queue ID (0 = Admin, 1+ = I/O)
    qid: u16,

    /// Queue size (number of entries, actual count not 0-based)
    size: u16,

    // Submission Queue state
    sq_base_phys: u64,
    sq_base_virt: u64,
    sq_dma: dma.DmaBuffer,
    sq_tail: u16,
    sq_doorbell_offset: u64,

    // Completion Queue state
    cq_base_phys: u64,
    cq_base_virt: u64,
    cq_dma: dma.DmaBuffer,
    cq_head: u16,
    cq_phase: bool,
    cq_doorbell_offset: u64,

    // Async request tracking
    pending_requests: [MAX_PENDING_REQUESTS]?*io.IoRequest,
    pending_lock: sync.Spinlock,

    // Command ID allocation
    next_cid: u16,

    // Whether this queue is active
    active: bool,

    const Self = @This();

    /// Initialize a new queue pair (queues must be allocated separately)
    pub fn init(qid: u16, size: u16) Self {
        return Self{
            .qid = qid,
            .size = size,
            .sq_base_phys = 0,
            .sq_base_virt = 0,
            .sq_dma = undefined,
            .sq_tail = 0,
            .sq_doorbell_offset = 0,
            .cq_base_phys = 0,
            .cq_base_virt = 0,
            .cq_dma = undefined,
            .cq_head = 0,
            .cq_phase = true, // Phase starts at 1
            .cq_doorbell_offset = 0,
            .pending_requests = [_]?*io.IoRequest{null} ** MAX_PENDING_REQUESTS,
            .pending_lock = .{},
            .next_cid = 0,
            .active = false,
        };
    }

    /// Get pointer to SQE at given index
    pub fn getSqEntry(self: *Self, index: u16) *volatile SubmissionEntry {
        const offset = @as(usize, index) * SQE_SIZE;
        return @ptrFromInt(self.sq_base_virt + offset);
    }

    /// Get pointer to CQE at given index
    pub fn getCqEntry(self: *Self, index: u16) *volatile CompletionEntry {
        const offset = @as(usize, index) * CQE_SIZE;
        return @ptrFromInt(self.cq_base_virt + offset);
    }

    /// Allocate a command ID (must be called under pending_lock)
    pub fn allocCidLocked(self: *Self) ?u16 {
        // Simple linear search for free slot
        // For higher performance, could use a free list
        const start = self.next_cid;
        var cid = start;

        while (true) {
            if (self.pending_requests[cid] == null) {
                self.next_cid = (cid + 1) % self.size;
                return cid;
            }
            cid = (cid + 1) % self.size;
            if (cid == start) {
                // Wrapped around - all slots in use
                return null;
            }
        }
    }

    /// Submit a command (advances SQ tail)
    /// Caller must have already built the SQE at getSqEntry(sq_tail)
    pub fn submit(self: *Self) void {
        // Advance tail pointer (wraps at queue size)
        self.sq_tail = (self.sq_tail + 1) % self.size;
    }

    /// Check if there's a new completion (phase bit matches expected)
    pub fn hasCompletion(self: *Self) bool {
        const cqe = self.getCqEntry(self.cq_head);
        return cqe.getPhase() == self.cq_phase;
    }

    /// Advance CQ head (call after processing a completion)
    pub fn advanceCqHead(self: *Self) void {
        self.cq_head = (self.cq_head + 1) % self.size;
        // Phase bit flips when we wrap around
        if (self.cq_head == 0) {
            self.cq_phase = !self.cq_phase;
        }
    }

    /// Get number of pending commands
    pub fn pendingCount(self: *Self) u16 {
        var count: u16 = 0;
        for (self.pending_requests) |req| {
            if (req != null) count += 1;
        }
        return count;
    }
};

// ============================================================================
// PRP List Management
// ============================================================================

/// Physical Region Page Entry
/// Each PRP entry is a 64-bit physical address
/// Lower 2 bits specify offset within page (must be 0 for PRP list entries)
pub const PrpEntry = u64;

/// Maximum PRPs in a single PRP list page (4KB / 8 bytes = 512 entries)
pub const MAX_PRPS_PER_PAGE: usize = 512;

/// Calculate number of PRP entries needed for a transfer
/// Returns: { prp1, prp2_or_list, list_entries }
pub fn calculatePrpNeeds(data_addr: u64, byte_count: usize, page_size: u32) struct {
    needs_list: bool,
    list_entries: usize,
} {
    if (byte_count == 0) {
        return .{ .needs_list = false, .list_entries = 0 };
    }

    const ps: usize = @intCast(page_size);

    // First page: from data_addr to end of first page
    const offset_in_first_page = data_addr & (@as(u64, ps) - 1);
    const first_page_bytes = ps - @as(usize, @intCast(offset_in_first_page));

    if (byte_count <= first_page_bytes) {
        // Fits in first page - only PRP1 needed
        return .{ .needs_list = false, .list_entries = 0 };
    }

    const remaining = byte_count - first_page_bytes;
    const additional_pages = (remaining + ps - 1) / ps;

    if (additional_pages <= 1) {
        // Fits in PRP1 + PRP2
        return .{ .needs_list = false, .list_entries = 0 };
    }

    // Need a PRP list
    return .{ .needs_list = true, .list_entries = additional_pages };
}
