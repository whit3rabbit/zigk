const std = @import("std");
const builtin = @import("builtin");
pub const uapi = @import("uapi");
const syscalls = uapi.syscalls;

/// Memory barrier
pub inline fn memoryBarrier() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mfence" : : : .{ .memory = true }),
        .aarch64 => asm volatile ("dmb sy" : : : .{ .memory = true }),
        else => {},
    }
}

// =============================================================================
// Raw Syscall Primitives
// =============================================================================

fn syscallRaw(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (number),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3),
              [arg4] "{r10}" (arg4),
              [arg5] "{r8}" (arg5),
              [arg6] "{r9}" (arg6),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (number),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3),
              [arg4] "{x3}" (arg4),
              [arg5] "{x4}" (arg5),
              [arg6] "{x5}" (arg6),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture"),
    };
}

pub inline fn syscall0(number: usize) usize {
    return syscallRaw(number, 0, 0, 0, 0, 0, 0);
}

pub inline fn syscall1(number: usize, arg1: usize) usize {
    return syscallRaw(number, arg1, 0, 0, 0, 0, 0);
}

pub inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return syscallRaw(number, arg1, arg2, 0, 0, 0, 0);
}

pub inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return syscallRaw(number, arg1, arg2, arg3, 0, 0, 0);
}

pub inline fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return syscallRaw(number, arg1, arg2, arg3, arg4, 0, 0);
}

pub inline fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return syscallRaw(number, arg1, arg2, arg3, arg4, arg5, 0);
}

pub inline fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return syscallRaw(number, arg1, arg2, arg3, arg4, arg5, arg6);
}

// =============================================================================
// Error Handling
// =============================================================================

pub const SyscallError = error{
    PermissionDenied,
    NoSuchFileOrDirectory,
    NoSuchProcess,
    Interrupted,
    IoError,
    NoSuchDevice,
    ArgumentListTooLong,
    ExecFormatError,
    BadFileDescriptor,
    NoChildProcesses,
    WouldBlock,
    OutOfMemory,
    AccessDenied,
    BadAddress,
    DeviceBusy,
    FileExists,
    InvalidArgument,
    TooManyOpenFiles,
    NotImplemented,
    Unexpected,
};

pub fn errorFromReturn(ret: usize) SyscallError {
    const err: isize = @bitCast(ret);
    if (err >= 0) return error.Unexpected;

    const errno_val: i32 = @truncate(-err);
    return switch (errno_val) {
        1 => error.PermissionDenied,
        2 => error.NoSuchFileOrDirectory,
        3 => error.NoSuchProcess,
        4 => error.Interrupted,
        5 => error.IoError,
        6 => error.NoSuchDevice,
        7 => error.ArgumentListTooLong,
        8 => error.ExecFormatError,
        9 => error.BadFileDescriptor,
        10 => error.NoChildProcesses,
        11 => error.WouldBlock,
        12 => error.OutOfMemory,
        13 => error.AccessDenied,
        14 => error.BadAddress,
        16 => error.DeviceBusy,
        17 => error.FileExists,
        22 => error.InvalidArgument,
        24 => error.TooManyOpenFiles,
        38 => error.NotImplemented,
        else => error.Unexpected,
    };
}

pub inline fn isError(ret: usize) bool {
    const signed: isize = @bitCast(ret);
    return signed < 0 and signed >= -4096;
}
