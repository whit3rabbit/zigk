// VirtIO-SCSI Queue Management
//
// Wraps the common VirtIO Virtqueue with SCSI-specific functionality.
// Handles control, event, and request queues.

const std = @import("std");
const virtio = @import("virtio");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");
const request = @import("request.zig");

/// Result type for completed requests (matches virtio.Virtqueue.getUsed return)
pub const UsedResult = struct { head: u16, len: u32 };

// ============================================================================
// Queue Types
// ============================================================================

/// VirtIO-SCSI queue type
pub const QueueType = enum {
    /// Control queue for TMF commands
    control,
    /// Event queue for async notifications
    event,
    /// Request queue for I/O commands
    request,
};

// ============================================================================
// SCSI Queue Wrapper
// ============================================================================

/// VirtIO-SCSI queue wrapper
pub const ScsiQueue = struct {
    /// Underlying virtqueue
    vq: virtio.Virtqueue,

    /// Queue type
    queue_type: QueueType,

    /// Queue index in VirtIO device
    queue_index: u16,

    /// Notify address for this queue
    notify_addr: u64,

    /// MSI-X vector assigned to this queue (0xFFFF = not configured)
    msix_vector: u16,

    /// Pending requests (for request queues)
    /// Indexed by descriptor head
    pending: [config.Limits.MAX_PENDING_PER_QUEUE]?*request.PendingRequest,

    /// Lock protecting pending array
    pending_lock: sync.Spinlock,

    /// Number of in-flight requests
    in_flight: std.atomic.Value(u32),

    const Self = @This();

    /// Initialize a SCSI queue
    pub fn init(queue_type: QueueType, queue_index: u16, queue_size: u16) ?Self {
        const vq = virtio.Virtqueue.init(queue_size) orelse return null;

        return Self{
            .vq = vq,
            .queue_type = queue_type,
            .queue_index = queue_index,
            .notify_addr = 0,
            .msix_vector = 0xFFFF,
            .pending = [_]?*request.PendingRequest{null} ** config.Limits.MAX_PENDING_PER_QUEUE,
            .pending_lock = .{},
            .in_flight = std.atomic.Value(u32).init(0),
        };
    }

    /// Set the notify address for this queue
    pub fn setNotifyAddr(self: *Self, base: u64, offset_mult: u32, queue_notify_off: u16) void {
        // notify_addr = notify_base + queue_notify_off * notify_off_mult
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

    /// Submit buffers and notify device
    pub fn submitAndKick(
        self: *Self,
        out_bufs: []const []const u8,
        in_bufs: []const []u8,
    ) ?u16 {
        const head = self.vq.addBuf(out_bufs, in_bufs) orelse return null;
        self.kick();
        return head;
    }

    /// Check if there are completed requests
    pub fn hasPending(self: *Self) bool {
        return self.vq.hasPending();
    }

    /// Get next completed request
    pub fn getUsed(self: *Self) ?UsedResult {
        if (self.vq.getUsed()) |result| {
            return UsedResult{ .head = result.head, .len = result.len };
        }
        return null;
    }

    /// Store a pending request
    pub fn storePending(self: *Self, desc_head: u16, pending_req: *request.PendingRequest) bool {
        if (desc_head >= config.Limits.MAX_PENDING_PER_QUEUE) return false;

        const held = self.pending_lock.acquire();
        defer held.release();

        if (self.pending[desc_head] != null) return false; // Slot already in use

        self.pending[desc_head] = pending_req;
        _ = self.in_flight.fetchAdd(1, .monotonic);
        return true;
    }

    /// Retrieve and clear a pending request
    pub fn takePending(self: *Self, desc_head: u16) ?*request.PendingRequest {
        if (desc_head >= config.Limits.MAX_PENDING_PER_QUEUE) return null;

        const held = self.pending_lock.acquire();
        defer held.release();

        const pending_req = self.pending[desc_head];
        if (pending_req != null) {
            self.pending[desc_head] = null;
            _ = self.in_flight.fetchSub(1, .monotonic);
        }
        return pending_req;
    }

    /// Get number of in-flight requests
    pub fn getInFlight(self: *Self) u32 {
        return self.in_flight.load(.monotonic);
    }

    /// Get number of free descriptors
    pub fn getFreeDescriptors(self: *Self) u16 {
        return self.vq.num_free;
    }

    /// Check if queue has space for a request
    /// SCSI requests typically need 3 descriptors: header, data, status
    pub fn hasSpace(self: *Self, desc_count: u16) bool {
        return self.vq.num_free >= desc_count;
    }

    /// Reset the queue state
    pub fn reset(self: *Self) void {
        self.vq.reset();

        const held = self.pending_lock.acquire();
        defer held.release();

        @memset(&self.pending, null);
        self.in_flight.store(0, .monotonic);
    }

    /// Get physical addresses for device configuration
    pub fn getPhysAddrs(self: *Self) struct { desc: u64, avail: u64, used: u64 } {
        return .{
            .desc = self.vq.desc_phys,
            .avail = self.vq.avail_phys,
            .used = self.vq.used_phys,
        };
    }
};

// ============================================================================
// Queue Set (Control + Event + Request queues)
// ============================================================================

/// Complete set of VirtIO-SCSI queues
pub const ScsiQueueSet = struct {
    /// Control queue (queue 0)
    control: ?ScsiQueue,

    /// Event queue (queue 1)
    event: ?ScsiQueue,

    /// Request queues (queue 2+)
    request_queues: [config.Limits.MAX_REQUEST_QUEUES]?ScsiQueue,

    /// Number of active request queues
    request_queue_count: u8,

    /// Round-robin index for request queue selection
    next_request_queue: std.atomic.Value(u32),

    const Self = @This();

    /// Initialize an empty queue set
    pub fn init() Self {
        return Self{
            .control = null,
            .event = null,
            .request_queues = [_]?ScsiQueue{null} ** config.Limits.MAX_REQUEST_QUEUES,
            .request_queue_count = 0,
            .next_request_queue = std.atomic.Value(u32).init(0),
        };
    }

    /// Select the next request queue (round-robin)
    pub fn selectRequestQueue(self: *Self) ?*ScsiQueue {
        if (self.request_queue_count == 0) return null;

        // Round-robin selection
        const idx = self.next_request_queue.fetchAdd(1, .monotonic) % self.request_queue_count;
        return &self.request_queues[idx].?;
    }

    /// Get a request queue by index
    pub fn getRequestQueue(self: *Self, idx: u8) ?*ScsiQueue {
        if (idx >= self.request_queue_count) return null;
        if (self.request_queues[idx] == null) return null;
        return &self.request_queues[idx].?;
    }

    /// Get total in-flight requests across all queues
    pub fn getTotalInFlight(self: *Self) u32 {
        var total: u32 = 0;
        for (0..self.request_queue_count) |i| {
            if (self.request_queues[i]) |*q| {
                total += q.getInFlight();
            }
        }
        return total;
    }

    /// Reset all queues
    pub fn resetAll(self: *Self) void {
        if (self.control) |*q| q.reset();
        if (self.event) |*q| q.reset();
        for (&self.request_queues) |*mq| {
            if (mq.*) |*q| q.reset();
        }
    }
};
