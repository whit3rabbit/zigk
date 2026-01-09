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
const timing = @import("../timing.zig");

// Extern declaration for syscall dispatch (defined in src/kernel/sys/syscall/core/table.zig)
// Using extern allows AArch64 to call the common dispatch table without module import issues
extern fn dispatch_syscall(frame: *syscall.SyscallFrame) callconv(.c) void;

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
/// Maps SPIs 32-47 to handler slots 0-15
var generic_irq_handlers: [16]?*const fn (u8) void = [_]?*const fn (u8) void{null} ** 16;

// SECURITY: Compile-time verification that array size matches the IRQ range check in handle_irq_zig
// The range check is (irq >= 32 and irq < 48), so slot = irq - 32 produces 0..15
comptime {
    const GENERIC_IRQ_START: u32 = 32;
    const GENERIC_IRQ_END: u32 = 48;
    const expected_size = GENERIC_IRQ_END - GENERIC_IRQ_START;
    if (generic_irq_handlers.len != expected_size) {
        @compileError("generic_irq_handlers array size does not match IRQ range (32..48)");
    }
}

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
// Timer INTIDs: Physical=30 (PPI14), Virtual=27 (PPI11)
// We use the virtual timer (CNTV_*) so we need INTID 27
const TIMER_PPI = 27; // EL1 Virtual timer (PPI 11, +16 = 27)
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
    var buf: [18]u8 = [_]u8{0} ** 18;
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

/// Unhandled exception types for panic diagnostics
const UnhandledExceptionType = enum(u8) {
    sp0_sync = 0,
    sp0_irq = 1,
    sp0_fiq = 2,
    sp0_serror = 3,
    fiq = 4,
    serror = 5,
    aarch32 = 6,
};

/// Handler for unhandled/unexpected exceptions
/// Called from entry.S when an exception occurs that we don't handle
pub export fn unhandled_exception_zig(
    exc_type: u8,
    esr: u64,
    elr: u64,
    far: u64,
) callconv(.c) noreturn {
    const type_names = [_][]const u8{
        "SP0 Sync",
        "SP0 IRQ",
        "SP0 FIQ",
        "SP0 SError",
        "FIQ",
        "SError",
        "AArch32 (unsupported)",
    };

    earlyPrint("\n!!! UNHANDLED EXCEPTION !!!\n");
    earlyPrint("Type: ");
    if (exc_type < type_names.len) {
        earlyPrint(type_names[exc_type]);
    } else {
        earlyPrint("Unknown");
    }
    earlyPrint("\nESR_EL1: ");
    printHex(esr);
    earlyPrint("\nELR_EL1: ");
    printHex(elr);
    earlyPrint("\nFAR_EL1: ");
    printHex(far);
    earlyPrint("\n");

    // Halt with interrupts disabled
    cpu.haltForever();
}

/// Exception handler called from entry.S
/// frame: pointer to saved register context (SyscallFrame) on kernel stack
/// esr: ESR_EL1 - exception syndrome (type, cause)
/// far: FAR_EL1 - fault address for memory aborts
pub export fn handle_exception_zig(frame: *syscall.SyscallFrame, esr: u64, far: u64) callconv(.c) void {
    const ec: ExceptionClass = @enumFromInt(@as(u6, @truncate(esr >> 26)));

    switch (ec) {
        .svc_aa64 => {
            // SVC instruction - dispatch to syscall handler
            // The dispatch_syscall function reads syscall number from x8,
            // arguments from x0-x5, and sets return value in x0
            dispatch_syscall(frame);
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
/// frame: pointer to saved register context on kernel stack
pub export fn handle_irq_zig(frame: *InterruptFrame) callconv(.c) void {
    // Acknowledge interrupt from GIC
    const irq = gic.acknowledgeIrq();

    // Check for spurious interrupt (GICv2 spurious is exactly 1023)
    // No EOI needed for spurious interrupts
    if (irq == 1023) {
        return;
    }

    // Dispatch based on interrupt number
    switch (irq) {
        TIMER_PPI => {
            // Re-arm the timer for the next interval
            timing.rearmTimer();

            // Timer interrupt - pass actual frame for context switching
            if (@atomicLoad(?*const fn (*const InterruptFrame) void, &timer_handler, .acquire)) |handler| {
                handler(frame);
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

    // Validate 2048-byte alignment required by ARM architecture
    if ((vbar & 0x7FF) != 0) {
        @panic("Exception vector table not 2048-byte aligned");
    }

    asm volatile (
        \\msr vbar_el1, %[val]
        \\isb                   // ARM ARM requires ISB after VBAR update
        :
        : [val] "r" (vbar),
    );

    // NOTE: Interrupts are NOT enabled here.
    // They are enabled later by the scheduler's start() function,
    // after per-CPU data (tpidr_el1) is initialized.
    // This matches x86_64 behavior where `sti` is in scheduler start.
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

pub fn registerHandler(_: u8, _: *const fn (*InterruptFrame) void) void {
    // AArch64 uses GIC-based routing, not per-vector registration
}

pub fn unregisterHandler(_: u8) void {}

// ============================================================================
// MSI-X Stubs (Not applicable to GICv2, would need GICv3+ ITS)
// ============================================================================

pub fn allocateMsixVectors(_: u8) !MsixVectorAllocation {
    return error.Unimplemented;
}

pub fn freeMsixVectors(_: MsixVectorAllocation) void {}

pub fn registerMsixHandler(_: u8, _: *const fn (*InterruptFrame) void) bool {
    return false;
}

pub fn unregisterMsixHandler(_: u8) void {}

pub fn allocateMsixVector() ?u8 {
    return null;
}

pub fn freeMsixVector(_: u8) void {}
