//! IO Uring Instance Management

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const types = @import("types.zig");
const ring = @import("ring.zig");
const pmm = @import("pmm");
const hal = @import("hal");
const heap = @import("heap");
const io = @import("io");
const thread_mod = @import("thread");
const Thread = thread_mod.Thread;
const user_mem = @import("user_mem");

// Bounce buffer cleanup note:
// Actually finalizeBounceBuffer uses user_mem. Let's move finalizeBounceBuffer to request.zig
// But freeInstance calls finalizeBounceBuffer. So freeInstance needs to call a function in request.zig?
// Cycle: instance -> request -> instance.
// Solution: finalizeBounceBuffer logic in request.zig, but it doesn't need Instance, just Request.
// So instance.zig can import request.zig helpers?
// But request.zig needs Instance struct definition?
// If request.zig imports instance.zig, then instance.zig cannot import request.zig.
// We can implement finalizeBounceBuffer in `utils.zig` or keep it here if it doesn't need Instance.
// finalizeBounceBuffer takes `*io.IoRequest`. It doesn't need Instance. 
// It uses `user_mem` and `heap`.
// So we can put it in a separate `util.zig` or `request_utils.zig`?
// Or just keep it in `instance.zig`? Request is defined in `io`.
// `freeInstance` iterates `pending_requests` and calls `finalizeBounceBuffer`.
// So it must be available to `instance.zig`.
// Let's keep `finalizeBounceBuffer` in `instance.zig` for now, or `request.zig` if we can avoid cycle.
// If I put `finalizeBounceBuffer` in `instance.zig`, then `processPendingRequests` (in `request.zig`) can call it.
// `request.zig` imports `instance.zig`. This works.

/// io_uring instance state with shared memory rings
pub const IoUringInstance = struct {
    // =========================================================================
    // Shared Memory Rings (physical pages mapped via HHDM)
    // =========================================================================

    /// SQ ring physical address (for mmap)
    sq_ring_phys: u64,
    /// SQ ring size in bytes
    sq_ring_size: usize,
    /// SQ ring kernel virtual address (via HHDM)
    sq_ring_virt: u64,

    /// CQ ring physical address
    cq_ring_phys: u64,
    /// CQ ring size in bytes
    cq_ring_size: usize,
    /// CQ ring kernel virtual address
    cq_ring_virt: u64,

    /// SQE array physical address
    sqes_phys: u64,
    /// SQE array size in bytes
    sqes_size: usize,
    /// SQE array kernel virtual address
    sqes_virt: u64,

    /// Ring configuration
    sq_ring_entries: u32,
    cq_ring_entries: u32,

    /// Pending IoRequests for this ring
    pending_requests: [types.MAX_RING_ENTRIES]*io.IoRequest,
    pending_count: u32,

    /// Thread waiting for completions (for sched.block() wakeup)
    waiting_thread: ?*Thread,

    /// Minimum completions needed to wake waiting thread
    min_complete: u32,

    /// Setup flags
    flags: u32,

    /// Allocated flag
    allocated: bool,

    pub fn init() IoUringInstance {
        return .{
            .sq_ring_phys = 0,
            .sq_ring_size = 0,
            .sq_ring_virt = 0,
            .cq_ring_phys = 0,
            .cq_ring_size = 0,
            .cq_ring_virt = 0,
            .sqes_phys = 0,
            .sqes_size = 0,
            .sqes_virt = 0,
            .sq_ring_entries = 0,
            .cq_ring_entries = 0,
            // SAFETY INVARIANT: pending_requests[0..pending_count] are always valid.
            // pending_count is only modified by addPendingRequest() which bounds-checks,
            // and freeInstance() only iterates 0..pending_count. The undefined portion
            // is never accessed. Using undefined here avoids zeroing MAX_RING_ENTRIES
            // pointers on every instance creation.
            .pending_requests = undefined,
            .pending_count = 0,
            .waiting_thread = null,
            .min_complete = 0,
            .flags = 0,
            .allocated = false,
        };
    }

    /// Get SQ ring header via HHDM
    pub fn getSqRing(self: *const IoUringInstance) *volatile types.SqRingHeader {
        return @ptrFromInt(self.sq_ring_virt);
    }

    /// Get CQ ring header via HHDM
    pub fn getCqRing(self: *const IoUringInstance) *volatile types.CqRingHeader {
        return @ptrFromInt(self.cq_ring_virt);
    }

    /// Get SQE array via HHDM
    pub fn getSqes(self: *const IoUringInstance) [*]volatile io_ring.IoUringSqe {
        return @ptrFromInt(self.sqes_virt);
    }

    /// Get CQE array (follows CQ ring header)
    pub fn getCqes(self: *const IoUringInstance) [*]volatile io_ring.IoUringCqe {
        const cq_header_size = @sizeOf(types.CqRingHeader);
        const cqes_offset = std.mem.alignForward(usize, cq_header_size, 16);
        return @ptrFromInt(self.cq_ring_virt + cqes_offset);
    }

    /// Get SQ index array (follows SQ ring header)
    pub fn getSqArray(self: *const IoUringInstance) [*]volatile u32 {
        const sq_header_size = @sizeOf(types.SqRingHeader);
        const array_offset = std.mem.alignForward(usize, sq_header_size, 4);
        return @ptrFromInt(self.sq_ring_virt + array_offset);
    }

    /// Get number of SQEs ready to submit
    pub fn sqReady(self: *const IoUringInstance) u32 {
        return ring.sqReady(self.getSqRing());
    }

    /// Get number of CQEs ready to consume
    pub fn cqReady(self: *const IoUringInstance) u32 {
        return ring.cqReady(self.getCqRing());
    }

    /// Check if CQ has space for more completions
    pub fn cqHasSpace(self: *const IoUringInstance) bool {
        return ring.cqHasSpace(self.getCqRing(), self.cq_ring_entries);
    }

    /// Add a CQE to the completion queue
    pub fn addCqe(self: *IoUringInstance, user_data: u64, res: i32, cqe_flags: u32) bool {
        return ring.addCqe(self.getCqRing(), self.getCqes(), self.cq_ring_entries, user_data, res, cqe_flags);
    }

    /// Add a request to the pending list with proper io_ring association
    /// Returns false if pending list is full
    pub fn addPendingRequest(self: *IoUringInstance, req: *io.IoRequest) bool {
        if (self.pending_count >= types.MAX_RING_ENTRIES) {
            return false;
        }

        // Associate request with this io_uring instance for CQE posting
        req.io_ring = @ptrCast(self);

        self.pending_requests[self.pending_count] = req;
        self.pending_count += 1;
        return true;
    }
    
    pub fn finalizeBounceBuffer(req: *io.IoRequest) void {
        if (req.bounce_buf) |buf| {
            // Copy bounce buffer data back to user for read operations
            const is_read_op = req.op == .socket_read or req.op == .keyboard_read;
            if (is_read_op and req.user_buf_ptr != 0) {
                switch (req.result) {
                    .success => |n| {
                        const copy_len = @min(n, @min(buf.len, req.user_buf_len));
                        if (copy_len > 0) {
                            const uptr = user_mem.UserPtr.from(req.user_buf_ptr);
                            _ = uptr.copyFromKernel(buf[0..copy_len]) catch {
                                req.result = .{ .err = error.EFAULT };
                            };
                        }
                    },
                    else => {},
                }
            }

            heap.allocator().free(buf);
            req.bounce_buf = null;
        }
    }
};

