const std = @import("std");
const builtin = @import("builtin");
const uapi = @import("uapi");

// Inline syscall wrapper to avoid module dependency issues
fn sys_write(fd: i32, buf: []const u8) usize {
    const number = uapi.syscalls.SYS_WRITE;
    const arg1 = @as(usize, @intCast(fd));
    const arg2 = @intFromPtr(buf.ptr);
    const arg3 = buf.len;

    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize)
            : [number] "{rax}" (number),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3)
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize)
            : [number] "{x8}" (number),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3)
            : .{ .memory = true }
        ),
        else => 0,
    };
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&buf, fmt, args)) |written| {
        _ = sys_write(1, written);
    } else |_| {
        // truncated or error
    }
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    print(fmt ++ "\n", args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    _ = fmt;
    _ = args;
    // print("DEBUG: " ++ fmt ++ "\n", args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    print("INFO: " ++ fmt ++ "\n", args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    print("WARN: " ++ fmt ++ "\n", args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    print("ERR: " ++ fmt ++ "\n", args);
}
