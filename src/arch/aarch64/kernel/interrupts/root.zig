// AArch64 Interrupt Controller and Exception Handling
//
// This module provides:
// - Exception vector dispatch (sync exceptions, IRQs)
// - GIC integration for interrupt acknowledgment
// - Handler registration API matching x86_64

const std = @import("std");
const cpu = @import("../cpu.zig");
const syscall = @import("../syscall.zig");
const gic = @import("../gic.zig");

// ============================================================================
// Handler State Variables
// ============================================================================

/// Console output writer callback
var console_writer: ?*const fn ([]const u8) void = null;

/// Keyboard IRQ handler callback
var keyboard_handler: ?*const fn () void = null;

/// Mouse IRQ handler callback
var mouse_handler: ?*const fn () void = null;

/// Serial IRQ handler callback
var serial_handler: ?*const fn () void = null;

/// Timer IRQ handler callback
var timer_handler: ?*const fn (*const InterruptFrame) void = null;

/// Guard page fault checker callback
var guard_page_checker: ?*const fn (u64) ?GuardPageInfo = null;

/// FPU access handler callback for lazy FPU switching
var fpu_access_handler: ?*const fn () bool = null;

/// Crash handler callback
var crash_handler: ?*const fn (u8, u64) noreturn = null;

/// Page fault handler callback for demand paging
var page_fault_handler: ?*const fn (u64, u64) bool = null;

/// Generic IRQ handlers (for userspace drivers/IPC)
var generic_irq_handlers: [16]?*const fn (u8) void = [_]?*const fn (u8) void{null} ** 16;

// ============================================================================
// Types
// ============================================================================

pub const InterruptFrame = syscall.SyscallFrame;

pub const GuardPageInfo = struct {
    thread_id: u64,
    thread_name: []const u8,
    stack_base: u64,
    stack_top: u64,
};

pub const MSIX_VECTOR_START: u8 = 64;
pub const MSIX_VECTOR_END: u8 = 128;
pub const MSIX_VECTOR_COUNT: u8 = MSIX_VECTOR_END - MSIX_VECTOR_START;

pub const MsixVectorAllocation = struct {
    first_vector: u32,
    count: u32,
};

// GIC interrupt numbers for QEMU virt machine
const TIMER_PPI = 30; // Virtual timer (PPI 14, +16 = 30)
const UART_SPI = 33; // PL011 UART (SPI 1, +32 = 33)

// ============================================================================
// Debug Output
// ============================================================================

pub fn earlyPrint(msg: []const u8) void {
    const pl011 = @import("serial");
    pl011.writeString(msg);
}

fn printHex(val: u64) void {
    const hex = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[17 - i] = hex[@as(usize, @truncate((val >> @as(u6, @truncate(i * 4))) & 0xF))];
    }
    earlyPrint(&buf);
}

// ============================================================================
// Exception Handling
// ============================================================================

/// Exception class codes from ESR_EL1
const ExceptionClass = enum(u6) {
    unknown = 0x00,
    svc_aa64 = 0x15, // SVC instruction from AArch64
    instr_abort_lower = 0x20, // Instruction abort from lower EL
    instr_abort_same = 0x21, // Instruction abort from same EL
    pc_alignment = 0x22, // PC alignment fault
    data_abort_lower = 0x24, // Data abort from lower EL
    data_abort_same = 0x25, // Data abort from same EL
    sp_alignment = 0x26, // SP alignment fault
    fp_exception = 0x2C, // FP exception
    serror = 0x2F, // SError interrupt
    breakpoint_lower = 0x30,
    breakpoint_same = 0x31,
    software_step_lower = 0x32,
    software_step_same = 0x33,
    watchpoint_lower = 0x34,
    watchpoint_same = 0x35,
    brk_aa64 = 0x3C, // BRK instruction
    _,
};

/// Exception handler called from entry.S
/// ESR_EL1 contains exception syndrome (type, cause)
/// FAR_EL1 contains fault address for memory aborts
pub export fn handle_exception_zig(esr: u64, far: u64) callconv(.c) void {
    const ec: ExceptionClass = @enumFromInt(@as(u6, @truncate(esr >> 26)));

    switch (ec) {
        .svc_aa64 => {
            // SVC instruction - this is a syscall from userspace
            // TODO: Dispatch to syscall handler
            earlyPrint("SVC from EL0, number: ");
            printHex(esr & 0xFFFF);
            earlyPrint("\n");
        },
        .instr_abort_lower, .instr_abort_same => {
            earlyPrint("Instruction Abort at ");
            printHex(far);
            earlyPrint(" ESR=");
            printHex(esr);
            earlyPrint("\n");
            cpu.halt();
        },
        .data_abort_lower, .data_abort_same => {
            // Check if page fault handler can handle it
            if (@atomicLoad(?*const fn (u64, u64) bool, &page_fault_handler, .acquire)) |handler| {
                if (handler(far, esr)) {
                    return; // Handler resolved the fault
                }
            }
            earlyPrint("Data Abort at ");
            printHex(far);
            earlyPrint(" ESR=");
            printHex(esr);
            earlyPrint("\n");
            cpu.halt();
        },
        .pc_alignment, .sp_alignment => {
            earlyPrint("Alignment Fault at ");
            printHex(far);
            earlyPrint("\n");
            cpu.halt();
        },
        .brk_aa64 => {
            earlyPrint("BRK instruction hit\n");
            cpu.halt();
        },
        else => {
            earlyPrint("Unknown Exception EC=");
            printHex(@intFromEnum(ec));
            earlyPrint(" ESR=");
            printHex(esr);
            earlyPrint(" FAR=");
            printHex(far);
            earlyPrint("\n");
            cpu.halt();
        },
    }
}

