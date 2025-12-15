// Kernel Async I/O Types
//
// Core types for the async I/O subsystem. Provides Future-based async
// operations inspired by Zig 0.16's std.Io patterns, adapted for
// freestanding kernel use.
//
// Design:
//   - IoRequest: Single async operation with state machine
//   - Future: Handle returned to caller for polling/waiting
//   - IoResult: Tagged union for operation outcomes
//   - Pool-allocated requests (no dynamic allocation per-op)
//
// Integration:
//   - Uses existing sched.block()/unblock() for blocking compat
//   - IRQ handlers complete requests via completeRequest()
//   - io_uring syscalls translate SQEs to IoRequests

const std = @import("std");
const builtin = @import("builtin");

// Conditional imports for freestanding vs test builds
const is_freestanding = builtin.os.tag == .freestanding;
const sched = if (is_freestanding) @import("sched") else null;
const Thread = if (is_freestanding) @import("thread").Thread else void;
const uapi = if (is_freestanding) @import("uapi") else struct {
    pub const errno = struct {
        pub const SyscallError = error{
            EPERM,
            ENOENT,
            EINTR,
            EIO,
            EBADF,
            EAGAIN,
            ENOMEM,
            EFAULT,
            EBUSY,
            EINVAL,
            ENOSYS,
            ETIMEDOUT,
            ECANCELED,
        };
    };
};

/// Operation types for async I/O
pub const IoOpType = enum(u8) {
    /// No operation (used for testing/placeholder)
    noop = 0,

    /// Socket accept - wait for incoming connection
    socket_accept = 1,

    /// Socket connect - wait for connection establishment
    socket_connect = 2,

    /// Socket read - wait for incoming data
    socket_read = 3,

    /// Socket write - wait for send buffer space
    socket_write = 4,

    /// Pipe read - wait for data from writer
    pipe_read = 5,

    /// Pipe write - wait for buffer space from reader
    pipe_write = 6,

    /// Keyboard read - wait for keypress
    keyboard_read = 7,

    /// Timer - wait for timeout expiration
    timer = 8,

    /// Poll - wait for any of multiple fds
    poll = 9,
};

/// Result of an I/O operation
pub const IoResult = union(enum) {
    /// Operation completed successfully with return value
    /// For read/write: bytes transferred
    /// For accept: new file descriptor
    /// For connect: 0 on success
    success: usize,

    /// Operation failed with syscall error
    err: uapi.errno.SyscallError,

    /// Operation was cancelled before completion
    cancelled: void,

    /// Operation still in progress (not yet complete)
    pending: void,

    /// Check if result indicates completion (success, error, or cancelled)
    pub fn isComplete(self: IoResult) bool {
        return switch (self) {
            .success, .err, .cancelled => true,
            .pending => false,
        };
    }

    /// Convert to syscall return value (positive on success, negative errno on error)
    pub fn toSyscallReturn(self: IoResult) isize {
        return switch (self) {
            .success => |n| @intCast(n),
            .err => |e| errorToReturn(e),
            .cancelled => errorToReturn(error.ECANCELED),
            .pending => errorToReturn(error.EAGAIN),
        };
    }

    fn errorToReturn(err: uapi.errno.SyscallError) isize {
        // Map error to negative errno value
        const errno_val: i32 = switch (err) {
            error.EPERM => 1,
            error.ENOENT => 2,
            error.EINTR => 4,
            error.EIO => 5,
            error.EBADF => 9,
            error.EAGAIN => 11,
            error.ENOMEM => 12,
            error.EFAULT => 14,
            error.EBUSY => 16,
            error.EINVAL => 22,
            error.ENOSYS => 38,
            error.ETIMEDOUT => 110,
            error.ECANCELED => 125,
        };
        return -@as(isize, errno_val);
    }
};

