// Interrupt Handlers for x86_64
//
// Contains exception handlers and IRQ handlers.
// These are registered with the IDT during initialization.

const idt = @import("idt.zig");
const pic = @import("pic.zig");
const cpu = @import("cpu.zig");
const debug = @import("debug.zig");

// Import console for output (will be set up during init)
var console_writer: ?*const fn ([]const u8) void = null;

// Keyboard IRQ handler callback (set by keyboard driver)
// This allows the HAL to call into the keyboard driver without importing it
var keyboard_handler: ?*const fn () void = null;

// Timer IRQ handler callback (set by scheduler)
// Returns a new frame pointer for context switching
// This allows the scheduler to perform preemptive context switches
var timer_handler: ?*const fn (*idt.InterruptFrame) *idt.InterruptFrame = null;

// Guard page fault handler callback (set by scheduler/thread module)
// Called when a page fault might be a stack overflow
// Returns thread info if the fault is in a guard page: (tid, name, stack_base, stack_top)
// Returns null if not a guard page fault
pub const GuardPageInfo = struct {
    thread_id: u32,
    thread_name: []const u8,
    stack_base: u64,
    stack_top: u64,
};
var guard_page_checker: ?*const fn (u64) ?GuardPageInfo = null;

// #NM (Device Not Available) handler callback for lazy FPU switching
// Called when a thread attempts to use FPU/SSE with CR0.TS set
// Returns true if handled (FPU state restored), false if not handled
var fpu_access_handler: ?*const fn () bool = null;

/// Exception names for debugging
const exception_names = [_][]const u8{
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

/// Initialize interrupt handlers
/// Must be called after IDT is set up
pub fn init() void {
    // Register exception handlers
    for (0..32) |i| {
        idt.registerHandler(@truncate(i), exceptionHandler);
    }

    // Register IRQ handlers (vectors 32-47)
    for (32..48) |i| {
        idt.registerHandler(@truncate(i), irqHandler);
    }
}

/// Set the console writer for debug output
pub fn setConsoleWriter(writer: *const fn ([]const u8) void) void {
    console_writer = writer;
    // Also set up debug module console writer
    debug.setConsoleWriter(writer);
}

/// Set the keyboard handler callback
/// This allows the keyboard driver to register its IRQ handler
pub fn setKeyboardHandler(handler: *const fn () void) void {
    keyboard_handler = handler;
}

/// Set the timer handler callback
/// This allows the scheduler to register its timer tick handler
/// The handler receives the current frame and returns the frame to restore
/// (may be different for context switch)
pub fn setTimerHandler(handler: *const fn (*idt.InterruptFrame) *idt.InterruptFrame) void {
    timer_handler = handler;
}

/// Set the guard page checker callback
/// This allows the scheduler/thread module to provide thread info for stack overflow detection
/// The callback is called with a fault address and returns thread info if in a guard page
pub fn setGuardPageChecker(checker: *const fn (u64) ?GuardPageInfo) void {
    guard_page_checker = checker;
}

/// Set the FPU access handler callback for lazy FPU switching
/// This allows the scheduler to handle #NM exceptions when threads access FPU
pub fn setFpuAccessHandler(handler: *const fn () bool) void {
    fpu_access_handler = handler;
}

/// Generic exception handler
fn exceptionHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

    // Handle #NM (Device Not Available) for lazy FPU switching
    // This is not an error - it's how we implement lazy FPU save/restore
    if (vector == 7) {
        if (fpu_access_handler) |handler| {
            if (handler()) {
                // FPU state restored, thread can continue
                return;
            }
        }
        // If no handler or handler failed, fall through to error handling
    }

    // Print exception info
    if (console_writer) |write| {
        write("\n!!! EXCEPTION: ");
        if (vector < exception_names.len) {
            write(exception_names[vector]);
        }
        write(" !!!\n");
    }

    // Print register state
    printFrame(frame);

    // For certain exceptions, print additional info
    switch (vector) {
        14 => {
            // Page fault - CR2 contains faulting address
            const cr2 = cpu.readCr2();

            // Check if we are in a safe copy region
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                // Redirect to fixup handler
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }

            // Check if this is a stack guard page fault
            if (guard_page_checker) |checker| {
                if (checker(cr2)) |guard_info| {
                    // This is a stack overflow - print detailed diagnostic
                    debug.printStackOverflowDiagnostic(
                        guard_info.thread_id,
                        guard_info.thread_name,
                        cr2,
                        guard_info.stack_base,
                        guard_info.stack_top,
                    );
                    // Use debug module for full register dump
                    debug.dumpRegisters(frame);
                    debug.dumpControlRegisters();
                    if (console_writer) |write| {
                        write("\nSystem halted due to stack overflow.\n");
                    }
                    cpu.halt();
                    return;
                }
            }

            // Regular page fault - use debug module for detailed output
            debug.dumpPageFaultInfo(frame);
            debug.dumpControlRegisters();
        },
        8 => {
            // Double fault - always fatal
            if (console_writer) |write| {
                write("DOUBLE FAULT - System halted\n");
            }
        },
        13 => {
            // Handle non-canonical pointers during user copy (#GP instead of #PF)
            const rip = frame.rip;
            if (rip >= @intFromPtr(&_asm_copy_user_start) and rip < @intFromPtr(&_asm_copy_user_end)) {
                frame.rip = @intFromPtr(&_asm_copy_user_fixup);
                return;
            }

            // General protection fault
            if (frame.error_code != 0) {
                if (console_writer) |write| {
                    write("Selector: ");
                    printHex(frame.error_code);
                    write("\n");
                }
            }
        },
        else => {},
    }

    // Halt on exception (for now)
    // In a real kernel, we might kill the faulting process instead
    if (console_writer) |write| {
        write("System halted.\n");
    }
    cpu.halt();
}

