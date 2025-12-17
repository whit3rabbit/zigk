// Kernel Async I/O Module
//
// Provides async I/O primitives for the kernel, inspired by Zig 0.16's std.Io
// patterns but adapted for freestanding kernel use.
//
// Main components:
//   - IoRequest: Single async operation with state machine
//   - Future: Handle for polling/waiting on operations
//   - IoRequestPool: Fixed-size pool of requests
//   - Reactor: Central coordinator and timer management
//
// Usage:
//   const io = @import("io");
//
//   // Allocate and submit an operation
//   const req = io.allocRequest(.socket_read) orelse return error.ENOMEM;
//   defer io.freeRequest(req);
//
//   // Configure the request
//   req.fd = socket_fd;
//   req.buf_ptr = buf_ptr;
//   req.buf_len = buf_len;
//
//   // Submit and get future
//   var future = io.submit(req);
//
//   // Wait for completion (blocking)
//   const result = future.wait();
//
//   // Or poll (non-blocking)
//   while (!future.isDone()) {
//       // do other work
//   }
//   const result = future.poll();

pub const types = @import("types.zig");
pub const pool = @import("pool.zig");
pub const reactor = @import("reactor.zig");
pub const timer = @import("timer.zig");
pub const kernel_io = @import("kernel_io.zig");

// Re-export commonly used types
pub const IoRequest = types.IoRequest;
pub const IoResult = types.IoResult;
pub const IoOpType = types.IoOpType;
pub const IoRequestState = types.IoRequestState;
pub const Future = types.Future;

// Re-export KernelIo types
pub const KernelIo = kernel_io.KernelIo;
pub const KernelIoError = kernel_io.KernelIoError;
pub const AsyncHandle = kernel_io.AsyncHandle;

pub const IoRequestPool = pool.IoRequestPool;
pub const MAX_REQUESTS = pool.MAX_REQUESTS;
pub const PoolStats = pool.PoolStats;

pub const Reactor = reactor.Reactor;
pub const ReactorStats = reactor.ReactorStats;

// Re-export global API
pub const initGlobal = reactor.initGlobal;
pub const getGlobal = reactor.getGlobal;
pub const allocRequest = reactor.allocRequest;
pub const freeRequest = reactor.freeRequest;
pub const submit = reactor.submit;
pub const timerTick = reactor.timerTick;

// Timer wheel re-exports
pub const TimerWheel = timer.TimerWheel;
pub const TimerStats = timer.TimerStats;
pub const nsToTicks = timer.nsToTicks;
pub const msToTicks = timer.msToTicks;
pub const secToTicks = timer.secToTicks;
pub const completeExpiredTimers = timer.completeExpiredTimers;
pub const MAX_TIMEOUT = timer.MAX_TIMEOUT;
pub const TICK_NS = timer.TICK_NS;
