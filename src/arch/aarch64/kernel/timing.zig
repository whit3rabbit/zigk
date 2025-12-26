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
/// SECURITY: Uses checked arithmetic to prevent overflow.
/// Returns early if delay calculation would overflow.
pub fn delayUs(us: u64) void {
    if (!calibrated) init();
    if (system_counter_freq == 0) return;

    // SECURITY: Use checked multiplication to prevent overflow.
    // With typical frequencies (24-100MHz), values above ~184 billion us could overflow.
    const product = std.math.mul(u64, us, system_counter_freq) catch {
        // Overflow: delay is unreasonably large, cap at max safe value
        // Log would be ideal but we're in a blocking context
        return;
    };
    const ticks = product / 1_000_000;
    const start = rdtsc();
    while (rdtsc() - start < ticks) {
        asm volatile ("yield");
    }
}

/// Delay for specified milliseconds (blocking)
/// SECURITY: Uses checked arithmetic to prevent overflow.
pub fn delayMs(ms: u64) void {
    const us = std.math.mul(u64, ms, 1000) catch {
        // Overflow: delay is unreasonably large, just return
        return;
    };
    delayUs(us);
}

/// Check if timeout_us has elapsed since start_tsc
/// SECURITY: Uses checked arithmetic. Returns true on overflow (fail-safe timeout).
pub fn hasTimedOut(start_tsc: u64, timeout_us: u64) bool {
    if (!calibrated) init();
    if (system_counter_freq == 0) return false;

    const elapsed_ticks = rdtsc() - start_tsc;
    // SECURITY: Use checked multiplication. On overflow, return true (timed out)
    // to fail-safe rather than causing an infinite wait.
    const product = std.math.mul(u64, timeout_us, system_counter_freq) catch return true;
    const timeout_ticks = product / 1_000_000;
    return elapsed_ticks >= timeout_ticks;
}

/// Convert TSC ticks to microseconds
/// SECURITY: Uses checked arithmetic. Returns max u64 on overflow.
pub fn ticksToUs(ticks: u64) u64 {
    if (!calibrated) init();
    if (system_counter_freq == 0) return 0;
    // SECURITY: Use checked multiplication. On overflow, return max value
    // to indicate "very large" rather than wrapping to small value.
    const product = std.math.mul(u64, ticks, 1_000_000) catch return std.math.maxInt(u64);
    return product / system_counter_freq;
}
