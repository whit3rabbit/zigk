// io_uring Syscall Handlers
//
// Implements Linux-compatible io_uring syscalls for async I/O.
// Translates io_uring SQEs to internal IoRequest operations.
//
// Syscalls:
//   - sys_io_uring_setup (425): Create io_uring instance
//   - sys_io_uring_enter (426): Submit SQEs and/or wait for CQEs
//   - sys_io_uring_register (427): Register resources
//
// Design:
//   - Per-process io_uring instances (tracked via file descriptors)
//   - SQE -> IoRequest translation in sys_io_uring_enter
//   - CQE generation on IoRequest completion
//   - Supports blocking and non-blocking modes

const std = @import("std");
const uapi = @import("uapi");
const io_ring = uapi.io_ring;
const SyscallError = uapi.errno.SyscallError;
const io = @import("io");
const user_mem = @import("user_mem");
const fd_mod = @import("fd");
const sched = @import("sched");
const thread_mod = @import("thread");
const Thread = thread_mod.Thread;
const hal = @import("hal");
const heap = @import("heap");
const pmm = @import("pmm");
const base = @import("base.zig");
const net = @import("net");
const socket = net.transport.socket;
const pipe_mod = @import("pipe");
const keyboard = @import("keyboard");

// =============================================================================
// IoUring Instance
// =============================================================================

/// Maximum io_uring instances per process
const MAX_RINGS_PER_PROCESS: usize = 4;

/// Maximum SQ/CQ entries (must be power of 2)
const MAX_RING_ENTRIES: u32 = 256;
const MIN_RING_ENTRIES: u32 = 1;

/// SQ ring header layout (at start of sq_ring page)
const SqRingHeader = extern struct {
    head: u32, // Consumer index (kernel reads)
    tail: u32, // Producer index (user writes)
    ring_mask: u32, // entries - 1
    ring_entries: u32, // Number of entries
    flags: u32,
    dropped: u32,
    // Followed by u32[entries] array of SQE indices
};

/// CQ ring header layout (at start of cq_ring page)
const CqRingHeader = extern struct {
    head: u32, // Consumer index (user reads)
    tail: u32, // Producer index (kernel writes)
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    // Followed by CQE[entries] array
};

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
    pending_requests: [MAX_RING_ENTRIES]*io.IoRequest,
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
            .pending_requests = undefined,
            .pending_count = 0,
            .waiting_thread = null,
            .min_complete = 0,
            .flags = 0,
            .allocated = false,
        };
    }

    /// Get SQ ring header via HHDM
    fn getSqRing(self: *const IoUringInstance) *volatile SqRingHeader {
        return @ptrFromInt(self.sq_ring_virt);
    }

    /// Get CQ ring header via HHDM
    fn getCqRing(self: *const IoUringInstance) *volatile CqRingHeader {
        return @ptrFromInt(self.cq_ring_virt);
    }

    /// Get SQE array via HHDM
    fn getSqes(self: *const IoUringInstance) [*]volatile io_ring.IoUringSqe {
        return @ptrFromInt(self.sqes_virt);
    }

    /// Get CQE array (follows CQ ring header)
    fn getCqes(self: *const IoUringInstance) [*]volatile io_ring.IoUringCqe {
        const cq_header_size = @sizeOf(CqRingHeader);
        const cqes_offset = std.mem.alignForward(usize, cq_header_size, 16);
        return @ptrFromInt(self.cq_ring_virt + cqes_offset);
    }

    /// Get SQ index array (follows SQ ring header)
    fn getSqArray(self: *const IoUringInstance) [*]volatile u32 {
        const sq_header_size = @sizeOf(SqRingHeader);
        const array_offset = std.mem.alignForward(usize, sq_header_size, 4);
        return @ptrFromInt(self.sq_ring_virt + array_offset);
    }

    /// Get number of SQEs ready to submit (reads from shared memory)
    pub fn sqReady(self: *const IoUringInstance) u32 {
        const ring = self.getSqRing();
        return ring.tail -% ring.head;
    }

    /// Get number of CQEs ready to consume (reads from shared memory)
    pub fn cqReady(self: *const IoUringInstance) u32 {
        const ring = self.getCqRing();
        return ring.tail -% ring.head;
    }

    /// Check if CQ has space for more completions
    pub fn cqHasSpace(self: *const IoUringInstance) bool {
        return self.cqReady() < self.cq_ring_entries;
    }

    /// Add a CQE to the completion queue (writes to shared memory)
    pub fn addCqe(self: *IoUringInstance, user_data: u64, res: i32, cqe_flags: u32) bool {
        if (!self.cqHasSpace()) {
            return false;
        }

        const ring = self.getCqRing();
        const cqes = self.getCqes();
        const idx = ring.tail & (self.cq_ring_entries - 1);

        // Write CQE to shared memory
        cqes[idx] = .{
            .user_data = user_data,
            .res = res,
            .flags = cqe_flags,
        };

        // Memory barrier before updating tail
        asm volatile ("mfence" ::: .{ .memory = true });

        ring.tail +%= 1;
        return true;
    }

    fn finalizeBounceBuffer(req: *io.IoRequest) void {
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

    /// Process pending requests and generate CQEs for completed ones
    pub fn processPendingRequests(self: *IoUringInstance) u32 {
        var completed: u32 = 0;
        var i: u32 = 0;

        while (i < self.pending_count) {
            const req = self.pending_requests[i];
            const state = req.getState();

            if (state == .completed or state == .cancelled) {
                finalizeBounceBuffer(req);

                // Generate CQE
                const res: i32 = switch (req.result) {
                    .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
                    .err => @intCast(req.result.toSyscallReturn()),
                    .cancelled => -@as(i32, 125), // ECANCELED
                    .pending => 0,
                };

                if (self.addCqe(req.user_data, res, 0)) {
                    completed += 1;
                }

                // Free the request
                io.pool.free(req);

                // Remove from pending list (swap with last)
                self.pending_count -= 1;
                if (i < self.pending_count) {
                    self.pending_requests[i] = self.pending_requests[self.pending_count];
                }
                // Don't increment i - we swapped in a new element
            } else {
                i += 1;
            }
        }

        // Wake waiting thread if we have enough completions
        if (completed > 0) {
            if (self.waiting_thread) |thread| {
                if (self.cqReady() >= self.min_complete) {
                    sched.unblock(thread);
                }
            }
        }

        return completed;
    }

    /// Add a request to the pending list with proper io_ring association
    /// Returns false if pending list is full
    pub fn addPendingRequest(self: *IoUringInstance, req: *io.IoRequest) bool {
        if (self.pending_count >= MAX_RING_ENTRIES) {
            return false;
        }

        // Associate request with this io_uring instance for CQE posting
        req.io_ring = @ptrCast(self);

        self.pending_requests[self.pending_count] = req;
        self.pending_count += 1;
        return true;
    }
};

