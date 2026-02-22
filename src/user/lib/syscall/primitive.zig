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
    PermissionDenied,        // 1
    NoSuchFileOrDirectory,   // 2
    NoSuchProcess,           // 3
    Interrupted,             // 4
    IoError,                 // 5
    NoSuchDevice,            // 6
    ArgumentListTooLong,     // 7
    ExecFormatError,         // 8
    BadFileDescriptor,       // 9
    NoChildProcesses,        // 10
    WouldBlock,              // 11
    OutOfMemory,             // 12
    AccessDenied,            // 13
    BadAddress,              // 14
    DeviceBusy,              // 16
    FileExists,              // 17
    NotADirectory,           // 20
    IsADirectory,            // 21
    InvalidArgument,         // 22
    TooManyOpenFiles,        // 24
    NoSpace,                 // 28
    IllegalSeek,             // 29
    ReadOnlyFilesystem,      // 30
    TooManyLinks,            // 31
    BrokenPipe,              // 32
    FilenameTooLong,         // 36
    NotImplemented,          // 38
    DirectoryNotEmpty,       // 39
    TooManySymbolicLinks,    // 40
    NotASocket,              // 88
    OperationNotSupported,   // 95
    AddressFamilyNotSupported, // 97
    AddressInUse,            // 98
    AddressNotAvailable,     // 99
    NetworkDown,             // 100
    NetworkUnreachable,      // 101
    ConnectionAborted,       // 103
    ConnectionReset,         // 104
    NoBufferSpace,           // 105
    AlreadyConnected,        // 106
    NotConnected,            // 107
    ConnectionTimedOut,      // 110
    ConnectionRefused,       // 111
    HostUnreachable,         // 113
    AlreadyInProgress,       // 114
    InProgress,              // 115
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
        20 => error.NotADirectory,
        21 => error.IsADirectory,
        22 => error.InvalidArgument,
        24 => error.TooManyOpenFiles,
        28 => error.NoSpace,
        29 => error.IllegalSeek,
        30 => error.ReadOnlyFilesystem,
        31 => error.TooManyLinks,
        32 => error.BrokenPipe,
        36 => error.FilenameTooLong,
        38 => error.NotImplemented,
        39 => error.DirectoryNotEmpty,
        40 => error.TooManySymbolicLinks,
        88 => error.NotASocket,
        95 => error.OperationNotSupported,
        97 => error.AddressFamilyNotSupported,
        98 => error.AddressInUse,
        99 => error.AddressNotAvailable,
        100 => error.NetworkDown,
        101 => error.NetworkUnreachable,
        103 => error.ConnectionAborted,
        104 => error.ConnectionReset,
        105 => error.NoBufferSpace,
        106 => error.AlreadyConnected,
        107 => error.NotConnected,
        110 => error.ConnectionTimedOut,
        111 => error.ConnectionRefused,
        113 => error.HostUnreachable,
        114 => error.AlreadyInProgress,
        115 => error.InProgress,
        else => error.Unexpected,
    };
}

pub inline fn isError(ret: usize) bool {
    const signed: isize = @bitCast(ret);
    return signed < 0 and signed >= -4096;
}
