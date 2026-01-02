// AArch64 MMIO Utilities

const std = @import("std");

pub const MmioDevice = struct {
    phys_addr: u64,
    virt_addr: u64,
    size: u64,
};

pub fn memoryBarrier() void {
    asm volatile ("dsb sy");
}

pub fn readBarrier() void {
    asm volatile ("dsb ld");
}

pub fn writeBarrier() void {
    asm volatile ("dsb st");
}


// SECURITY NOTE: These low-level MMIO functions do NOT validate addresses.
// Callers MUST ensure addresses are valid MMIO regions. Prefer using
// MmioDevice wrapper (from mmio_device.zig) which provides bounds checking.
// These raw functions are intended for HAL code that has already validated
// addresses through other means (e.g., GIC driver with isValidGicAddress).

/// Read 8-bit value from MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn read8(addr: u64) u8 {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 1);
    }
    const val = @as(*volatile u8, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

/// Read 16-bit value from MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn read16(addr: u64) u16 {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 2);
    }
    const val = @as(*volatile u16, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

/// Read 32-bit value from MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn read32(addr: u64) u32 {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 4);
    }
    const val = @as(*volatile u32, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

/// Read 64-bit value from MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn read64(addr: u64) u64 {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 8);
    }
    const val = @as(*volatile u64, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

/// Write 8-bit value to MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn write8(addr: u64, val: u8) void {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 1);
    }
    memoryBarrier();
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

/// Write 16-bit value to MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn write16(addr: u64, val: u16) void {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 2);
    }
    memoryBarrier();
    @as(*volatile u16, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

/// Write 32-bit value to MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn write32(addr: u64, val: u32) void {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 4);
    }
    memoryBarrier();
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

/// Write 64-bit value to MMIO address.
/// SAFETY: Caller must ensure addr points to valid MMIO memory.
pub fn write64(addr: u64, val: u64) void {
    if (std.debug.runtime_safety) {
        validateMmioAddress(addr, 8);
    }
    memoryBarrier();
    @as(*volatile u64, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

// Minimum valid MMIO address - addresses below this are likely errors.
// On AArch64, like x86_64, low addresses are typically not used for MMIO.
const MIN_MMIO_ADDR: u64 = 0x1000;

/// Debug-mode validation for MMIO addresses.
/// Checks for null/low addresses and alignment.
fn validateMmioAddress(addr: u64, size: usize) void {
    // Null/low address check - catches null pointers and misconfigurations
    if (addr < MIN_MMIO_ADDR) {
        @panic("MMIO: invalid address (null or too low)");
    }
    // Alignment check
    if (addr % size != 0) {
        @panic("MMIO: unaligned access");
    }
}

/// Map MMIO region into virtual address space.
/// SECURITY: Returns error instead of 0 to prevent null pointer dereference
/// or accidental writes to address 0 if caller doesn't check return value.
pub fn mapMmio(phys_addr: u64, size: u64) !u64 {
    _ = phys_addr;
    _ = size;
    // TODO: Implement proper MMIO mapping via VMM
    // For now, return error to prevent callers from using invalid address
    return error.NotImplemented;
}