// =============================================================================
// File Descriptor Integration
// =============================================================================

const IoUringFdData = struct {
    instance_idx: usize,
};

const io_uring_file_ops = fd_mod.FileOps{
    .read = null,
    .write = null,
    .close = ioUringClose,
    .seek = null,
    .stat = null,
    .ioctl = null,
    .mmap = ioUringMmap,
    .poll = null,
};

fn ioUringClose(fd: *fd_mod.FileDescriptor) isize {
    const data = getIoUringData(fd) orelse return 0;
    freeInstance(data.instance_idx);

    // Free the fd data
    if (fd.private_data) |ptr| {
        const allocator = heap.getKernelAllocator();
        const data_ptr: *IoUringFdData = @ptrCast(@alignCast(ptr));
        allocator.destroy(data_ptr);
    }
    return 0;
}

/// mmap handler for io_uring - returns physical address of ring region
/// offset determines which ring to map:
///   IORING_OFF_SQ_RING (0x0) - SQ ring header and index array
///   IORING_OFF_CQ_RING (0x8000000) - CQ ring header and CQE array
///   IORING_OFF_SQES (0x10000000) - SQE array
fn ioUringMmap(fd: *fd_mod.FileDescriptor, offset: u64, size: *usize) u64 {
    const data = getIoUringData(fd) orelse return 0;
    const inst = getInstance(data.instance_idx) orelse return 0;

    switch (offset) {
        io_ring.IORING_OFF_SQ_RING => {
            size.* = inst.sq_ring_size;
            return inst.sq_ring_phys;
        },
        io_ring.IORING_OFF_CQ_RING => {
            size.* = inst.cq_ring_size;
            return inst.cq_ring_phys;
        },
        io_ring.IORING_OFF_SQES => {
            size.* = inst.sqes_size;
            return inst.sqes_phys;
        },
        else => return 0,
    }
}

fn getIoUringData(fd: *fd_mod.FileDescriptor) ?*IoUringFdData {
    if (fd.ops != &io_uring_file_ops) {
        return null;
    }
    const data_ptr = fd.private_data orelse return null;
    return @ptrCast(@alignCast(data_ptr));
}

// =============================================================================
// Instance Pool
// =============================================================================

/// Global pool of io_uring instances
var instances: [MAX_RINGS_PER_PROCESS * 16]IoUringInstance = undefined;
var instances_initialized: bool = false;

fn initInstances() void {
    if (instances_initialized) return;

    for (&instances) |*inst| {
        inst.* = IoUringInstance.init();
    }
    instances_initialized = true;
}

