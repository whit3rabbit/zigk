// x86_64 Timing Utilities
//
// Provides calibrated time delays using TSC (Time Stamp Counter).
// TSC is calibrated at boot using the PIT channel 2 as a reference clock.
//
// Must call calibrate() before using delayUs/delayMs/hasTimedOut.

const io = @import("io.zig");
const cpu = @import("cpu.zig");
const console = @import("console");

// PIT Constants
const PIT_CHANNEL2: u16 = 0x42;
const PIT_COMMAND: u16 = 0x43;
const PIT_BASE_FREQUENCY: u64 = 1193182;

// TSC frequency in Hz (set during calibration)
var tsc_frequency_hz: u64 = 0;
var calibrated: bool = false;

/// Read TSC (Time Stamp Counter)
pub inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

/// Calibrate TSC using PIT channel 2 as reference
/// Call once during boot, before interrupts are enabled
pub fn calibrate() void {
    // Use 10ms calibration period for reasonable accuracy
    const calibration_ms: u64 = 10;
    const pit_divisor: u16 = @intCast((PIT_BASE_FREQUENCY * calibration_ms) / 1000);

    // Gate PIT channel 2 by setting bit 0 of port 0x61
    // Also ensure speaker is off (bit 1 = 0)
    var port61 = io.inb(0x61);
    port61 = (port61 & 0xFC) | 0x01; // Enable gate, disable speaker
    io.outb(0x61, port61);

    // Configure PIT channel 2, mode 0 (one-shot), lobyte/hibyte access
    // Command: 10 11 000 0 = 0xB0
    // Channel 2 (10), lobyte/hibyte (11), mode 0 (000), binary (0)
    io.outb(PIT_COMMAND, 0xB0);

    // Write divisor (lobyte then hibyte)
    io.outb(PIT_CHANNEL2, @truncate(pit_divisor));
    io.outb(PIT_CHANNEL2, @truncate(pit_divisor >> 8));

    // Read starting TSC
    const tsc_start = rdtsc();

    // Wait for PIT to count down - poll OUT signal via port 0x61 bit 5
    // OUT goes high when counter reaches 0
    while ((io.inb(0x61) & 0x20) == 0) {
        cpu.pause();
    }

    // Read ending TSC
    const tsc_end = rdtsc();

    // Calculate frequency: ticks / calibration_time_seconds
    const tsc_delta = tsc_end - tsc_start;
    tsc_frequency_hz = (tsc_delta * 1000) / calibration_ms;
    calibrated = true;

    // Log calibration result
    const mhz = tsc_frequency_hz / 1_000_000;
    const khz_frac = (tsc_frequency_hz % 1_000_000) / 1000;
    console.info("Timing: TSC calibrated to {d}.{d:0>3} MHz", .{ mhz, khz_frac });
}

/// Get TSC frequency in Hz (must call calibrate first)
pub fn getTscFrequency() u64 {
    return tsc_frequency_hz;
}

/// Check if TSC has been calibrated
pub fn isCalibrated() bool {
    return calibrated;
}

/// Delay for specified microseconds (blocking)
pub fn delayUs(us: u64) void {
    if (!calibrated or tsc_frequency_hz == 0) {
        // Fallback: rough estimate assuming ~2GHz (common for QEMU)
        spinDelay(us * 2000);
        return;
    }

    const tsc_ticks = (us * tsc_frequency_hz) / 1_000_000;
    const start = rdtsc();
    while (rdtsc() - start < tsc_ticks) {
        cpu.pause();
    }
}

/// Delay for specified milliseconds (blocking)
pub fn delayMs(ms: u64) void {
    delayUs(ms * 1000);
}

/// Check if timeout_us has elapsed since start_tsc
pub fn hasTimedOut(start_tsc: u64, timeout_us: u64) bool {
    if (!calibrated or tsc_frequency_hz == 0) {
        // Cannot determine - return false to avoid spurious timeouts
        return false;
    }
    const elapsed_ticks = rdtsc() - start_tsc;
    const timeout_ticks = (timeout_us * tsc_frequency_hz) / 1_000_000;
    return elapsed_ticks >= timeout_ticks;
}

/// Convert TSC ticks to microseconds
pub fn ticksToUs(ticks: u64) u64 {
    if (tsc_frequency_hz == 0) return 0;
    return (ticks * 1_000_000) / tsc_frequency_hz;
}

/// Fallback spin delay (iteration-based, uncalibrated)
fn spinDelay(iterations: u64) void {
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        cpu.pause();
    }
}