// External symbols for safe copy fixup
extern const _asm_copy_user_start: anyopaque;
extern const _asm_copy_user_end: anyopaque;
extern const _asm_copy_user_fixup: anyopaque;

/// Generic IRQ handler
fn irqHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    const irq = vector - pic.IRQ_OFFSET;

    // Check for spurious IRQ
    if (pic.isSpurious(irq)) {
        return;
    }

    // Handle specific IRQs
    switch (irq) {
        0 => {
            // Timer IRQ - delegate to scheduler for preemption
            if (timer_handler) |handler| {
                // The handler returns the frame to restore (possibly different thread)
                const new_frame = handler(frame);
                // Signal dispatch_interrupt to use this frame instead
                if (new_frame != frame) {
                    idt.setNewFrame(new_frame);
                }
            }
            // If no timer handler, just acknowledge and continue
        },
        1 => {
            // Keyboard IRQ - delegate to keyboard driver
            if (keyboard_handler) |handler| {
                handler();
            } else {
                // Fallback: read scancode to acknowledge (prevents keyboard lockup)
                _ = @import("io.zig").inb(0x60);
            }
        },
        else => {
            // Unhandled IRQ
        },
    }

    // Send EOI to PIC
    pic.sendEoi(irq);
}

/// Print interrupt frame (register dump)
fn printFrame(frame: *idt.InterruptFrame) void {
    if (console_writer == null) return;
    const write = console_writer.?;

    write("Registers:\n");
    write("  RAX=");
    printHex(frame.rax);
    write(" RBX=");
    printHex(frame.rbx);
    write(" RCX=");
    printHex(frame.rcx);
    write("\n");

    write("  RDX=");
    printHex(frame.rdx);
    write(" RSI=");
    printHex(frame.rsi);
    write(" RDI=");
    printHex(frame.rdi);
    write("\n");

    write("  RBP=");
    printHex(frame.rbp);
    write(" RSP=");
    printHex(frame.rsp);
    write("\n");

    write("  R8 =");
    printHex(frame.r8);
    write(" R9 =");
    printHex(frame.r9);
    write(" R10=");
    printHex(frame.r10);
    write("\n");

    write("  R11=");
    printHex(frame.r11);
    write(" R12=");
    printHex(frame.r12);
    write(" R13=");
    printHex(frame.r13);
    write("\n");

    write("  R14=");
    printHex(frame.r14);
    write(" R15=");
    printHex(frame.r15);
    write("\n");

    write("  RIP=");
    printHex(frame.rip);
    write(" CS =");
    printHex(frame.cs);
    write("\n");

    write("  RFLAGS=");
    printHex(frame.rflags);
    write("\n");

    write("  Error code=");
    printHex(frame.error_code);
    write(" Vector=");
    printHex(frame.vector);
    write("\n");
}

/// Print a 64-bit value in hex
fn printHex(value: u64) void {
    if (console_writer == null) return;
    const write = console_writer.?;

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

    write(&buf);
}
