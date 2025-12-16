//! Kernel Panic and Crash Handling
//!
//! Provides the core `panic` handler used by Zig's safety features and the kernel's
//! own error handling mechanisms.
//!
//! Also handles user-mode exceptions (crashes), mapping hardware exceptions to POSIX signals
//! and terminating the offending process.

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const process = @import("process");

/// Halt the kernel (disables interrupts and loops forever)
pub fn halt() noreturn {
    hal.cpu.haltForever();
}

/// Custom panic handler for freestanding environment
/// Called by Zig's runtime on safety violations or explicit `@panic` calls.
/// Prints the message and halts the CPU.
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    // Disable interrupts to prevent further issues on this core
    hal.cpu.disableInterrupts();

    console.printUnsafe("\n!!! KERNEL PANIC !!!\n");
    console.printUnsafe("Message: ");
    console.printUnsafe(msg);
    console.printUnsafe("\n");

    halt();
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
    console.warn("Process crashed! Vector={d} Code={x} Signal={d}", .{ vector, err_code, signal });

    // Terminate the process with signal status
    // Signal status is stored in bits 0-6 of exit_status
    process.exit(signal);
}
