const std = @import("std");
const builtin = @import("builtin");
const libc = @import("libc");
const syscall = @import("syscall");

// Import main from C test
extern fn main() c_int;

// Entry point called by ELF loader (aarch64 only - x86_64 uses crt0.S)
const Aarch64Entry = if (builtin.cpu.arch == .aarch64) struct {
    pub export fn _start() noreturn {
        const ret = main();
        libc.exit(ret);
        while (true) {}
    }
} else struct {};

comptime {
    _ = Aarch64Entry;
}

// Force libc exports to be linked
// Note: printf is exported directly to C, use _impl for references
comptime {
    _ = &libc.printf_impl;
    _ = &libc.fprintf_impl;
    _ = &libc.sprintf_impl;
    _ = &libc.snprintf_impl;
    _ = &libc.sscanf_impl;
    _ = &libc.fscanf_impl;
    _ = &libc.scanf_impl;
    _ = &libc.__errno_location;
    _ = &libc.signal;
    _ = &libc.raise;
    _ = &libc.stdout;
    _ = &libc.stderr;
}
