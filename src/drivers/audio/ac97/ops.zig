const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const sched = @import("sched");
const kernel_io = @import("io");
const types = @import("types.zig");
const regs = @import("regs.zig");
const dsp = @import("dsp.zig");

const port_io = hal.io;

pub fn write(self: *types.Ac97, data: []const u8) isize {
    const hw_frame_size: usize = 4;
    var written: usize = 0;

    while (written < data.len) {
        const held = self.lock.acquire();

        if (self.current_buffer >= types.BDL_ENTRY_COUNT) {
            held.release();
            return -5; // EIO
        }

        const civ = port_io.inb(self.nabm_base + regs.NABM_PO_CIV);

        if (self.current_buffer == civ) {
            const sr = port_io.inw(self.nabm_base + regs.NABM_PO_SR);
            if ((sr & regs.SR_DCH) == 0) {
                held.release();
                sched.yield();
                continue;
            }
        }

        const dst_slice = self.buffers[self.current_buffer][0..types.BUFFER_SIZE];
        const src_slice = data[written..];

        const res = dsp.processAudio(self, dst_slice, src_slice);

        if (res.consumed == 0 and src_slice.len > 0) {
             held.release();
             break;
        }

        const samples = res.written / hw_frame_size;
        self.bdl[self.current_buffer].len = @truncate(samples);

        written += res.consumed;

        const next_buffer = (self.current_buffer + 1) % types.BDL_ENTRY_COUNT;
        self.current_buffer = next_buffer;

        port_io.outb(self.nabm_base + regs.NABM_PO_LVI, @truncate(self.current_buffer));

        const cr = port_io.inb(self.nabm_base + regs.NABM_PO_CR);
        if ((cr & regs.CR_RPBM) == 0) {
            port_io.outb(self.nabm_base + regs.NABM_PO_CR, regs.CR_RPBM);
        }

        held.release();
    }

    return @intCast(written);
}

pub fn writeAsync(self: *types.Ac97, request: *kernel_io.IoRequest) void {
    const held = self.lock.acquire();
    defer held.release();

    const civ = port_io.inb(self.nabm_base + regs.NABM_PO_CIV);

    if (civ >= types.BDL_ENTRY_COUNT) {
        _ = request.complete(.{ .err = error.EIO });
        return;
    }

    const sr = port_io.inw(self.nabm_base + regs.NABM_PO_SR);
    const dma_halted = (sr & regs.SR_DCH) != 0;
    const buffers_available = dma_halted or (self.current_buffer != civ);

    if (buffers_available) {
        submitBuffer(self, request);
    } else {
        self.enqueueRequest(request);
    }
}

pub fn submitBuffer(self: *types.Ac97, request: *kernel_io.IoRequest) void {
    const frame_size: usize = 4;
    const buf_idx = self.current_buffer;

    if (buf_idx >= types.BDL_ENTRY_COUNT) {
        _ = request.complete(.{ .err = error.EIO });
        return;
    }

    const buf = self.buffers[buf_idx];

    var src_consumed: usize = 0;
    var dst_written: usize = 0;

    if (request.bounce_buf) |bounce| {
        const res = dsp.processAudio(self, buf[0..types.BUFFER_SIZE], bounce[0..request.buf_len]);
        src_consumed = res.consumed;
        dst_written = res.written;
    } else {
        _ = request.complete(.{ .err = error.EFAULT });
        return;
    }

    const samples = dst_written / frame_size;
    self.bdl[buf_idx].len = @truncate(samples);

    @atomicStore(?*kernel_io.IoRequest, &self.pending_requests[buf_idx], request, .release);
    _ = request.compareAndSwapState(.pending, .in_progress);
    
    const bytes_le = std.mem.toBytes(@as(u64, src_consumed));
    @memcpy(request.op_data.raw[0..8], &bytes_le); 

    self.current_buffer = (self.current_buffer + 1) % types.BDL_ENTRY_COUNT;

    port_io.outb(self.nabm_base + regs.NABM_PO_LVI, @truncate(self.current_buffer));

    const cr = port_io.inb(self.nabm_base + regs.NABM_PO_CR);
    if ((cr & regs.CR_RPBM) == 0) {
        port_io.outb(self.nabm_base + regs.NABM_PO_CR, cr | regs.CR_RPBM | regs.CR_IOCE);
    }
}

pub fn handleInterrupt(self: *types.Ac97) void {
    const held = self.lock.acquire();
    defer held.release();

    const sr = port_io.inw(self.nabm_base + regs.NABM_PO_SR);

    if ((sr & regs.SR_BCIS) != 0) {
        port_io.outw(self.nabm_base + regs.NABM_PO_SR, regs.SR_BCIS);

        const civ = port_io.inb(self.nabm_base + regs.NABM_PO_CIV);

        if (civ >= types.BDL_ENTRY_COUNT) {
            console.warn("AC97: Invalid CIV {} from hardware", .{civ});
            return;
        }

        const consumed_count = (civ +% types.BDL_ENTRY_COUNT -% self.last_completed) % types.BDL_ENTRY_COUNT;

        for (0..consumed_count) |offset| {
            const idx = (self.last_completed + offset) % types.BDL_ENTRY_COUNT;
            const slot = &self.pending_requests[idx];

            const maybe_req = @atomicRmw(?*kernel_io.IoRequest, slot, .Xchg, null, .acq_rel);
            if (maybe_req) |request| {
                if (request.getState() == .in_progress) {
                    const written = std.mem.bytesToValue(u64, request.op_data.raw[0..8]);
                    _ = request.complete(.{ .success = written });
                }
            }
        }

        self.last_completed = civ;

        while (self.dequeueRequest()) |queued| {
            std.debug.assert(queued.next == null);

            const new_civ = port_io.inb(self.nabm_base + regs.NABM_PO_CIV);

            if (new_civ >= types.BDL_ENTRY_COUNT) {
                self.enqueueRequest(queued);
                console.warn("AC97: Invalid new_civ {} from hardware", .{new_civ});
                break;
            }

            if (self.current_buffer == new_civ) {
                queued.next = self.pending_queue_head;
                self.pending_queue_head = queued;

                if (queued.next == null) {
                    self.pending_queue_tail = queued;
                }

                break;
            }
            submitBuffer(self, queued);
        }
    }

    if ((sr & regs.SR_LVBCI) != 0) {
        port_io.outw(self.nabm_base + regs.NABM_PO_SR, regs.SR_LVBCI);
    }

    if ((sr & regs.SR_FIFO) != 0) {
        port_io.outw(self.nabm_base + regs.NABM_PO_SR, regs.SR_FIFO);
        console.warn("AC97: FIFO error", .{});
    }
}
