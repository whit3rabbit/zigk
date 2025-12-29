const std = @import("std");
const state = @import("state.zig");
const idt = @import("../idt.zig");
const pic = @import("../pic.zig");
const apic = @import("../apic/root.zig");
const io = @import("../../lib/io.zig");

/// Generic IRQ handler
pub fn irqHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    const irq = vector - pic.IRQ_OFFSET;

    if (!apic.isActive()) {
        if (pic.isSpurious(irq)) {
            return;
        }
    }

    switch (irq) {
        0 => {
            const tmr_handler = @atomicLoad(?*const fn (*idt.InterruptFrame) *idt.InterruptFrame, &state.timer_handler, .acquire);
            if (tmr_handler) |handler| {
                const returned_frame = handler(frame);
                if (returned_frame != frame) {
                    idt.setNewFrame(returned_frame);
                }
            }
        },
        1 => {
            const kbd_handler = @atomicLoad(?*const fn () void, &state.keyboard_handler, .acquire);
            if (kbd_handler) |handler| {
                handler();
            } else {
                _ = io.inb(0x60);
            }
        },
        12 => {
            const mse_handler = @atomicLoad(?*const fn () void, &state.mouse_handler, .acquire);
            if (mse_handler) |handler| {
                handler();
            } else {
                _ = io.inb(0x60);
            }
        },
        4 => {
            const ser_handler = @atomicLoad(?*const fn () void, &state.serial_handler, .acquire);
            if (ser_handler) |handler| {
                handler();
            } else if (loadGenericIrqHandler(irq)) |handler| {
                handler(irq);
            } else {
                logUnexpectedIrq(irq);
            }
        },
        else => {
            if (loadGenericIrqHandler(irq)) |handler| {
                handler(irq);
            } else {
                logUnexpectedIrq(irq);
            }
        },
    }

    if (apic.isActive()) {
        apic.lapic.sendEoi();
    } else {
        pic.sendEoi(irq);
    }
}

/// Atomically load a generic IRQ handler
fn loadGenericIrqHandler(irq: u8) ?*const fn (u8) void {
    if (irq >= 16) return null;
    return @atomicLoad(?*const fn (u8) void, &state.generic_irq_handlers[irq], .acquire);
}

/// Rate-limited logging for unexpected IRQs
pub fn logUnexpectedIrq(irq: u8) void {
    // SECURITY: Use atomic operations to prevent lost updates from concurrent IRQs
    const count = state.unexpected_irq_count.fetchAdd(1, .monotonic) + 1;
    const last_irq = state.last_unexpected_irq.load(.acquire);

    if (irq != last_irq or count <= 1) {
        state.last_unexpected_irq.store(irq, .release);
        if (state.console_writer) |write| {
            write("[WARN] Unexpected IRQ: ");
            const hex_chars = "0123456789ABCDEF";
            var buf: [2]u8 = undefined;
            buf[0] = hex_chars[irq >> 4];
            buf[1] = hex_chars[irq & 0x0F];
            write(&buf);
            write("\n");
        }
    }
}

// =============================================================================
// MSI-X Vector Allocator
// =============================================================================

/// Allocate one or more contiguous MSI-X vectors
pub fn allocateMsixVectors(count: u8) ?state.MsixVectorAllocation {
    if (count == 0 or count >= state.MSIX_VECTOR_COUNT) {
        if (count == state.MSIX_VECTOR_COUNT) {
            const prev = state.msix_allocated.cmpxchgWeak(0, 0xFFFFFFFFFFFFFFFF, .acq_rel, .acquire);
            if (prev == null) {
                return state.MsixVectorAllocation{
                    .first_vector = state.MSIX_VECTOR_START,
                    .count = state.MSIX_VECTOR_COUNT,
                };
            }
        }
        return null;
    }

    const mask: u64 = (@as(u64, 1) << @truncate(count)) - 1;
    var offset: u8 = 0;
    while (offset <= state.MSIX_VECTOR_COUNT - count) : (offset += 1) {
        const shifted_mask = mask << @as(u6, @truncate(offset));
        while (true) {
            const current = state.msix_allocated.load(.acquire);
            if ((current & shifted_mask) != 0) {
                break;
            }
            const new_value = current | shifted_mask;
            const prev = state.msix_allocated.cmpxchgWeak(current, new_value, .acq_rel, .acquire);
            if (prev == null) {
                return state.MsixVectorAllocation{
                    .first_vector = state.MSIX_VECTOR_START + offset,
                    .count = count,
                };
            }
        }
    }
    return null;
}

