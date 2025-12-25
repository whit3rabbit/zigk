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

pub fn stall(us: u64) void {
    var i: u64 = 0;
    while (i < us * 10) : (i += 1) {
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

// Stubs for x86 MSRs
pub const IA32_GS_BASE = 0;
pub const IA32_FS_BASE = 0;
pub const IA32_KERNEL_GS_BASE = 0;

pub fn writeMsr(msr: anytype, val: u64) void {
    _ = msr; _ = val;
}

pub fn readMsr(msr: anytype) u64 {
    _ = msr; return 0;
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

/// Context switch: saves current state to old_sp, loads new_sp
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
    );
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
