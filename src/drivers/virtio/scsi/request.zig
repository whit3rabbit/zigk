// VirtIO-SCSI Request and Response Structures
//
// SCSI command request/response definitions per VirtIO Specification 1.1 Section 5.6.6
//
// Request format:
//   [ScsiRequestCmd header] -> [data out] -> [ScsiResponseCmd] <- [data in]
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html

const std = @import("std");
const io = @import("io");
const dma = @import("dma");
const config = @import("config.zig");

// ============================================================================
// VirtIO-SCSI Request Header
// ============================================================================

/// VirtIO-SCSI command request header (device-readable)
/// Per VirtIO spec Section 5.6.6.1
pub const ScsiRequestCmd = extern struct {
    /// LUN address in VirtIO format (8 bytes)
    /// Format: [1][target][lun_hi|0x40][lun_lo][0][0][0][0]
    lun: [8]u8 align(1),

    /// Unique tag identifying this request (for request/response correlation)
    tag: u64 align(1),

    /// Task attribute (SAM-5 task attributes)
    /// 0=SIMPLE, 1=ORDERED, 2=HEAD_OF_QUEUE, 3=ACA
    task_attr: u8 align(1),

    /// Command priority (0-15)
    prio: u8 align(1),

    /// Command reference number (for task management)
    crn: u8 align(1),

    /// SCSI Command Descriptor Block
    /// Padded to config.cdb_size (typically 16 or 32 bytes)
    cdb: [config.Limits.MAX_CDB_SIZE]u8 align(1),

    /// Get the actual size based on cdb_size configuration
    pub fn sizeForCdbSize(cdb_size: u32) usize {
        // Base size (lun + tag + task_attr + prio + crn) + cdb_size
        return 8 + 8 + 1 + 1 + 1 + cdb_size;
    }
};

// Compile-time verification
comptime {
    // lun(8) + tag(8) + task_attr(1) + prio(1) + crn(1) + cdb(32) = 51 bytes
    if (@sizeOf(ScsiRequestCmd) != 51) {
        @compileError("ScsiRequestCmd size mismatch");
    }
}

// ============================================================================
// VirtIO-SCSI Response
// ============================================================================

/// VirtIO-SCSI command response (device-writable)
/// Per VirtIO spec Section 5.6.6.1
pub const ScsiResponseCmd = extern struct {
    /// Number of bytes written to sense buffer
    sense_len: u32 align(1),

    /// Residual bytes (number of bytes NOT transferred)
    /// For reads: expected - actual received
    /// For writes: expected - actual sent
    residual: u32 align(1),

    /// SCSI status qualifier (vendor-specific)
    status_qualifier: u16 align(1),

    /// SCSI status byte (CHECK_CONDITION, GOOD, etc.)
    status: u8 align(1),

    /// VirtIO response code
    response: u8 align(1),

    /// Sense data buffer (variable size, typically 96 bytes)
    sense: [config.Limits.SENSE_SIZE]u8 align(1),

    /// Check if command completed successfully
    pub fn isSuccess(self: *const ScsiResponseCmd) bool {
        return self.response == @intFromEnum(Response.OK) and
            self.status == @intFromEnum(ScsiStatus.GOOD);
    }

    /// Get the actual size based on sense_size configuration
    pub fn sizeForSenseSize(sense_size: u32) usize {
        // sense_len(4) + residual(4) + status_qualifier(2) + status(1) + response(1) + sense
        return 4 + 4 + 2 + 1 + 1 + sense_size;
    }
};

// Compile-time verification
comptime {
    // sense_len(4) + residual(4) + status_qualifier(2) + status(1) + response(1) + sense(96) = 108 bytes
    if (@sizeOf(ScsiResponseCmd) != 108) {
        @compileError("ScsiResponseCmd size mismatch");
    }
}

// ============================================================================
// VirtIO Response Codes
// ============================================================================

/// VirtIO-SCSI response codes (Section 5.6.6.1)
pub const Response = enum(u8) {
    /// Command completed successfully
    OK = 0,
    /// Data overrun (more data than buffer could hold)
    OVERRUN = 1,
    /// Command was aborted
    ABORTED = 2,
    /// Invalid target
    BAD_TARGET = 3,
    /// Target/LUN reset occurred
    RESET = 4,
    /// Target is busy
    BUSY = 5,
    /// Transport failure
    TRANSPORT_FAILURE = 6,
    /// Target failure
    TARGET_FAILURE = 7,
    /// Nexus failure
    NEXUS_FAILURE = 8,
    /// Generic failure
    FAILURE = 9,
    _,
};

// ============================================================================
// SCSI Status Codes
// ============================================================================