// =============================================================================
// Instance Pool
// =============================================================================

/// Global pool of io_uring instances
/// SAFETY: instances_initialized guards access; initInstances() properly initializes
/// each instance before any use. The undefined initialization is safe because
/// all code paths check instances_initialized or call initInstances() first.
var instances: [types.MAX_RINGS_PER_PROCESS * 16]IoUringInstance = undefined;
var instances_initialized: bool = false;

/// SECURITY: Pool lock to prevent concurrent allocInstance/freeInstance races.
/// Without this lock, two concurrent allocInstance calls could both see the same
/// instance as unallocated and return it to different processes.
/// Using atomic spinlock pattern directly since sync module not in dependencies.
var pool_lock: std.atomic.Value(u32) = .{ .raw = 0 };

/// Lock state returned by acquirePoolLock, passed to releasePoolLock
const LockState = struct { irq_state: bool };

/// Acquire the pool lock (IRQ-safe spinlock pattern)
fn acquirePoolLock() LockState {
    const irq_state = hal.cpu.interruptsEnabled();
    hal.cpu.disableInterrupts();
    while (pool_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        hal.cpu.pause();
    }
    return .{ .irq_state = irq_state };
}

/// Release the pool lock
fn releasePoolLock(state: LockState) void {
    pool_lock.store(0, .release);
    if (state.irq_state) hal.cpu.enableInterrupts();
}

fn initInstances() void {
    if (instances_initialized) return;

    for (&instances) |*inst| {
        inst.* = IoUringInstance.init();
    }
    instances_initialized = true;
}

