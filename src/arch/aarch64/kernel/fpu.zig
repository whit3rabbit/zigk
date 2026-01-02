// AArch64 FPU/NEON State Management
//
// Saves and restores the NEON/FPU state (32x 128-bit Q registers + FPSR + FPCR)
// for context switching.

const std = @import("std");

/// AArch64 FPU/NEON state (v0-v31, fpsr, fpcr)
/// Size: 32 * 16 + 4 + 4 + 8 = 528 bytes
pub const FpuState = extern struct {
    q: [32]u128 align(16),
    fpsr: u32,
    fpcr: u32,
    _padding: u64 = 0,

    pub fn init() FpuState {
        return std.mem.zeroes(FpuState);
    }
};

/// Initialize FPU/NEON for current EL
pub fn init() void {
    // Enable FPU/NEON/SVE access in CPACR_EL1
    // FPEN (bits 21:20) = 0b11 means no trapping of FP/SIMD from EL0/EL1
    var cpacr: u64 = 0;
    asm volatile ("mrs %[ret], cpacr_el1"
        : [ret] "=r" (cpacr),
    );
    cpacr |= (3 << 20); // FPEN = 0b11
    asm volatile ("msr cpacr_el1, %[val]"
        :
        : [val] "r" (cpacr),
    );
    // ISB to ensure the setting takes effect
    asm volatile ("isb");
}

/// Save FPU/NEON state to memory
pub fn save(state: *FpuState) void {
    // Save Q0-Q31 (128-bit NEON registers)
    const ptr = @intFromPtr(&state.q);
    asm volatile (
        \\stp q0, q1, [%[base], #0]
        \\stp q2, q3, [%[base], #32]
        \\stp q4, q5, [%[base], #64]
        \\stp q6, q7, [%[base], #96]
        \\stp q8, q9, [%[base], #128]
        \\stp q10, q11, [%[base], #160]
        \\stp q12, q13, [%[base], #192]
        \\stp q14, q15, [%[base], #224]
        \\stp q16, q17, [%[base], #256]
        \\stp q18, q19, [%[base], #288]
        \\stp q20, q21, [%[base], #320]
        \\stp q22, q23, [%[base], #352]
        \\stp q24, q25, [%[base], #384]
        \\stp q26, q27, [%[base], #416]
        \\stp q28, q29, [%[base], #448]
        \\stp q30, q31, [%[base], #480]
        :
        : [base] "r" (ptr),
        : .{ .memory = true }
    );

    // Save FPSR and FPCR
    var fpsr: u32 = 0;
    var fpcr: u32 = 0;
    asm volatile ("mrs %[fpsr], fpsr"
        : [fpsr] "=r" (fpsr),
    );
    asm volatile ("mrs %[fpcr], fpcr"
        : [fpcr] "=r" (fpcr),
    );
    state.fpsr = fpsr;
    state.fpcr = fpcr;
}

/// Restore FPU/NEON state from memory
pub fn restore(state: *const FpuState) void {
    // Restore FPSR and FPCR first
    asm volatile ("msr fpsr, %[fpsr]"
        :
        : [fpsr] "r" (state.fpsr),
    );
    asm volatile ("msr fpcr, %[fpcr]"
        :
        : [fpcr] "r" (state.fpcr),
    );

    // Restore Q0-Q31
    const ptr = @intFromPtr(&state.q);
    asm volatile (
        \\ldp q0, q1, [%[base], #0]
        \\ldp q2, q3, [%[base], #32]
        \\ldp q4, q5, [%[base], #64]
        \\ldp q6, q7, [%[base], #96]
        \\ldp q8, q9, [%[base], #128]
        \\ldp q10, q11, [%[base], #160]
        \\ldp q12, q13, [%[base], #192]
        \\ldp q14, q15, [%[base], #224]
        \\ldp q16, q17, [%[base], #256]
        \\ldp q18, q19, [%[base], #288]
        \\ldp q20, q21, [%[base], #320]
        \\ldp q22, q23, [%[base], #352]
        \\ldp q24, q25, [%[base], #384]
        \\ldp q26, q27, [%[base], #416]
        \\ldp q28, q29, [%[base], #448]
        \\ldp q30, q31, [%[base], #480]
        :
        : [base] "r" (ptr),
    );
}

/// Alias for save (x86 compat)
pub fn fxsave(state: *FpuState) void {
    save(state);
}

/// Alias for restore (x86 compat)
pub fn fxrstor(state: *const FpuState) void {
    restore(state);
}

/// Set task switched flag (x86 compat - no-op on AArch64)
/// On x86, this sets CR0.TS to trigger #NM on FPU access for lazy switching.
/// AArch64 uses eager save/restore via cpu.switchContextWithFpu().
///
/// SECURITY: The scheduler MUST use cpu.switchContextWithFpu() for user thread
/// context switches to prevent information leakage via FPU registers.
pub fn setTaskSwitched() void {}

/// Clear task switched flag (x86 compat - no-op on AArch64)
/// See setTaskSwitched() for AArch64 FPU handling strategy.
pub fn clearTaskSwitched() void {}

/// x86 compatibility: Get XSAVE area size
/// On AArch64, we use FpuState size (528 bytes for Q0-Q31 + FPSR + FPCR)
pub fn getXsaveAreaSize() usize {
    return @sizeOf(FpuState);
}

/// x86 compatibility: Save FPU state to a buffer
/// Buffer must be at least getXsaveAreaSize() bytes with 64-byte alignment
pub fn saveState(buf: []align(64) u8) void {
    if (buf.len < @sizeOf(FpuState)) return;
    const state: *FpuState = @ptrCast(@alignCast(buf.ptr));
    save(state);
}

/// x86 compatibility: Restore FPU state from a buffer
pub fn restoreState(buf: []align(64) u8) void {
    if (buf.len < @sizeOf(FpuState)) return;
    const state: *const FpuState = @ptrCast(@alignCast(buf.ptr));
    restore(state);
}
