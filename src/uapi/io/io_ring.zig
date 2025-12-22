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
pub const IORING_OP_FADVISE: u8 = 24;
pub const IORING_OP_MADVISE: u8 = 25;
pub const IORING_OP_SEND: u8 = 26;
pub const IORING_OP_RECV: u8 = 27;
pub const IORING_OP_OPENAT2: u8 = 28;
pub const IORING_OP_EPOLL_CTL: u8 = 29;
pub const IORING_OP_SPLICE: u8 = 30;
pub const IORING_OP_PROVIDE_BUFFERS: u8 = 31;
pub const IORING_OP_REMOVE_BUFFERS: u8 = 32;
pub const IORING_OP_TEE: u8 = 33;
pub const IORING_OP_SHUTDOWN: u8 = 34;
pub const IORING_OP_RENAMEAT: u8 = 35;
pub const IORING_OP_UNLINKAT: u8 = 36;
pub const IORING_OP_MKDIRAT: u8 = 37;
pub const IORING_OP_SYMLINKAT: u8 = 38;
pub const IORING_OP_LINKAT: u8 = 39;
pub const IORING_OP_MSG_RING: u8 = 40;
pub const IORING_OP_FSETXATTR: u8 = 41;
pub const IORING_OP_SETXATTR: u8 = 42;
pub const IORING_OP_FGETXATTR: u8 = 43;
pub const IORING_OP_GETXATTR: u8 = 44;
pub const IORING_OP_SOCKET: u8 = 45;
pub const IORING_OP_URING_CMD: u8 = 46;
pub const IORING_OP_SEND_ZC: u8 = 47;
pub const IORING_OP_SENDMSG_ZC: u8 = 48;
pub const IORING_OP_READ_MULTISHOT: u8 = 49;
pub const IORING_OP_WAITID: u8 = 50;
pub const IORING_OP_FUTEX_WAIT: u8 = 51;
pub const IORING_OP_FUTEX_WAKE: u8 = 52;
pub const IORING_OP_FUTEX_WAITV: u8 = 53;
pub const IORING_OP_FIXED_FD_INSTALL: u8 = 54;
pub const IORING_OP_FTRUNCATE: u8 = 55;
pub const IORING_OP_BIND: u8 = 56;
pub const IORING_OP_LISTEN: u8 = 57;
pub const IORING_OP_RECV_ZC: u8 = 58;
pub const IORING_OP_EPOLL_WAIT: u8 = 59;
pub const IORING_OP_CLONE: u8 = 60;
pub const IORING_OP_PIPE: u8 = 61;

/// Maximum opcode value (for bounds checking)
pub const IORING_OP_LAST: u8 = 62;

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
/// Support for RW at current file position
pub const IORING_FEAT_RW_CUR_POS: u32 = 1 << 3;
/// Support for personality
pub const IORING_FEAT_CUR_PERSONALITY: u32 = 1 << 4;
/// Support for fast poll
pub const IORING_FEAT_FAST_POLL: u32 = 1 << 5;
/// Support for 32-bit poll events
pub const IORING_FEAT_POLL_32BITS: u32 = 1 << 6;
/// Support for SQPOLL with non-fixed files
pub const IORING_FEAT_SQPOLL_NONFIXED: u32 = 1 << 7;
/// Support for extended arguments
pub const IORING_FEAT_EXT_ARG: u32 = 1 << 8;
/// Support for native workers
pub const IORING_FEAT_NATIVE_WORKERS: u32 = 1 << 9;
/// Support for resource tags
pub const IORING_FEAT_RSRC_TAGS: u32 = 1 << 10;
/// Support for CQE skip
pub const IORING_FEAT_CQE_SKIP: u32 = 1 << 11;
/// Support for linked files
pub const IORING_FEAT_LINKED_FILE: u32 = 1 << 12;
/// Support for registered ring fds
pub const IORING_FEAT_REG_REG_RING: u32 = 1 << 13;

// =============================================================================
// Registration Opcodes
// =============================================================================