/// Allocate physical pages for io_uring shared memory rings
fn allocInstance(entries: u32) ?struct { idx: usize, instance: *IoUringInstance } {
    initInstances();

    for (&instances, 0..) |*inst, idx| {
        if (!inst.allocated) {
            inst.allocated = true;
            inst.sq_ring_entries = entries;
            inst.cq_ring_entries = entries * 2; // CQ is typically 2x SQ

            // Calculate sizes for each ring region
            // SQ ring: header + u32[entries] array
            const sq_header_size = @sizeOf(SqRingHeader);
            const sq_array_size = entries * @sizeOf(u32);
            inst.sq_ring_size = std.mem.alignForward(usize, sq_header_size + sq_array_size, pmm.PAGE_SIZE);

            // CQ ring: header + CQE[entries*2] array
            const cq_header_size = @sizeOf(CqRingHeader);
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
            inst.sq_ring_virt = pmm.physToVirt(inst.sq_ring_phys);

            // Allocate physical pages for CQ ring
            const cq_pages: u32 = @intCast(inst.cq_ring_size / pmm.PAGE_SIZE);
            inst.cq_ring_phys = pmm.allocZeroedPages(cq_pages) orelse {
                pmm.freePages(inst.sq_ring_phys, sq_pages);
                inst.allocated = false;
                return null;
            };
            inst.cq_ring_virt = pmm.physToVirt(inst.cq_ring_phys);

            // Allocate physical pages for SQE array
            const sqe_pages: u32 = @intCast(inst.sqes_size / pmm.PAGE_SIZE);
            inst.sqes_phys = pmm.allocZeroedPages(sqe_pages) orelse {
                pmm.freePages(inst.sq_ring_phys, sq_pages);
                pmm.freePages(inst.cq_ring_phys, cq_pages);
                inst.allocated = false;
                return null;
            };
            inst.sqes_virt = pmm.physToVirt(inst.sqes_phys);

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

fn freeInstance(idx: usize) void {
    if (idx >= instances.len) return;

    var inst = &instances[idx];
    if (!inst.allocated) return;

    // Free any pending requests
    for (0..inst.pending_count) |i| {
        IoUringInstance.finalizeBounceBuffer(inst.pending_requests[i]);
        io.pool.free(inst.pending_requests[i]);
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

fn getInstance(idx: usize) ?*IoUringInstance {
    if (idx >= instances.len) return null;
    const inst = &instances[idx];
    if (!inst.allocated) return null;
    return inst;
}

// =============================================================================
// Syscall Handlers
// =============================================================================

/// sys_io_uring_setup (425)
///
/// Create a new io_uring instance.
///
/// Arguments:
///   entries: Number of SQ entries (must be power of 2, 1-256)
///   params_ptr: Pointer to IoUringParams structure (in/out)
///
/// Returns: File descriptor for the io_uring on success
pub fn sys_io_uring_setup(entries: usize, params_ptr: usize) SyscallError!usize {
    // Validate entries count
    if (entries < MIN_RING_ENTRIES or entries > MAX_RING_ENTRIES) {
        return error.EINVAL;
    }

    // Must be power of 2
    const entries_u32: u32 = @intCast(entries);
    if (entries_u32 & (entries_u32 - 1) != 0) {
        return error.EINVAL;
    }

    // Validate and read params
    if (!user_mem.isValidUserAccess(params_ptr, @sizeOf(io_ring.IoUringParams), .write)) {
        return error.EFAULT;
    }

    var params: io_ring.IoUringParams = undefined;
    user_mem.copyFromUser(io_ring.IoUringParams, params_ptr) catch return error.EFAULT;

    // Check for unsupported flags
    const supported_flags = io_ring.IORING_SETUP_CQSIZE | io_ring.IORING_SETUP_CLAMP;
    if (params.flags & ~supported_flags != 0) {
        return error.EINVAL;
    }

    // Allocate instance
    const alloc_result = allocInstance(entries_u32) orelse return error.ENOMEM;

    // Set up params output
    params.sq_entries = entries_u32;
    params.cq_entries = entries_u32 * 2;
    params.features = io_ring.IORING_FEAT_NODROP;

    // SQ offsets (simplified - in real Linux these point into mmap region)
    params.sq_off = .{
        .head = 0,
        .tail = 4,
        .ring_mask = 8,
        .ring_entries = 12,
        .flags = 16,
        .dropped = 20,
        .array = 24,
        ._resv1 = 0,
        ._resv2 = 0,
    };

    // CQ offsets
    params.cq_off = .{
        .head = 0,
        .tail = 4,
        .ring_mask = 8,
        .ring_entries = 12,
        .overflow = 16,
        .cqes = 20,
        .flags = 24,
        ._resv1 = 0,
        ._resv2 = 0,
    };

    // Copy params back to user
    user_mem.copyToUser(io_ring.IoUringParams, params_ptr, params) catch {
        freeInstance(alloc_result.idx);
        return error.EFAULT;
    };

    // Create file descriptor
    const fd_table = base.getGlobalFdTable();

    const allocator = heap.getKernelAllocator();
    const fd_data = allocator.create(IoUringFdData) catch {
        freeInstance(alloc_result.idx);
        return error.ENOMEM;
    };
    fd_data.instance_idx = alloc_result.idx;

    const fd_num = fd_table.allocate() orelse {
        allocator.destroy(fd_data);
        freeInstance(alloc_result.idx);
        return error.EMFILE;
    };

    const fd = fd_table.get(fd_num) orelse {
        fd_table.free(fd_num);
        allocator.destroy(fd_data);
        freeInstance(alloc_result.idx);
        return error.EBADF;
    };

    fd.ops = &io_uring_file_ops;
    fd.private_data = fd_data;
    fd.flags = 0;

    return fd_num;
}

/// sys_io_uring_enter (426)
///
/// Submit SQEs and/or wait for CQEs.
///
/// Two modes of operation:
///   1. Shared memory mode (Linux compatible): sqes_ptr=0, cqes_ptr=0
///      - Reads SQEs from mmap'd shared memory
///      - CQEs are available in mmap'd shared memory after return
///   2. Copy mode (legacy): sqes_ptr/cqes_ptr provided
///      - Copies SQEs from userspace pointer
///      - Copies CQEs to userspace pointer
///
/// Arguments:
///   ring_fd: File descriptor from io_uring_setup
///   to_submit: Number of SQEs to submit
///   min_complete: Minimum CQEs to wait for (if GETEVENTS)
///   flags: IORING_ENTER_* flags
///   sqes_ptr: Pointer to userspace SQE array (0 for shared memory mode)
///   cqes_ptr: Pointer to userspace CQE array (0 for shared memory mode)
///
/// Returns: Number of SQEs submitted (or CQEs ready if only GETEVENTS in shared mode)
pub fn sys_io_uring_enter(
    ring_fd: usize,
    to_submit: usize,
    min_complete: usize,
    flags: usize,
    sqes_ptr: usize,
    cqes_ptr: usize,
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    const data = getIoUringData(fd) orelse return error.EBADF;
    const inst = getInstance(data.instance_idx) orelse return error.EBADF;

    var submitted: usize = 0;

    // Submit SQEs
    if (to_submit > 0) {
        if (sqes_ptr != 0) {
            // Legacy copy mode: copy SQEs from userspace
            submitted = try copySqesAndSubmit(inst, sqes_ptr, to_submit);
        } else {
            // Shared memory mode: read SQEs from mmap'd ring
            submitted = try submitFromSharedMemory(inst, to_submit);
        }
    }

    // Wait for completions if requested
    if (flags & io_ring.IORING_ENTER_GETEVENTS != 0) {
        waitForCompletions(inst, @intCast(min_complete));

        if (cqes_ptr != 0 and min_complete > 0) {
            // Legacy mode: copy CQEs to userspace
            const copied = try copyCompletionsToUser(inst, cqes_ptr, min_complete);
            if (to_submit == 0) {
                return copied;
            }
        } else {
            // Shared memory mode: CQEs already in shared memory
            // Return count of ready CQEs
            if (to_submit == 0) {
                return inst.cqReady();
            }
        }
    }

    return submitted;
}

/// Submit SQEs from shared memory ring
fn submitFromSharedMemory(inst: *IoUringInstance, to_submit: usize) SyscallError!usize {
    const sq_ring = inst.getSqRing();
    const sq_array = inst.getSqArray();
    const sqes = inst.getSqes();

    // Memory barrier before reading indices
    asm volatile ("lfence" ::: .{ .memory = true });

    var submitted: usize = 0;
    var head = sq_ring.head;
    const tail = sq_ring.tail;

    while (submitted < to_submit and head != tail) {
        const idx = head & (inst.sq_ring_entries - 1);

        // SQ array contains indices into SQE array
        const sqe_idx = sq_array[idx] & (inst.sq_ring_entries - 1);
        const sqe = &sqes[sqe_idx];

        // Process the SQE (read from shared memory)
        const result = processSqe(inst, sqe);
        if (result) |_| {
            submitted += 1;
        } else |_| {
            // On error, generate immediate CQE with EINVAL
            _ = inst.addCqe(sqe.user_data, -@as(i32, 22), 0);
            submitted += 1;
        }

        head +%= 1;
    }

    // Update SQ head (kernel consumed these entries)
    sq_ring.head = head;

    // Memory barrier after updating head
    asm volatile ("sfence" ::: .{ .memory = true });

    return submitted;
}

/// sys_io_uring_register (427)
///
/// Register resources with an io_uring instance.
///
/// Arguments:
///   ring_fd: File descriptor from io_uring_setup
///   opcode: Registration operation
///   arg: Operation-specific argument
///   nr_args: Number of arguments
///
/// Returns: 0 on success
pub fn sys_io_uring_register(
    ring_fd: usize,
    opcode: usize,
    arg: usize,
    nr_args: usize,
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getGlobalFdTable();
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    _ = getIoUringData(fd) orelse return error.EBADF;

    // Handle registration operations
    switch (opcode) {
        io_ring.IORING_REGISTER_PROBE => {
            return registerProbe(arg, nr_args);
        },

        // Unsupported operations return ENOSYS
        io_ring.IORING_REGISTER_BUFFERS,
        io_ring.IORING_UNREGISTER_BUFFERS,
        io_ring.IORING_REGISTER_FILES,
        io_ring.IORING_UNREGISTER_FILES,
        => {
            return error.ENOSYS;
        },

        else => {
            return error.EINVAL;
        },
    }
}

/// Handle IORING_REGISTER_PROBE - report supported operations
fn registerProbe(arg: usize, nr_ops: usize) SyscallError!usize {
    if (arg == 0) {
        return error.EFAULT;
    }

    // Validate user buffer for probe header
    if (!user_mem.isValidUserAccess(arg, @sizeOf(io_ring.IoUringProbe), .Write)) {
        return error.EFAULT;
    }

    // Supported opcodes in this implementation
    const supported_ops = [_]u8{
        io_ring.IORING_OP_NOP,
        io_ring.IORING_OP_READ,
        io_ring.IORING_OP_WRITE,
        io_ring.IORING_OP_ACCEPT,
        io_ring.IORING_OP_CONNECT,
        io_ring.IORING_OP_RECV,
        io_ring.IORING_OP_SEND,
        io_ring.IORING_OP_TIMEOUT,
        io_ring.IORING_OP_OPENAT,
        io_ring.IORING_OP_CLOSE,
        io_ring.IORING_OP_ASYNC_CANCEL,
    };

    // Find the last supported opcode
    var last_op: u8 = 0;
    for (supported_ops) |op| {
        if (op > last_op) last_op = op;
    }

    // Create probe header
    const ops_to_report = @min(nr_ops, io_ring.IORING_OP_LAST);
    const probe = io_ring.IoUringProbe{
        .last_op = last_op,
        .ops_len = @intCast(ops_to_report),
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };

    // Write probe header to userspace
    const user_ptr = user_mem.UserPtr.from(arg);
    user_mem.copyStructToUser(io_ring.IoUringProbe, user_ptr, probe) catch {
        return error.EFAULT;
    };

    // Write per-op probe entries if space provided
    if (nr_ops > 0) {
        const ops_ptr = arg + @sizeOf(io_ring.IoUringProbe);
        const ops_size = ops_to_report * @sizeOf(io_ring.IoUringProbeOp);

        if (!user_mem.isValidUserAccess(ops_ptr, ops_size, .Write)) {
            return error.EFAULT;
        }

        // Write each op entry
        for (0..ops_to_report) |i| {
            const op: u8 = @intCast(i);
            var op_entry = io_ring.IoUringProbeOp{
                .op = op,
                .resv = 0,
                .flags = 0,
                .resv2 = 0,
            };

            // Check if this op is supported
            for (supported_ops) |supported| {
                if (supported == op) {
                    op_entry.flags = io_ring.IO_URING_OP_SUPPORTED;
                    break;
                }
            }

            const entry_ptr = user_mem.UserPtr.from(ops_ptr + i * @sizeOf(io_ring.IoUringProbeOp));
            user_mem.copyStructToUser(io_ring.IoUringProbeOp, entry_ptr, op_entry) catch {
                return error.EFAULT;
            };
        }
    }

    return 0;
}

// =============================================================================
// SQE/CQE Copy Operations (Copy-Based Ring Model)
// =============================================================================

/// Copy SQEs from userspace and process them.
/// This is the key fix for the copy-based ring model - SQEs MUST be copied from
/// userspace before processing.
fn copySqesAndSubmit(inst: *IoUringInstance, sqes_ptr: usize, count: usize) SyscallError!usize {
    if (sqes_ptr == 0) {
        return error.EFAULT;
    }

    // Limit to ring size
    const copy_count = @min(count, inst.sq_ring_entries);
    const sqe_size = @sizeOf(io_ring.IoUringSqe);

    // Validate entire user buffer
    if (!user_mem.isValidUserAccess(sqes_ptr, copy_count * sqe_size, .Read)) {
        return error.EFAULT;
    }

    var submitted: usize = 0;

    // Copy and process each SQE
    for (0..copy_count) |i| {
        const src_addr = sqes_ptr + i * sqe_size;
        const user_ptr = user_mem.UserPtr.from(src_addr);

        // Copy SQE from userspace
        const sqe = user_mem.copyStructFromUser(io_ring.IoUringSqe, user_ptr) catch {
            return error.EFAULT;
        };

        // Process the SQE
        const result = processSqe(inst, &sqe);
        if (result) |_| {
            submitted += 1;
        } else |_| {
            // On error, generate immediate CQE with EINVAL
            _ = inst.addCqe(sqe.user_data, -@as(i32, 22), 0);
            submitted += 1;
        }
    }

    return submitted;
}

/// Copy CQEs to userspace after completions.
/// This is the key fix - CQEs MUST be copied back to userspace for the user to read them.
fn copyCompletionsToUser(inst: *IoUringInstance, cqes_ptr: usize, max_cqes: usize) SyscallError!usize {
    if (cqes_ptr == 0) {
        return 0;
    }

    const ready = inst.cqReady();
    const copy_count = @min(ready, max_cqes);
    const cqe_size = @sizeOf(io_ring.IoUringCqe);

    if (copy_count == 0) {
        return 0;
    }

    // Validate entire user buffer
    if (!user_mem.isValidUserAccess(cqes_ptr, copy_count * cqe_size, .Write)) {
        return error.EFAULT;
    }

    // Access CQ via shared memory getters (not non-existent instance fields)
    const cq_ring = inst.getCqRing();
    const cqes = inst.getCqes();

    // Copy each CQE to userspace
    for (0..copy_count) |i| {
        const idx = cq_ring.head & (inst.cq_ring_entries - 1);
        const cqe = cqes[idx];
        const dest_addr = cqes_ptr + i * cqe_size;
        const user_ptr = user_mem.UserPtr.from(dest_addr);

        user_mem.copyStructToUser(io_ring.IoUringCqe, user_ptr, cqe) catch {
            return error.EFAULT;
        };

        cq_ring.head +%= 1;
    }

    return copy_count;
}

// =============================================================================
// SQE Processing
// =============================================================================

fn processSqe(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    switch (sqe.opcode) {
        io_ring.IORING_OP_NOP => {
            // NOP completes immediately
            _ = inst.addCqe(sqe.user_data, 0, 0);
        },

        io_ring.IORING_OP_READ => {
            try processReadOp(inst, sqe);
        },

        io_ring.IORING_OP_WRITE => {
            try processWriteOp(inst, sqe);
        },

        io_ring.IORING_OP_ACCEPT => {
            try processAcceptOp(inst, sqe);
        },

        io_ring.IORING_OP_CONNECT => {
            try processConnectOp(inst, sqe);
        },

        io_ring.IORING_OP_RECV => {
            try processRecvOp(inst, sqe);
        },

        io_ring.IORING_OP_SEND => {
            try processSendOp(inst, sqe);
        },

        io_ring.IORING_OP_TIMEOUT => {
            try processTimeoutOp(inst, sqe);
        },

        io_ring.IORING_OP_OPENAT => {
            processOpenatOp(inst, sqe);
        },

        io_ring.IORING_OP_CLOSE => {
            processCloseOp(inst, sqe);
        },

        io_ring.IORING_OP_ASYNC_CANCEL => {
            processAsyncCancelOp(inst, sqe);
        },

        else => {
            return error.EINVAL;
        },
    }
}

fn processReadOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Allocate IoRequest
    const req = io.pool.alloc(.keyboard_read) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    // SECURITY: Use bounce buffer to prevent TOCTOU race condition.
    // User could unmap/remap the buffer between validation and async completion.
    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Write, false);
    req.buf_ptr = @intFromPtr(buf.ptr);
    req.buf_len = buf.len;

    // For now, assume keyboard read for fd -1 or special fd
    // In full implementation, would dispatch based on fd type
    if (keyboard.getCharAsync(req)) {
        // Queued for later - add to pending
        if (!inst.addPendingRequest(req)) {
            IoUringInstance.finalizeBounceBuffer(req);
            io.pool.free(req);
            return error.EBUSY;
        }
    } else {
        // Completed immediately - finalize bounce buffer and generate CQE
        IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    }
}

fn processWriteOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Validate fd
    if (sqe.fd < 0) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 9), 0); // EBADF
        return;
    }

    // Validate user buffer
    if (!user_mem.isValidUserAccess(sqe.addr, sqe.len, .Read)) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 14), 0); // EFAULT
        return;
    }

    // Dispatch to sys_write implementation
    const io_syscall = @import("io.zig");
    const result = io_syscall.sys_write(@intCast(sqe.fd), sqe.addr, sqe.len);

    const res: i32 = if (result) |n|
        @intCast(@min(n, @as(usize, std.math.maxInt(i32))))
    else |e|
        -@as(i32, @intFromEnum(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

fn processAcceptOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // Get socket from fd
    const sock_fd: usize = @intCast(sqe.fd);

    // Allocate IoRequest
    const req = io.pool.alloc(.socket_accept) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;
    req.op_data.accept = .{
        .addr_ptr = sqe.addr,
        .addrlen_ptr = sqe.off,
    };

    // Try async accept
    socket.acceptAsync(sock_fd, req) catch |e| {
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        // Completed immediately
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        // Queued for later
        if (!inst.addPendingRequest(req)) {
            io.pool.free(req);
            return error.EBUSY;
        }
    }
}

fn processConnectOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.pool.alloc(.socket_connect) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;
    req.op_data.connect = .{
        .addr_ptr = sqe.addr,
        .addrlen = @intCast(sqe.len),
    };

    // Copy address from userspace
    if (!user_mem.isValidUserAccess(sqe.addr, @sizeOf(socket.types.SockAddrIn), .read)) {
        io.pool.free(req);
        return error.EFAULT;
    }

    var addr: socket.types.SockAddrIn = undefined;
    user_mem.copyFromUser(socket.types.SockAddrIn, sqe.addr) catch {
        io.pool.free(req);
        return error.EFAULT;
    };

    socket.connectAsync(sock_fd, req, &addr) catch |e| {
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        const res: i32 = switch (req.result) {
            .success => 0,
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            IoUringInstance.finalizeBounceBuffer(req);
            io.pool.free(req);
            return error.EBUSY;
        }
    }
}

