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


pub fn read8(addr: u64) u8 {
    const val = @as(*volatile u8, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

pub fn read16(addr: u64) u16 {
    const val = @as(*volatile u16, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

pub fn read32(addr: u64) u32 {
    const val = @as(*volatile u32, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

pub fn read64(addr: u64) u64 {
    const val = @as(*volatile u64, @ptrFromInt(addr)).*;
    memoryBarrier();
    return val;
}

pub fn write8(addr: u64, val: u8) void {
    memoryBarrier();
    @as(*volatile u8, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

pub fn write16(addr: u64, val: u16) void {
    memoryBarrier();
    @as(*volatile u16, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

pub fn write32(addr: u64, val: u32) void {
    memoryBarrier();
    @as(*volatile u32, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

pub fn write64(addr: u64, val: u64) void {
    memoryBarrier();
    @as(*volatile u64, @ptrFromInt(addr)).* = val;
    memoryBarrier();
}

pub fn mapMmio(phys_addr: u64, size: u64) !u64 {
    _ = phys_addr; _ = size;
    return 0; // Stub
}
