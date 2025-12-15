// io_uring User API Structures
//
// Linux-compatible io_uring structures for async I/O syscalls.
// These structures are shared between kernel and userspace.
//
// Reference: Linux kernel include/uapi/linux/io_uring.h
//
// ABI Compatibility:
//   - All structures use extern for C-compatible layout
//   - Sizes verified with comptime assertions
//   - Matches Linux x86_64 ABI

const std = @import("std");

// =============================================================================
// Submission Queue Entry (SQE) - 64 bytes
// =============================================================================

/// io_uring Submission Queue Entry
/// Describes a single I/O operation to be submitted
pub const IoUringSqe = extern struct {
    /// Operation code (IORING_OP_*)
    opcode: u8,

    /// IOSQE_* flags
    flags: u8,

    /// I/O priority
    ioprio: u16,

    /// File descriptor
    fd: i32,

    /// Offset or address2 for certain operations
    off: u64,

    /// Buffer address or pointer
    addr: u64,

    /// Buffer length
    len: u32,

    /// Operation-specific flags union
    op_flags: extern union {
        /// For read/write operations
        rw_flags: u32,
        /// For poll operations
        poll_events: u32,
        /// For accept operations
        accept_flags: u32,
        /// For send/recv operations
        msg_flags: u32,
        /// For timeout operations
        timeout_flags: u32,
        /// For sync_file_range
        sync_range_flags: u32,
        /// Generic flags
        flags: u32,
    },

    /// User data - passed through to completion
    user_data: u64,

    /// Buffer index or group for registered buffers
    buf_union: extern union {
        /// Buffer index for fixed buffers
        buf_index: u16,
        /// Buffer group for provided buffers
        buf_group: u16,
    },

    /// Personality to use for this operation
    personality: u16,

    /// For splice operations
    splice_fd_in: i32,

    /// Reserved/padding
    _pad: [2]u64,

    comptime {
        if (@sizeOf(IoUringSqe) != 64) {
            @compileError("IoUringSqe must be 64 bytes for Linux ABI compatibility");
        }
    }

    /// Create a NOP operation
    pub fn nop(user_data: u64) IoUringSqe {
        return std.mem.zeroes(IoUringSqe).with(.{
            .opcode = IORING_OP_NOP,
            .user_data = user_data,
        });
    }

    /// Create a read operation
    pub fn read(fd: i32, buf: usize, len: u32, offset: u64, user_data: u64) IoUringSqe {
        var sqe = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_READ;
        sqe.fd = fd;
        sqe.addr = buf;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = user_data;
        return sqe;
    }

    /// Create a write operation
    pub fn write(fd: i32, buf: usize, len: u32, offset: u64, user_data: u64) IoUringSqe {
        var sqe = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_WRITE;
        sqe.fd = fd;
        sqe.addr = buf;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = user_data;
        return sqe;
    }

    fn with(self: IoUringSqe, fields: anytype) IoUringSqe {
        var result = self;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
            @field(result, field.name) = @field(fields, field.name);
        }
        return result;
    }
};

// =============================================================================
// Completion Queue Entry (CQE) - 16 bytes
// =============================================================================

/// io_uring Completion Queue Entry
/// Returned when an operation completes
pub const IoUringCqe = extern struct {
    /// User data from SQE
    user_data: u64,

    /// Result (bytes transferred or negative errno)
    res: i32,

    /// IORING_CQE_F_* flags
    flags: u32,

    comptime {
        if (@sizeOf(IoUringCqe) != 16) {
            @compileError("IoUringCqe must be 16 bytes for Linux ABI compatibility");
        }
    }

    /// Check if this completion indicates success
    pub fn isSuccess(self: IoUringCqe) bool {
        return self.res >= 0;
    }

    /// Get error as positive errno value (0 if success)
    pub fn getError(self: IoUringCqe) u32 {
        if (self.res < 0) {
            return @intCast(-self.res);
        }
        return 0;
    }
};