/// Allocate physical pages for io_uring shared memory rings
pub fn allocInstance(entries: u32) ?struct { idx: usize, instance: *IoUringInstance } {
    initInstances();

    // SECURITY: Acquire pool lock to prevent concurrent allocation of same instance
    const lock_state = acquirePoolLock();
    defer releasePoolLock(lock_state);

    for (&instances, 0..) |*inst, idx| {
        if (!inst.allocated) {
            inst.allocated = true;
            inst.sq_ring_entries = entries;
            inst.cq_ring_entries = entries * 2; // CQ is typically 2x SQ

            // Calculate sizes for each ring region
            // SQ ring: header + u32[entries] array
            const sq_header_size = @sizeOf(types.SqRingHeader);
            const sq_array_size = entries * @sizeOf(u32);
            inst.sq_ring_size = std.mem.alignForward(usize, sq_header_size + sq_array_size, pmm.PAGE_SIZE);

            // CQ ring: header + CQE[entries*2] array
            const cq_header_size = @sizeOf(types.CqRingHeader);
            const cq_entries_size = (entries * 2) * @sizeOf(io_ring.IoUringCqe);
            inst.cq_ring_size = std.mem.alignForward(usize, cq_header_size + cq_entries_size, pmm.PAGE_SIZE);

            // SQE array: SQE[entries]
            inst.sqes_size = std.mem.alignForward(usize, entries * @sizeOf(io_ring.IoUringSqe), pmm.PAGE_SIZE);

            // Allocate physical pages for SQ ring
            const sq_pages: u32 = @intCast(inst.sq_ring_size / pmm.PAGE_SIZE);
            inst.sq_ring_phys = pmm.allocZeroedPages(sq_pages) orelse {
                inst.allocated = false;
                return null;
            };
            inst.sq_ring_virt = @intFromPtr(hal.paging.physToVirt(inst.sq_ring_phys));

            // Allocate physical pages for CQ ring
            const cq_pages: u32 = @intCast(inst.cq_ring_size / pmm.PAGE_SIZE);
            inst.cq_ring_phys = pmm.allocZeroedPages(cq_pages) orelse {
                pmm.freePages(inst.sq_ring_phys, sq_pages);
                inst.allocated = false;
                return null;
            };
            inst.cq_ring_virt = @intFromPtr(hal.paging.physToVirt(inst.cq_ring_phys));

            // Allocate physical pages for SQE array
            const sqe_pages: u32 = @intCast(inst.sqes_size / pmm.PAGE_SIZE);
            inst.sqes_phys = pmm.allocZeroedPages(sqe_pages) orelse {
                pmm.freePages(inst.sq_ring_phys, sq_pages);
                pmm.freePages(inst.cq_ring_phys, cq_pages);
                inst.allocated = false;
                return null;
            };
            inst.sqes_virt = @intFromPtr(hal.paging.physToVirt(inst.sqes_phys));

            // Initialize ring headers
            const sq_ring = inst.getSqRing();
            sq_ring.head = 0;
            sq_ring.tail = 0;
            sq_ring.ring_mask = entries - 1;
            sq_ring.ring_entries = entries;
            sq_ring.flags = 0;
            sq_ring.dropped = 0;

            const cq_ring = inst.getCqRing();
            cq_ring.head = 0;
            cq_ring.tail = 0;
            cq_ring.ring_mask = (entries * 2) - 1;
            cq_ring.ring_entries = entries * 2;
            cq_ring.overflow = 0;

            return .{ .idx = idx, .instance = inst };
        }
    }
    return null;
}

pub fn freeInstance(idx: usize) void {
    if (idx >= instances.len) return;

    // SECURITY: Acquire pool lock to prevent concurrent free/alloc races
    const lock_state = acquirePoolLock();
    defer releasePoolLock(lock_state);

    var inst = &instances[idx];
    if (!inst.allocated) return;

    // Free any pending requests
    for (0..inst.pending_count) |i| {
        IoUringInstance.finalizeBounceBuffer(inst.pending_requests[i]);
        io.freeRequest(inst.pending_requests[i]);
    }

    // Free physical pages
    if (inst.sq_ring_phys != 0) {
        const sq_pages: u32 = @intCast(inst.sq_ring_size / pmm.PAGE_SIZE);
        pmm.freePages(inst.sq_ring_phys, sq_pages);
    }
    if (inst.cq_ring_phys != 0) {
        const cq_pages: u32 = @intCast(inst.cq_ring_size / pmm.PAGE_SIZE);
        pmm.freePages(inst.cq_ring_phys, cq_pages);
    }
    if (inst.sqes_phys != 0) {
        const sqe_pages: u32 = @intCast(inst.sqes_size / pmm.PAGE_SIZE);
        pmm.freePages(inst.sqes_phys, sqe_pages);
    }

    inst.* = IoUringInstance.init();
}

pub fn getInstance(idx: usize) ?*IoUringInstance {
    if (idx >= instances.len) return null;
    const inst = &instances[idx];
    if (!inst.allocated) return null;
    return inst;
}
