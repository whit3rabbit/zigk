// AArch64 Syscall Implementation
//
// CROSS-PLATFORM COMPATIBILITY NOTE:
// ==================================
// The SyscallFrame struct uses x86 register names (rax, rdi, rsi, etc.) for
// cross-platform code compatibility with the x86_64 implementation. This allows
// shared syscall handler code to work on both architectures.
//
// REGISTER MAPPING (x86 name -> AArch64 register):
//   rax -> x0  (return value / arg0)
//   rdi -> x1  (arg1)
//   rsi -> x2  (arg2)
//   rdx -> x3  (arg3)
//   r10 -> x4  (arg4)
//   r8  -> x5  (arg5)
//   r9  -> x6
//   rcx -> x11
//   r11 -> x12
//   r12 -> x13
//   r13 -> x14
//   rbx -> x15
//   r14 -> x28
//   rbp -> x29 (frame pointer)
//   r15 -> x30 (link register)
//
// SECURITY: This mapping MUST match the assembly in entry.S (SAVE_CONTEXT macro).
// Mismatches will cause incorrect syscall argument parsing, potentially leading
// to security vulnerabilities (e.g., treating untrusted data as trusted pointers).

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
/// Layout (288 bytes total, 36 fields * 8):
///   Offset 0-240:   x0-x30 (31 registers)
///   Offset 248:     ELR_EL1
///   Offset 256:     SPSR_EL1
///   Offset 264:     SP_EL0 (user stack pointer)
///   Offset 272-280: Reserved (rsp, vector for x86 compat)
///
/// SECURITY: Field order and sizes must exactly match entry.S SAVE_CONTEXT.
/// Compile-time assertions verify struct layout matches expected offsets.
pub const SyscallFrame = extern struct {
    // x0-x30 stored at offsets 0-240
    // Names use x86 convention for cross-platform compatibility
    rax: u64, // x0 - return value / arg0
    rdi: u64, // x1 - arg1
    rsi: u64, // x2 - arg2
    rdx: u64, // x3 - arg3
    r10: u64, // x4 - arg4
    r8: u64,  // x5 - arg5
    r9: u64,  // x6
    x7: u64,
    x8: u64,  // Syscall number
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
    rbp: u64, // x29 (frame pointer)
    r15: u64, // x30 (link register)
    // System registers at offsets 248-264
    elr: u64,    // Exception Link Register (return address)
    spsr: u64,   // Saved Program Status Register
    sp_el0: u64, // User stack pointer
    // Reserved for x86 compatibility
    rsp: u64 = 0,
    vector: u64 = 0,

    // SECURITY: Compile-time assertions to verify struct layout matches entry.S
    comptime {
        // Verify critical field offsets match assembly expectations
        if (@offsetOf(SyscallFrame, "rax") != 0) @compileError("x0/rax must be at offset 0");
        if (@offsetOf(SyscallFrame, "x8") != 64) @compileError("x8 (syscall#) must be at offset 64");
        if (@offsetOf(SyscallFrame, "elr") != 248) @compileError("elr must be at offset 248");
        if (@offsetOf(SyscallFrame, "spsr") != 256) @compileError("spsr must be at offset 256");
        if (@offsetOf(SyscallFrame, "sp_el0") != 264) @compileError("sp_el0 must be at offset 264");
        if (@sizeOf(SyscallFrame) != 288) @compileError("SyscallFrame must be 288 bytes");
    }

    pub fn getSyscallNumber(self: *const SyscallFrame) usize { return self.x8; }
    pub fn getArgs(self: *const SyscallFrame) [6]usize {
        return .{ self.rax, self.rdi, self.rsi, self.rdx, self.r10, self.r8 };
    }
    pub fn setReturnValue(self: *SyscallFrame, value: usize) void { self.rax = value; }
    pub fn setReturnSigned(self: *SyscallFrame, value: isize) void { self.rax = @bitCast(value); }
    pub fn setReturnRip(self: *SyscallFrame, addr: u64) void { self.elr = addr; }
    pub fn setUserRsp(self: *SyscallFrame, sp: u64) void { self.sp_el0 = sp; }
    pub fn getReturnRip(self: *const SyscallFrame) u64 { return self.elr; }
    pub fn getUserRsp(self: *const SyscallFrame) u64 { return self.sp_el0; }
};
