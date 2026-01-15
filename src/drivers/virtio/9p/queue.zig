// VirtIO-9P Queue Management
//
// Wraps the common VirtIO Virtqueue with 9P-specific functionality.
// VirtIO-9P uses a single request/response queue.

const std = @import("std");
const virtio = @import("virtio");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");
const protocol = @import("protocol.zig");

/// Result type for completed requests
pub const UsedResult = struct { head: u16, len: u32 };

// ============================================================================
// Pending Request Tracking
// ============================================================================

/// State of a pending 9P request
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

/// Tracking structure for in-flight 9P requests
pub const PendingRequest = struct {
    /// Current state
    state: PendingState,
    /// 9P message tag for correlation
    tag: u16,
    /// Expected response type
    expected_type: protocol.MsgType,
    /// Descriptor head index
    desc_head: u16,
    /// Response buffer (points to virtqueue buffer)
    response_buf: []u8,
    /// Actual response length from device
    response_len: u32,
    /// Completion event (for synchronous waits)
    completed: std.atomic.Value(bool),

    const Self = @This();

    pub fn init() Self {
        return .{
            .state = .free,
            .tag = 0,
            .expected_type = .Rversion,
            .desc_head = 0,
            .response_buf = &.{},
            .response_len = 0,
            .completed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn reset(self: *Self) void {
        self.state = .free;
        self.tag = 0;
        self.response_len = 0;
        self.completed.store(false, .release);
    }

    pub fn setup(self: *Self, tag: u16, expected: protocol.MsgType, desc_head: u16, resp_buf: []u8) void {
        self.state = .pending;
        self.tag = tag;
        self.expected_type = expected;
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
// 9P Queue Wrapper
// ============================================================================

/// VirtIO-9P queue wrapper
pub const P9Queue = struct {
    /// Underlying virtqueue
    vq: virtio.Virtqueue,

    /// Queue index in VirtIO device (always 0 for 9P)
    queue_index: u16,

    /// Notify address for this queue
    notify_addr: u64,

    /// MSI-X vector assigned to this queue (0xFFFF = not configured)
    msix_vector: u16,

    /// Pending requests indexed by descriptor head
    pending: [config.Limits.MAX_PENDING_REQUESTS]PendingRequest,

    /// Lock protecting pending array
    lock: sync.Spinlock,

    /// Next tag to use (wraps at MAX_TAG)
    next_tag: u16,

    /// Number of in-flight requests
    in_flight: std.atomic.Value(u32),

    const Self = @This();

    /// Initialize a 9P queue
    pub fn init(queue_size: u16) ?Self {
        const vq = virtio.Virtqueue.init(queue_size) orelse return null;

        var self = Self{
            .vq = vq,
            .queue_index = config.QueueIndex.REQUEST,
            .notify_addr = 0,
            .msix_vector = 0xFFFF,
            .pending = undefined,
            .lock = .{},
            .next_tag = 1,
            .in_flight = std.atomic.Value(u32).init(0),
        };

        // Initialize pending slots
        for (&self.pending) |*p| {
            p.* = PendingRequest.init();
        }

        return self;
    }

    /// Set the notify address for this queue
    pub fn setNotifyAddr(self: *Self, base: u64, offset_mult: u32, queue_notify_off: u16) void {
        const offset = std.math.mul(u64, queue_notify_off, offset_mult) catch 0;
        self.notify_addr = std.math.add(u64, base, offset) catch base;
    }

    /// Notify the device that new buffers are available
    pub fn kick(self: *Self) void {
        if (self.notify_addr == 0) return;

        // Memory barrier before notify
        hal.mmio.memoryBarrier();

        // Write queue index to notify register
        const ptr: *volatile u16 = @ptrFromInt(self.notify_addr);
        ptr.* = self.queue_index;
    }

    /// Allocate a request tag
    pub fn allocTag(self: *Self) u16 {
        const held = self.lock.acquire();
        defer held.release();

        const tag = self.next_tag;
        self.next_tag +%= 1;
        if (self.next_tag > config.Limits.MAX_TAG) {
            self.next_tag = 1;
        }
        return tag;
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

    /// Submit a 9P request
    /// Returns the pending request slot on success
    pub fn submitRequest(
        self: *Self,
        request_buf: []const u8,
        response_buf: []u8,
        tag: u16,
        expected_response: protocol.MsgType,
    ) ?*PendingRequest {
        const held = self.lock.acquire();
        defer held.release();

        // Find a free pending slot
        const slot_idx = self.findFreeSlot() orelse return null;

        // Submit to virtqueue
        // 9P uses: out[0] = request, in[0] = response
        const out_bufs = [_][]const u8{request_buf};
        const in_bufs = [_][]u8{response_buf};

        const desc_head = self.vq.addBuf(&out_bufs, &in_bufs) orelse return null;

        // Setup pending tracking
        self.pending[slot_idx].setup(tag, expected_response, desc_head, response_buf);
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

    /// Find a completed request by tag
    pub fn findCompleted(self: *Self, tag: u16) ?*PendingRequest {
        const held = self.lock.acquire();
        defer held.release();

        for (&self.pending) |*p| {
            if (p.state == .completed and p.tag == tag) {
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
        self.next_tag = 1;
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
