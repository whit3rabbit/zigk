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
/// SECURITY: ret initialized to 0 for defense-in-depth against info leak
/// if the SVC handler fails to write x0 before returning.
pub fn syscall0(number: usize) usize {
    var ret: usize = 0;
    asm volatile ("svc #0"
        : [ret] "={x0}" (ret),
        : [number] "{x8}" (number),
        : .{ .memory = true }
    );
    return ret;
}

/// Perform syscall with 1 argument
pub fn syscall1(number: usize, arg1: usize) usize {
    var ret: usize = 0;
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
    var ret: usize = 0;
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
    var ret: usize = 0;
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
    var ret: usize = 0;
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
    var ret: usize = 0;
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
    var ret: usize = 0;
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

// User address space boundaries
// On AArch64 with 48-bit VAs, user space is the lower canonical half (bit 47 = 0)
// Addresses 0x0000_0000_0000_0000 to 0x0000_FFFF_FFFF_FFFF are user space
// Addresses 0xFFFF_0000_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF are kernel space
const USER_SPACE_MAX: u64 = 0x0000_FFFF_FFFF_FFFF;
const USER_SPACE_MIN: u64 = 0x0000_0000_0000_1000; // Above null page

// =============================================================================
// PAN-Compatible User Memory Access
// =============================================================================
// With PAN (Privileged Access Never) enabled, kernel code cannot access user
// memory with regular LDR/STR. We must use LDTR/STTR (unprivileged load/store)
// which access memory as if from EL0.

/// Store a 64-bit value to user memory (PAN-compatible)
/// Uses STTR instruction which performs unprivileged store.
/// SECURITY: Caller must validate that addr is in user address space.
fn storeUserU64(addr: u64, value: u64) void {
    asm volatile ("sttr %[val], [%[addr]]"
        :
        : [val] "r" (value),
          [addr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Validate that an address is in user space
fn isUserAddress(addr: u64) bool {
    return addr >= USER_SPACE_MIN and addr <= USER_SPACE_MAX;
}

/// Enter userspace at specified entry point with given stack pointer
/// This is a one-way transition - the function never returns
///
/// Security: Validates that entry and stack are in user address space.
/// Panics if either is in kernel space (this is a kernel bug, not user error).
///
/// Parameters:
///   entry: Entry point address in user space
///   stack: Stack pointer in user space (must be 16-byte aligned)
///   tls_base: Thread Local Storage base address (for TPIDR_EL0), 0 if not used
pub fn enterUserspace(entry: u64, stack: u64, tls_base: u64) noreturn {
    const interrupts = @import("interrupts/root.zig");
    const cpu = @import("cpu.zig");

    // Validate entry point is in user space
    if (!isUserAddress(entry)) {
        interrupts.earlyPrint("PANIC: enterUserspace with kernel entry address\n");
        interrupts.earlyPrint("  entry=0x");
        printHex(entry);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // Validate stack is in user space
    if (!isUserAddress(stack)) {
        interrupts.earlyPrint("PANIC: enterUserspace with kernel stack address\n");
        interrupts.earlyPrint("  stack=0x");
        printHex(stack);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // Validate stack is 16-byte aligned (AArch64 ABI requirement)
    if ((stack & 0xF) != 0) {
        interrupts.earlyPrint("PANIC: enterUserspace with misaligned stack\n");
        interrupts.earlyPrint("  stack=0x");
        printHex(stack);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // SPSR_EL1 = 0 means:
    // - Return to EL0 with SP_EL0
    // - All interrupts enabled (DAIF = 0)
    // - AArch64 execution state
    const spsr: u64 = 0;

    // SECURITY: Clear all general-purpose registers before eret to prevent
    // kernel data leakage to userspace. This mitigates:
    // - Information disclosure via register contents
    // - Speculative execution attacks using kernel register values as gadgets
    //
    // We set up system registers first, then clear all GPRs, then eret.
    // The order matters: we use registers to pass values before clearing them.
    asm volatile (
        // Set up system registers
        \\msr tpidr_el0, %[tls]    // Thread pointer for TLS
        \\msr spsr_el1, %[spsr]    // Saved program status
        \\msr elr_el1, %[entry]    // Return address
        \\msr sp_el0, %[stack]     // User stack pointer
        //
        // SECURITY: Clear all caller-saved and callee-saved registers
        // to prevent kernel information leakage to userspace.
        // x0 will be argc (set by kernel), but we clear it here;
        // the exec path sets it via the SyscallFrame.
        \\mov x0, #0
        \\mov x1, #0
        \\mov x2, #0
        \\mov x3, #0
        \\mov x4, #0
        \\mov x5, #0
        \\mov x6, #0
        \\mov x7, #0
        \\mov x8, #0
        \\mov x9, #0
        \\mov x10, #0
        \\mov x11, #0
        \\mov x12, #0
        \\mov x13, #0
        \\mov x14, #0
        \\mov x15, #0
        \\mov x16, #0
        \\mov x17, #0
        \\mov x18, #0
        \\mov x19, #0
        \\mov x20, #0
        \\mov x21, #0
        \\mov x22, #0
        \\mov x23, #0
        \\mov x24, #0
        \\mov x25, #0
        \\mov x26, #0
        \\mov x27, #0
        \\mov x28, #0
        \\mov x29, #0
        \\mov x30, #0
        // Return to userspace
        \\eret
        :
        : [tls] "r" (tls_base),
          [spsr] "r" (spsr),
          [entry] "r" (entry),
          [stack] "r" (stack),
    );
    unreachable;
}

/// Enter userspace with default TLS (0)
/// Convenience wrapper for code that doesn't use TLS
pub fn enterUserspaceSimple(entry: u64, stack: u64) noreturn {
    enterUserspace(entry, stack, 0);
}

fn printHex(val: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = [_]u8{0} ** 16;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[15 - i] = hex[@as(usize, @truncate((val >> @as(u6, @truncate(i * 4))) & 0xF))];
    }
    @import("interrupts/root.zig").earlyPrint(&buf);
}

/// Enter userspace with argc/argv/envp setup on stack
/// stack_top: Top of user stack
/// entry: Entry point address
/// argc: Argument count
/// argv: Pointer to argument vector
/// envp: Pointer to environment vector
///
/// SECURITY: This function performs critical validation to prevent:
///   1. Privilege escalation via kernel memory writes (validates user address FIRST)
///   2. Integer underflow in stack pointer arithmetic (uses checked arithmetic)
///   3. Stack exhaustion attacks (validates sufficient space before writes)
pub fn enterUserspaceWithArgs(
    entry: u64,
    stack_top: u64,
    argc: usize,
    argv: [*]const [*:0]const u8,
    envp: [*]const [*:0]const u8,
) noreturn {
    const interrupts = @import("interrupts/root.zig");
    const cpu = @import("cpu.zig");
    const std = @import("std");

    // SECURITY: Validate stack_top BEFORE any memory writes to prevent
    // privilege escalation via writes to kernel memory addresses.
    // This check MUST come before any sp arithmetic or dereferences.
    if (!isUserAddress(stack_top)) {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs with kernel stack address\n");
        interrupts.earlyPrint("  stack_top=0x");
        printHex(stack_top);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // SECURITY: Maximum argument and environment variable counts to prevent
    // unbounded iteration from corrupted argc/argv/envp pointers.
    // POSIX ARG_MAX is typically 128KB-2MB; 4096 entries is generous.
    const MAX_ARG_COUNT: usize = 4096;
    const MAX_ENV_COUNT: usize = 4096;

    // SECURITY: Validate argc is within reasonable bounds.
    // A corrupted argc value could cause OOB reads from argv array.
    if (argc > MAX_ARG_COUNT) {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs argc too large\n");
        interrupts.earlyPrint("  argc=");
        printHex(argc);
        interrupts.earlyPrint(" max=");
        printHex(MAX_ARG_COUNT);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // Count envp entries first (before any stack modifications)
    var envp_count: usize = 0;
    while (envp_count < MAX_ENV_COUNT and envp[envp_count] != @as([*:0]const u8, @ptrFromInt(0))) {
        envp_count += 1;
    }

    // SECURITY: Reject if envp exceeds maximum (likely corrupted or malicious)
    if (envp_count >= MAX_ENV_COUNT) {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs envp array too large or unterminated\n");
        cpu.haltForever();
    }

    // SECURITY: Calculate total required stack space using checked arithmetic
    // to prevent integer underflow attacks.
    // Stack layout: argc + (argc * argv ptrs) + NULL + (envp_count * envp ptrs) + NULL + alignment
    // Total slots: 1 (argc) + argc + 1 (NULL) + envp_count + 1 (NULL) = argc + envp_count + 3
    const total_slots = std.math.add(usize, argc, envp_count) catch {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs argc+envp overflow\n");
        cpu.haltForever();
    };
    const total_slots_with_nulls = std.math.add(usize, total_slots, 3) catch {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs slot count overflow\n");
        cpu.haltForever();
    };
    const required_bytes = std.math.mul(usize, total_slots_with_nulls, 8) catch {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs stack size overflow\n");
        cpu.haltForever();
    };
    // Add 16 for alignment padding
    const required_with_align = std.math.add(usize, required_bytes, 16) catch {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs alignment overflow\n");
        cpu.haltForever();
    };

    // SECURITY: Validate stack has sufficient space and won't underflow
    // into kernel address space after all decrements.
    if (stack_top < USER_SPACE_MIN + required_with_align) {
        interrupts.earlyPrint("PANIC: enterUserspaceWithArgs insufficient user stack space\n");
        interrupts.earlyPrint("  stack_top=0x");
        printHex(stack_top);
        interrupts.earlyPrint(" required=0x");
        printHex(required_with_align);
        interrupts.earlyPrint("\n");
        cpu.haltForever();
    }

    // Now safe to perform stack operations - we've validated:
    // 1. stack_top is in user space
    // 2. All arithmetic won't overflow
    // 3. Final sp will still be in user space
    var sp = stack_top;

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

    // SECURITY: All writes below use storeUserU64() which uses STTR instruction.
    // This is required because PAN (Privileged Access Never) is enabled,
    // preventing kernel from accessing user memory with regular STR.

    // Push NULL terminator for envp
    sp -= 8;
    storeUserU64(sp, 0);

    // Push envp entries (reverse order)
    var i: usize = envp_count;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        storeUserU64(sp, @intFromPtr(envp[i]));
    }

    // Push NULL terminator for argv
    sp -= 8;
    storeUserU64(sp, 0);

    // Push argv entries (reverse order)
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        storeUserU64(sp, @intFromPtr(argv[i]));
    }

    // Push argc
    sp -= 8;
    storeUserU64(sp, argc);

    // Align sp to 16 bytes
    sp = sp & ~@as(u64, 0xF);

    enterUserspace(entry, sp, 0);
}

/// Initialize userspace support
pub fn init() void {
    // Set up TTBR0_EL1 for user address space (lower half)
    // TCR_EL1 configuration is done in boot code

    // Enable user access to generic timer (virtual counter only)
    // CNTKCTL_EL1 bits:
    //   Bit 0 (EL0PCTEN): EL0 access to physical counter (CNTPCT_EL0)
    //   Bit 1 (EL0VCTEN): EL0 access to virtual counter (CNTVCT_EL0)
    //
    // SECURITY: Only enable virtual counter (bit 1), NOT physical counter (bit 0).
    // The virtual counter is sufficient for userspace timing (clock_gettime, etc).
    // Keeping physical counter kernel-only reduces entropy correlation attacks:
    // the kernel uses CNTPCT_EL0 for timing-based entropy fallback, and if
    // userspace cannot read it, predicting kernel entropy becomes harder.
    asm volatile (
        \\mrs x0, cntkctl_el1
        \\bic x0, x0, #0x1
        \\orr x0, x0, #0x2
        \\msr cntkctl_el1, x0
        ::: .{ .x0 = true });
}
