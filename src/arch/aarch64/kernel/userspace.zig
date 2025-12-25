// AArch64 Userspace Support
//
// Provides syscall wrapper functions for userspace programs
// and utilities for transitioning to/from EL0.
//
// AArch64 Linux Syscall ABI:
// - Syscall number: x8
// - Arguments: x0-x5
// - Return value: x0
// - SVC #0 triggers the syscall

/// Perform syscall with no arguments
pub fn syscall0(number: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 1 argument
pub fn syscall1(number: usize, arg1: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 2 arguments
pub fn syscall2(number: usize, arg1: usize, arg2: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
          [arg2] "{x1}" (arg2),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 3 arguments
pub fn syscall3(number: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
          [arg2] "{x1}" (arg2),
          [arg3] "{x2}" (arg3),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 4 arguments
pub fn syscall4(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
          [arg2] "{x1}" (arg2),
          [arg3] "{x2}" (arg3),
          [arg4] "{x3}" (arg4),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 5 arguments
pub fn syscall5(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
          [arg2] "{x1}" (arg2),
          [arg3] "{x2}" (arg3),
          [arg4] "{x3}" (arg4),
          [arg5] "{x4}" (arg5),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 6 arguments
pub fn syscall6(number: usize, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    var ret: usize = undefined;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
          [arg1] "{x0}" (arg1),
          [arg2] "{x1}" (arg2),
          [arg3] "{x2}" (arg3),
          [arg4] "{x3}" (arg4),
          [arg5] "{x4}" (arg5),
          [arg6] "{x5}" (arg6),
        : .{ .memory = true }
    );
    return ret;
}

/// Enter userspace at specified entry point with given stack pointer
/// This is a one-way transition - the function never returns
pub fn enterUserspace(entry: u64, stack: u64) noreturn {
    // SPSR_EL1 = 0 means:
    // - Return to EL0 with SP_EL0
    // - All interrupts enabled (DAIF = 0)
    // - AArch64 execution state
    const spsr: u64 = 0;

    asm volatile (
        \\msr spsr_el1, %[spsr]
        \\msr elr_el1, %[entry]
        \\msr sp_el0, %[stack]
        \\eret
        :
        : [spsr] "r" (spsr),
          [entry] "r" (entry),
          [stack] "r" (stack),
    );
    unreachable;
}

/// Enter userspace with argc/argv/envp setup on stack
/// stack_top: Top of user stack
/// entry: Entry point address
/// argc: Argument count
/// argv: Pointer to argument vector
/// envp: Pointer to environment vector
pub fn enterUserspaceWithArgs(
    entry: u64,
    stack_top: u64,
    argc: usize,
    argv: [*]const [*:0]const u8,
    envp: [*]const [*:0]const u8,
) noreturn {
    // Set up stack for program start
    // AArch64 ABI: sp must be 16-byte aligned
    // Stack layout at entry:
    //   sp+0:  argc
    //   sp+8:  argv[0]
    //   ...
    //   sp+n:  NULL
    //   sp+n+8: envp[0]
    //   ...
    //   sp+m:  NULL

    var sp = stack_top;

    // Count envp entries
    var envp_count: usize = 0;
    while (envp[envp_count] != @as([*:0]const u8, @ptrFromInt(0))) {
        envp_count += 1;
    }

    // Push NULL terminator for envp
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // Push envp entries (reverse order)
    var i: usize = envp_count;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        @as(*u64, @ptrFromInt(sp)).* = @intFromPtr(envp[i]);
    }

    // Push NULL terminator for argv
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    // Push argv entries (reverse order)
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        @as(*u64, @ptrFromInt(sp)).* = @intFromPtr(argv[i]);
    }

    // Push argc
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = argc;

    // Align sp to 16 bytes
    sp = sp & ~@as(u64, 0xF);

    enterUserspace(entry, sp);
}

/// Initialize userspace support
pub fn init() void {
    // Set up TTBR0_EL1 for user address space (lower half)
    // TCR_EL1 configuration is done in boot code

    // Enable user access to generic timer
    // CNTKCTL_EL1: Allow EL0 to access physical timer
    asm volatile (
        \\mrs x0, cntkctl_el1
        \\orr x0, x0, #0x3
        \\msr cntkctl_el1, x0
        ::: .{ .x0 = true });
}
