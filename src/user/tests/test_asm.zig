// Minimal test userland program for Zscapek
// Uses direct syscalls to print "Hello" and exit

const std = @import("std");
const builtin = @import("builtin");

pub fn panic(msg: []const u8, stack_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    _ = stack_trace;
    while (true) {}
}

const message = "Hello\n";

// Entry point - must be exported for linker to find
export fn _start() callconv(.naked) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // Note: Use message (the pointer) not &message (address of the pointer variable)
            asm volatile (
                \\    mov $1, %%rax
                \\    mov $1, %%rdi
                \\    mov $6, %%rdx
                \\    syscall
                \\    mov $60, %%rax
                \\    xor %%rdi, %%rdi
                \\    syscall
                :
                : [msg] "{rsi}" (message)
            );
        },
        .aarch64 => {
            // Note: Use message (the pointer) not &message (address of the pointer variable)
            asm volatile (
                \\    mov x8, #64 // sys_write
                \\    mov x0, #1  // stdout
                \\    mov x2, #6  // count
                \\    svc #0
                \\    mov x8, #93 // sys_exit
                \\    mov x0, #0
                \\    svc #0
                :
                : [msg] "{x1}" (message)
            );
        },
        else => @compileError("Unsupported architecture"),
    }
}