fn initBounceBuffer(
    req: *io.IoRequest,
    user_ptr: usize,
    len: usize,
    mode: user_mem.AccessMode,
    copy_from_user: bool,
) SyscallError![]u8 {
    if (len == 0) {
        req.bounce_buf = null;
        req.user_buf_ptr = user_ptr;
        req.user_buf_len = 0;
        return &[_]u8{};
    }

    if (!user_mem.isValidUserAccess(user_ptr, len, mode)) {
        return error.EFAULT;
    }

    const kbuf = heap.allocator().alloc(u8, len) catch return error.ENOMEM;
    errdefer heap.allocator().free(kbuf);

    if (copy_from_user) {
        const uptr = user_mem.UserPtr.from(user_ptr);
        _ = uptr.copyToKernel(kbuf) catch {
            return error.EFAULT;
        };
    }

    req.bounce_buf = kbuf;
    req.user_buf_ptr = user_ptr;
    req.user_buf_len = len;
    return kbuf;
}

fn processRecvOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.pool.alloc(.socket_read) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Write, false);
    req.buf_ptr = @intFromPtr(buf.ptr);
    req.buf_len = buf.len;

    socket.recvAsync(sock_fd, req, buf) catch |e| {
        if (req.bounce_buf) |bounce| {
            heap.allocator().free(bounce);
            req.bounce_buf = null;
        }
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            IoUringInstance.finalizeBounceBuffer(req);
            io.pool.free(req);
            return error.EBUSY;
        }
    }
}

