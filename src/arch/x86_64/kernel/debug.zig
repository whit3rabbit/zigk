// Debug Helpers for x86_64
//
// Provides diagnostic utilities for exception handlers and kernel debugging.
// These helpers format and print register states, detect stack overflow
// conditions, and provide crash diagnostics.
//
// Per FR-032-034 from archived/004: Page fault handler must print CR2/RIP
// and provide comprehensive register dumps for debugging.

const cpu = @import("cpu.zig");
const idt = @import("idt.zig");

// Console writer callback - set by interrupts package (init.zig)
var console_writer: ?*const fn ([]const u8) void = null;

/// Set the console writer for debug output
pub fn setConsoleWriter(writer: *const fn ([]const u8) void) void {
    console_writer = writer;
}

/// Dump all registers from an interrupt frame
/// Provides a comprehensive view of CPU state at the time of the exception
pub fn dumpRegisters(frame: *const idt.InterruptFrame) void {
    const write = console_writer orelse return;

    write("=== Register Dump ===\n");

    // General purpose registers
    write("General Purpose Registers:\n");

    write("  RAX=");
    printHex64(frame.rax);
    write("  RBX=");
    printHex64(frame.rbx);
    write("\n");

    write("  RCX=");
    printHex64(frame.rcx);
    write("  RDX=");
    printHex64(frame.rdx);
    write("\n");

    write("  RSI=");
    printHex64(frame.rsi);
    write("  RDI=");
    printHex64(frame.rdi);
    write("\n");

    write("  RBP=");
    printHex64(frame.rbp);
    write("  RSP=");
    printHex64(frame.rsp);
    write("\n");

    write("  R8 =");
    printHex64(frame.r8);
    write("  R9 =");
    printHex64(frame.r9);
    write("\n");

    write("  R10=");
    printHex64(frame.r10);
    write("  R11=");
    printHex64(frame.r11);
    write("\n");

    write("  R12=");
    printHex64(frame.r12);
    write("  R13=");
    printHex64(frame.r13);
    write("\n");

    write("  R14=");
    printHex64(frame.r14);
    write("  R15=");
    printHex64(frame.r15);
    write("\n");

    // Instruction pointer and segment registers
    write("Instruction Pointer:\n");
    write("  RIP=");
    printHex64(frame.rip);
    write("  CS=");
    printHex16(@truncate(frame.cs));
    write("  SS=");
    printHex16(@truncate(frame.ss));
    write("\n");

    // Flags register
    write("Flags:\n");
    write("  RFLAGS=");
    printHex64(frame.rflags);
    printRflags(frame.rflags);
    write("\n");

    // Exception info
    write("Exception Info:\n");
    write("  Vector=");
    printHex8(@truncate(frame.vector));
    write("  Error Code=");
    printHex64(frame.error_code);
    write("\n");
}

/// Dump control registers (CR0, CR2, CR3, CR4)
/// Useful for debugging page faults and memory issues
pub fn dumpControlRegisters() void {
    const write = console_writer orelse return;

    write("Control Registers:\n");

    write("  CR0=");
    printHex64(cpu.readCr0());
    write("  CR2=");
    printHex64(cpu.readCr2());
    write("\n");

    write("  CR3=");
    printHex64(cpu.readCr3());
    write("  CR4=");
    printHex64(cpu.readCr4());
    write("\n");
}

/// Print detailed page fault information
/// Decodes the error code bits and prints the faulting address from CR2
pub fn dumpPageFaultInfo(frame: *const idt.InterruptFrame) void {
    const write = console_writer orelse return;

    const cr2 = cpu.readCr2();
    const err = frame.error_code;

    write("Page Fault Details:\n");

    write("  Faulting Address (CR2): ");
    printHex64(cr2);
    write("\n");

    write("  Faulting Instruction (RIP): ");
    printHex64(frame.rip);
    write("\n");

    write("  Error Code: ");
    printHex64(err);
    write("\n");

    // Decode error code bits
    write("  Cause: ");
    if (err & 1 == 0) {
        write("Page not present");
    } else {
        write("Protection violation");
    }

    if (err & 2 != 0) {
        write(" | Write access");
    } else {
        write(" | Read access");
    }

    if (err & 4 != 0) {
        write(" | User mode");
    } else {
        write(" | Supervisor mode");
    }

    if (err & 8 != 0) {
        write(" | Reserved bit set");
    }

    if (err & 16 != 0) {
        write(" | Instruction fetch");
    }

    write("\n");
}

