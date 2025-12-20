const std = @import("std");
const state = @import("state.zig");
const idt = @import("../idt.zig");
const debug = @import("../debug.zig");
const apic = @import("../apic/root.zig");
const handlers = @import("handlers.zig");
const irq = @import("irq.zig");

/// Register a raw IDT interrupt handler (helper wrapper)
pub fn registerHandler(vector: u8, handler: *const fn (*idt.InterruptFrame) void) void {
    idt.registerHandler(vector, handler);
}

/// Initialize interrupt handlers
pub fn init() void {
    // Register exception handlers
    for (0..32) |i| {
        idt.registerHandler(@truncate(i), handlers.exceptionHandler);
    }

    // Register IRQ handlers (vectors 32-47)
    for (32..48) |i| {
        idt.registerHandler(@truncate(i), irq.irqHandler);
    }

    // Register LAPIC Timer handler (vector 48)
    idt.registerHandler(apic.lapic.TIMER_VECTOR, handlers.lapicTimerHandler);
}

/// Set the console writer for debug output
pub fn setConsoleWriter(writer: *const fn ([]const u8) void) void {
    state.console_writer = writer;
    debug.setConsoleWriter(writer);
}

/// Set the keyboard handler callback
pub fn setKeyboardHandler(handler: *const fn () void) void {
    @atomicStore(?*const fn () void, &state.keyboard_handler, handler, .release);
}

/// Set the mouse handler callback
pub fn setMouseHandler(handler: *const fn () void) void {
    @atomicStore(?*const fn () void, &state.mouse_handler, handler, .release);
}

/// Set the updated serial handler callback
pub fn setSerialHandler(handler: ?*const fn () void) void {
    @atomicStore(?*const fn () void, &state.serial_handler, handler, .release);
}

/// Set the crash handler callback
pub fn setCrashHandler(handler: *const fn (u8, u64) noreturn) void {
    @atomicStore(?*const fn (u8, u64) noreturn, &state.crash_handler, handler, .release);
}

/// Set the timer handler callback
pub fn setTimerHandler(handler: *const fn (*idt.InterruptFrame) *idt.InterruptFrame) void {
    @atomicStore(?*const fn (*idt.InterruptFrame) *idt.InterruptFrame, &state.timer_handler, handler, .release);
}

/// Set the guard page checker callback
pub fn setGuardPageChecker(checker: *const fn (u64) ?state.GuardPageInfo) void {
    @atomicStore(?*const fn (u64) ?state.GuardPageInfo, &state.guard_page_checker, checker, .release);
}

/// Set the FPU access handler callback for lazy FPU switching
pub fn setFpuAccessHandler(handler: *const fn () bool) void {
    @atomicStore(?*const fn () bool, &state.fpu_access_handler, handler, .release);
}

/// Set the page fault handler callback for demand paging
pub fn setPageFaultHandler(handler: *const fn (u64, u64) bool) void {
    @atomicStore(?*const fn (u64, u64) bool, &state.page_fault_handler, handler, .release);
}

/// Set a generic handler for an IRQ
pub fn setGenericIrqHandler(irq_num: u8, handler: *const fn (u8) void) void {
    if (irq_num < 16) {
        @atomicStore(?*const fn (u8) void, &state.generic_irq_handlers[irq_num], handler, .release);
    }
}