fn processSendOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.pool.alloc(.socket_write) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.user_data = sqe.user_data;

    const buf = try initBounceBuffer(req, sqe.addr, sqe.len, .Read, true);
    const data: []const u8 = buf;
    req.buf_ptr = @intFromPtr(data.ptr);
    req.buf_len = data.len;

    socket.sendAsync(sock_fd, req, data) catch |e| {
        if (req.bounce_buf) |bounce| {
            heap.allocator().free(bounce);
            req.bounce_buf = null;
        }
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        IoUringInstance.finalizeBounceBuffer(req);
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        if (!inst.addPendingRequest(req)) {
            io.pool.free(req);
            return error.EBUSY;
        }
    }
}

/// Kernel timespec structure for timeout operations
const KernelTimespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

fn processTimeoutOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // IORING_OP_TIMEOUT uses:
    //   - sqe.addr: pointer to struct __kernel_timespec
    //   - sqe.len: count (number of completions to wait for, 0 = pure timeout)
    //   - sqe.off: flags (IORING_TIMEOUT_ABS for absolute time)

    const req = io.pool.alloc(.timer) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.user_data = sqe.user_data;

    // Read timeout value from userspace
    if (sqe.addr != 0) {
        // SECURITY: Copy timespec to kernel stack to prevent TOCTOU.
        // Do NOT dereference user memory directly via @ptrFromInt.
        const user_ptr = user_mem.UserPtr.from(sqe.addr);
        const ts = user_ptr.readValue(KernelTimespec) catch {
            io.pool.free(req);
            return error.EFAULT;
        };

        // SECURITY: Clamp values to prevent integer overflow in multiplication.
        // Max timeout of ~1 year prevents overflow when multiplied by 1e9.
        const MAX_TIMEOUT_SEC: i64 = 86400 * 365; // ~1 year
        const MAX_NSEC: i64 = 999_999_999;

        const clamped_sec = @min(@max(0, ts.tv_sec), MAX_TIMEOUT_SEC);
        const clamped_nsec = @min(@max(0, ts.tv_nsec), MAX_NSEC);

        const timeout_ns: u64 = @as(u64, @intCast(clamped_sec)) * 1_000_000_000 +
            @as(u64, @intCast(clamped_nsec));

        // Convert nanoseconds to ticks (1ms per tick)
        const timeout_ticks = io.nsToTicks(timeout_ns);

        // Transition request to pending
        if (!req.compareAndSwapState(.idle, .pending)) {
            io.pool.free(req);
            return error.EINVAL;
        }

        // Add to reactor timer queue
        const reactor = io.getGlobal();
        reactor.addTimer(req, timeout_ticks);

        // Add to pending list for CQE generation
        if (!inst.addPendingRequest(req)) {
            _ = reactor.cancelTimer(req);
            io.pool.free(req);
            return error.EBUSY;
        }
    } else {
        // No timeout specified - complete immediately
        _ = req.complete(.{ .success = 0 });
        _ = inst.addCqe(sqe.user_data, 0, 0);
        io.pool.free(req);
    }
}

