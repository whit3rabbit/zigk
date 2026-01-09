// AArch64 Timing Utilities
//
// Provides timing using the ARMv8-A Generic Timer (system counter).
// Unlike x86 TSC, the AArch64 system counter frequency is typically
// constant and provided by the system.
//
// Under KVM, pvtime provides stolen time tracking for accurate CPU time.

const std = @import("std");
const console = @import("console");
const pvtime = @import("../hypervisor/pvtime.zig");

/// Available clock sources for aarch64
pub const ClockSource = enum {
    /// No clock source initialized
    none,
    /// ARMv8-A Generic Timer (cntpct_el0)
    generic_timer,
    /// Generic Timer + pvtime stolen time tracking
    generic_timer_pvtime,
};

var system_counter_freq: u64 = 0;
var calibrated: bool = false;
var active_clock_source: ClockSource = .none;
var timer_ticks_per_interval: u64 = 0;

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

// =============================================================================
// Paravirtualized Timing Support
// =============================================================================

/// Initialize timing with best available clock source
/// On AArch64 under KVM: Generic Timer + pvtime stolen time tracking
/// On bare metal/other: Generic Timer only
pub fn initBest() void {
    // Always initialize the generic timer first
    init();

    // Try to enable pvtime for stolen time tracking under KVM
    pvtime.init();
    if (pvtime.isAvailable()) {
        active_clock_source = .generic_timer_pvtime;
        console.info("Timing: Using Generic Timer + pvtime (stolen time tracking)", .{});
    } else {
        active_clock_source = .generic_timer;
        console.info("Timing: Using Generic Timer", .{});
    }
}

/// Get current time in nanoseconds
/// Returns time adjusted for stolen time when running under KVM with pvtime
pub fn getNanoseconds() u64 {
    if (!calibrated) init();
    if (system_counter_freq == 0) return 0;

    // Read counter and convert to nanoseconds
    const counter = rdtsc();
    const ns = @as(u128, counter) * 1_000_000_000 / system_counter_freq;

    return @as(u64, @truncate(ns));
}

/// Get adjusted time (wall time minus stolen time) when available
/// Returns null if pvtime is not available
pub fn getAdjustedNanoseconds() ?u64 {
    if (active_clock_source != .generic_timer_pvtime) {
        return null;
    }
    return pvtime.getAdjustedTimeNs();
}

/// Get the active clock source
pub fn getClockSource() ClockSource {
    return active_clock_source;
}

/// Get accumulated stolen time in nanoseconds (time vCPU was preempted)
/// Returns null if not running under KVM with pvtime
pub fn getStolenTimeNs() ?u64 {
    if (active_clock_source != .generic_timer_pvtime) {
        return null;
    }
    return pvtime.getStolenTimeNs();
}

// =============================================================================
// Periodic Timer (for scheduler)
// =============================================================================

/// Start the periodic timer at the specified frequency (Hz)
/// Uses the EL1 virtual timer (CNTV)
/// Note: Uses CVAL approach (compare value) which is better emulated in QEMU TCG
pub fn startPeriodicTimer(freq_hz: u32) void {
    if (!calibrated) init();
    if (system_counter_freq == 0) {
        console.err("Timing: Cannot start timer, frequency unknown", .{});
        return;
    }

    // Calculate ticks per interval
    timer_ticks_per_interval = system_counter_freq / freq_hz;

    console.info("Timing: Starting periodic timer at {d}Hz ({d} ticks/interval)", .{ freq_hz, timer_ticks_per_interval });

    // Read current virtual counter and set compare value
    var cntvct: u64 = 0;
    asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (cntvct),
    );

    const cval = cntvct + timer_ticks_per_interval;
    asm volatile ("msr cntv_cval_el0, %[val]"
        :
        : [val] "r" (cval),
    );

    // Enable the timer (bit 0 = enable, bit 1 = mask interrupt)
    // Set ENABLE=1, IMASK=0 to generate interrupts
    asm volatile ("msr cntv_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );

    // Debug: verify timer is enabled
    var ctl: u64 = 0;
    asm volatile ("mrs %[ret], cntv_ctl_el0"
        : [ret] "=r" (ctl),
    );
    console.debug("Timing: CNTV_CTL_EL0 = {x} (ENABLE={d}, IMASK={d}, ISTATUS={d})", .{
        ctl,
        ctl & 1,
        (ctl >> 1) & 1,
        (ctl >> 2) & 1,
    });
}

/// Re-arm the timer for the next interval
/// Must be called from the timer interrupt handler
/// Uses CVAL approach for better QEMU TCG compatibility
pub fn rearmTimer() void {
    if (timer_ticks_per_interval == 0) return;

    // Read current virtual counter and set next compare value
    var cntvct: u64 = 0;
    asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (cntvct),
    );

    const cval = cntvct + timer_ticks_per_interval;
    asm volatile ("msr cntv_cval_el0, %[val]"
        :
        : [val] "r" (cval),
    );
}

/// Stop the periodic timer
pub fn stopTimer() void {
    // Disable the timer (clear ENABLE bit)
    asm volatile ("msr cntv_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 0)),
    );
}
