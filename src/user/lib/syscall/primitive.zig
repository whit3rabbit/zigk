const std = @import("std");
pub const uapi = @import("uapi");
const syscalls = uapi.syscalls;

/// Memory barrier for x86_64 userspace
pub inline fn memoryBarrier() void {
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
}

// =============================================================================
// Raw Syscall Primitives
// =============================================================================

/// Execute syscall with 0 arguments
pub inline fn syscall0(number: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 1 argument
pub inline fn syscall1(number: usize, arg1: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 2 arguments
pub inline fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 3 arguments
pub inline fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 4 arguments
/// Note: R10 is used instead of RCX because syscall clobbers RCX
pub inline fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 5 arguments
pub inline fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

/// Execute syscall with 6 arguments
pub inline fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [number] "{rax}" (number),
          [arg1] "{rdi}" (arg1),
          [arg2] "{rsi}" (arg2),
          [arg3] "{rdx}" (arg3),
          [arg4] "{r10}" (arg4),
          [arg5] "{r8}" (arg5),
          [arg6] "{r9}" (arg6),
        : .{ .rcx = true, .r11 = true, .memory = true }
    );
}

// =============================================================================
// Error Handling
// =============================================================================

/// Result type for syscalls that can fail
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

/// Convert raw syscall return value to error union
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

/// Check if return value indicates error (negative)
pub inline fn isError(ret: usize) bool {
    const signed: isize = @bitCast(ret);
    return signed < 0 and signed >= -4096;
}