/// Request state machine
pub const IoRequestState = enum(u8) {
    /// Request is allocated but not yet submitted
    idle = 0,

    /// Request is queued, waiting for resource availability
    pending = 1,

    /// Request is actively being processed
    in_progress = 2,

    /// Request completed (check result field)
    completed = 3,

    /// Request was cancelled
    cancelled = 4,
};

/// Single async I/O operation request
///
/// Allocated from a fixed-size pool. Lifetime is managed by the caller
/// who must call pool.free() after consuming the result.
///
/// Thread safety:
///   - State transitions are atomic
///   - Only one thread should modify non-atomic fields at a time
///   - IRQ handlers only transition state and set result
pub const IoRequest = struct {
    /// Unique identifier for this request (monotonically increasing)
    id: u64,

    /// Operation type
    op: IoOpType,

    /// File descriptor (socket, pipe, fd index)
    fd: i32,

    /// User buffer pointer (validated before use)
    buf_ptr: usize,

    /// User buffer length
    buf_len: usize,

    /// Operation-specific data
    op_data: OpData,

    /// Thread that submitted this request (for wakeup on completion)
    /// Null if no thread is waiting (pure async / io_uring)
    submitter: ?*Thread,

    /// Intrusive linked list pointer for pending queues
    next: ?*IoRequest,

    /// io_uring user_data field (returned in CQE)
    user_data: u64,

    /// Completion result (valid when state == .completed or .cancelled)
    result: IoResult,

    /// Current state (use atomic operations for thread safety)
    state: std.atomic.Value(IoRequestState),

    /// Operation-specific data union
    pub const OpData = extern union {
        /// For accept: where to store peer address
        accept: extern struct {
            addr_ptr: usize,
            addrlen_ptr: usize,
        },

        /// For connect: target address
        connect: extern struct {
            addr_ptr: usize,
            addrlen: u32,
            _pad: u32 = 0,
        },

        /// For timer: expiration time in nanoseconds
        timer: extern struct {
            timeout_ns: u64,
        },

        /// For poll: events to wait for
        poll: extern struct {
            events: u32,
            _pad: u32 = 0,
        },

        /// Raw bytes for custom data
        raw: [16]u8,
    };

    /// Initialize a request with default values
    pub fn init(id: u64, op: IoOpType) IoRequest {
        return .{
            .id = id,
            .op = op,
            .fd = -1,
            .buf_ptr = 0,
            .buf_len = 0,
            .op_data = .{ .raw = [_]u8{0} ** 16 },
            .submitter = null,
            .next = null,
            .user_data = 0,
            .result = .pending,
            .state = std.atomic.Value(IoRequestState).init(.idle),
        };
    }

    /// Atomically transition state if in expected state
    /// Returns true if transition succeeded
    pub fn compareAndSwapState(
        self: *IoRequest,
        expected: IoRequestState,
        new_state: IoRequestState,
    ) bool {
        return self.state.cmpxchgStrong(expected, new_state, .acq_rel, .acquire) == null;
    }

    /// Get current state with acquire ordering
    pub fn getState(self: *const IoRequest) IoRequestState {
        return self.state.load(.acquire);
    }

    /// Complete this request with a result
    /// Safe to call from IRQ context
    /// Returns true if completion was accepted (state was pending/in_progress)
    pub fn complete(self: *IoRequest, result: IoResult) bool {
        // Try to transition from pending or in_progress to completed
        const current = self.state.load(.acquire);

        if (current == .pending or current == .in_progress) {
            self.result = result;

            // Use release store to ensure result is visible before state change
            self.state.store(.completed, .release);

            // Wake submitter thread if one is waiting
            if (is_freestanding) {
                if (self.submitter) |thread| {
                    sched.unblock(thread);
                }
            }

            return true;
        }

        return false;
    }

    /// Attempt to cancel this request
    /// Returns true if cancellation succeeded (state was pending)
    pub fn cancel(self: *IoRequest) bool {
        // Can only cancel pending requests (not in_progress)
        if (self.compareAndSwapState(.pending, .cancelled)) {
            self.result = .cancelled;

            // Wake submitter so they see the cancellation
            if (is_freestanding) {
                if (self.submitter) |thread| {
                    sched.unblock(thread);
                }
            }

            return true;
        }

        return false;
    }
};

