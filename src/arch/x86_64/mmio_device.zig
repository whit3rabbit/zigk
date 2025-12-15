// MmioDevice - Zero-Cost MMIO Device Wrapper
//
// Provides type-safe, comptime-validated register access for MMIO devices.
// Eliminates per-driver boilerplate while maintaining zero runtime overhead.
//
// Key Features:
// - Register offsets computed at comptime (no runtime math)
// - Bounds checking only in Debug mode (zero-cost in release)
// - Type-safe accessors via packed struct casting
// - Register names enforced by enum (typos caught at compile time)
//
// Usage:
// ```
// const Reg = enum(u64) { ctrl = 0x0000, status = 0x0008 };
// const DeviceRegs = MmioDevice(Reg);
// var regs = DeviceRegs{ .base = mmio_base, .size = bar_size };
// const status = regs.read(.status);
// regs.write(.ctrl, 0x1234);
// ```

const std = @import("std");
const builtin = @import("builtin");
const mmio = @import("mmio.zig");

/// Zero-cost MMIO device wrapper with compile-time offset validation.
///
/// RegisterMap must be an enum whose integer backing type represents byte offsets.
/// All register accesses are bounds-checked in Debug mode only.
pub fn MmioDevice(comptime RegisterMap: type) type {
    comptime {
        const info = @typeInfo(RegisterMap);
        if (info != .@"enum") {
            @compileError("MmioDevice requires an enum type for RegisterMap, got " ++ @typeName(RegisterMap));
        }
    }

    return struct {
        /// MMIO base virtual address
        base: u64,
        /// MMIO region size in bytes (for bounds checking)
        size: usize,

        const Self = @This();

        /// Create an MmioDevice from base address and size
        pub fn init(base: u64, size: usize) Self {
            return .{ .base = base, .size = size };
        }

        // =====================================================================
        // 32-bit Register Access (most common for PCIe devices)
        // =====================================================================

        /// Read a 32-bit register by name. Offset computed at comptime.
        pub inline fn read(self: Self, comptime reg: RegisterMap) u32 {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 4 > self.size) {
                    @panic("MmioDevice: read32 out of bounds");
                }
            }
            return mmio.read32(self.base + offset);
        }

        /// Write a 32-bit register by name.
        pub inline fn write(self: Self, comptime reg: RegisterMap, value: u32) void {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 4 > self.size) {
                    @panic("MmioDevice: write32 out of bounds");
                }
            }
            mmio.write32(self.base + offset, value);
        }

        /// Read and cast to a typed packed struct.
        /// T must be a packed struct with backing type u32.
        pub inline fn readTyped(self: Self, comptime reg: RegisterMap, comptime T: type) T {
            comptime {
                const info = @typeInfo(T);
                if (info != .@"struct" or info.@"struct".backing_integer != u32) {
                    @compileError("readTyped requires packed struct(u32), got " ++ @typeName(T));
                }
            }
            return @bitCast(self.read(reg));
        }

        /// Write from a typed packed struct.
        pub inline fn writeTyped(self: Self, comptime reg: RegisterMap, value: anytype) void {
            const T = @TypeOf(value);
            comptime {
                const info = @typeInfo(T);
                if (info != .@"struct" or info.@"struct".backing_integer != u32) {
                    @compileError("writeTyped requires packed struct(u32), got " ++ @typeName(T));
                }
            }
            self.write(reg, @bitCast(value));
        }

        // Aliases for explicit 32-bit access (for code clarity)
        pub const read32 = read;
        pub const write32 = write;

        // =====================================================================
        // Other Register Sizes
        // =====================================================================

        /// Read a 64-bit register by name.
        pub inline fn read64(self: Self, comptime reg: RegisterMap) u64 {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 8 > self.size) {
                    @panic("MmioDevice: read64 out of bounds");
                }
            }
            return mmio.read64(self.base + offset);
        }

        /// Write a 64-bit register by name.
        pub inline fn write64(self: Self, comptime reg: RegisterMap, value: u64) void {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 8 > self.size) {
                    @panic("MmioDevice: write64 out of bounds");
                }
            }
            mmio.write64(self.base + offset, value);
        }

        /// Read and cast to a typed packed struct with u64 backing.
        pub inline fn readTyped64(self: Self, comptime reg: RegisterMap, comptime T: type) T {
            comptime {
                const info = @typeInfo(T);
                if (info != .@"struct" or info.@"struct".backing_integer != u64) {
                    @compileError("readTyped64 requires packed struct(u64), got " ++ @typeName(T));
                }
            }
            return @bitCast(self.read64(reg));
        }

        /// Write from a typed packed struct with u64 backing.
        pub inline fn writeTyped64(self: Self, comptime reg: RegisterMap, value: anytype) void {
            const T = @TypeOf(value);
            comptime {
                const info = @typeInfo(T);
                if (info != .@"struct" or info.@"struct".backing_integer != u64) {
                    @compileError("writeTyped64 requires packed struct(u64), got " ++ @typeName(T));
                }
            }
            self.write64(reg, @bitCast(value));
        }

        /// Read a 16-bit register by name.
        pub inline fn read16(self: Self, comptime reg: RegisterMap) u16 {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 2 > self.size) {
                    @panic("MmioDevice: read16 out of bounds");
                }
            }
            return mmio.read16(self.base + offset);
        }

        /// Write a 16-bit register by name.
        pub inline fn write16(self: Self, comptime reg: RegisterMap, value: u16) void {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 2 > self.size) {
                    @panic("MmioDevice: write16 out of bounds");
                }
            }
            mmio.write16(self.base + offset, value);
        }

        /// Read an 8-bit register by name.
        pub inline fn read8(self: Self, comptime reg: RegisterMap) u8 {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 1 > self.size) {
                    @panic("MmioDevice: read8 out of bounds");
                }
            }
            return mmio.read8(self.base + offset);
        }

        /// Write an 8-bit register by name.
        pub inline fn write8(self: Self, comptime reg: RegisterMap, value: u8) void {
            const offset = @intFromEnum(reg);
            if (builtin.mode == .Debug) {
                if (offset + 1 > self.size) {
                    @panic("MmioDevice: write8 out of bounds");
                }
            }
            mmio.write8(self.base + offset, value);
        }

        // =====================================================================
        // Read-Modify-Write Operations
        // =====================================================================

        /// Set bits in a 32-bit register (read-modify-write).
        pub inline fn setBits(self: Self, comptime reg: RegisterMap, bits: u32) void {
            self.write(reg, self.read(reg) | bits);
        }

        /// Clear bits in a 32-bit register (read-modify-write).
        pub inline fn clearBits(self: Self, comptime reg: RegisterMap, bits: u32) void {
            self.write(reg, self.read(reg) & ~bits);
        }

        /// Modify bits in a 32-bit register.
        /// Clears bits in mask, then sets bits in value.
        pub inline fn modifyBits(self: Self, comptime reg: RegisterMap, mask: u32, value: u32) void {
            self.write(reg, (self.read(reg) & ~mask) | (value & mask));
        }

        // =====================================================================
        // Polling Operations
        // =====================================================================

        /// Poll a 32-bit register until condition is met or max iterations reached.
        /// Returns true if condition met, false if timeout.
        pub fn poll(self: Self, comptime reg: RegisterMap, mask: u32, expected: u32, max_iterations: usize) bool {
            const offset = @intFromEnum(reg);
            return mmio.poll32(self.base + offset, mask, expected, max_iterations);
        }

        /// Poll a 32-bit register with real timeout in microseconds.
        pub fn pollTimed(self: Self, comptime reg: RegisterMap, mask: u32, expected: u32, timeout_us: u64) bool {
            const offset = @intFromEnum(reg);
            return mmio.poll32Timed(self.base + offset, mask, expected, timeout_us);
        }

        // =====================================================================
        // Raw Access (for dynamic offsets computed at runtime)
        // =====================================================================

        /// Read a 32-bit value at base + runtime offset.
        /// Use sparingly - prefer enum-based access for compile-time safety.
        pub inline fn readRaw(self: Self, offset: u64) u32 {
            if (builtin.mode == .Debug) {
                if (offset + 4 > self.size) {
                    @panic("MmioDevice: readRaw out of bounds");
                }
            }
            return mmio.read32(self.base + offset);
        }

        /// Write a 32-bit value at base + runtime offset.
        pub inline fn writeRaw(self: Self, offset: u64, value: u32) void {
            if (builtin.mode == .Debug) {
                if (offset + 4 > self.size) {
                    @panic("MmioDevice: writeRaw out of bounds");
                }
            }
            mmio.write32(self.base + offset, value);
        }
    };
}