// =============================================================================
// File Operation Handlers (OPENAT, CLOSE)
// =============================================================================

fn processOpenatOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_OPENAT uses:
    //   - sqe.fd: dirfd (AT_FDCWD for cwd)
    //   - sqe.addr: pathname pointer
    //   - sqe.len: flags (O_RDONLY, O_WRONLY, etc.)
    //   - sqe.off: mode (low 32 bits)
    const result = fd_mod.sys_openat(
        @bitCast(@as(i64, sqe.fd)), // Handle negative dirfd (AT_FDCWD = -100)
        sqe.addr,
        sqe.len,
        @truncate(sqe.off),
    );

    const res: i32 = if (result) |fd|
        @intCast(@min(fd, @as(usize, std.math.maxInt(i32))))
    else |e|
        -@as(i32, @intFromEnum(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

fn processCloseOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_CLOSE uses:
    //   - sqe.fd: file descriptor to close
    if (sqe.fd < 0) {
        _ = inst.addCqe(sqe.user_data, -@as(i32, 9), 0); // EBADF
        return;
    }

    const result = fd_mod.sys_close(@intCast(sqe.fd));

    const res: i32 = if (result) |_|
        0
    else |e|
        -@as(i32, @intFromEnum(e));

    _ = inst.addCqe(sqe.user_data, res, 0);
}

// =============================================================================
// Async Cancel Handler
// =============================================================================

fn processAsyncCancelOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) void {
    // IORING_OP_ASYNC_CANCEL uses:
    //   - sqe.addr: user_data of request to cancel
    const target_user_data = sqe.addr;

    // Search pending requests for matching user_data
    for (inst.pending_requests[0..inst.pending_count]) |req| {
        if (req.user_data == target_user_data) {
            // Attempt to cancel the request
            if (req.cancel()) {
                // Successfully cancelled - CQE for cancelled request will be
                // generated by processPendingRequests()
                _ = inst.addCqe(sqe.user_data, 0, 0);
                return;
            }
        }
    }

    // No matching request found or cancel failed
    _ = inst.addCqe(sqe.user_data, -@as(i32, 2), 0); // ENOENT
}

