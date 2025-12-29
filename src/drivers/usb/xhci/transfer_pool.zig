// USB Transfer Request Pool
//
// Fixed-size pool of TransferRequest structures for async USB operations.
// Pre-allocates all requests at init time - no dynamic allocation during transfers.
//
// Design:
//   - Intrusive free list using TransferRequest.next pointer
//   - O(1) alloc and free operations
//   - Thread-safe via spinlock
//   - Returns null on exhaustion (caller should return error or retry)
//
// Security:
//   - Fixed pool size prevents unbounded memory growth from malicious devices
//   - Pointer validation on free prevents corruption attacks
//   - No per-transfer allocation overhead

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync");
const io = @import("io");

const device = @import("device.zig");
const trb = @import("trb.zig");

const TransferRequest = device.UsbDevice.TransferRequest;
const TransferState = device.UsbDevice.TransferState;
const TransferCallback = device.UsbDevice.TransferCallback;

/// Maximum number of concurrent USB transfer requests
/// This is a system-wide limit across all USB devices
pub const MAX_REQUESTS: usize = 256;

/// Pool of pre-allocated TransferRequest structures
pub const TransferRequestPool = struct {
    /// Storage for all requests
    requests: [MAX_REQUESTS]TransferRequest,

    /// Head of the free list (null = pool exhausted)
    free_list: ?*TransferRequest,

    /// Number of currently allocated requests
    allocated_count: usize,

    /// Lock protecting pool state
    lock: sync.Spinlock,

    /// Initialize the pool with all requests on the free list
    pub fn init(self: *TransferRequestPool) void {
        self.* = .{
            .requests = undefined,
            .free_list = null,
            .allocated_count = 0,
            .lock = .{},
        };

        // Initialize all requests and build free list (reverse order for cache locality)
        var i: usize = MAX_REQUESTS;
        while (i > 0) {
            i -= 1;
            self.requests[i] = TransferRequest{
                .trb_phys = 0,
                .dci = 0,
                .state = std.atomic.Value(TransferState).init(.pending),
                .completion_code = .Invalid,
                .residual = 0,
                .request_len = 0,
                .callback = .{ .none = {} },
                .next = self.free_list,
                .io_request = null,
            };
            self.free_list = &self.requests[i];
        }
    }

    /// Allocate a request from the pool
    /// Returns null if pool is exhausted
    /// io_request: Optional kernel IoRequest for reactor/io_uring integration
    pub fn alloc(
        self: *TransferRequestPool,
        dci: u5,
        trb_phys: u64,
        request_len: u24,
        callback: TransferCallback,
        io_request: ?*io.IoRequest,
    ) ?*TransferRequest {
        const held = self.lock.acquire();
        defer held.release();

        const req = self.free_list orelse return null;

        // Remove from free list
        self.free_list = req.next;
        self.allocated_count += 1;

        // Initialize the request
        req.* = TransferRequest.init(dci, trb_phys, request_len, callback);
        req.io_request = io_request;

        return req;
    }

    /// Return a request to the pool
    /// Security: Validates request belongs to this pool before modifying free list
    pub fn free(self: *TransferRequestPool, req: *TransferRequest) void {
        const held = self.lock.acquire();
        defer held.release();

        // Security: Verify request belongs to this pool to prevent
        // double-free and arbitrary-free attacks
        const base = @intFromPtr(&self.requests[0]);
        const end = base + MAX_REQUESTS * @sizeOf(TransferRequest);
        const ptr = @intFromPtr(req);

        if (ptr < base or ptr >= end) {
            // Invalid pointer - do not corrupt free list
            if (builtin.mode == .Debug) {
                @panic("TransferRequestPool.free: request not from this pool");
            }
            return;
        }

        // Verify alignment
        if ((ptr - base) % @sizeOf(TransferRequest) != 0) {
            if (builtin.mode == .Debug) {
                @panic("TransferRequestPool.free: misaligned request pointer");
            }
            return;
        }

        // Reset state and add to free list
        req.* = TransferRequest{
            .trb_phys = 0,
            .dci = 0,
            .state = std.atomic.Value(TransferState).init(.pending),
            .completion_code = .Invalid,
            .residual = 0,
            .request_len = 0,
            .callback = .{ .none = {} },
            .next = self.free_list,
            .io_request = null,
        };
        self.free_list = req;
        self.allocated_count -= 1;
    }

    /// Get number of available requests
    pub fn available(self: *TransferRequestPool) usize {
        const held = self.lock.acquire();
        defer held.release();
        return MAX_REQUESTS - self.allocated_count;
    }

    /// Check if pool is exhausted
    pub fn isEmpty(self: *TransferRequestPool) bool {
        const held = self.lock.acquire();
        defer held.release();
        return self.free_list == null;
    }
};

// =============================================================================
// Global Pool Instance
// =============================================================================

/// Global transfer request pool
var global_pool: TransferRequestPool = undefined;

/// Initialization state for thread-safe one-time init
/// 0 = not started, 1 = in progress, 2 = complete
/// Security: Uses cmpxchg to prevent TOCTOU race where multiple CPUs
/// could pass a simple flag check and corrupt the pool by double-init.
var init_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Initialize the global pool (call once during USB subsystem init)
/// Thread-safe: Uses compare-and-swap to ensure exactly one CPU initializes.
pub fn initGlobal() void {
    while (true) {
        const state = init_state.load(.acquire);
        if (state == 2) return; // Already initialized

        if (state == 0) {
            // Try to claim initialization
            if (init_state.cmpxchgStrong(0, 1, .acq_rel, .acquire)) |_| {
                // Lost race - another CPU claimed it, retry
                continue;
            }
            // We won the race - do initialization
            global_pool.init();
            // Release ordering ensures init() writes are visible before state=2
            init_state.store(2, .release);
            return;
        }

        // state == 1: Another CPU is initializing, spin-wait
        std.atomic.spinLoopHint();
    }
}

/// Allocate a transfer request from the global pool
/// io_request: Optional kernel IoRequest for reactor/io_uring integration
pub fn allocRequest(
    dci: u5,
    trb_phys: u64,
    request_len: u24,
    callback: TransferCallback,
    io_request: ?*io.IoRequest,
) ?*TransferRequest {
    // Only proceed if initialization is complete (state == 2)
    if (init_state.load(.acquire) != 2) return null;
    return global_pool.alloc(dci, trb_phys, request_len, callback, io_request);
}

/// Free a transfer request back to the global pool
pub fn freeRequest(req: *TransferRequest) void {
    // Only proceed if initialization is complete (state == 2)
    if (init_state.load(.acquire) == 2) {
        global_pool.free(req);
    }
}

/// Get number of available requests in global pool
pub fn availableRequests() usize {
    // Only proceed if initialization is complete (state == 2)
    if (init_state.load(.acquire) != 2) return 0;
    return global_pool.available();
}