// =============================================================================
// Ring Indices - Shared between kernel and userspace
// =============================================================================

/// Ring index structure for submission and completion queues
pub const IoRingIndices = extern struct {
    /// Consumer index
    /// For SQ: kernel reads (consumes), user writes
    /// For CQ: user reads (consumes), kernel writes
    head: u32,

    /// Producer index
    /// For SQ: user writes (produces)
    /// For CQ: kernel writes (produces)
    tail: u32,

    /// Ring mask (entries - 1, entries must be power of 2)
    ring_mask: u32,

    /// Number of entries in the ring
    ring_entries: u32,

    /// Ring flags
    flags: u32,

    /// Dropped submissions (SQ only)
    dropped: u32,

    /// Overflow completions (CQ only)
    overflow: u32,

    /// Reserved
    _resv: [2]u32,

    comptime {
        if (@sizeOf(IoRingIndices) != 36) {
            @compileError("IoRingIndices must be 36 bytes");
        }
    }
};

// =============================================================================
// io_uring_params - Setup parameters
// =============================================================================

/// Parameters for io_uring_setup syscall
pub const IoUringParams = extern struct {
    /// Submission queue size (must be power of 2)
    sq_entries: u32,

    /// Completion queue size (must be power of 2)
    cq_entries: u32,

    /// IORING_SETUP_* flags
    flags: u32,

    /// Hint for sq_thread_cpu (if SQPOLL)
    sq_thread_cpu: u32,

    /// Idle timeout for sq_thread (if SQPOLL)
    sq_thread_idle: u32,

    /// IORING_FEAT_* features supported
    features: u32,

    /// Reserved
    _resv: [4]u32,

    /// Submission queue ring offset info
    sq_off: SqRingOffsets,

    /// Completion queue ring offset info
    cq_off: CqRingOffsets,

    comptime {
        if (@sizeOf(IoUringParams) != 120) {
            @compileError("IoUringParams must be 120 bytes");
        }
    }
};

/// Offsets within the submission queue mmap region
pub const SqRingOffsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    flags: u32,
    dropped: u32,
    array: u32,
    _resv1: u32,
    _resv2: u64,

    comptime {
        if (@sizeOf(SqRingOffsets) != 40) {
            @compileError("SqRingOffsets must be 40 bytes");
        }
    }
};

/// Offsets within the completion queue mmap region
pub const CqRingOffsets = extern struct {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    cqes: u32,
    flags: u32,
    _resv1: u32,
    _resv2: u64,

    comptime {
        if (@sizeOf(CqRingOffsets) != 40) {
            @compileError("CqRingOffsets must be 40 bytes");
        }
    }
};

// =============================================================================
// Operation Codes
// =============================================================================

pub const IORING_OP_NOP: u8 = 0;
pub const IORING_OP_READV: u8 = 1;
pub const IORING_OP_WRITEV: u8 = 2;
pub const IORING_OP_FSYNC: u8 = 3;
pub const IORING_OP_READ_FIXED: u8 = 4;
pub const IORING_OP_WRITE_FIXED: u8 = 5;
pub const IORING_OP_POLL_ADD: u8 = 6;
pub const IORING_OP_POLL_REMOVE: u8 = 7;
pub const IORING_OP_SYNC_FILE_RANGE: u8 = 8;
pub const IORING_OP_SENDMSG: u8 = 9;
pub const IORING_OP_RECVMSG: u8 = 10;
pub const IORING_OP_TIMEOUT: u8 = 11;
pub const IORING_OP_TIMEOUT_REMOVE: u8 = 12;
pub const IORING_OP_ACCEPT: u8 = 13;
pub const IORING_OP_ASYNC_CANCEL: u8 = 14;
pub const IORING_OP_LINK_TIMEOUT: u8 = 15;
pub const IORING_OP_CONNECT: u8 = 16;
pub const IORING_OP_FALLOCATE: u8 = 17;
pub const IORING_OP_OPENAT: u8 = 18;
pub const IORING_OP_CLOSE: u8 = 19;
pub const IORING_OP_FILES_UPDATE: u8 = 20;
pub const IORING_OP_STATX: u8 = 21;
pub const IORING_OP_READ: u8 = 22;
pub const IORING_OP_WRITE: u8 = 23;
pub const IORING_OP_SEND: u8 = 26;
pub const IORING_OP_RECV: u8 = 27;

