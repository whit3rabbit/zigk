// VirtIO-FS Queue Management
//
// Wraps the common VirtIO Virtqueue with FUSE-specific functionality.
// VirtIO-FS uses multiple queues:
//   - Queue 0 (hiprio): FORGET/INTERRUPT messages (no response expected)
//   - Queue 1+ (request): Normal FUSE operations with request/response
//
// Reference: VirtIO Specification 1.2+ Section 5.11 (virtiofs)

const std = @import("std");
const virtio = @import("virtio");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");
const protocol = @import("protocol.zig");

// ============================================================================
// Pending Request Tracking
// ============================================================================

/// State of a pending FUSE request
pub const PendingState = enum {
    /// Slot is free
    free,
    /// Request submitted, waiting for response
    pending,
    /// Response received
    completed,
    /// Request failed/timed out
    failed,
};

/// Tracking structure for in-flight FUSE requests
pub const PendingRequest = struct {
    /// Current state
    state: PendingState,
    /// Unique request ID for correlation
    unique: u64,
    /// Expected opcode
    opcode: config.FuseOpcode,
    /// Descriptor head index
    desc_head: u16,
    /// Response buffer
    response_buf: []u8,
    /// Actual response length from device
    response_len: u32,
    /// Completion flag (for synchronous waits)
    completed: std.atomic.Value(bool),

    const Self = @This();

    pub fn init() Self {
        return .{
            .state = .free,
            .unique = 0,
            .opcode = .INIT,
            .desc_head = 0,
            .response_buf = &.{},
            .response_len = 0,
            .completed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn reset(self: *Self) void {
        self.state = .free;
        self.unique = 0;
        self.response_len = 0;
        self.completed.store(false, .release);
    }

    pub fn setup(self: *Self, unique: u64, opcode: config.FuseOpcode, desc_head: u16, resp_buf: []u8) void {
        self.state = .pending;
        self.unique = unique;
        self.opcode = opcode;
        self.desc_head = desc_head;
        self.response_buf = resp_buf;
        self.response_len = 0;
        self.completed.store(false, .release);
    }

    pub fn complete(self: *Self, len: u32) void {
        self.response_len = len;
        self.state = .completed;
        self.completed.store(true, .release);
    }

    pub fn fail(self: *Self) void {
        self.state = .failed;
        self.completed.store(true, .release);
    }

    /// Wait for completion (polling, for kernel context)
    pub fn waitCompletion(self: *Self, timeout_ns: u64) bool {
        const start = hal.timing.getNanoseconds();
        while (!self.completed.load(.acquire)) {
            const elapsed = hal.timing.getNanoseconds() - start;
            if (elapsed >= timeout_ns) return false;
            hal.cpu.pause();
        }
        return true;
    }
};

// ============================================================================
// High-Priority Queue (FORGET/INTERRUPT)
// ============================================================================

/// High-priority queue for FORGET and INTERRUPT messages
/// These messages do not expect a response
pub const HiprioQueue = struct {
    /// Underlying virtqueue
    vq: virtio.Virtqueue,

    /// Queue index (always 0)
    queue_index: u16,

    /// Notify address
    notify_addr: u64,

    /// Lock for queue access
    lock: sync.Spinlock,

    const Self = @This();

    /// Initialize the hiprio queue
    pub fn init(queue_size: u16) ?Self {
        const vq = virtio.Virtqueue.init(queue_size) orelse return null;

        return Self{
            .vq = vq,
            .queue_index = config.QueueIndex.HIPRIO,
            .notify_addr = 0,
            .lock = .{},
        };
    }

    /// Set the notify address
    pub fn setNotifyAddr(self: *Self, base: u64, offset_mult: u32, queue_notify_off: u16) void {
        const offset = std.math.mul(u64, queue_notify_off, offset_mult) catch 0;
        self.notify_addr = std.math.add(u64, base, offset) catch base;
    }

    /// Notify the device
    pub fn kick(self: *Self) void {
        if (self.notify_addr == 0) return;

        hal.mmio.memoryBarrier();
        const ptr: *volatile u16 = @ptrFromInt(self.notify_addr);
        ptr.* = self.queue_index;
    }

    /// Submit a FORGET message (fire and forget, no response)
    pub fn submitForget(self: *Self, msg_buf: []const u8) bool {
        const held = self.lock.acquire();
        defer held.release();

        // For FORGET, we only need an output buffer
        const out_bufs = [_][]const u8{msg_buf};
        const in_bufs = [_][]u8{};

        const desc_head = self.vq.addBuf(&out_bufs, &in_bufs) orelse return false;
        _ = desc_head;

        self.kick();
        return true;
    }

    /// Process any completed FORGET messages (clean up descriptors)
    pub fn processCompleted(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        // Just drain the used ring - FORGET doesn't need response handling
        while (self.vq.getUsed()) |_| {
            // Descriptor already freed by getUsed
        }
    }

    /// Get physical addresses for device configuration
    pub fn getPhysAddrs(self: *const Self) struct { desc: u64, avail: u64, used: u64 } {
        return .{
            .desc = self.vq.desc_phys,
            .avail = self.vq.avail_phys,
            .used = self.vq.used_phys,
        };
    }
};

// ============================================================================
// Request Queue (Normal FUSE Operations)
// ============================================================================

/// Request queue for normal FUSE operations
pub const RequestQueue = struct {
    /// Underlying virtqueue
    vq: virtio.Virtqueue,

    /// Queue index (1 or higher)
    queue_index: u16,

    /// Notify address
    notify_addr: u64,

    /// MSI-X vector assigned (0xFFFF = not configured)
    msix_vector: u16,

    /// Pending requests indexed by slot
    pending: [config.Limits.MAX_PENDING_REQUESTS]PendingRequest,

    /// Lock for pending array and queue
    lock: sync.Spinlock,

    /// Next unique ID to use
    next_unique: std.atomic.Value(u64),

    /// Number of in-flight requests
    in_flight: std.atomic.Value(u32),

    const Self = @This();

    /// Initialize a request queue
    pub fn init(queue_size: u16, queue_index: u16) ?Self {
        const vq = virtio.Virtqueue.init(queue_size) orelse return null;

        var self = Self{
            .vq = vq,
            .queue_index = queue_index,
            .notify_addr = 0,
            .msix_vector = 0xFFFF,
            .pending = undefined,
            .lock = .{},
            .next_unique = std.atomic.Value(u64).init(1),
            .in_flight = std.atomic.Value(u32).init(0),
        };

        for (&self.pending) |*p| {
            p.* = PendingRequest.init();
        }

        return self;
    }

    /// Set the notify address
    pub fn setNotifyAddr(self: *Self, base: u64, offset_mult: u32, queue_notify_off: u16) void {
        const offset = std.math.mul(u64, queue_notify_off, offset_mult) catch 0;
        self.notify_addr = std.math.add(u64, base, offset) catch base;
    }

    /// Notify the device
    pub fn kick(self: *Self) void {
        if (self.notify_addr == 0) return;

        hal.mmio.memoryBarrier();
        const ptr: *volatile u16 = @ptrFromInt(self.notify_addr);
        ptr.* = self.queue_index;
    }

    /// Allocate a unique request ID
    pub fn allocUnique(self: *Self) u64 {
        return self.next_unique.fetchAdd(1, .monotonic);
    }

    /// Find a free pending slot
    fn findFreeSlot(self: *Self) ?usize {
        for (&self.pending, 0..) |*p, i| {
            if (p.state == .free) {
                return i;
            }
        }
        return null;
    }

    /// Submit a FUSE request
    pub fn submitRequest(
        self: *Self,
        request_buf: []const u8,
        response_buf: []u8,
        unique: u64,
        opcode: config.FuseOpcode,
    ) ?*PendingRequest {
        const held = self.lock.acquire();
        defer held.release();

        // Find a free pending slot
        const slot_idx = self.findFreeSlot() orelse return null;

        // Submit to virtqueue: out[0] = request, in[0] = response
        const out_bufs = [_][]const u8{request_buf};
        const in_bufs = [_][]u8{response_buf};

        const desc_head = self.vq.addBuf(&out_bufs, &in_bufs) orelse return null;

        // Setup pending tracking
        self.pending[slot_idx].setup(unique, opcode, desc_head, response_buf);
        _ = self.in_flight.fetchAdd(1, .monotonic);

        // Kick the device
        self.kick();

        return &self.pending[slot_idx];
    }

    /// Check if there are completed requests
    pub fn hasPending(self: *Self) bool {
        return self.vq.hasPending();
    }

    /// Process completed requests from the used ring
    pub fn processCompleted(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        while (self.vq.getUsed()) |result| {
            // Find the pending request by descriptor head
            for (&self.pending) |*p| {
                if (p.state == .pending and p.desc_head == result.head) {
                    p.complete(result.len);
                    _ = self.in_flight.fetchSub(1, .monotonic);
                    break;
                }
            }
        }
    }

    /// Find a completed request by unique ID
    pub fn findByUnique(self: *Self, unique: u64) ?*PendingRequest {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.pending) |*p| {
            if ((p.state == .completed or p.state == .pending) and p.unique == unique) {
                return p;
            }
        }
        return null;
    }

    /// Release a pending request slot
    pub fn releaseRequest(self: *Self, req: *PendingRequest) void {
        const held = self.lock.acquire();
        defer held.release();
        req.reset();
    }

    /// Get number of in-flight requests
    pub fn getInFlight(self: *Self) u32 {
        return self.in_flight.load(.monotonic);
    }

    /// Get number of free descriptors
    pub fn getFreeDescriptors(self: *Self) u16 {
        return self.vq.num_free;
    }

    /// Check if queue has space for a request (needs 2 descriptors: req + resp)
    pub fn hasSpace(self: *Self) bool {
        return self.vq.num_free >= 2;
    }

    /// Reset the queue state
    pub fn reset(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        self.vq.reset();
        for (&self.pending) |*p| {
            p.reset();
        }
        self.in_flight.store(0, .monotonic);
    }

    /// Get physical addresses for device configuration
    pub fn getPhysAddrs(self: *const Self) struct { desc: u64, avail: u64, used: u64 } {
        return .{
            .desc = self.vq.desc_phys,
            .avail = self.vq.avail_phys,
            .used = self.vq.used_phys,
        };
    }
};

// ============================================================================
// Combined Queue Set
// ============================================================================

/// Complete queue set for a VirtIO-FS device
pub const FsQueues = struct {
    /// High-priority queue for FORGET/INTERRUPT
    hiprio: HiprioQueue,

    /// Request queue(s) for normal operations
    /// Most implementations use a single request queue
    request: RequestQueue,

    /// Number of request queues available
    num_request_queues: u32,

    const Self = @This();

    /// Initialize all queues
    pub fn init(queue_size: u16, num_request_queues: u32) ?Self {
        const hiprio = HiprioQueue.init(queue_size) orelse return null;
        const request = RequestQueue.init(queue_size, config.QueueIndex.REQUEST) orelse return null;

        return Self{
            .hiprio = hiprio,
            .request = request,
            .num_request_queues = num_request_queues,
        };
    }

    /// Process completions on all queues
    pub fn processAllCompleted(self: *Self) void {
        self.hiprio.processCompleted();
        self.request.processCompleted();
    }
};

// ============================================================================
// Helper: Wait for completion with polling
// ============================================================================

/// Wait for a pending request to complete, polling the queue
/// This handles the case where MSI-X interrupts don't work
pub fn waitForCompletion(queue: *RequestQueue, pending: *PendingRequest, timeout_ns: u64) bool {
    const start = hal.timing.getNanoseconds();
    while (!pending.completed.load(.acquire)) {
        // Poll the used ring to check for completions
        queue.processCompleted();

        const elapsed = hal.timing.getNanoseconds() - start;
        if (elapsed >= timeout_ns) return false;
        hal.cpu.pause();
    }
    return true;
}