// =============================================================================
// Completion Waiting
// =============================================================================

fn waitForCompletions(inst: *IoUringInstance, min_complete: u32) void {
    // Process any already-completed requests
    _ = inst.processPendingRequests();

    // If we have enough completions, return immediately
    if (inst.cqReady() >= min_complete) {
        return;
    }

    // Need to wait for more completions using proper blocking
    // Get current thread for wakeup registration
    const current_thread = sched.getCurrentThread() orelse {
        // No current thread context - fall back to limited spinning
        var spins: u32 = 0;
        while (inst.cqReady() < min_complete and spins < 1000) : (spins += 1) {
            _ = inst.processPendingRequests();
            hal.cpu.pause();
        }
        return;
    };

    // Register ourselves for wakeup when completions arrive
    inst.waiting_thread = current_thread;
    inst.min_complete = min_complete;

    // Block until we have enough completions
    // The completion path (processPendingRequests or IRQ handler) will wake us
    while (inst.cqReady() < min_complete) {
        // Double-check before blocking (race condition avoidance)
        _ = inst.processPendingRequests();
        if (inst.cqReady() >= min_complete) {
            break;
        }

        // Block the thread - scheduler will context switch
        // We will be woken by sched.unblock() when completions arrive
        sched.block();

        // After wakeup, process any newly completed requests
        _ = inst.processPendingRequests();
    }

    // Clear the waiting state
    inst.waiting_thread = null;
    inst.min_complete = 0;
}

