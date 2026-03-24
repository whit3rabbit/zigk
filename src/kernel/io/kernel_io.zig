// KernelIo - std.Io Compatible Interface for Kernel Async Operations
//
// Provides a Zig 0.16 std.Io-inspired interface for kernel-space async I/O.
// Maps high-level async primitives to kernel scheduler and reactor mechanisms.
//
// Design:
//   - sleep() -> Reactor timer + sched.block()
//   - async_() -> Reactor.submit() returning AsyncHandle
//   - await_() -> Future.wait() with proper blocking
//   - concurrent() -> error.ConcurrencyUnavailable (no kernel parallelism)
//
// Usage:
//   var kernel_io = KernelIo.init(reactor.getGlobal());
//
//   // Sleep for 100ms
//   try kernel_io.sleep(100_000_000);
//
//   // Async operation
//   var handle = try kernel_io.async_(doWork, .{args});
//   defer handle.cancel() catch {};
//   const result = try handle.await_();

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const reactor_mod = @import("reactor.zig");
const timer_mod = @import("timer.zig");

const IoRequest = types.IoRequest;
const IoResult = types.IoResult;
const IoOpType = types.IoOpType;
const IoRequestState = types.IoRequestState;
const Future = types.Future;
const Reactor = reactor_mod.Reactor;

// Conditional imports for freestanding
const is_freestanding = builtin.os.tag == .freestanding;
const sched = if (is_freestanding) @import("sched") else null;
const Thread = if (is_freestanding) @import("thread").Thread else void;

/// Errors specific to KernelIo operations
pub const KernelIoError = error{
    /// No pool slots available
    OutOfMemory,
    /// Reactor not initialized
    NotInitialized,
    /// Concurrent execution not supported in kernel
    ConcurrencyUnavailable,
    /// Operation was cancelled
    Cancelled,
    /// Operation timed out
    Timeout,
    /// Generic I/O error
    IoError,
};

/// KernelIo - std.Io-compatible interface for kernel async operations
///
/// This struct provides high-level async primitives that map to the kernel's
/// Reactor and scheduler mechanisms. It is designed to be compatible with
/// Zig 0.16's std.Io patterns while working in freestanding kernel context.
pub const KernelIo = struct {
    reactor: *Reactor,

    /// Initialize KernelIo with a reactor instance
    pub fn init(reactor: *Reactor) KernelIo {
        return .{ .reactor = reactor };
    }

    /// Initialize KernelIo with the global reactor
    pub fn initGlobal() KernelIo {
        return .{ .reactor = reactor_mod.getGlobal() };
    }

    /// Sleep for the specified duration in nanoseconds
    ///
    /// This is a blocking sleep that yields to the scheduler while waiting.
    /// Uses the Reactor's timer queue internally.
    pub fn sleep(self: *KernelIo, duration_ns: u64) KernelIoError!void {
        if (duration_ns == 0) return;

        // Allocate a timer request
        const req = self.reactor.allocRequest(.timer) orelse return error.OutOfMemory;
        errdefer self.reactor.freeRequest(req);

        // Set up timer operation
        req.op_data = .{ .timer = .{ .timeout_ns = duration_ns } };

        // Transition to pending state
        _ = req.compareAndSwapState(.idle, .pending);

        // Calculate ticks and add to timer queue
        const ticks = timer_mod.nsToTicks(duration_ns);
        self.reactor.addTimer(req, ticks);

        // Wait for completion
        var future = Future{ .request = req };
        const result = future.wait();

        // Free the request
        self.reactor.freeRequest(req);

        // Check result
        switch (result) {
            .success => return,
            .cancelled => return error.Cancelled,
            .err => return error.IoError,
            .pending => unreachable, // wait() should not return pending
        }
    }

    /// Sleep for the specified duration in milliseconds (convenience)
    pub fn sleepMs(self: *KernelIo, ms: u64) KernelIoError!void {
        return self.sleep(ms * 1_000_000);
    }

    /// Sleep for the specified duration in seconds (convenience)
    pub fn sleepSec(self: *KernelIo, sec: u64) KernelIoError!void {
        return self.sleep(sec * 1_000_000_000);
    }

    /// Submit an async I/O operation and get a handle for later await
    ///
    /// The returned AsyncHandle can be used to:
    ///   - await_() - block until completion
    ///   - poll() - non-blocking check
    ///   - cancel() - attempt cancellation
    ///
    /// Caller is responsible for calling cancel() or await_() to ensure
    /// the underlying IoRequest is properly freed.
    pub fn submitAsync(self: *KernelIo, op: IoOpType) KernelIoError!AsyncHandle {
        const req = self.reactor.allocRequest(op) orelse return error.OutOfMemory;

        // Transition to pending
        _ = req.compareAndSwapState(.idle, .pending);

        // Submit to reactor
        const future = self.reactor.submit(req);

        return AsyncHandle{
            .request = future.request,
            .reactor = self.reactor,
            .owned = true,
        };
    }

    /// Request concurrent execution (not supported in kernel)
    ///
    /// Kernel code runs in a single address space without true parallelism
    /// for async operations. Use submitAsync() instead.
    pub fn concurrent(self: *KernelIo, comptime func: anytype, args: anytype) KernelIoError!void {
        _ = self;
        _ = func;
        _ = args;
        return error.ConcurrencyUnavailable;
    }

    /// Get the underlying reactor
    pub fn getReactor(self: *const KernelIo) *Reactor {
        return self.reactor;
    }

    /// Allocate a raw IoRequest for manual operation setup
    pub fn allocRequest(self: *KernelIo, op: IoOpType) ?*IoRequest {
        return self.reactor.allocRequest(op);
    }

    /// Free a raw IoRequest
    pub fn freeRequest(self: *KernelIo, req: *IoRequest) void {
        self.reactor.freeRequest(req);
    }

    /// Submit a pre-configured IoRequest
    pub fn submit(self: *KernelIo, req: *IoRequest) Future {
        _ = req.compareAndSwapState(.idle, .pending);
        return self.reactor.submit(req);
    }
};

