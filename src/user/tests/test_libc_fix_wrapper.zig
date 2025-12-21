const std = @import("std");
const libc = @import("libc");
const syscall = @import("syscall");


// Force libc exports to be linked
comptime {
    _ = &libc.printf;
    _ = &libc.__errno_location;
    _ = &libc.signal;
    _ = &libc.raise;
    _ = &libc.stdout;
    _ = &libc.stderr;
}