// ============================================================================
// IRQ Handling
// ============================================================================

/// IRQ handler called from entry.S
pub export fn handle_irq_zig() callconv(.c) void {
    // Acknowledge interrupt from GIC
    const irq = gic.acknowledgeIrq();

    // Check for spurious interrupt (ID 1023)
    if (irq >= 1020) {
        return;
    }

    // Dispatch based on interrupt number
    switch (irq) {
        TIMER_PPI => {
            // Timer interrupt
            if (@atomicLoad(?*const fn (*const InterruptFrame) void, &timer_handler, .acquire)) |handler| {
                // TODO: Pass actual frame pointer from entry.S
                // For now we pass a dummy - this won't work for context switching
                handler(undefined);
            }
        },
        UART_SPI => {
            // UART interrupt
            if (@atomicLoad(?*const fn () void, &serial_handler, .acquire)) |handler| {
                handler();
            }
        },
        else => {
            // Check generic IRQ handlers (map SPI 32-47 to slots 0-15)
            if (irq >= 32 and irq < 48) {
                const slot = irq - 32;
                if (@atomicLoad(?*const fn (u8) void, &generic_irq_handlers[slot], .acquire)) |handler| {
                    handler(@truncate(irq));
                }
            } else {
                earlyPrint("Unexpected IRQ: ");
                printHex(irq);
                earlyPrint("\n");
            }
        },
    }

    // Signal end of interrupt to GIC
    gic.endOfInterrupt(irq);
}

// ============================================================================
// Initialization
// ============================================================================

pub fn init() void {
    // Initialize GIC (Distributor + CPU Interface)
    gic.init();

    // Set up VBAR_EL1 to point to our exception vector table
    const vbar = @intFromPtr(&exception_vector_table);
    asm volatile ("msr vbar_el1, %[val]"
        :
        : [val] "r" (vbar),
    );

    // Enable interrupts at CPU level
    cpu.enableInterrupts();
}

extern const exception_vector_table: anyopaque;

// ============================================================================
// Handler Registration API
// ============================================================================

pub fn setConsoleWriter(writer: *const fn ([]const u8) void) void {
    @atomicStore(?*const fn ([]const u8) void, &console_writer, writer, .release);
}

pub fn setKeyboardHandler(handler: *const fn () void) void {
    @atomicStore(?*const fn () void, &keyboard_handler, handler, .release);
}

pub fn setMouseHandler(handler: *const fn () void) void {
    @atomicStore(?*const fn () void, &mouse_handler, handler, .release);
}

pub fn setSerialHandler(handler: ?*const fn () void) void {
    @atomicStore(?*const fn () void, &serial_handler, handler, .release);
    if (handler != null) {
        gic.enableIrq(UART_SPI);
    } else {
        gic.disableIrq(UART_SPI);
    }
}

pub fn setTimerHandler(handler: *const fn (*const InterruptFrame) void) void {
    @atomicStore(?*const fn (*const InterruptFrame) void, &timer_handler, handler, .release);
    gic.enableIrq(TIMER_PPI);
}

pub fn setGuardPageChecker(checker: *const fn (u64) ?GuardPageInfo) void {
    @atomicStore(?*const fn (u64) ?GuardPageInfo, &guard_page_checker, checker, .release);
}

pub fn setFpuAccessHandler(handler: *const fn () bool) void {
    @atomicStore(?*const fn () bool, &fpu_access_handler, handler, .release);
}

pub fn setPageFaultHandler(handler: *const fn (u64, u64) bool) void {
    @atomicStore(?*const fn (u64, u64) bool, &page_fault_handler, handler, .release);
}

pub fn setCrashHandler(handler: *const fn (u8, u64) noreturn) void {
    @atomicStore(?*const fn (u8, u64) noreturn, &crash_handler, handler, .release);
}

pub fn setGenericIrqHandler(irq_num: u8, handler: *const fn (u8) void) void {
    if (irq_num < 16) {
        @atomicStore(?*const fn (u8) void, &generic_irq_handlers[irq_num], handler, .release);
        // Enable corresponding SPI (irq_num + 32)
        gic.enableIrq(@as(u32, irq_num) + 32);
    }
}

pub fn registerHandler(_: u32, _: *const fn (*const InterruptFrame) void) void {
    // AArch64 uses GIC-based routing, not per-vector registration
}

pub fn unregisterHandler(_: u32) void {}

// ============================================================================
// MSI-X Stubs (Not applicable to GICv2, would need GICv3+ ITS)
// ============================================================================

pub fn allocateMsixVectors(_: u32) !MsixVectorAllocation {
    return error.Unimplemented;
}

pub fn freeMsixVectors(_: MsixVectorAllocation) void {}

pub fn registerMsixHandler(_: u32, _: *const fn (*const InterruptFrame) void) bool {
    return false;
}

pub fn unregisterMsixHandler(_: u32) void {}

pub fn allocateMsixVector() ?u32 {
    return null;
}

pub fn freeMsixVector(_: u32) void {}
