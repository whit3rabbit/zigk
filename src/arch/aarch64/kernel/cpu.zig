// AArch64 CPU Control Utilities

const std = @import("std");
const builtin = @import("builtin");

/// Halt CPU until next interrupt
pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

pub fn haltForever() noreturn {
    disableInterrupts();
    while (true) {
        asm volatile ("wfi");
    }
}

/// Yield to other threads (CPU hint)
pub inline fn pause() void {
    asm volatile ("yield");
}

/// Busy-wait stall for approximately us microseconds.
/// SECURITY: Uses checked arithmetic to prevent overflow.
/// On overflow, caps to max safe iterations rather than wrapping.
pub fn stall(us: u64) void {
    // SECURITY: Checked multiplication to prevent wrap-around
    const iterations = std.math.mul(u64, us, 10) catch std.math.maxInt(u64);
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        pause();
    }
}

/// Enable interrupts globally
pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #2");
}

/// Disable interrupts globally
pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #2");
}

pub fn enableAndHalt() noreturn {
    enableInterrupts();
    halt();
}

pub fn disableInterruptsSaveFlags() u64 {
    var daif: u64 = 0;
    asm volatile ("mrs %[ret], daif" : [ret] "=r" (daif));
    disableInterrupts();
    return daif;
}

pub fn restoreInterrupts(flags: u64) void {
    asm volatile ("msr daif, %[val]" : : [val] "r" (flags));
}

/// Check if interrupts are enabled
pub fn interruptsEnabled() bool {
    var daif: u64 = 0;
    asm volatile ("mrs %[ret], daif" : [ret] "=r" (daif));
    return (daif & (1 << 7)) == 0;
}

// MSR-equivalent constants for cross-platform compatibility
// On AArch64, FS_BASE maps to TPIDR_EL0 (user thread pointer)
pub const IA32_GS_BASE: u32 = 0xC0000101;
pub const IA32_FS_BASE: u32 = 0xC0000100;
pub const IA32_KERNEL_GS_BASE: u32 = 0xC0000102;

/// Write MSR-equivalent register
/// On AArch64, maps IA32_FS_BASE to TPIDR_EL0 for userspace TLS
pub fn writeMsr(msr: u32, val: u64) void {
    switch (msr) {
        IA32_FS_BASE => {
            // User TLS pointer - TPIDR_EL0 is accessible from EL0
            asm volatile ("msr tpidr_el0, %[val]" : : [val] "r" (val));
        },
        IA32_GS_BASE, IA32_KERNEL_GS_BASE => {
            // Kernel per-CPU pointer - TPIDR_EL1 (not directly settable here,
            // typically set during per-CPU init)
        },
        else => {},
    }
}

/// Read MSR-equivalent register
pub fn readMsr(msr: u32) u64 {
    switch (msr) {
        IA32_FS_BASE => {
            var val: u64 = undefined;
            asm volatile ("mrs %[ret], tpidr_el0" : [ret] "=r" (val));
            return val;
        },
        IA32_GS_BASE, IA32_KERNEL_GS_BASE => {
            var val: u64 = undefined;
            asm volatile ("mrs %[ret], tpidr_el1" : [ret] "=r" (val));
            return val;
        },
        else => return 0,
    }
}

/// Write page table base (TTBR1_EL1 - kernel mappings)
pub fn writeCr3(val: u64) void {
    asm volatile (
        \\dsb ishst
        \\msr ttbr1_el1, %[addr]
        \\isb
        :
        : [addr] "r" (val),
    );
}

/// Read page table base (TTBR1_EL1 - kernel mappings)
pub fn readCr3() u64 {
    var ttbr1: u64 = undefined;
    asm volatile ("mrs %[ret], ttbr1_el1"
        : [ret] "=r" (ttbr1),
    );
    return ttbr1 & 0x0000_FFFF_FFFF_F000;
}

/// Read FAR_EL1 (Fault Address Register)
pub fn readFar() u64 {
    var far: u64 = undefined;
    asm volatile ("mrs %[ret], far_el1"
        : [ret] "=r" (far),
    );
    return far;
}

/// Read CR4 equivalent (just return 0 for AArch64)
pub fn readCr4() u64 {
    return 0;
}

