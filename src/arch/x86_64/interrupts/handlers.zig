const std = @import("std");
const state = @import("state.zig");
const idt = @import("../idt.zig");
const cpu = @import("../cpu.zig");
const debug = @import("../debug.zig");
const apic = @import("../apic/root.zig");
const console = @import("console");

// External symbols for safe copy fixup
extern const _asm_copy_user_start: anyopaque;
extern const _asm_copy_user_end: anyopaque;
extern const _asm_copy_user_fixup: anyopaque;

/// Exception names for debugging
pub const exception_names = [_][]const u8{
    "Divide Error (#DE)",
    "Debug (#DB)",
    "Non-Maskable Interrupt",
    "Breakpoint (#BP)",
    "Overflow (#OF)",
    "Bound Range Exceeded (#BR)",
    "Invalid Opcode (#UD)",
    "Device Not Available (#NM)",
    "Double Fault (#DF)",
    "Coprocessor Segment Overrun",
    "Invalid TSS (#TS)",
    "Segment Not Present (#NP)",
    "Stack-Segment Fault (#SS)",
    "General Protection Fault (#GP)",
    "Page Fault (#PF)",
    "Reserved",
    "x87 FPU Error (#MF)",
    "Alignment Check (#AC)",
    "Machine Check (#MC)",
    "SIMD Floating-Point (#XM)",
    "Virtualization Exception (#VE)",
    "Control Protection (#CP)",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection (#HV)",
    "VMM Communication (#VC)",
    "Security Exception (#SX)",
    "Reserved",
};

/// Generic exception handler
pub fn exceptionHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    // Handle #NM (Device Not Available) for lazy FPU switching
    if (vector == 7) {
        const fpu_handler = @atomicLoad(?*const fn () bool, &state.fpu_access_handler, .acquire);
        if (fpu_handler) |handler| {
            if (handler()) {
                return;
            }
        }
    }

    // Handle user mode page faults for demand paging
    if (vector == 14 and (frame.cs & 3) == 3) {
        const cr2 = cpu.readCr2();
        const pf_handler = @atomicLoad(?*const fn (u64, u64) bool, &state.page_fault_handler, .acquire);
        if (pf_handler) |handler| {
            if (handler(cr2, frame.error_code)) {
                return;
            }
        }
    }

    // For user mode exceptions
    if ((frame.cs & 3) == 3) {
        console.printUnsafe("\n!!! USER EXCEPTION: ");
        if (vector < exception_names.len) {
            console.printUnsafe(exception_names[vector]);
        } else {
            console.printUnsafe("Unknown");
        }
        console.printUnsafe(" !!!\n");

        if (vector == 14) {
            debug.dumpPageFaultInfo(frame);
        } else {
            debug.dumpRegisters(frame);
        }

        const handler_ptr = @atomicLoad(?*const fn (u8, u64) noreturn, &state.crash_handler, .acquire);
        if (handler_ptr) |handler| {
            handler(vector, frame.error_code);
        } else {
            console.printUnsafe("FATAL: User exception with no crash handler registered!\n");
            console.printUnsafe("Kernel initialization error - spinning forever.\n");
            while (true) {
                cpu.halt();
            }
        }
        unreachable;
    }

    // Print exception info for kernel mode
    console.printUnsafe("\n!!! EXCEPTION: ");
    if (vector < exception_names.len) {
        console.printUnsafe(exception_names[vector]);
    }
    console.printUnsafe(" !!!\n");

    printFrame(frame);

    switch (vector) {
        14 => {
            const cr2 = cpu.readCr2();
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }

            const gp_checker = @atomicLoad(?*const fn (u64) ?state.GuardPageInfo, &state.guard_page_checker, .acquire);
            if (gp_checker) |checker| {
                if (checker(cr2)) |guard_info| {
                    debug.printStackOverflowDiagnostic(
                        guard_info.thread_id,
                        guard_info.thread_name,
                        cr2,
                        guard_info.stack_base,
                        guard_info.stack_top,
                    );
                    debug.dumpRegisters(frame);
                    debug.dumpControlRegisters();
                    console.printUnsafe("\nSystem halted due to stack overflow.\n");
                    cpu.halt();
                    return;
                }
            }
            debug.dumpPageFaultInfo(frame);
            debug.dumpControlRegisters();
        },
        8 => {
            console.printUnsafe("DOUBLE FAULT - System halted\n");
        },
        13 => {
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }
        },
        else => {},
    }

    console.printUnsafe("System halted.\n");
    cpu.halt();
}

/// LAPIC Timer handler
pub fn lapicTimerHandler(frame: *idt.InterruptFrame) void {
    const tmr_handler = @atomicLoad(?*const fn (*idt.InterruptFrame) *idt.InterruptFrame, &state.timer_handler, .acquire);
    if (tmr_handler) |handler| {
        const returned_frame = handler(frame);
        if (returned_frame != frame) {
            idt.setNewFrame(returned_frame);
        }
    }
    apic.lapic.sendEoi();
}

/// Print interrupt frame (register dump)
pub fn printFrame(frame: *idt.InterruptFrame) void {
    console.printUnsafe("Registers:\n");
    console.printUnsafe("  RAX=");
    printHex(frame.rax);
    console.printUnsafe(" RBX=");
    printHex(frame.rbx);
    console.printUnsafe(" RCX=");
    printHex(frame.rcx);
    console.printUnsafe("\n");

    console.printUnsafe("  RDX=");
    printHex(frame.rdx);
    console.printUnsafe(" RSI=");
    printHex(frame.rsi);
    console.printUnsafe(" RDI=");
    printHex(frame.rdi);
    console.printUnsafe("\n");

    console.printUnsafe("  RBP=");
    printHex(frame.rbp);
    console.printUnsafe(" RSP=");
    printHex(frame.rsp);
    console.printUnsafe("\n");

    console.printUnsafe("  R8 =");
    printHex(frame.r8);
    console.printUnsafe("  R9 =");
    printHex(frame.r9);
    console.printUnsafe(" R10=");
    printHex(frame.r10);
    console.printUnsafe("\n");

    console.printUnsafe("  R11=");
    printHex(frame.r11);
    console.printUnsafe(" R12=");
    printHex(frame.r12);
    console.printUnsafe(" R13=");
    printHex(frame.r13);
    console.printUnsafe("\n");

    console.printUnsafe("  R14=");
    printHex(frame.r14);
    console.printUnsafe(" R15=");
    printHex(frame.r15);
    console.printUnsafe("\n");

    console.printUnsafe("  RIP=");
    printHex(frame.rip);
    console.printUnsafe(" CS =");
    printHex(frame.cs);
    console.printUnsafe("\n");

    console.printUnsafe("  RFLAGS=");
    printHex(frame.rflags);
    console.printUnsafe("\n");

    console.printUnsafe("  Error code=");
    printHex(frame.error_code);
    console.printUnsafe(" Vector=");
    printHex(frame.vector);
    console.printUnsafe("\n");
}

/// Print a 64-bit value in hex
pub fn printHex(value: u64) void {
    const hex_chars = "0123456789ABCDEF";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @truncate(60 - i * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hex_chars[nibble];
    }

    console.printUnsafe(&buf);
}