/// Handle for an async operation
///
/// Similar to std.Io's Future but adapted for kernel use.
/// Provides await, poll, and cancel operations.
pub const AsyncHandle = struct {
    request: *IoRequest,
    reactor: *Reactor,
    owned: bool,

    /// Block until the operation completes
    ///
    /// Returns the result and frees the underlying request.
    /// After await_(), this handle is invalid.
    pub fn await_(self: *AsyncHandle) KernelIoError!usize {
        if (!self.owned) return error.IoError;

        var future = Future{ .request = self.request };
        const result = future.wait();

        // Free request and mark as not owned
        self.reactor.freeRequest(self.request);
        self.owned = false;

        return switch (result) {
            .success => |n| n,
            .cancelled => error.Cancelled,
            .err => error.IoError,
            .pending => unreachable,
        };
    }

    /// Non-blocking poll for completion
    pub fn poll(self: *const AsyncHandle) ?IoResult {
        const future = Future{ .request = self.request };
        const result = future.poll();
        if (result == .pending) return null;
        return result;
    }

    /// Check if operation has completed
    pub fn isDone(self: *const AsyncHandle) bool {
        const future = Future{ .request = self.request };
        return future.isDone();
    }

    /// Attempt to cancel the operation
    ///
    /// Returns true if cancellation succeeded.
    /// After cancel(), call await_() to clean up the request.
    pub fn cancel(self: *AsyncHandle) KernelIoError!void {
        if (!self.owned) return;

        _ = self.request.cancel();

        // Free request
        self.reactor.freeRequest(self.request);
        self.owned = false;
    }

    /// Get the underlying IoRequest (for advanced use)
    pub fn getRequest(self: *const AsyncHandle) *IoRequest {
        return self.request;
    }
};

// =============================================================================
// Convenience Functions (Global API)
// =============================================================================

var global_kernel_io: ?KernelIo = null;

/// Initialize the global KernelIo instance
pub fn initGlobal() void {
    global_kernel_io = KernelIo.initGlobal();
}

/// Get the global KernelIo instance
pub fn getGlobal() *KernelIo {
    if (global_kernel_io == null) {
        initGlobal();
    }
    return &global_kernel_io.?;
}

/// Sleep using the global KernelIo
pub fn sleep(duration_ns: u64) KernelIoError!void {
    return getGlobal().sleep(duration_ns);
}

/// Submit an async operation using the global KernelIo
pub fn submitAsync(op: IoOpType) KernelIoError!AsyncHandle {
    return getGlobal().submitAsync(op);
}

// =============================================================================
// Tests
// =============================================================================

test "KernelIo basic init" {
    var reactor: Reactor = undefined;
    reactor.init();

    const kio = KernelIo.init(&reactor);
    try std.testing.expect(kio.reactor == &reactor);
}

test "KernelIo submitAsync and poll" {
    var reactor: Reactor = undefined;
    reactor.init();

    var kio = KernelIo.init(&reactor);

    // Submit async operation
    var handle = try kio.submitAsync(.noop);

    // Should not be done initially
    try std.testing.expect(!handle.isDone());

    // Complete it manually (simulating IRQ completion)
    _ = handle.request.complete(.{ .success = 42 });

    // Now should be done
    try std.testing.expect(handle.isDone());

    const result = handle.poll();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(IoResult{ .success = 42 }, result.?);

    // Clean up
    handle.reactor.freeRequest(handle.request);
    handle.owned = false;
}

test "AsyncHandle cancel" {
    var reactor: Reactor = undefined;
    reactor.init();

    var kio = KernelIo.init(&reactor);

    var handle = try kio.submitAsync(.timer);

    // Cancel should succeed on pending request
    try handle.cancel();

    // Handle is no longer owned
    try std.testing.expect(!handle.owned);
}
