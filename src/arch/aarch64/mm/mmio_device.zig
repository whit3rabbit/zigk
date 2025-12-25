// MmioDevice - Zero-Cost MMIO Device Wrapper (AArch64)

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");

pub fn MmioDevice(comptime RegisterMap: type) type {
    comptime {
        const info = @typeInfo(RegisterMap);
        if (info != .@"enum") {
            @compileError("MmioDevice requires an enum type for RegisterMap, got " ++ @typeName(RegisterMap));
        }
    }

    return struct {
        base: u64,
        size: usize,

        const Self = @This();
        const bounds_check_enabled = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

        pub fn init(base: u64, size: usize) Self {
            return .{ .base = base, .size = size };
        }

        pub inline fn read(self: Self, comptime reg: RegisterMap) u32 {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 4 > self.size) @panic("MmioDevice: read32 out of bounds");
            return mmio.read32(self.base + offset);
        }

        pub inline fn write(self: Self, comptime reg: RegisterMap, value: u32) void {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 4 > self.size) @panic("MmioDevice: write32 out of bounds");
            mmio.write32(self.base + offset, value);
        }

        pub inline fn read32(self: Self, comptime reg: RegisterMap) u32 { return self.read(reg); }
        pub inline fn write32(self: Self, comptime reg: RegisterMap, value: u32) void { self.write(reg, value); }

        pub inline fn readTyped(self: Self, comptime reg: RegisterMap, comptime T: type) T {
            return @bitCast(self.read(reg));
        }

        pub inline fn writeTyped(self: Self, comptime reg: RegisterMap, value: anytype) void {
            self.write(reg, @bitCast(value));
        }

        pub inline fn read64(self: Self, comptime reg: RegisterMap) u64 {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 8 > self.size) @panic("MmioDevice: read64 out of bounds");
            return mmio.read64(self.base + offset);
        }

        pub inline fn write64(self: Self, comptime reg: RegisterMap, value: u64) void {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 8 > self.size) @panic("MmioDevice: write64 out of bounds");
            mmio.write64(self.base + offset, value);
        }

        pub inline fn readTyped64(self: Self, comptime reg: RegisterMap, comptime T: type) T {
            return @bitCast(self.read64(reg));
        }

        pub inline fn writeTyped64(self: Self, comptime reg: RegisterMap, value: anytype) void {
            self.write64(reg, @bitCast(value));
        }

        pub inline fn read16(self: Self, comptime reg: RegisterMap) u16 {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 2 > self.size) @panic("MmioDevice: read16 out of bounds");
            return mmio.read16(self.base + offset);
        }

        pub inline fn write16(self: Self, comptime reg: RegisterMap, value: u16) void {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 2 > self.size) @panic("MmioDevice: write16 out of bounds");
            mmio.write16(self.base + offset, value);
        }

        pub inline fn read8(self: Self, comptime reg: RegisterMap) u8 {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 1 > self.size) @panic("MmioDevice: read8 out of bounds");
            return mmio.read8(self.base + offset);
        }

        pub inline fn write8(self: Self, comptime reg: RegisterMap, value: u8) void {
            const offset = @intFromEnum(reg);
            if (bounds_check_enabled and offset + 1 > self.size) @panic("MmioDevice: write8 out of bounds");
            mmio.write8(self.base + offset, value);
        }
        
        pub inline fn setBits(self: Self, comptime reg: RegisterMap, bits: u32) void { self.write(reg, self.read(reg) | bits); }
        pub inline fn clearBits(self: Self, comptime reg: RegisterMap, bits: u32) void { self.write(reg, self.read(reg) & ~bits); }
        
        pub fn pollTimed(_: Self, _: RegisterMap, _: u32, _: u32, _: u64) bool { return false; }
        pub inline fn writeRaw(_: Self, _: u64, _: u32) void {}
    };
}
