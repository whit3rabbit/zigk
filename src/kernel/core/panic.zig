//! Kernel Panic and Crash Handling
//!
//! Provides the core `panic` handler used by Zig's safety features and the kernel's
//! own error handling mechanisms.
//!
//! Also handles user-mode exceptions (crashes), mapping hardware exceptions to POSIX signals
//! and terminating the offending process.
//!
//! SECURITY (KASLR): In release builds, kernel addresses are masked to prevent
//! KASLR bypass through panic output. Attackers cannot determine the kernel's
//! randomized base address from panic messages.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const console = @import("console");
const process = @import("process");
const layout = @import("layout");

/// Mask a kernel address for display in panic output.
/// In Debug builds, returns the full address for debugging.
/// In Release builds, returns only the offset from kernel base to prevent KASLR leaks.
pub fn maskAddress(addr: u64) u64 {
    if (builtin.mode == .Debug) {
        // Debug mode: show full address for development
        return addr;
    }

    // Release modes: mask to prevent KASLR bypass
    if (!layout.isInitialized()) {
        // Layout not initialized yet - show placeholder
        return 0xDEAD_DEAD_DEAD_DEAD;
    }

    const kernel_base = layout.getHhdmBase();
    if (addr >= kernel_base) {
        // Kernel address: show offset from base only
        // Attacker cannot determine absolute address without knowing base
        return addr - kernel_base;
    }

    // User address or unknown: show as-is (not sensitive)
    return addr;
}

/// Format a masked address for panic output.
/// In Debug: "0x<full address>"
/// In Release: "<kernel+0x<offset>>"
pub fn formatMaskedAddress(addr: u64, buf: []u8) []u8 {
    if (builtin.mode == .Debug) {
        return std.fmt.bufPrint(buf, "0x{x}", .{addr}) catch buf[0..0];
    }

    const masked = maskAddress(addr);
    if (masked == 0xDEAD_DEAD_DEAD_DEAD) {
        return std.fmt.bufPrint(buf, "<uninitialized>", .{}) catch buf[0..0];
    }

    const kernel_base = if (layout.isInitialized()) layout.getHhdmBase() else 0;
    if (addr >= kernel_base) {
        return std.fmt.bufPrint(buf, "<kernel+0x{x}>", .{masked}) catch buf[0..0];
    }

    return std.fmt.bufPrint(buf, "0x{x}", .{addr}) catch buf[0..0];
}

/// Halt the kernel (disables interrupts and loops forever)
pub fn halt() noreturn {
    hal.cpu.haltForever();
}

/// Custom panic handler for freestanding environment
/// Called by Zig's runtime on safety violations or explicit `@panic` calls.
/// Prints the message and halts the CPU.
///
/// SECURITY: Does not print kernel addresses in release builds to protect KASLR.
pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // Disable interrupts to prevent further issues on this core
    hal.cpu.disableInterrupts();

    // Use printUnsafe to avoid locks during panic
    console.printUnsafe("\n!!! KERNEL PANIC !!!\n");
    console.printUnsafe("Message: ");
    console.printUnsafe(msg);
    console.printUnsafe("\n");

    // Print return address if available (masked in release builds)
    if (ret_addr) |addr| {
        if (builtin.mode == .Debug) {
            var buf: [64]u8 = undefined;
            const formatted = std.fmt.bufPrint(&buf, "Return address: 0x{x}\n", .{addr}) catch "";
            console.printUnsafe(formatted);
        } else {
            var buf: [64]u8 = undefined;
            const masked = maskAddress(addr);
            const formatted = std.fmt.bufPrint(&buf, "Return address: <kernel+0x{x}>\n", .{masked}) catch "";
            console.printUnsafe(formatted);
        }
    }

    // Print stack trace if available (masked in release builds)
    if (trace) |t| {
        printMaskedStackTrace(t);
    }

    halt();
}

/// Print a stack trace with addresses masked in release builds
fn printMaskedStackTrace(trace: *std.builtin.StackTrace) void {
    console.printUnsafe("Stack trace:\n");

    var buf: [64]u8 = undefined;
    for (trace.instruction_addresses) |addr| {
        if (addr == 0) break;

        if (builtin.mode == .Debug) {
            const formatted = std.fmt.bufPrint(&buf, "  0x{x}\n", .{addr}) catch "";
            console.printUnsafe(formatted);
        } else {
            const masked = maskAddress(addr);
            const formatted = std.fmt.bufPrint(&buf, "  <kernel+0x{x}>\n", .{masked}) catch "";
            console.printUnsafe(formatted);
        }
    }
}

/// Handle user process crashes (exceptions in user mode)
/// Called by the IDT exception handlers when an exception occurs in Ring 3.
/// Maps the CPU exception vector to a POSIX signal and terminates the process.
pub fn handleCrash(vector: u8, err_code: u64) noreturn {
    // Map exception vector to POSIX signal
    const signal: i32 = switch (vector) {
        0 => 8,  // #DE -> SIGFPE
        6 => 4,  // #UD -> SIGILL
        13, 14 => 11, // #GP, #PF -> SIGSEGV
        else => 11, // Default to SIGSEGV
    };

    // Always log crashes
    // Use printUnsafe or be careful with formatted printing if it might alloc/lock
    // console.warn uses printf which is generally safe but relies on backend.
    // For crash handlers we prefer simple output.
    
    // For MVP we assume console.warn is safe enough for user crashes
    console.warn("Process crashed! Vector={d} Code={x} Signal={d}", .{ vector, err_code, signal });

    // Terminate the process with signal status
    // Signal status is stored in bits 0-6 of exit_status
    process.exit(signal);
}
