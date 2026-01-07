// VirtIO-Sound Queue Management
//
// Wraps the common VirtIO Virtqueue with Sound-specific functionality.
// Handles control, event, TX (playback), and RX (capture) queues.

const std = @import("std");
const virtio = @import("virtio");
const hal = @import("hal");
const sync = @import("sync");
const config = @import("config.zig");

/// Result type for completed requests
pub const UsedResult = struct { head: u16, len: u32 };

// =============================================================================
// Queue Types
// =============================================================================

/// VirtIO-Sound queue type
pub const QueueType = enum {
    /// Control queue for configuration requests
    control,
    /// Event queue for async notifications
    event,
    /// TX queue for PCM playback
    tx,
    /// RX queue for PCM capture
    rx,
};

// =============================================================================
// Pending Audio Buffer
// =============================================================================

/// Pending audio buffer tracking
pub const PendingBuffer = struct {
    /// Physical address of audio data
    data_phys: u64,
    /// Virtual address of audio data
    data_virt: [*]u8,
    /// Size of audio data in bytes
    size: u32,
    /// Stream ID this buffer belongs to
    stream_id: u32,
    /// Completion callback (optional)
    on_complete: ?*const fn (buffer: *PendingBuffer, status: u32) void,
    /// User context for callback
    context: ?*anyopaque,
    /// Is this buffer in use?
    in_use: bool,
};

// =============================================================================
// Sound Queue Wrapper
// =============================================================================