/// Register fixed buffers
pub const IORING_REGISTER_BUFFERS: u32 = 0;
/// Unregister fixed buffers
pub const IORING_UNREGISTER_BUFFERS: u32 = 1;
/// Register fixed files
pub const IORING_REGISTER_FILES: u32 = 2;
/// Unregister fixed files
pub const IORING_UNREGISTER_FILES: u32 = 3;
/// Register eventfd
pub const IORING_REGISTER_EVENTFD: u32 = 4;
/// Unregister eventfd
pub const IORING_UNREGISTER_EVENTFD: u32 = 5;
/// Update registered files
pub const IORING_REGISTER_FILES_UPDATE: u32 = 6;
/// Register async eventfd
pub const IORING_REGISTER_EVENTFD_ASYNC: u32 = 7;
/// Probe capabilities
pub const IORING_REGISTER_PROBE: u32 = 8;
/// Register personality
pub const IORING_REGISTER_PERSONALITY: u32 = 9;
/// Unregister personality
pub const IORING_UNREGISTER_PERSONALITY: u32 = 10;
/// Register restrictions
pub const IORING_REGISTER_RESTRICTIONS: u32 = 11;
/// Enable rings
pub const IORING_REGISTER_ENABLE_RINGS: u32 = 12;
/// Register files (v2)
pub const IORING_REGISTER_FILES2: u32 = 13;
/// Update files (v2)
pub const IORING_REGISTER_FILES_UPDATE2: u32 = 14;
/// Register buffers (v2)
pub const IORING_REGISTER_BUFFERS2: u32 = 15;
/// Update buffers
pub const IORING_REGISTER_BUFFERS_UPDATE: u32 = 16;
/// Register IO worker affinity
pub const IORING_REGISTER_IOWQ_AFF: u32 = 17;
/// Unregister IO worker affinity
pub const IORING_UNREGISTER_IOWQ_AFF: u32 = 18;
/// Set max IO workers
pub const IORING_REGISTER_IOWQ_MAX_WORKERS: u32 = 19;
/// Register ring file descriptors
pub const IORING_REGISTER_RING_FDS: u32 = 20;
/// Unregister ring file descriptors
pub const IORING_UNREGISTER_RING_FDS: u32 = 21;
/// Register provided buffer ring
pub const IORING_REGISTER_PBUF_RING: u32 = 22;
/// Unregister provided buffer ring
pub const IORING_UNREGISTER_PBUF_RING: u32 = 23;
/// Synchronous cancel
pub const IORING_REGISTER_SYNC_CANCEL: u32 = 24;
/// Register file allocation range
pub const IORING_REGISTER_FILE_ALLOC_RANGE: u32 = 25;
/// Get provided buffer status
pub const IORING_REGISTER_PBUF_STATUS: u32 = 26;
/// Register NAPI
pub const IORING_REGISTER_NAPI: u32 = 27;
/// Unregister NAPI
pub const IORING_UNREGISTER_NAPI: u32 = 28;

/// Maximum registration opcode
pub const IORING_REGISTER_LAST: u32 = 29;

// =============================================================================
// mmap Offsets
// =============================================================================

/// Offset for mmap() to map the SQ ring
pub const IORING_OFF_SQ_RING: u64 = 0;
/// Offset for mmap() to map the CQ ring
pub const IORING_OFF_CQ_RING: u64 = 0x8000000;
/// Offset for mmap() to map the SQE array
pub const IORING_OFF_SQES: u64 = 0x10000000;

// =============================================================================
// Probe Structures
// =============================================================================

/// io_uring_probe_op - Per-opcode probe result
pub const IoUringProbeOp = extern struct {
    /// Operation code
    op: u8,
    /// Reserved
    resv: u8,
    /// IORING_PROBE_OP_* flags
    flags: u16,
    /// Reserved
    resv2: u32,

    comptime {
        if (@sizeOf(IoUringProbeOp) != 8) {
            @compileError("IoUringProbeOp must be 8 bytes");
        }
    }
};

/// io_uring_probe - Probe capabilities
pub const IoUringProbe = extern struct {
    /// Last supported opcode
    last_op: u8,
    /// Number of ops following
    ops_len: u8,
    /// Reserved
    resv: u16,
    /// Reserved
    resv2: [3]u32,
    // Followed by ops_len IoUringProbeOp entries

    comptime {
        if (@sizeOf(IoUringProbe) != 16) {
            @compileError("IoUringProbe must be 16 bytes");
        }
    }
};

/// Opcode is supported
pub const IO_URING_OP_SUPPORTED: u16 = 1 << 0;

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