/// Future handle for async operations
///
/// Returned by async submit functions. Caller uses this to:
///   - poll() for non-blocking completion check
///   - wait() for blocking wait (uses sched.block())
///   - cancel() to attempt cancellation
///
/// The Future does not own the IoRequest - caller must free it
/// after the operation completes.
pub const Future = struct {
    request: *IoRequest,

    /// Non-blocking poll for completion
    /// Returns the result if complete, .pending otherwise
    pub fn poll(self: *const Future) IoResult {
        const state = self.request.getState();
        if (state == .completed or state == .cancelled) {
            return self.request.result;
        }
        return .pending;
    }

    /// Check if the operation has completed
    pub fn isDone(self: *const Future) bool {
        const state = self.request.getState();
        return state == .completed or state == .cancelled;
    }

    /// Blocking wait for completion
    /// Uses sched.block() internally - only call from process context
    /// Returns the final result
    pub fn wait(self: *const Future) IoResult {
        if (is_freestanding) {
            // Set ourselves as the submitter for wakeup
            self.request.submitter = sched.getCurrentThread();

            // Spin-wait with blocking
            while (!self.isDone()) {
                sched.block();
            }
        }

        return self.request.result;
    }

    /// Attempt to cancel the pending operation
    /// Returns true if cancellation succeeded
    pub fn cancelOp(self: *Future) bool {
        return self.request.cancel();
    }

    /// Get the underlying request (for advanced use)
    pub fn getRequest(self: *const Future) *IoRequest {
        return self.request;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "IoRequest init and state transitions" {
    var req = IoRequest.init(42, .socket_read);

    try std.testing.expectEqual(@as(u64, 42), req.id);
    try std.testing.expectEqual(IoOpType.socket_read, req.op);
    try std.testing.expectEqual(IoRequestState.idle, req.getState());

    // Transition to pending
    try std.testing.expect(req.compareAndSwapState(.idle, .pending));
    try std.testing.expectEqual(IoRequestState.pending, req.getState());

    // Complete the request
    try std.testing.expect(req.complete(.{ .success = 100 }));
    try std.testing.expectEqual(IoRequestState.completed, req.getState());
    try std.testing.expectEqual(IoResult{ .success = 100 }, req.result);
}

test "IoRequest cancellation" {
    var req = IoRequest.init(1, .timer);

    // Transition to pending
    _ = req.compareAndSwapState(.idle, .pending);

    // Cancel should succeed
    try std.testing.expect(req.cancel());
    try std.testing.expectEqual(IoRequestState.cancelled, req.getState());
    try std.testing.expectEqual(IoResult.cancelled, req.result);
}

test "IoResult toSyscallReturn" {
    const success: IoResult = .{ .success = 42 };
    try std.testing.expectEqual(@as(isize, 42), success.toSyscallReturn());

    const err_result: IoResult = .{ .err = error.EBADF };
    try std.testing.expectEqual(@as(isize, -9), err_result.toSyscallReturn());

    const cancelled: IoResult = .cancelled;
    try std.testing.expectEqual(@as(isize, -125), cancelled.toSyscallReturn());
}

test "Future poll" {
    var req = IoRequest.init(1, .noop);
    var future = Future{ .request = &req };

    // Initially pending
    try std.testing.expectEqual(IoResult.pending, future.poll());
    try std.testing.expect(!future.isDone());

    // Complete it
    _ = req.compareAndSwapState(.idle, .pending);
    _ = req.complete(.{ .success = 0 });

    // Now complete
    try std.testing.expect(future.isDone());
    try std.testing.expectEqual(IoResult{ .success = 0 }, future.poll());
}
