// Memory-Mapped I/O (MMIO) Primitives
//
// Provides volatile read/write operations for memory-mapped device registers.
// All operations use volatile semantics to prevent compiler reordering or elision.
//
// Usage: Map device memory with cache-disabled pages (PageFlags.MMIO),
// then use these functions to access device registers.
//
// HAL Contract: This module provides low-level MMIO access.
// Drivers should use these primitives for all device register access.
//
// SECURITY NOTES:
// - These are low-level primitives with no address validation. Callers must
//   ensure addresses point to valid, mapped MMIO regions.
// - Read-modify-write operations (setBits32, clearBits32, modifyBits32) are
//   NOT atomic. Callers must hold appropriate locks when concurrent access
//   is possible (see individual function documentation).
// - Memory barriers are valid for Uncacheable (UC) and Write-Through (WT)
//   memory types. Write-Combining (WC) memory (e.g., framebuffers) may
//   require additional serialization (clflush or serializing instructions).
// - Debug builds include alignment and address validation assertions.

const builtin = @import("builtin");
const std = @import("std");

// SMP safety check support (debug builds only)
// We check if interrupts are enabled as a proxy for "unprotected access".
// If interrupts are enabled and we're doing non-atomic RMW on SMP systems,
// that's a potential race condition.
inline fn debugCheckSmpSafety(comptime func_name: []const u8) void {
    if (comptime builtin.mode == .Debug) {
        // Check RFLAGS.IF to see if interrupts are enabled
        const rflags = asm volatile ("pushfq; pop %[ret]"
            : [ret] "=r" (-> u64),
        );
        const interrupts_enabled = (rflags & (1 << 9)) != 0;

        // If interrupts are enabled, warn that this RMW might be racy
        // We can't check SMP CPU count from HAL level, so we just warn
        // when interrupts are enabled as that's when races are possible.
        if (interrupts_enabled) {
            // Use debug.print instead of panic to allow existing code to work
            // but make the issue visible during development.
            std.debug.print("MMIO WARNING: {s} called with interrupts enabled (potential race)\n", .{func_name});
        }
    }
}

// Minimum valid MMIO address - addresses below this are likely errors.
// On x86_64, the first 1MB is real-mode legacy area, and low addresses
// are typically not used for MMIO.
const MIN_MMIO_ADDR: u64 = 0x1000;

// Maximum fallback iterations for timed polls when TSC is uncalibrated.
// At ~1 cycle per iteration with pause, this is roughly 10ms on a 1GHz CPU.
const FALLBACK_MAX_ITERATIONS: usize = 10_000_000;

/// Validate address in debug builds. Catches null pointers and suspiciously
/// low addresses that are unlikely to be valid MMIO regions.
inline fn debugValidateAddr(addr: u64, alignment: u64) void {
    // Check alignment only in debug/safe builds - use std.debug.assert
    // which is comptime-removed in release builds
    std.debug.assert(addr % alignment == 0);

    // SECURITY: Always check for null or suspiciously low addresses.
    // This catches null pointer dereferences and misconfigurations early
    // even in release builds.
    if (addr < MIN_MMIO_ADDR) {
        @panic("MMIO: invalid address (null or too low)");
    }
}

