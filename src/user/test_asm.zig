// Minimal test userland program for Zscapek
// Uses direct syscalls to print "Hello" and exit

const std = @import("std");

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) {}
}

const message = "Hello\n";

// Entry point - must be exported for linker to find
export fn _start() callconv(.naked) noreturn {
    // sys_write(stdout=1, message, 6)
    // sys_exit(0)
    asm volatile (
        \\    mov $1, %%rax
        \\    mov $1, %%rdi
        \\    mov $6, %%rdx
        \\    syscall
        \\    mov $60, %%rax
        \\    xor %%rdi, %%rdi
        \\    syscall
        :
        : [msg] "{rsi}" (&message)
    );
}