// =============================================================================
// Error Conversion
// =============================================================================

fn socketErrorToSyscallError(err: socket.errors.SocketError) SyscallError {
    return switch (err) {
        socket.errors.SocketError.InvalidSocket => error.EBADF,
        socket.errors.SocketError.InvalidState => error.EINVAL,
        socket.errors.SocketError.NoBufferSpace => error.ENOMEM,
        socket.errors.SocketError.AddrInUse => error.EADDRINUSE,
        socket.errors.SocketError.AddrNotAvail => error.EADDRNOTAVAIL,
        socket.errors.SocketError.ConnectionRefused => error.ECONNREFUSED,
        socket.errors.SocketError.ConnectionReset => error.ECONNRESET,
        socket.errors.SocketError.NetworkUnreachable => error.ENETUNREACH,
        socket.errors.SocketError.HostUnreachable => error.EHOSTUNREACH,
        socket.errors.SocketError.WouldBlock => error.EAGAIN,
        socket.errors.SocketError.AlreadyConnected => error.EISCONN,
        socket.errors.SocketError.NotConnected => error.ENOTCONN,
        socket.errors.SocketError.Timeout => error.ETIMEDOUT,
        socket.errors.SocketError.ConnectionAborted => error.ECONNABORTED,
        socket.errors.SocketError.NotListening => error.EINVAL,
        socket.errors.SocketError.RoutingError => error.ENETUNREACH,
    };
}
