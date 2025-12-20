const std = @import("std");
const primitive = @import("primitive.zig");
const io = @import("io.zig");
const uapi = primitive.uapi;
const syscalls = uapi.syscalls;
const io_ring = uapi.io_ring;

pub const SyscallError = primitive.SyscallError;

// =============================================================================
// io_uring Async I/O (425-427)
// =============================================================================

/// io_uring types from uapi
pub const IoUringSqe = io_ring.IoUringSqe;
pub const IoUringCqe = io_ring.IoUringCqe;
pub const IoUringParams = io_ring.IoUringParams;
pub const IORING_ENTER_GETEVENTS = io_ring.IORING_ENTER_GETEVENTS;
pub const IORING_OP_NOP = io_ring.IORING_OP_NOP;
pub const IORING_OP_READ = io_ring.IORING_OP_READ;
pub const IORING_OP_WRITE = io_ring.IORING_OP_WRITE;
pub const IORING_OP_ACCEPT = io_ring.IORING_OP_ACCEPT;
pub const IORING_OP_RECV = io_ring.IORING_OP_RECV;
pub const IORING_OP_SEND = io_ring.IORING_OP_SEND;
pub const IORING_OP_CLOSE = io_ring.IORING_OP_CLOSE;
pub const IORING_OFF_SQ_RING = io_ring.IORING_OFF_SQ_RING;
pub const IORING_OFF_CQ_RING = io_ring.IORING_OFF_CQ_RING;
pub const IORING_OFF_SQES = io_ring.IORING_OFF_SQES;