/// SCSI status byte values (SAM-5)
pub const ScsiStatus = enum(u8) {
    /// Command completed successfully
    GOOD = 0x00,
    /// Sense data available via REQUEST SENSE
    CHECK_CONDITION = 0x02,
    /// Condition met
    CONDITION_MET = 0x04,
    /// Target is busy
    BUSY = 0x08,
    /// Reservation conflict
    RESERVATION_CONFLICT = 0x18,
    /// Task set full (queue full)
    TASK_SET_FULL = 0x28,
    /// ACA active
    ACA_ACTIVE = 0x30,
    /// Task aborted
    TASK_ABORTED = 0x40,
    _,
};

// ============================================================================
// Task Attributes
// ============================================================================

/// SAM-5 task attribute values
pub const TaskAttr = enum(u8) {
    /// Simple task (default, unordered)
    SIMPLE = 0,
    /// Ordered task (strict ordering)
    ORDERED = 1,
    /// Head of queue (immediate execution)
    HEAD_OF_QUEUE = 2,
    /// Auto contingent allegiance
    ACA = 3,
};

// ============================================================================
// Control Queue Requests (Task Management)
// ============================================================================

/// Task Management Function request (Section 5.6.6.2)
pub const ScsiTmfRequest = extern struct {
    /// TMF subtype
    type: TmfType align(1),
    /// TMF subtype-specific value
    subtype: u32 align(1),
    /// LUN address
    lun: [8]u8 align(1),
    /// Tag of command to abort (for ABORT_TASK)
    tag: u64 align(1),
};

/// TMF response
pub const ScsiTmfResponse = extern struct {
    /// TMF response code
    response: u8,
};

/// Task Management Function types
pub const TmfType = enum(u32) {
    ABORT_TASK = 0,
    ABORT_TASK_SET = 1,
    CLEAR_ACA = 2,
    CLEAR_TASK_SET = 3,
    I_T_NEXUS_RESET = 4,
    LOGICAL_UNIT_RESET = 5,
    QUERY_TASK = 6,
    QUERY_TASK_SET = 7,
    _,
};

// ============================================================================
// Event Queue Structures
// ============================================================================

/// Event notification (Section 5.6.6.3)
pub const ScsiEvent = extern struct {
    /// Event type
    event: EventType align(1),
    /// LUN that generated the event
    lun: [8]u8 align(1),
    /// Event reason code
    reason: u32 align(1),
};

/// Event types
pub const EventType = enum(u32) {
    /// No event (used as sentinel)
    NO_EVENT = 0,
    /// LUN transport parameters changed
    TRANSPORT_RESET = 1,
    /// Async notification (SCSI-3 AN)
    ASYNC_NOTIFY = 2,
    /// LUN configuration changed (added/removed)
    LUN_PARAM_CHANGE = 0x80000000 | 1,
    _,
};

// ============================================================================
// Pending Request Tracking
// ============================================================================

/// Per-request state for async I/O tracking
pub const PendingRequest = struct {
    /// Associated IoRequest from the kernel I/O reactor
    io_request: *io.IoRequest,

    /// DMA buffer for request header
    req_dma: dma.DmaBuffer,

    /// DMA buffer for response
    resp_dma: dma.DmaBuffer,

    /// DMA buffer for data transfer (null for no-data commands)
    data_dma: ?dma.DmaBuffer,

    /// User-provided buffer pointer (for copy-back on read completion)
    user_buffer: ?[]u8,

    /// Virtqueue descriptor head index
    desc_head: u16,

    /// Queue index this request is on
    queue_idx: u8,

    /// Target/LUN for this request
    target: u16,
    lun: u32,

    /// Expected transfer size in bytes
    expected_bytes: u32,

    /// Whether this is a read operation
    is_read: bool,

    /// Request tag (for correlation)
    tag: u64,
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Encode a LUN in VirtIO SCSI format
/// VirtIO uses a simplified single-level LUN addressing
pub fn encodeLun(target: u16, lun: u32) [8]u8 {
    var buf: [8]u8 = [_]u8{0} ** 8;

    // VirtIO SCSI LUN format (simplified single-level):
    // Byte 0: 1 (indicates single-level LUN addressing)
    // Byte 1: Target ID (low 8 bits)
    // Byte 2: LUN high byte with address method (0x40 = peripheral device addressing)
    // Byte 3: LUN low byte
    // Bytes 4-7: Reserved (zero)
    buf[0] = 1;
    buf[1] = @truncate(target);
    buf[2] = @as(u8, @truncate(lun >> 8)) | 0x40; // Peripheral device addressing method
    buf[3] = @truncate(lun);

    return buf;
}

/// Decode a LUN from VirtIO SCSI format
pub fn decodeLun(lun_bytes: [8]u8) struct { target: u16, lun: u32 } {
    const target: u16 = lun_bytes[1];
    const lun: u32 = (@as(u32, lun_bytes[2] & 0x3F) << 8) | lun_bytes[3];
    return .{ .target = target, .lun = lun };
}

/// Generate a unique request tag
var tag_counter: u64 = 0;
pub fn generateTag() u64 {
    return @atomicRmw(u64, &tag_counter, .Add, 1, .monotonic);
}
