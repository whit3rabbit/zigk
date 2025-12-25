// AArch64 Timing Utilities
//
// Provides timing using the ARMv8-A Generic Timer (system counter).
// Unlike x86 TSC, the AArch64 system counter frequency is typically
// constant and provided by the system.

const std = @import("std");

var system_counter_freq: u64 = 0;
var calibrated: bool = false;

/// Read System Counter (AArch64's rdtsc equivalent)
/// Usually cntpct_el0 (physical counter) or cntvct_el0 (virtual counter)
pub inline fn rdtsc() u64 {
    var val: u64 = 0;
    asm volatile ("mrs %[ret], cntpct_el0"
        : [ret] "=r" (val),
    );
    return val;
}

/// Initialize timing (read system frequency)
pub fn init() void {
    var freq: u64 = 0;
    asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (freq),
    );
    system_counter_freq = freq;
    calibrated = true;
}

pub fn calibrate() void {
    if (!calibrated) init();
}

pub fn getTscFrequency() u64 {
    if (!calibrated) init();
    return system_counter_freq;
}

pub fn isCalibrated() bool {
    return calibrated;
}

/// Delay for specified microseconds (blocking)
pub fn delayUs(us: u64) void {
    if (!calibrated) init();
    if (system_counter_freq == 0) return;

    const ticks = (us * system_counter_freq) / 1_000_000;
    const start = rdtsc();
    while (rdtsc() - start < ticks) {
        asm volatile ("yield");
    }
}

/// Delay for specified milliseconds (blocking)
pub fn delayMs(ms: u64) void {
    delayUs(ms * 1000);
}

/// Check if timeout_us has elapsed since start_tsc
pub fn hasTimedOut(start_tsc: u64, timeout_us: u64) bool {
    if (!calibrated) init();
    if (system_counter_freq == 0) return false;

    const elapsed_ticks = rdtsc() - start_tsc;
    const timeout_ticks = (timeout_us * system_counter_freq) / 1_000_000;
    return elapsed_ticks >= timeout_ticks;
}

/// Convert TSC ticks to microseconds
pub fn ticksToUs(ticks: u64) u64 {
    if (!calibrated) init();
    if (system_counter_freq == 0) return 0;
    return (ticks * 1_000_000) / system_counter_freq;
}
