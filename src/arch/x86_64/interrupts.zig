// Interrupt Handlers for x86_64
//
// Contains exception handlers and IRQ handlers.
// These are registered with the IDT during initialization.

const idt = @import("idt.zig");
const pic = @import("pic.zig");
const cpu = @import("cpu.zig");

// Import console for output (will be set up during init)
var console_writer: ?*const fn ([]const u8) void = null;

// Keyboard IRQ handler callback (set by keyboard driver)
// This allows the HAL to call into the keyboard driver without importing it
var keyboard_handler: ?*const fn () void = null;

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
}

/// Set the keyboard handler callback
/// This allows the keyboard driver to register its IRQ handler
pub fn setKeyboardHandler(handler: *const fn () void) void {
    keyboard_handler = handler;
}

/// Generic exception handler
fn exceptionHandler(frame: *idt.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);

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
            if (console_writer) |write| {
                write("CR2 (faulting address): ");
                printHex(cr2);
                write("\n");

                // Decode error code
                const err = frame.error_code;
                write("  Cause: ");
                if (err & 1 == 0) {
                    write("Page not present");
                } else {
                    write("Protection violation");
                }
                if (err & 2 != 0) {
                    write(", Write access");
                } else {
                    write(", Read access");
                }
                if (err & 4 != 0) {
                    write(", User mode");
                } else {
                    write(", Supervisor mode");
                }
                if (err & 8 != 0) {
                    write(", Reserved bit set");
                }
                if (err & 16 != 0) {
                    write(", Instruction fetch");
                }
                write("\n");
            }
        },
        8 => {
            // Double fault - always fatal
            if (console_writer) |write| {
                write("DOUBLE FAULT - System halted\n");
            }
        },
        13 => {
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
            // Timer IRQ - just acknowledge for now
            // A real kernel would update tick count, check for preemption, etc.
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
