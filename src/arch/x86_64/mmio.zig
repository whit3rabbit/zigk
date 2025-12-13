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

/// Read a 8-bit value from a memory-mapped register
pub inline fn read8(addr: u64) u8 {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 8-bit value to a memory-mapped register
pub inline fn write8(addr: u64, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 16-bit value from a memory-mapped register
/// Address should be 2-byte aligned
pub inline fn read16(addr: u64) u16 {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 16-bit value to a memory-mapped register
/// Address should be 2-byte aligned
pub inline fn write16(addr: u64, value: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 32-bit value from a memory-mapped register
/// Address should be 4-byte aligned
pub inline fn read32(addr: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 32-bit value to a memory-mapped register
/// Address should be 4-byte aligned
pub inline fn write32(addr: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Read a 64-bit value from a memory-mapped register
/// Address should be 8-byte aligned
pub inline fn read64(addr: u64) u64 {
    const ptr: *volatile u64 = @ptrFromInt(addr);
    return ptr.*;
}

/// Write a 64-bit value to a memory-mapped register
/// Address should be 8-byte aligned
pub inline fn write64(addr: u64, value: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Memory barrier - ensures all prior memory operations complete
/// before subsequent operations. Use after writing control registers
/// that affect device behavior.
pub inline fn memoryBarrier() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Read memory barrier - ensures all prior reads complete
pub inline fn readBarrier() void {
    asm volatile ("lfence" ::: .{ .memory = true });
}

/// Write memory barrier - ensures all prior writes complete
pub inline fn writeBarrier() void {
    asm volatile ("sfence" ::: .{ .memory = true });
}

/// Set bits in a 32-bit MMIO register (read-modify-write)
pub inline fn setBits32(addr: u64, bits: u32) void {
    write32(addr, read32(addr) | bits);
}

/// Clear bits in a 32-bit MMIO register (read-modify-write)
pub inline fn clearBits32(addr: u64, bits: u32) void {
    write32(addr, read32(addr) & ~bits);
}

/// Modify bits in a 32-bit MMIO register (read-modify-write)
/// Clears bits in mask, then sets bits in value
pub inline fn modifyBits32(addr: u64, mask: u32, value: u32) void {
    write32(addr, (read32(addr) & ~mask) | (value & mask));
}

/// Poll a 32-bit register until condition is met or timeout
/// Returns true if condition met, false if timeout
pub fn poll32(addr: u64, mask: u32, expected: u32, max_iterations: usize) bool {
    var i: usize = 0;
    while (i < max_iterations) : (i += 1) {
        if ((read32(addr) & mask) == expected) {
            return true;
        }
        // Small delay to avoid hammering the bus
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}

/// Poll a 32-bit register until any bit in mask is set
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

const timing = @import("timing.zig");

/// Poll a 32-bit register with real timeout in microseconds
/// Uses calibrated TSC for accurate wall-clock timing
pub fn poll32Timed(addr: u64, mask: u32, expected: u32, timeout_us: u64) bool {
    const start = timing.rdtsc();
    while (!timing.hasTimedOut(start, timeout_us)) {
        if ((read32(addr) & mask) == expected) {
            return true;
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}

/// Poll a 32-bit register until any bit in mask is set, with real timeout
pub fn pollAny32Timed(addr: u64, mask: u32, timeout_us: u64) bool {
    const start = timing.rdtsc();
    while (!timing.hasTimedOut(start, timeout_us)) {
        if ((read32(addr) & mask) != 0) {
            return true;
        }
        asm volatile ("pause" ::: .{ .memory = true });
    }
    return false;
}