// =============================================================================
// SQE Flags
// =============================================================================

/// Use fixed file (registered fd table)
pub const IOSQE_FIXED_FILE: u8 = 1 << 0;
/// Issue after inflight operations complete
pub const IOSQE_IO_DRAIN: u8 = 1 << 1;
/// Link this operation to next
pub const IOSQE_IO_LINK: u8 = 1 << 2;
/// Hard link (fail linked ops on error)
pub const IOSQE_IO_HARDLINK: u8 = 1 << 3;
/// Always run in async context
pub const IOSQE_ASYNC: u8 = 1 << 4;
/// Use registered buffer
pub const IOSQE_BUFFER_SELECT: u8 = 1 << 5;

// =============================================================================
// CQE Flags
// =============================================================================

/// Buffer available for buffer selection
pub const IORING_CQE_F_BUFFER: u32 = 1 << 0;
/// More completions coming for this request
pub const IORING_CQE_F_MORE: u32 = 1 << 1;

// =============================================================================
// Setup Flags
// =============================================================================

/// Use io_uring_enter for SQ polling
pub const IORING_SETUP_IOPOLL: u32 = 1 << 0;
/// Kernel threads poll SQ
pub const IORING_SETUP_SQPOLL: u32 = 1 << 1;
/// Set sq_thread_cpu
pub const IORING_SETUP_SQ_AFF: u32 = 1 << 2;
/// App provides CQ size
pub const IORING_SETUP_CQSIZE: u32 = 1 << 3;
/// Clamp entries to max
pub const IORING_SETUP_CLAMP: u32 = 1 << 4;
/// Attach to existing wq
pub const IORING_SETUP_ATTACH_WQ: u32 = 1 << 5;

// =============================================================================
// Enter Flags
// =============================================================================

/// Wait for completions
pub const IORING_ENTER_GETEVENTS: u32 = 1 << 0;
/// Wake SQ polling thread
pub const IORING_ENTER_SQ_WAKEUP: u32 = 1 << 1;
/// Submit from SQ wait point
pub const IORING_ENTER_SQ_WAIT: u32 = 1 << 2;

// =============================================================================
// Feature Flags
// =============================================================================

/// Support for single mmap
pub const IORING_FEAT_SINGLE_MMAP: u32 = 1 << 0;
/// Never drop completions
pub const IORING_FEAT_NODROP: u32 = 1 << 1;
/// Support for IOSQE_ASYNC
pub const IORING_FEAT_SUBMIT_STABLE: u32 = 1 << 2;

// =============================================================================
// Tests
// =============================================================================

test "IoUringSqe size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(IoUringSqe));
}

test "IoUringCqe size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(IoUringCqe));
}

test "IoUringParams size" {
    try std.testing.expectEqual(@as(usize, 120), @sizeOf(IoUringParams));
}

test "SQE read helper" {
    const sqe = IoUringSqe.read(5, 0x1000, 4096, 0, 42);
    try std.testing.expectEqual(IORING_OP_READ, sqe.opcode);
    try std.testing.expectEqual(@as(i32, 5), sqe.fd);
    try std.testing.expectEqual(@as(u64, 0x1000), sqe.addr);
    try std.testing.expectEqual(@as(u32, 4096), sqe.len);
    try std.testing.expectEqual(@as(u64, 42), sqe.user_data);
}