/// Allocate a single MSI-X vector
pub fn allocateMsixVector() ?u8 {
    const alloc = allocateMsixVectors(1) orelse return null;
    return alloc.first_vector;
}

/// Free previously allocated MSI-X vectors
pub fn freeMsixVectors(first_vector: u8, count: u8) bool {
    if (first_vector < state.MSIX_VECTOR_START or first_vector >= state.MSIX_VECTOR_END) {
        return false;
    }

    const offset: u6 = @truncate(first_vector - state.MSIX_VECTOR_START);
    const actual_count = @min(count, state.MSIX_VECTOR_END - first_vector);

    const mask: u64 = if (actual_count >= 64)
        0xFFFFFFFFFFFFFFFF
    else
        (@as(u64, 1) << @truncate(actual_count)) - 1;
    const shifted_mask = mask << offset;

    while (true) {
        const current = state.msix_allocated.load(.acquire);
        if ((current & shifted_mask) != shifted_mask) {
            return false;
        }

        const new_value = current & ~shifted_mask;
        const prev = state.msix_allocated.cmpxchgWeak(current, new_value, .acq_rel, .acquire);

        if (prev == null) {
            for (offset..offset + actual_count) |i| {
                @atomicStore(?*const fn (*idt.InterruptFrame) void, &state.msix_handlers[i], null, .release);
            }
            return true;
        }
    }
}

/// Free a single MSI-X vector
pub fn freeMsixVector(vector: u8) bool {
    return freeMsixVectors(vector, 1);
}

/// Register a handler for an MSI-X vector
pub fn registerMsixHandler(vector: u8, handler: *const fn (*idt.InterruptFrame) void) bool {
    if (vector < state.MSIX_VECTOR_START or vector >= state.MSIX_VECTOR_END) {
        return false;
    }

    const offset: u6 = @truncate(vector - state.MSIX_VECTOR_START);
    const bit_mask: u64 = @as(u64, 1) << offset;

    const allocated = state.msix_allocated.load(.acquire);
    if ((allocated & bit_mask) == 0) {
        return false;
    }

    @atomicStore(?*const fn (*idt.InterruptFrame) void, &state.msix_handlers[offset], handler, .release);
    // Full memory fence to ensure handler visibility before checking allocation
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );

    const still_allocated = state.msix_allocated.load(.acquire);
    if ((still_allocated & bit_mask) == 0) {
        @atomicStore(?*const fn (*idt.InterruptFrame) void, &state.msix_handlers[offset], null, .release);
        return false;
    }

    idt.registerHandler(vector, msixHandler);
    return true;
}

/// Unregister an MSI-X handler
pub fn unregisterMsixHandler(vector: u8) void {
    if (vector < state.MSIX_VECTOR_START or vector >= state.MSIX_VECTOR_END) {
        return;
    }

    const offset: u6 = @truncate(vector - state.MSIX_VECTOR_START);
    @atomicStore(?*const fn (*idt.InterruptFrame) void, &state.msix_handlers[offset], null, .release);
    idt.unregisterHandler(vector);
}

/// Generic MSI-X interrupt handler
fn msixHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    if (vector >= state.MSIX_VECTOR_START and vector < state.MSIX_VECTOR_END) {
        const offset: u6 = @truncate(vector - state.MSIX_VECTOR_START);
        const handler_ptr = @atomicLoad(?*const fn (*idt.InterruptFrame) void, &state.msix_handlers[offset], .acquire);
        if (handler_ptr) |handler| {
            handler(frame);
        }
    }
    apic.lapic.sendEoi();
}

/// Get the number of free MSI-X vectors
pub fn getFreeMsixVectorCount() u8 {
    const allocated = state.msix_allocated.load(.acquire);
    var count: u8 = 0;
    var remaining = ~allocated;
    while (remaining != 0) : (remaining &= remaining - 1) {
        count += 1;
    }
    return @min(count, state.MSIX_VECTOR_COUNT);
}

/// Check if a specific vector is allocated
pub fn isMsixVectorAllocated(vector: u8) bool {
    if (vector < state.MSIX_VECTOR_START or vector >= state.MSIX_VECTOR_END) {
        return false;
    }
    const offset: u6 = @truncate(vector - state.MSIX_VECTOR_START);
    const allocated = state.msix_allocated.load(.acquire);
    return (allocated & (@as(u64, 1) << offset)) != 0;
}
