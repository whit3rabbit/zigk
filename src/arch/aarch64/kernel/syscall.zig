// AArch64 Syscall Implementation

const std = @import("std");

/// AArch64 version of per-CPU kernel data
pub const KernelGsData = extern struct {
    kernel_stack: u64,
    user_stack: u64,
    current_thread: u64,
    scratch: u64,
    apic_id: u32 = 0,
    _padding: u32 = 0,
    idle_thread: u64 = 0,
};

/// Syscall frame pushed on kernel stack during exception entry.
/// Matches the layout in entry.S (SAVE_CONTEXT macro).
pub const SyscallFrame = extern struct {
    rax: u64, // x0
    rdi: u64, // x1
    rsi: u64, // x2
    rdx: u64, // x3
    r10: u64, // x4
    r8: u64,  // x5
    r9: u64,  // x6
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    rcx: u64, // x11
    r11: u64, // x12
    r12: u64, // x13
    r13: u64, // x14
    rbx: u64, // x15
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    r14: u64, // x28
    rbp: u64, // x29
    r15: u64, // x30
    elr: u64,
    spsr: u64,
    sp_el0: u64,
    rsp: u64 = 0,
    vector: u64 = 0,

    pub fn getSyscallNumber(self: *const SyscallFrame) usize { return self.x8; }
    pub fn getArgs(self: *const SyscallFrame) [6]usize {
        return .{ self.rax, self.rdi, self.rsi, self.rdx, self.r10, self.r8 };
    }
    pub fn setReturnValue(self: *SyscallFrame, value: usize) void { self.rax = value; }
    pub fn setReturnSigned(self: *SyscallFrame, value: isize) void { self.rax = @bitCast(value); }
    pub fn setReturnRip(self: *SyscallFrame, addr: u64) void { self.elr = addr; }
    pub fn setUserRsp(self: *SyscallFrame, sp: u64) void { self.sp_el0 = sp; self.rsp = sp; }
    pub fn getReturnRip(self: *const SyscallFrame) u64 { return self.elr; }
    pub fn getUserRsp(self: *const SyscallFrame) u64 { return self.sp_el0; }
};