/// Read a 8-bit value from a memory-mapped register.
/// No alignment requirement for single-byte access.
pub inline fn read8(addr: u64) u8 {
    debugValidateAddr(addr, 1);
    const ptr: *volatile u8 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 8-bit value to a memory-mapped register.
/// No alignment requirement for single-byte access.
pub inline fn write8(addr: u64, value: u8) void {
    debugValidateAddr(addr, 1);
    const ptr: *volatile u8 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 16-bit value from a memory-mapped register.
/// Address must be 2-byte aligned for atomic access.
pub inline fn read16(addr: u64) u16 {
    debugValidateAddr(addr, 2);
    const ptr: *volatile u16 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 16-bit value to a memory-mapped register.
/// Address must be 2-byte aligned for atomic access.
pub inline fn write16(addr: u64, value: u16) void {
    debugValidateAddr(addr, 2);
    const ptr: *volatile u16 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 32-bit value from a memory-mapped register.
/// Address must be 4-byte aligned for atomic access.
pub inline fn read32(addr: u64) u32 {
    debugValidateAddr(addr, 4);
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 32-bit value to a memory-mapped register.
/// Address must be 4-byte aligned for atomic access.
pub inline fn write32(addr: u64, value: u32) void {
    debugValidateAddr(addr, 4);
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 64-bit value from a memory-mapped register.
/// Address must be 8-byte aligned for atomic access.
pub inline fn read64(addr: u64) u64 {
    debugValidateAddr(addr, 8);
    const ptr: *volatile u64 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 64-bit value to a memory-mapped register.
/// Address must be 8-byte aligned for atomic access.
pub inline fn write64(addr: u64, value: u64) void {
    debugValidateAddr(addr, 8);
    const ptr: *volatile u64 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Full memory barrier - ensures all prior memory operations complete
/// before subsequent operations. Use after writing control registers
/// that affect device behavior.
///
/// MEMORY TYPE NOTES:
/// - Valid for Uncacheable (UC) and Write-Through (WT) memory.
/// - For Write-Combining (WC) memory (framebuffers), stores may still be
///   buffered. Use clflush or a serializing instruction for WC regions.
/// - Does not prevent speculative execution on all microarchitectures.
pub inline fn memoryBarrier() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Read memory barrier - ensures all prior reads complete before
/// subsequent memory operations.
///
/// NOTE: On some microarchitectures, lfence does not prevent speculative
/// loads. For Spectre mitigations, additional measures may be needed.
pub inline fn readBarrier() void {
    asm volatile ("lfence" ::: .{ .memory = true });
}

/// Write memory barrier - ensures all prior writes complete before
/// subsequent write operations.
///
/// NOTE: sfence only orders stores, not loads. For full ordering, use
/// memoryBarrier() instead.
pub inline fn writeBarrier() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

/// Set bits in a 32-bit MMIO register (read-modify-write).
///
/// CONCURRENCY WARNING: This is NOT atomic. The operation consists of:
///   1. Read current value
///   2. OR with bits
///   3. Write result
/// If another thread or ISR accesses the same register between steps 1 and 3,
/// one modification will be lost (lost update race condition).
///
/// CALLER REQUIREMENT: Hold a spinlock or disable interrupts before calling
/// if concurrent access to this register is possible. Example:
///   interrupts.disable();
///   defer interrupts.enable();
///   mmio.setBits32(ctrl_reg, ENABLE_BIT);
///
/// DEBUG: In debug builds, warns if interrupts are enabled (potential race).
pub inline fn setBits32(addr: u64, bits: u32) void {
    debugCheckSmpSafety("setBits32");
    write32(addr, read32(addr) | bits);
}

/// Clear bits in a 32-bit MMIO register (read-modify-write).
///
/// CONCURRENCY WARNING: This is NOT atomic. See setBits32 for details.
/// Caller must hold appropriate locks when concurrent access is possible.
///
/// DEBUG: In debug builds, warns if interrupts are enabled (potential race).
pub inline fn clearBits32(addr: u64, bits: u32) void {
    debugCheckSmpSafety("clearBits32");
    write32(addr, read32(addr) & ~bits);
}

/// Modify bits in a 32-bit MMIO register (read-modify-write).
/// Clears bits in mask, then sets bits in value.
///
/// CONCURRENCY WARNING: This is NOT atomic. See setBits32 for details.
/// Caller must hold appropriate locks when concurrent access is possible.
///
/// DEBUG: In debug builds, warns if interrupts are enabled (potential race).
pub inline fn modifyBits32(addr: u64, mask: u32, value: u32) void {
    debugCheckSmpSafety("modifyBits32");
    write32(addr, (read32(addr) & ~mask) | (value & mask));
}

/// Set bits in a 32-bit MMIO register atomically using LOCK prefix.
/// Use this when concurrent access is possible and holding a lock is too expensive.
pub inline fn setBits32Atomic(addr: u64, bits: u32) void {
    debugValidateAddr(addr, 4);
    asm volatile ("lock orl %[bits], (%[ptr])"
        :
        : [bits] "er" (bits),
          [ptr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Clear bits in a 32-bit MMIO register atomically using LOCK prefix.
/// Use this when concurrent access is possible and holding a lock is too expensive.
pub inline fn clearBits32Atomic(addr: u64, bits: u32) void {
    debugValidateAddr(addr, 4);
    asm volatile ("lock andl %[bits], (%[ptr])"
        :
        : [bits] "er" (~bits),
          [ptr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Poll a 32-bit register until condition is met or iteration limit reached.
/// Returns true if condition met, false if timeout.
///
/// Use this for early boot or when TSC is not yet calibrated.
/// For wall-clock timeouts, prefer poll32Timed().
pub fn poll32(addr: u64, mask: u32, expected: u32, max_iterations: usize) bool {
    var i: usize = 0;
    while (i < max_iterations) : (i += 1) {
        if ((read32(addr) & mask) == expected) {
            return true;
        }
        // pause reduces power consumption and improves spin-wait performance
        // by hinting to the CPU that this is a spin-loop
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}

/// Poll a 32-bit register until any bit in mask is set, or iteration limit.
/// Returns true if any bit set, false if timeout.
pub fn pollAny32(addr: u64, mask: u32, max_iterations: usize) bool {
    var i: usize = 0;
    while (i < max_iterations) : (i += 1) {
        if ((read32(addr) & mask) != 0) {
            return true;
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}

const timing = @import("../kernel/timing.zig");

/// Poll a 32-bit register with real timeout in microseconds.
/// Uses calibrated TSC for accurate wall-clock timing.
///
/// FALLBACK BEHAVIOR: If TSC is not calibrated (e.g., early boot),
/// falls back to iteration-based polling with FALLBACK_MAX_ITERATIONS.
/// This prevents infinite loops but timing will be approximate.
///
/// Returns true if condition met, false if timeout.
pub fn poll32Timed(addr: u64, mask: u32, expected: u32, timeout_us: u64) bool {
    // Check if TSC is calibrated; if not, use iteration fallback to prevent
    // infinite loop (hasTimedOut returns false when uncalibrated)
    if (!timing.isCalibrated()) {
        // Fallback: estimate iterations based on typical timeout
        // Scale iterations by timeout (1us ~ 1000 iterations at 1GHz with pause)
        const scaled_iterations = @min(
            FALLBACK_MAX_ITERATIONS,
            @as(usize, @intCast(timeout_us)) *| 1000,
        );
        return poll32(addr, mask, expected, scaled_iterations);
    }

    const start = timing.rdtsc();
    while (!timing.hasTimedOut(start, timeout_us)) {
        if ((read32(addr) & mask) == expected) {
            return true;
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}

/// Poll a 32-bit register until any bit in mask is set, with real timeout.
///
/// FALLBACK BEHAVIOR: If TSC is not calibrated, falls back to iteration-based
/// polling. See poll32Timed() for details.
///
/// Returns true if any bit set, false if timeout.
pub fn pollAny32Timed(addr: u64, mask: u32, timeout_us: u64) bool {
    // Check if TSC is calibrated; if not, use iteration fallback
    if (!timing.isCalibrated()) {
        const scaled_iterations = @min(
            FALLBACK_MAX_ITERATIONS,
            @as(usize, @intCast(timeout_us)) *| 1000,
        );
        return pollAny32(addr, mask, scaled_iterations);
    }

    const start = timing.rdtsc();
    while (!timing.hasTimedOut(start, timeout_us)) {
        if ((read32(addr) & mask) != 0) {
            return true;
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}
