// x86_64 SYSCALL/SYSRET Configuration
//
// Configures the fast system call mechanism using Model-Specific Registers.
// SYSCALL is the standard method for user->kernel transitions on x86_64.
//
// MSR Configuration:
//   IA32_STAR:  Segment selectors for SYSCALL/SYSRET
//   IA32_LSTAR: Target RIP for SYSCALL (64-bit mode)
//   IA32_FMASK: RFLAGS mask (bits to clear on SYSCALL entry)
//
// Register Convention on SYSCALL entry:
//   RAX = syscall number
//   RDI = arg1, RSI = arg2, RDX = arg3, R10 = arg4, R8 = arg5, R9 = arg6
//   RCX = return RIP (saved by CPU)
//   R11 = return RFLAGS (saved by CPU)
//
// IMPORTANT: SYSCALL does NOT switch stacks. We must switch to kernel stack manually.

const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");

/// RFLAGS bits to clear on syscall entry
/// We clear IF (bit 9) to disable interrupts - Big Kernel Lock
/// Also clear DF (bit 10) to ensure forward string operations
/// Also clear TF (bit 8) to disable single-step traps
const FMASK_VALUE: u64 = (1 << 9) | // IF - Interrupt Flag
    (1 << 10) | // DF - Direction Flag
    (1 << 8); // TF - Trap Flag

/// External syscall entry point from asm_helpers.S
extern fn _syscall_entry() void;

/// Initialize SYSCALL/SYSRET MSRs
pub fn init() void {
    // Enable SYSCALL/SYSRET in IA32_EFER (SCE bit, bit 0)
    const efer = cpu.readMsr(cpu.IA32_EFER);
    cpu.writeMsr(cpu.IA32_EFER, efer | 1);

    // Configure IA32_STAR: segment selectors
    // Format: [63:48] = SYSRET CS base, [47:32] = SYSCALL CS base
    //
    // For SYSCALL (kernel entry):
    //   CS = STAR[47:32] = 0x08 (KERNEL_CODE)
    //   SS = STAR[47:32] + 8 = 0x10 (KERNEL_DATA)
    //
    // For SYSRET (user return, 64-bit mode):
    //   CS = STAR[63:48] + 16 = 0x20 (USER_CODE)
    //   SS = STAR[63:48] + 8 = 0x18 (USER_DATA)
    //
    // So STAR[63:48] = 0x10, STAR[47:32] = 0x08
    const sysret_base: u64 = 0x10; // USER_CODE - 16
    const syscall_base: u64 = gdt.KERNEL_CODE;
    const star_value: u64 = (sysret_base << 48) | (syscall_base << 32);
    cpu.writeMsr(cpu.IA32_STAR, star_value);

    // Configure IA32_LSTAR: syscall entry point
    cpu.writeMsr(cpu.IA32_LSTAR, @intFromPtr(&_syscall_entry));

    // Configure IA32_FMASK: clear IF to disable interrupts on entry
    cpu.writeMsr(cpu.IA32_FMASK, FMASK_VALUE);

    // Configure IA32_KERNEL_GS_BASE for SWAPGS
    // This will be swapped with GS_BASE on syscall entry
    // We'll set this to point to the current thread's kernel data
    // For now, set to 0 - will be configured per-thread
    cpu.writeMsr(cpu.IA32_KERNEL_GS_BASE, 0);
}

/// Set the kernel GS base for the current CPU
/// This is swapped in by SWAPGS on syscall entry
/// Should point to per-CPU kernel data (including kernel stack pointer)
pub fn setKernelGsBase(addr: u64) void {
    cpu.writeMsr(cpu.IA32_KERNEL_GS_BASE, addr);
}

/// Get the current kernel GS base
pub fn getKernelGsBase() u64 {
    return cpu.readMsr(cpu.IA32_KERNEL_GS_BASE);
}

/// Per-CPU kernel data structure accessed via GS segment
/// This structure is pointed to by KERNEL_GS_BASE and accessed after SWAPGS
/// Layout must match asm_helpers.S:_syscall_entry GS offsets
pub const KernelGsData = extern struct {
    /// Kernel stack pointer (top of stack) for this CPU
    kernel_stack: u64,
    /// User stack pointer saved on syscall entry
    user_stack: u64,
    /// Current thread pointer (optional, for fast access)
    current_thread: u64,
    /// Scratch space for syscall entry
    scratch: u64,

    comptime {
        if (@sizeOf(KernelGsData) != 32) @compileError("KernelGsData must be 32 bytes (must match asm_helpers.S)");
    }
};

/// Syscall frame pushed on kernel stack by syscall entry handler
/// This matches the layout expected by the syscall dispatcher
pub const SyscallFrame = extern struct {
    // Saved by syscall entry stub (in reverse order due to push)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    // Syscall arguments (caller-saved, but we preserve them)
    r9: u64, // arg6
    r8: u64, // arg5
    r10: u64, // arg4
    rdx: u64, // arg3
    rsi: u64, // arg2
    rdi: u64, // arg1
    // Syscall number
    rax: u64,
    // Saved by CPU on SYSCALL
    rcx: u64, // Return RIP
    r11: u64, // Return RFLAGS
    // User stack pointer (saved manually)
    user_rsp: u64,

    /// Get syscall number
    pub fn getSyscallNumber(self: *const SyscallFrame) usize {
        return self.rax;
    }

    /// Get syscall arguments
    pub fn getArgs(self: *const SyscallFrame) [6]usize {
        return .{
            self.rdi, // arg1
            self.rsi, // arg2
            self.rdx, // arg3
            self.r10, // arg4
            self.r8, // arg5
            self.r9, // arg6
        };
    }

    /// Set return value in RAX
    pub fn setReturnValue(self: *SyscallFrame, value: usize) void {
        self.rax = value;
    }

    /// Set return value from signed value (for error codes)
    pub fn setReturnSigned(self: *SyscallFrame, value: isize) void {
        self.rax = @bitCast(value);
    }

    /// Set the return RIP (for execve - redirect execution to new entry point)
    pub fn setReturnRip(self: *SyscallFrame, rip: u64) void {
        self.rcx = rip;
    }

    /// Set the user stack pointer (for execve - use new stack)
    pub fn setUserRsp(self: *SyscallFrame, rsp: u64) void {
        self.user_rsp = rsp;
    }

    /// Get the return RIP
    pub fn getReturnRip(self: *const SyscallFrame) u64 {
        return self.rcx;
    }

    /// Get the user stack pointer
    pub fn getUserRsp(self: *const SyscallFrame) u64 {
        return self.user_rsp;
    }

    // 16 u64 fields = 128 bytes
    comptime {
        if (@sizeOf(SyscallFrame) != 128) @compileError("SyscallFrame must be 128 bytes (must match asm_helpers.S:_syscall_entry)");
    }
};