/// VirtIO-Sound queue wrapper
pub const SoundQueue = struct {
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

    /// Pending buffers (for TX/RX queues)
    /// Indexed by descriptor head
    pending: [config.Limits.MAX_PENDING_PER_QUEUE]PendingBuffer,

    /// Lock protecting pending array
    pending_lock: sync.Spinlock,

    /// Number of in-flight buffers
    in_flight: std.atomic.Value(u32),

    /// Total bytes written (for TX)
    bytes_written: std.atomic.Value(u64),

    /// Total bytes read (for RX)
    bytes_read: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize a sound queue
    pub fn init(queue_type: QueueType, queue_index: u16, queue_size: u16) ?Self {
        const vq = virtio.Virtqueue.init(queue_size) orelse return null;

        var pending: [config.Limits.MAX_PENDING_PER_QUEUE]PendingBuffer = undefined;
        for (&pending) |*p| {
            p.* = .{
                .data_phys = 0,
                .data_virt = undefined,
                .size = 0,
                .stream_id = 0,
                .on_complete = null,
                .context = null,
                .in_use = false,
            };
        }

        return Self{
            .vq = vq,
            .queue_type = queue_type,
            .queue_index = queue_index,
            .notify_addr = 0,
            .msix_vector = 0xFFFF,
            .pending = pending,
            .pending_lock = .{},
            .in_flight = std.atomic.Value(u32).init(0),
            .bytes_written = std.atomic.Value(u64).init(0),
            .bytes_read = std.atomic.Value(u64).init(0),
        };
    }

    /// Set the notify address for this queue
    /// SECURITY: Uses checked arithmetic to prevent overflow-based attacks
    pub fn setNotifyAddr(self: *Self, base: u64, offset_mult: u32, queue_notify_off: u16) void {
        const offset = std.math.mul(u64, queue_notify_off, offset_mult) catch {
            // Overflow in device-provided values - log and use base as fallback
            // This prevents malicious offset_mult from causing incorrect notify address
            @import("console").warn("VirtIO-Sound: notify offset overflow (off={}, mult={})", .{ queue_notify_off, offset_mult });
            self.notify_addr = base;
            return;
        };
        self.notify_addr = std.math.add(u64, base, offset) catch {
            @import("console").warn("VirtIO-Sound: notify address overflow (base=0x{x}, offset=0x{x})", .{ base, offset });
            self.notify_addr = base;
            return;
        };
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

    /// Store a pending buffer
    pub fn storePending(
        self: *Self,
        desc_head: u16,
        data_phys: u64,
        data_virt: [*]u8,
        size: u32,
        stream_id: u32,
    ) bool {
        if (desc_head >= config.Limits.MAX_PENDING_PER_QUEUE) return false;

        const held = self.pending_lock.acquire();
        defer held.release();

        if (self.pending[desc_head].in_use) return false;

        self.pending[desc_head] = .{
            .data_phys = data_phys,
            .data_virt = data_virt,
            .size = size,
            .stream_id = stream_id,
            .on_complete = null,
            .context = null,
            .in_use = true,
        };
        _ = self.in_flight.fetchAdd(1, .monotonic);
        return true;
    }

    /// Retrieve and clear a pending buffer
    pub fn takePending(self: *Self, desc_head: u16) ?PendingBuffer {
        if (desc_head >= config.Limits.MAX_PENDING_PER_QUEUE) return null;

        const held = self.pending_lock.acquire();
        defer held.release();

        if (!self.pending[desc_head].in_use) return null;

        const buffer = self.pending[desc_head];
        self.pending[desc_head].in_use = false;
        _ = self.in_flight.fetchSub(1, .monotonic);

        // Track bytes for TX/RX queues
        switch (self.queue_type) {
            .tx => _ = self.bytes_written.fetchAdd(buffer.size, .monotonic),
            .rx => _ = self.bytes_read.fetchAdd(buffer.size, .monotonic),
            else => {},
        }

        return buffer;
    }

    /// Get number of in-flight buffers
    pub fn getInFlight(self: *Self) u32 {
        return self.in_flight.load(.monotonic);
    }

    /// Get number of free descriptors
    pub fn getFreeDescriptors(self: *Self) u16 {
        return self.vq.num_free;
    }

    /// Check if queue has space for a request
    /// Audio transfers typically need 3 descriptors: header, data, status
    pub fn hasSpace(self: *Self, desc_count: u16) bool {
        return self.vq.num_free >= desc_count;
    }

    /// Get available buffer space in bytes (for OSS GETOSPACE)
    pub fn getAvailableSpace(self: *Self) u32 {
        // Each pending slot can hold one buffer
        const free_slots = config.Limits.MAX_PENDING_PER_QUEUE - self.in_flight.load(.monotonic);
        return @intCast(free_slots * config.Limits.BUFFER_SIZE);
    }

    /// Reset the queue state
    pub fn reset(self: *Self) void {
        self.vq.reset();

        const held = self.pending_lock.acquire();
        defer held.release();

        for (&self.pending) |*p| {
            p.in_use = false;
        }
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

// =============================================================================
// Queue Set (Control + Event + TX + RX queues)
// =============================================================================

/// Complete set of VirtIO-Sound queues
pub const SoundQueueSet = struct {
    /// Control queue (queue 0)
    control: ?SoundQueue,

    /// Event queue (queue 1)
    event: ?SoundQueue,

    /// TX queues for playback (queue 2+)
    tx_queues: [config.Limits.MAX_TX_QUEUES]?SoundQueue,

    /// RX queues for capture
    rx_queues: [config.Limits.MAX_RX_QUEUES]?SoundQueue,

    /// Number of active TX queues
    tx_queue_count: u8,

    /// Number of active RX queues
    rx_queue_count: u8,

    /// Round-robin index for TX queue selection
    next_tx_queue: std.atomic.Value(u32),

    const Self = @This();

    /// Initialize an empty queue set
    pub fn init() Self {
        return Self{
            .control = null,
            .event = null,
            .tx_queues = [_]?SoundQueue{null} ** config.Limits.MAX_TX_QUEUES,
            .rx_queues = [_]?SoundQueue{null} ** config.Limits.MAX_RX_QUEUES,
            .tx_queue_count = 0,
            .rx_queue_count = 0,
            .next_tx_queue = std.atomic.Value(u32).init(0),
        };
    }

    /// Select the next TX queue (round-robin)
    /// SECURITY: Defensively checks queue is non-null to prevent panic
    pub fn selectTxQueue(self: *Self) ?*SoundQueue {
        if (self.tx_queue_count == 0) return null;

        const idx = self.next_tx_queue.fetchAdd(1, .monotonic) % self.tx_queue_count;
        // Defensive check: verify queue exists before unwrapping
        if (self.tx_queues[idx]) |*q| {
            return q;
        }
        return null;
    }

    /// Get a TX queue by index
    pub fn getTxQueue(self: *Self, idx: u8) ?*SoundQueue {
        if (idx >= self.tx_queue_count) return null;
        if (self.tx_queues[idx] == null) return null;
        return &self.tx_queues[idx].?;
    }

    /// Get a RX queue by index
    pub fn getRxQueue(self: *Self, idx: u8) ?*SoundQueue {
        if (idx >= self.rx_queue_count) return null;
        if (self.rx_queues[idx] == null) return null;
        return &self.rx_queues[idx].?;
    }

    /// Get total available TX buffer space
    pub fn getTotalTxSpace(self: *Self) u32 {
        var total: u32 = 0;
        for (0..self.tx_queue_count) |i| {
            if (self.tx_queues[i]) |*q| {
                total = std.math.add(u32, total, q.getAvailableSpace()) catch total;
            }
        }
        return total;
    }

    /// Get total in-flight TX buffers
    pub fn getTotalTxInFlight(self: *Self) u32 {
        var total: u32 = 0;
        for (0..self.tx_queue_count) |i| {
            if (self.tx_queues[i]) |*q| {
                total += q.getInFlight();
            }
        }
        return total;
    }

    /// Reset all queues
    pub fn resetAll(self: *Self) void {
        if (self.control) |*q| q.reset();
        if (self.event) |*q| q.reset();
        for (&self.tx_queues) |*mq| {
            if (mq.*) |*q| q.reset();
        }
        for (&self.rx_queues) |*mq| {
            if (mq.*) |*q| q.reset();
        }
    }
};