/// Setup an io_uring instance
pub fn io_uring_setup(entries: u32, params: *IoUringParams) SyscallError!i32 {
    const ret = primitive.syscall2(
        syscalls.SYS_IO_URING_SETUP,
        entries,
        @intFromPtr(params),
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Submit SQEs and optionally wait for completions
pub fn io_uring_enter(ring_fd: i32, to_submit: u32, min_complete: u32, flags: u32) SyscallError!u32 {
    const ret = primitive.syscall4(
        syscalls.SYS_IO_URING_ENTER,
        @bitCast(@as(isize, ring_fd)),
        to_submit,
        min_complete,
        flags,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(ret);
}

/// Register resources with an io_uring instance
pub fn io_uring_register(ring_fd: i32, opcode: u32, arg: usize, nr_args: u32) SyscallError!i32 {
    const ret = primitive.syscall4(
        syscalls.SYS_IO_URING_REGISTER,
        @bitCast(@as(isize, ring_fd)),
        opcode,
        arg,
        nr_args,
    );
    if (primitive.isError(ret)) return primitive.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// High-level io_uring ring wrapper for userspace
pub const IoUring = struct {
    ring_fd: i32,
    sq_ring: [*]u8,
    cq_ring: [*]u8,
    sqes: [*]IoUringSqe,
    sq_head: *volatile u32,
    sq_tail: *volatile u32,
    sq_mask: u32,
    sq_array: [*]u32,
    cq_head: *volatile u32,
    cq_tail: *volatile u32,
    cq_mask: u32,
    cqes: [*]IoUringCqe,
    sq_ring_size: usize,
    cq_ring_size: usize,
    sqes_size: usize,

    /// Initialize io_uring with given number of entries
    pub fn init(entries: u32) SyscallError!IoUring {
        var params: IoUringParams = std.mem.zeroes(IoUringParams);

        const ring_fd = try io_uring_setup(entries, &params);
        errdefer io.close(ring_fd) catch {};

        if (params.sq_entries == 0 or params.cq_entries == 0) {
            return error.InvalidArgument;
        }

        const sq_array_size = std.math.mul(usize, params.sq_entries, @sizeOf(u32)) catch {
            return error.OutOfMemory;
        };
        const sq_ring_size = std.math.add(usize, params.sq_off.array, sq_array_size) catch {
            return error.OutOfMemory;
        };

        const cqes_array_size = std.math.mul(usize, params.cq_entries, @sizeOf(IoUringCqe)) catch {
            return error.OutOfMemory;
        };
        const cq_ring_size = std.math.add(usize, params.cq_off.cqes, cqes_array_size) catch {
            return error.OutOfMemory;
        };

        const sqes_size = std.math.mul(usize, params.sq_entries, @sizeOf(IoUringSqe)) catch {
            return error.OutOfMemory;
        };

        const sq_ring = try io.mmap(
            null,
            sq_ring_size,
            io.PROT_READ | io.PROT_WRITE,
            io.MAP_SHARED | io.MAP_POPULATE,
            ring_fd,
            IORING_OFF_SQ_RING,
        );
        errdefer io.munmap(sq_ring, sq_ring_size) catch {};

        const cq_ring = try io.mmap(
            null,
            cq_ring_size,
            io.PROT_READ | io.PROT_WRITE,
            io.MAP_SHARED | io.MAP_POPULATE,
            ring_fd,
            IORING_OFF_CQ_RING,
        );
        errdefer io.munmap(cq_ring, cq_ring_size) catch {};

        const sqes_ptr = try io.mmap(
            null,
            sqes_size,
            io.PROT_READ | io.PROT_WRITE,
            io.MAP_SHARED | io.MAP_POPULATE,
            ring_fd,
            IORING_OFF_SQES,
        );
        errdefer io.munmap(sqes_ptr, sqes_size) catch {};

        const u32_align = @alignOf(u32);
        const sqe_align = @alignOf(IoUringSqe);
        const cqe_align = @alignOf(IoUringCqe);

        if (params.sq_off.head % u32_align != 0 or
            params.sq_off.tail % u32_align != 0 or
            params.sq_off.array % u32_align != 0 or
            params.cq_off.head % u32_align != 0 or
            params.cq_off.tail % u32_align != 0 or
            params.cq_off.cqes % cqe_align != 0 or
            @intFromPtr(sqes_ptr) % sqe_align != 0)
        {
            return error.InvalidArgument;
        }

        return IoUring{
            .ring_fd = ring_fd,
            .sq_ring = sq_ring,
            .cq_ring = cq_ring,
            .sqes = @ptrCast(@alignCast(sqes_ptr)),
            .sq_head = @ptrCast(@alignCast(sq_ring + params.sq_off.head)),
            .sq_tail = @ptrCast(@alignCast(sq_ring + params.sq_off.tail)),
            .sq_mask = params.sq_entries - 1,
            .sq_array = @ptrCast(@alignCast(sq_ring + params.sq_off.array)),
            .cq_head = @ptrCast(@alignCast(cq_ring + params.cq_off.head)),
            .cq_tail = @ptrCast(@alignCast(cq_ring + params.cq_off.tail)),
            .cq_mask = params.cq_entries - 1,
            .cqes = @ptrCast(@alignCast(cq_ring + params.cq_off.cqes)),
            .sq_ring_size = sq_ring_size,
            .cq_ring_size = cq_ring_size,
            .sqes_size = sqes_size,
        };
    }

    pub fn deinit(self: *IoUring) void {
        io.munmap(self.sq_ring, self.sq_ring_size) catch {};
        io.munmap(self.cq_ring, self.cq_ring_size) catch {};
        io.munmap(@ptrCast(self.sqes), self.sqes_size) catch {};
        io.close(self.ring_fd) catch {};
    }

    pub fn getSqeAtomic(self: *IoUring, ctx: anytype) bool {
        const tail = self.sq_tail.*;
        const head = self.sq_head.*;

        if (tail - head >= self.sq_mask + 1) {
            return false;
        }

        const index = tail & self.sq_mask;
        self.sq_array[index] = index;

        const sqe = &self.sqes[index];
        sqe.* = std.mem.zeroes(IoUringSqe);

        ctx.populate(sqe);

        primitive.memoryBarrier();
        self.sq_tail.* = tail + 1;

        return true;
    }

    pub fn getSqeAtomicFn(
        self: *IoUring,
        populate_fn: *const fn (*IoUringSqe, ?*anyopaque) void,
        user_ctx: ?*anyopaque,
    ) bool {
        const tail = self.sq_tail.*;
        const head = self.sq_head.*;

        if (tail - head >= self.sq_mask + 1) {
            return false;
        }

        const index = tail & self.sq_mask;
        self.sq_array[index] = index;

        const sqe = &self.sqes[index];
        sqe.* = std.mem.zeroes(IoUringSqe);

        populate_fn(sqe, user_ctx);

        primitive.memoryBarrier();
        self.sq_tail.* = tail + 1;

        return true;
    }

    pub fn submit(self: *IoUring, min_complete: u32) SyscallError!u32 {
        const to_submit = self.sq_tail.* - self.sq_head.*;
        if (to_submit == 0 and min_complete == 0) return 0;

        const flags: u32 = if (min_complete > 0) IORING_ENTER_GETEVENTS else 0;
        return io_uring_enter(self.ring_fd, to_submit, min_complete, flags);
    }

    pub fn cqReady(self: *IoUring) u32 {
        return self.cq_tail.* - self.cq_head.*;
    }

    pub fn peekCqe(self: *IoUring) ?*IoUringCqe {
        if (self.cq_head.* == self.cq_tail.*) {
            return null;
        }
        const index = self.cq_head.* & self.cq_mask;
        return &self.cqes[index];
    }

    pub fn advanceCq(self: *IoUring) void {
        primitive.memoryBarrier();
        self.cq_head.* += 1;
        primitive.memoryBarrier();
    }

    pub fn prepAccept(sqe: *IoUringSqe, fd: i32, addr: ?*@import("net.zig").SockAddrIn, addrlen: ?*u32, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_ACCEPT;
        sqe.fd = fd;
        sqe.addr = if (addr) |a| @intFromPtr(a) else 0;
        sqe.off = if (addrlen) |l| @intFromPtr(l) else 0;
        sqe.user_data = user_data;
    }

    pub const PrepError = error{BufferTooLarge};

    pub fn prepRecvSafe(sqe: *IoUringSqe, fd: i32, buf: []u8, user_data: u64) PrepError!void {
        if (buf.len > std.math.maxInt(u32)) {
            return error.BufferTooLarge;
        }
        prepRecv(sqe, fd, buf, user_data);
    }

    pub fn prepRecv(sqe: *IoUringSqe, fd: i32, buf: []u8, user_data: u64) void {
        if (buf.len > std.math.maxInt(u32)) {
            @panic("prepRecv: buffer length exceeds u32 max");
        }
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_RECV;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @truncate(buf.len);
        sqe.user_data = user_data;
    }

    pub fn prepSendSafe(sqe: *IoUringSqe, fd: i32, buf: []const u8, user_data: u64) PrepError!void {
        if (buf.len > std.math.maxInt(u32)) {
            return error.BufferTooLarge;
        }
        prepSend(sqe, fd, buf, user_data);
    }

    pub fn prepSend(sqe: *IoUringSqe, fd: i32, buf: []const u8, user_data: u64) void {
        if (buf.len > std.math.maxInt(u32)) {
            @panic("prepSend: buffer length exceeds u32 max");
        }
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_SEND;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(buf.ptr);
        sqe.len = @truncate(buf.len);
        sqe.user_data = user_data;
    }

    pub fn prepClose(sqe: *IoUringSqe, fd: i32, user_data: u64) void {
        sqe.* = std.mem.zeroes(IoUringSqe);
        sqe.opcode = IORING_OP_CLOSE;
        sqe.fd = fd;
        sqe.user_data = user_data;
    }
};
