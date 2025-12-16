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
const hal = @import("hal");
const heap = @import("heap");
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

/// io_uring instance state
pub const IoUringInstance = struct {
    /// Submission queue entries (kernel-side copy)
    sq_entries: []io_ring.IoUringSqe,

    /// Completion queue entries (kernel-side buffer)
    cq_entries: []io_ring.IoUringCqe,

    /// SQ head/tail (shared with userspace via mmap in real Linux, here we copy)
    sq_head: u32,
    sq_tail: u32,

    /// CQ head/tail
    cq_head: u32,
    cq_tail: u32,

    /// Ring size
    sq_ring_entries: u32,
    cq_ring_entries: u32,

    /// Pending IoRequests for this ring
    pending_requests: [MAX_RING_ENTRIES]*io.IoRequest,
    pending_count: u32,

    /// Setup flags
    flags: u32,

    /// Allocated flag
    allocated: bool,

    pub fn init() IoUringInstance {
        return .{
            .sq_entries = &.{},
            .cq_entries = &.{},
            .sq_head = 0,
            .sq_tail = 0,
            .cq_head = 0,
            .cq_tail = 0,
            .sq_ring_entries = 0,
            .cq_ring_entries = 0,
            .pending_requests = undefined,
            .pending_count = 0,
            .flags = 0,
            .allocated = false,
        };
    }

    /// Get number of SQEs ready to submit
    pub fn sqReady(self: *const IoUringInstance) u32 {
        return self.sq_tail -% self.sq_head;
    }

    /// Get number of CQEs ready to consume
    pub fn cqReady(self: *const IoUringInstance) u32 {
        return self.cq_tail -% self.cq_head;
    }

    /// Check if CQ has space for more completions
    pub fn cqHasSpace(self: *const IoUringInstance) bool {
        return self.cqReady() < self.cq_ring_entries;
    }

    /// Add a CQE to the completion queue
    pub fn addCqe(self: *IoUringInstance, user_data: u64, res: i32, flags: u32) bool {
        if (!self.cqHasSpace()) {
            return false;
        }

        const idx = self.cq_tail & (self.cq_ring_entries - 1);
        self.cq_entries[idx] = .{
            .user_data = user_data,
            .res = res,
            .flags = flags,
        };
        self.cq_tail +%= 1;
        return true;
    }

    /// Process pending requests and generate CQEs for completed ones
    pub fn processPendingRequests(self: *IoUringInstance) u32 {
        var completed: u32 = 0;
        var i: u32 = 0;

        while (i < self.pending_count) {
            const req = self.pending_requests[i];
            const state = req.getState();

            if (state == .completed or state == .cancelled) {
                // Generate CQE
                const res: i32 = switch (req.result) {
                    .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
                    .err => |e| @intCast(req.result.toSyscallReturn()),
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

        return completed;
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
};

fn ioUringClose(fd: *fd_mod.FileDescriptor) void {
    const data = getIoUringData(fd) orelse return;
    freeInstance(data.instance_idx);

    // Free the fd data
    if (fd.private_data) |ptr| {
        const allocator = heap.getKernelAllocator();
        const data_ptr: *IoUringFdData = @ptrCast(@alignCast(ptr));
        allocator.destroy(data_ptr);
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

fn allocInstance(entries: u32) ?struct { idx: usize, instance: *IoUringInstance } {
    initInstances();

    for (&instances, 0..) |*inst, idx| {
        if (!inst.allocated) {
            inst.allocated = true;
            inst.sq_ring_entries = entries;
            inst.cq_ring_entries = entries * 2; // CQ is typically 2x SQ

            // Allocate entry arrays from kernel heap
            const allocator = heap.getKernelAllocator();

            inst.sq_entries = allocator.alloc(io_ring.IoUringSqe, entries) catch return null;
            inst.cq_entries = allocator.alloc(io_ring.IoUringCqe, entries * 2) catch {
                allocator.free(inst.sq_entries);
                inst.allocated = false;
                return null;
            };

            // Zero initialize
            @memset(inst.sq_entries, std.mem.zeroes(io_ring.IoUringSqe));
            @memset(inst.cq_entries, std.mem.zeroes(io_ring.IoUringCqe));

            return .{ .idx = idx, .instance = inst };
        }
    }
    return null;
}

fn freeInstance(idx: usize) void {
    if (idx >= instances.len) return;

    var inst = &instances[idx];
    if (!inst.allocated) return;

    const allocator = heap.getKernelAllocator();

    // Free any pending requests
    for (0..inst.pending_count) |i| {
        io.pool.free(inst.pending_requests[i]);
    }

    // Free entry arrays
    if (inst.sq_entries.len > 0) {
        allocator.free(inst.sq_entries);
    }
    if (inst.cq_entries.len > 0) {
        allocator.free(inst.cq_entries);
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
    const fd_table = base.getFdTable() orelse {
        freeInstance(alloc_result.idx);
        return error.EBADF;
    };

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
/// Extended interface for copy-based ring model (not true shared memory):
///   - SQEs are copied FROM userspace sqes_ptr
///   - CQEs are copied TO userspace cqes_ptr
///
/// Arguments:
///   ring_fd: File descriptor from io_uring_setup
///   to_submit: Number of SQEs to submit
///   min_complete: Minimum CQEs to wait for (if GETEVENTS), also max CQEs to copy out
///   flags: IORING_ENTER_* flags
///   sqes_ptr: Pointer to userspace SQE array (required if to_submit > 0)
///   cqes_ptr: Pointer to userspace CQE array for output (optional, for GETEVENTS)
///
/// Returns: Number of SQEs submitted (or CQEs copied if only GETEVENTS)
pub fn sys_io_uring_enter(
    ring_fd: usize,
    to_submit: usize,
    min_complete: usize,
    flags: usize,
    sqes_ptr: usize,
    cqes_ptr: usize,
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getFdTable() orelse return error.EBADF;
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    const data = getIoUringData(fd) orelse return error.EBADF;
    const inst = getInstance(data.instance_idx) orelse return error.EBADF;

    var submitted: usize = 0;

    // Copy SQEs from userspace and submit
    if (to_submit > 0) {
        submitted = try copySqesAndSubmit(inst, sqes_ptr, to_submit);
    }

    // Wait for completions if requested
    if (flags & io_ring.IORING_ENTER_GETEVENTS != 0) {
        waitForCompletions(inst, @intCast(min_complete));

        // Copy CQEs to userspace if pointer provided
        if (cqes_ptr != 0 and min_complete > 0) {
            const copied = try copyCompletionsToUser(inst, cqes_ptr, min_complete);
            // If only getting events (no submit), return CQE count
            if (to_submit == 0) {
                return copied;
            }
        }
    }

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
    _: usize, // arg - unused for now
    _: usize, // nr_args - unused for now
) SyscallError!usize {
    // Get fd and validate
    const fd_table = base.getFdTable() orelse return error.EBADF;
    const fd = fd_table.get(ring_fd) orelse return error.EBADF;
    _ = getIoUringData(fd) orelse return error.EBADF;

    // For now, we don't support any register operations
    // In a full implementation, this would handle:
    // - IORING_REGISTER_BUFFERS
    // - IORING_REGISTER_FILES
    // - etc.
    _ = opcode;

    return error.ENOSYS;
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

    // Copy each CQE to userspace
    for (0..copy_count) |i| {
        const idx = inst.cq_head & (inst.cq_ring_entries - 1);
        const cqe = inst.cq_entries[idx];
        const dest_addr = cqes_ptr + i * cqe_size;
        const user_ptr = user_mem.UserPtr.from(dest_addr);

        user_mem.copyStructToUser(io_ring.IoUringCqe, user_ptr, cqe) catch {
            return error.EFAULT;
        };

        inst.cq_head +%= 1;
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
    req.buf_ptr = sqe.addr;
    req.buf_len = sqe.len;
    req.user_data = sqe.user_data;

    // For now, assume keyboard read for fd -1 or special fd
    // In full implementation, would dispatch based on fd type
    if (keyboard.getCharAsync(req)) {
        // Queued for later - add to pending
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
    } else {
        // Completed immediately - generate CQE
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
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
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
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
    }
}

fn processRecvOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.pool.alloc(.socket_read) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.buf_ptr = sqe.addr;
    req.buf_len = sqe.len;
    req.user_data = sqe.user_data;

    // Validate buffer
    if (!user_mem.isValidUserAccess(sqe.addr, sqe.len, .write)) {
        io.pool.free(req);
        return error.EFAULT;
    }

    const buf: []u8 = @as([*]u8, @ptrFromInt(sqe.addr))[0..sqe.len];

    socket.recvAsync(sock_fd, req, buf) catch |e| {
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
    }
}

fn processSendOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    const sock_fd: usize = @intCast(sqe.fd);

    const req = io.pool.alloc(.socket_write) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.fd = sqe.fd;
    req.buf_ptr = sqe.addr;
    req.buf_len = sqe.len;
    req.user_data = sqe.user_data;

    // Validate buffer
    if (!user_mem.isValidUserAccess(sqe.addr, sqe.len, .read)) {
        io.pool.free(req);
        return error.EFAULT;
    }

    const data: []const u8 = @as([*]const u8, @ptrFromInt(sqe.addr))[0..sqe.len];

    socket.sendAsync(sock_fd, req, data) catch |e| {
        io.pool.free(req);
        return socketErrorToSyscallError(e);
    };

    const state = req.getState();
    if (state == .completed) {
        const res: i32 = switch (req.result) {
            .success => |n| @intCast(@min(n, @as(usize, std.math.maxInt(i32)))),
            .err => @intCast(req.result.toSyscallReturn()),
            else => 0,
        };
        _ = inst.addCqe(sqe.user_data, res, 0);
        io.pool.free(req);
    } else {
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
    }
}

fn processTimeoutOp(inst: *IoUringInstance, sqe: *const io_ring.IoUringSqe) SyscallError!void {
    // IORING_OP_TIMEOUT uses:
    //   - sqe.addr: pointer to struct __kernel_timespec
    //   - sqe.len: count (number of completions to wait for, 0 = pure timeout)
    //   - sqe.off: flags (IORING_TIMEOUT_ABS for absolute time)

    const req = io.pool.alloc(.timer) orelse return error.ENOMEM;
    errdefer io.pool.free(req);

    req.user_data = sqe.user_data;

    // Read timeout value from userspace
    // struct __kernel_timespec { i64 tv_sec; i64 tv_nsec; }
    if (sqe.addr != 0) {
        if (!user_mem.isValidUserAccess(sqe.addr, 16, .read)) {
            io.pool.free(req);
            return error.EFAULT;
        }

        const ts_ptr: *const extern struct { tv_sec: i64, tv_nsec: i64 } = @ptrFromInt(sqe.addr);
        const timeout_ns: u64 = @as(u64, @intCast(@max(0, ts_ptr.tv_sec))) * 1_000_000_000 +
            @as(u64, @intCast(@max(0, ts_ptr.tv_nsec)));

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
        if (inst.pending_count >= MAX_RING_ENTRIES) {
            _ = reactor.cancelTimer(req);
            io.pool.free(req);
            return error.EBUSY;
        }
        inst.pending_requests[inst.pending_count] = req;
        inst.pending_count += 1;
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

    // If we have enough completions, return
    if (inst.cqReady() >= min_complete) {
        return;
    }

    // Need to wait for more completions
    // For now, just spin-poll (in full implementation would use proper blocking)
    var spins: u32 = 0;
    const max_spins: u32 = 10000;

    while (inst.cqReady() < min_complete and spins < max_spins) {
        _ = inst.processPendingRequests();
        spins += 1;

        // Yield to allow IRQ handlers to run
        if (spins % 100 == 0) {
            hal.cpu.pause();
        }
    }
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