/// Check if an address is within a guard page region
/// Returns true if the address is in the guard page (stack overflow likely)
pub fn isGuardPageFault(fault_addr: u64, stack_base: u64, page_size: usize) bool {
    // Guard page is the page immediately below the stack base
    // Stack grows downward, so guard is at (stack_base - page_size) to stack_base
    const guard_start = stack_base;
    const guard_end = stack_base + page_size;

    return fault_addr >= guard_start and fault_addr < guard_end;
}

/// Print stack overflow diagnostic message
/// Called when a page fault is detected in a guard page region
pub fn printStackOverflowDiagnostic(
    thread_id: ?u64, // u64 to match Thread.tid
    thread_name: ?[]const u8,
    fault_addr: u64,
    stack_base: u64,
    stack_top: u64,
) void {
    const write = console_writer orelse return;

    write("\n");
    write("!!! STACK OVERFLOW DETECTED !!!\n");
    write("\n");

    if (thread_id) |tid| {
        write("Thread ID: ");
        printDecimal(tid);
        write("\n");
    }

    if (thread_name) |name| {
        write("Thread Name: ");
        write(name);
        write("\n");
    }

    write("Fault Address: ");
    printHex64(fault_addr);
    write("\n");

    write("Stack Base (Guard Page): ");
    printHex64(stack_base);
    write("\n");

    write("Stack Top: ");
    printHex64(stack_top);
    write("\n");

    write("\n");
    write("The thread's stack has grown beyond its allocated region.\n");
    write("Consider increasing stack size or reducing recursion depth.\n");
}

// --- Formatting helpers ---

/// Print a 64-bit value in hex with 0x prefix
fn printHex64(value: u64) void {
    const write = console_writer orelse return;

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

/// Print a 32-bit value in hex with 0x prefix
fn printHex32(value: u32) void {
    const write = console_writer orelse return;

    const hex_chars = "0123456789ABCDEF";
    var buf: [10]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @truncate(28 - i * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hex_chars[nibble];
    }

    write(&buf);
}

/// Print a 16-bit value in hex with 0x prefix
fn printHex16(value: u16) void {
    const write = console_writer orelse return;

    const hex_chars = "0123456789ABCDEF";
    var buf: [6]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const shift: u4 = @truncate(12 - i * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hex_chars[nibble];
    }

    write(&buf);
}

/// Print an 8-bit value in hex with 0x prefix
fn printHex8(value: u8) void {
    const write = console_writer orelse return;

    const hex_chars = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    buf[2] = hex_chars[value >> 4];
    buf[3] = hex_chars[value & 0xF];

    write(&buf);
}

/// Print a decimal number (u64 for TID support)
fn printDecimal(value: u64) void {
    const write = console_writer orelse return;

    if (value == 0) {
        write("0");
        return;
    }

    var buf: [20]u8 = undefined; // 20 digits max for u64
    var i: usize = 0;
    var v = value;

    while (v > 0) : (i += 1) {
        buf[19 - i] = '0' + @as(u8, @truncate(v % 10));
        v /= 10;
    }

    write(buf[20 - i ..]);
}

/// Print decoded RFLAGS bits
fn printRflags(rflags: u64) void {
    const write = console_writer orelse return;

    write(" [");

    if (rflags & (1 << 0) != 0) write(" CF"); // Carry Flag
    if (rflags & (1 << 2) != 0) write(" PF"); // Parity Flag
    if (rflags & (1 << 4) != 0) write(" AF"); // Auxiliary Flag
    if (rflags & (1 << 6) != 0) write(" ZF"); // Zero Flag
    if (rflags & (1 << 7) != 0) write(" SF"); // Sign Flag
    if (rflags & (1 << 8) != 0) write(" TF"); // Trap Flag
    if (rflags & (1 << 9) != 0) write(" IF"); // Interrupt Flag
    if (rflags & (1 << 10) != 0) write(" DF"); // Direction Flag
    if (rflags & (1 << 11) != 0) write(" OF"); // Overflow Flag
    if (rflags & (1 << 14) != 0) write(" NT"); // Nested Task
    if (rflags & (1 << 16) != 0) write(" RF"); // Resume Flag
    if (rflags & (1 << 17) != 0) write(" VM"); // Virtual 8086 Mode
    if (rflags & (1 << 18) != 0) write(" AC"); // Alignment Check
    if (rflags & (1 << 19) != 0) write(" VIF"); // Virtual Interrupt Flag
    if (rflags & (1 << 20) != 0) write(" VIP"); // Virtual Interrupt Pending
    if (rflags & (1 << 21) != 0) write(" ID"); // ID Flag

    write(" ]");
}