/// Context switch (low-level): saves current state to old_sp, loads new_sp
///
/// SECURITY WARNING: This function does NOT save/restore FPU/SIMD state.
/// Use switchContextWithFpu() instead to prevent information leakage between threads.
///
/// This function must properly declare all clobbered registers to prevent:
///   1. Information leakage between threads via stale register values
///   2. Compiler mis-optimization due to incorrect register assumptions
///   3. Memory corruption if compiler reuses "preserved" registers
///
/// Clobber list rationale:
///   - x9: Used as scratch for stack pointer manipulation
///   - x19-x30: Callee-saved registers pushed/popped across the switch
///   - memory: Stack and memory state changes across context switch
///   - cc: Condition codes may be affected by load/store operations
///
/// SIMD/FPU registers (q0-q31, FPSR, FPCR) are NOT saved here.
/// Callers MUST use switchContextWithFpu() for user threads to prevent
/// cross-thread information disclosure via FPU register contents.
pub fn switchContext(old_sp: *u64, new_sp: u64) void {
    asm volatile (
        \\ stp x19, x20, [sp, #-16]!
        \\ stp x21, x22, [sp, #-16]!
        \\ stp x23, x24, [sp, #-16]!
        \\ stp x25, x26, [sp, #-16]!
        \\ stp x27, x28, [sp, #-16]!
        \\ stp x29, x30, [sp, #-16]!
        \\ mov x9, sp
        \\ str x9, [%[old_sp]]
        \\ mov sp, %[new_sp]
        \\ ldp x29, x30, [sp], #16
        \\ ldp x27, x28, [sp], #16
        \\ ldp x25, x26, [sp], #16
        \\ ldp x23, x24, [sp], #16
        \\ ldp x21, x22, [sp], #16
        \\ ldp x19, x20, [sp], #16
        :
        : [old_sp] "r" (old_sp),
          [new_sp] "r" (new_sp)
        : .{
            .x9 = true,
            .x19 = true,
            .x20 = true,
            .x21 = true,
            .x22 = true,
            .x23 = true,
            .x24 = true,
            .x25 = true,
            .x26 = true,
            .x27 = true,
            .x28 = true,
            .x29 = true,
            .x30 = true,
            .memory = true,
            .cc = true,
        }
    );
}

const fpu = @import("fpu.zig");

/// Context switch with FPU state save/restore (RECOMMENDED for user threads)
///
/// SECURITY: This function properly saves and restores FPU/SIMD state to prevent
/// information leakage between threads. Thread A's cryptographic keys or other
/// sensitive data in SIMD registers cannot leak to Thread B.
///
/// Parameters:
///   old_sp: Pointer to save current stack pointer
///   new_sp: New stack pointer to load
///   old_fpu: FPU state buffer to save current SIMD registers into
///   new_fpu: FPU state buffer to restore SIMD registers from
///
/// The scheduler should maintain per-thread FpuState and pass the appropriate
/// buffers for the outgoing and incoming threads.
pub fn switchContextWithFpu(
    old_sp: *u64,
    new_sp: u64,
    old_fpu: *fpu.FpuState,
    new_fpu: *const fpu.FpuState,
) void {
    // Save current thread's FPU state before switching
    fpu.save(old_fpu);

    // Perform the actual context switch (saves/restores GPRs)
    switchContext(old_sp, new_sp);

    // Restore new thread's FPU state
    fpu.restore(new_fpu);
}

pub fn flushTlb() void {
    asm volatile ("tlbi vmalle1is");
}

pub fn invlpg(virt: u64) void {
    asm volatile ("tlbi vaae1is, %[va]" : : [va] "r" (virt >> 12));
}

pub fn rdtsc() u64 {
    return @import("timing.zig").rdtsc();
}

pub fn cpuid(_: u32, _: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    return .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
}

// ============================================================================
// Security Features
// ============================================================================

/// SCTLR_EL1 bit definitions
const SCTLR_PAN: u64 = 1 << 22; // Privileged Access Never

/// Read ID_AA64MMFR1_EL1 for feature detection
fn readIdAa64Mmfr1El1() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[ret], id_aa64mmfr1_el1" : [ret] "=r" (val));
    return val;
}

/// Check if FEAT_PAN is supported by the CPU
pub fn hasPANSupport() bool {
    const mmfr1 = readIdAa64Mmfr1El1();
    // PAN field is bits 23:20, value >= 1 means PAN supported
    const pan_field = (mmfr1 >> 20) & 0xF;
    return pan_field >= 1;
}

/// Enable PAN (Privileged Access Never)
/// When enabled, kernel-mode code cannot access user-mode memory via normal
/// load/store instructions. Must use LDTR/STTR for explicit user access.
///
/// SECURITY: Verifies FEAT_PAN support before enabling.
/// Panics if PAN is not supported (security-critical feature).
pub fn enablePAN() void {
    // Verify FEAT_PAN support (fail-secure)
    if (!hasPANSupport()) {
        @panic("FEAT_PAN not supported by CPU - required for security");
    }

    // Read current SCTLR_EL1
    var sctlr: u64 = undefined;
    asm volatile ("mrs %[ret], sctlr_el1" : [ret] "=r" (sctlr));

    // Set PAN bit
    sctlr |= SCTLR_PAN;

    // Write back with proper barrier sequence per ARM ARM
    // DSB ISHST ensures all previous stores complete before MSR
    // DSB ISH ensures MSR completes before subsequent memory accesses
    // ISB ensures instruction stream sees the new SCTLR value
    asm volatile (
        \\dsb ishst
        \\msr sctlr_el1, %[val]
        \\dsb ish
        \\isb
        :
        : [val] "r" (sctlr)
    );

    // Verify PAN was actually enabled (defense in depth)
    if (!isPANEnabled()) {
        @panic("Failed to enable PAN after MSR write");
    }
}

/// Check if PAN is enabled
pub fn isPANEnabled() bool {
    var sctlr: u64 = undefined;
    asm volatile ("mrs %[ret], sctlr_el1" : [ret] "=r" (sctlr));
    return (sctlr & SCTLR_PAN) != 0;
}
