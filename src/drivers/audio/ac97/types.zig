const std = @import("std");
const hal = @import("hal");
const sync = @import("sync");
const thread = @import("thread");
const kernel_io = @import("io");
const regs = @import("regs.zig");

// Buffer Descriptor List (BDL) Constants
pub const BDL_ENTRY_COUNT: usize = 32;
pub const BUFFER_SIZE: usize = 0x1000; // 4KB per buffer

// BDL Entry Structure (Hardware format)
pub const BdlEntry = packed struct {
    ptr: u32,             // Physical address of buffer
    ioc: bool = true,     // Interrupt On Completion
    bup: bool = true,     // Buffer Underrun Policy (play last sample vs zero)
    reserved: u14 = 0,
    len: u16,             // Number of samples (not bytes)
};

// Driver Instance
pub const Ac97 = struct {
    nam_base: u16,       // Mixer Base Address (NAMBAR)
    nabm_base: u16,      // Bus Master Base Address (NABMBAR)
    irq_line: u8,

    bdl_phys: u64,       // Physical address of BDL
    bdl: *[BDL_ENTRY_COUNT]BdlEntry, // Virtual address of BDL

    buffers: [BDL_ENTRY_COUNT][*]u8, // Virtual addresses of buffers
    buffers_phys: [BDL_ENTRY_COUNT]u64, // Physical addresses

    current_buffer: usize, // Software write pointer (buffer index)
    last_completed: usize, // Last buffer index completed by hardware (for IRQ tracking)

    // PCM State
    sample_rate: u32,
    channels: u32,
    format: u32, // AFMT_*
    vra_supported: bool,

    lock: sync.Spinlock,
    wait_queue: ?*thread.Thread, // Single waiter for now (simple blocking)

    // Async I/O support
    // Track pending IoRequest per buffer slot for IRQ-driven completion
    pending_requests: [BDL_ENTRY_COUNT]?*kernel_io.IoRequest,
    pending_queue_head: ?*kernel_io.IoRequest, // FIFO queue of waiting requests
    pending_queue_tail: ?*kernel_io.IoRequest,
    irq_enabled: bool,

    const Self = @This();

    // These will be implemented in their respective files or namespaced here
    pub const dsp = @import("dsp.zig");
    pub const init = @import("init.zig");

    // Helper methods that were in the monolithic struct
    pub fn enqueueRequest(self: *Self, request: *kernel_io.IoRequest) void {
        request.next = null;
        if (self.pending_queue_tail) |tail| {
            tail.next = request;
            self.pending_queue_tail = request;
        } else {
            self.pending_queue_head = request;
            self.pending_queue_tail = request;
        }
    }

    pub fn dequeueRequest(self: *Self) ?*kernel_io.IoRequest {
        const head = self.pending_queue_head orelse return null;
        self.pending_queue_head = head.next;
        if (self.pending_queue_head == null) {
            self.pending_queue_tail = null;
        }
        head.next = null;
        return head;
    }
};
