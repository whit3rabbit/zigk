// x86_64 System V ABI va_list implementation
//
// Extracted from vprintf.zig for cross-architecture reuse.
// The va_list structure tracks both register-saved and stack-passed arguments.

const std = @import("std");

/// x86_64 System V ABI va_list structure layout offsets:
/// - gp_offset (4 bytes at offset 0): offset in reg_save_area for next GP register arg
/// - fp_offset (4 bytes at offset 4): offset in reg_save_area for next FP register arg
/// - overflow_arg_area (8 bytes at offset 8): pointer to stack-passed arguments
/// - reg_save_area (8 bytes at offset 16): pointer to register save area
const VA_GP_OFFSET = 0;
const VA_FP_OFFSET = 4;
const VA_OVERFLOW_ARG_AREA = 8;
const VA_REG_SAVE_AREA = 16;

/// Maximum GP registers used for argument passing (6 registers x 8 bytes = 48)
const GP_REG_LIMIT: u32 = 48;

/// Maximum FP registers used for argument passing (8 registers x 16 bytes = 128)
const FP_REG_LIMIT: u32 = 176; // 48 (GP) + 128 (FP)

/// Read a u32 from potentially unaligned memory
inline fn readU32(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) |
        (@as(u32, ptr[1]) << 8) |
        (@as(u32, ptr[2]) << 16) |
        (@as(u32, ptr[3]) << 24);
}

/// Read a u64 from potentially unaligned memory
inline fn readU64(ptr: [*]const u8) u64 {
    return @as(u64, ptr[0]) |
        (@as(u64, ptr[1]) << 8) |
        (@as(u64, ptr[2]) << 16) |
        (@as(u64, ptr[3]) << 24) |
        (@as(u64, ptr[4]) << 32) |
        (@as(u64, ptr[5]) << 40) |
        (@as(u64, ptr[6]) << 48) |
        (@as(u64, ptr[7]) << 56);
}

/// Write a u32 to potentially unaligned memory
inline fn writeU32(ptr: [*]u8, val: u32) void {
    ptr[0] = @truncate(val);
    ptr[1] = @truncate(val >> 8);
    ptr[2] = @truncate(val >> 16);
    ptr[3] = @truncate(val >> 24);
}

/// Write a u64 to potentially unaligned memory
inline fn writeU64(ptr: [*]u8, val: u64) void {
    ptr[0] = @truncate(val);
    ptr[1] = @truncate(val >> 8);
    ptr[2] = @truncate(val >> 16);
    ptr[3] = @truncate(val >> 24);
    ptr[4] = @truncate(val >> 32);
    ptr[5] = @truncate(val >> 40);
    ptr[6] = @truncate(val >> 48);
    ptr[7] = @truncate(val >> 56);
}

/// x86_64 VaList wrapper for manual argument extraction
pub const VaList = struct {
    ptr: [*]u8,

    /// Create VaList from raw va_list pointer
    /// SECURITY: Panics if raw is null - this indicates a programming error
    /// where a varargs function was called with a null va_list pointer.
    pub fn from(raw: ?*anyopaque) VaList {
        if (raw) |r| {
            return .{ .ptr = @ptrCast(r) };
        } else {
            @panic("VaList.from: null va_list pointer - programming error");
        }
    }

    /// Get next argument of type T from va_list (advances the va_list state)
    pub fn arg(self: *VaList, comptime T: type) T {
        const type_info = @typeInfo(T);

        // Handle floating-point types via FP register area
        if (type_info == .float) {
            return self.argFloat(T);
        }

        // GP types: integers, pointers, enums
        const val = self.argRaw();

        // Convert raw value to requested type
        return switch (type_info) {
            .pointer => @ptrFromInt(val),
            .optional => |opt| blk: {
                if (@typeInfo(opt.child) == .pointer) {
                    break :blk if (val == 0) null else @ptrFromInt(val);
                } else {
                    break :blk @bitCast(@as(usize, val));
                }
            },
            .int => |int_info| blk: {
                if (int_info.signedness == .signed) {
                    const signed: i64 = @bitCast(val);
                    break :blk @truncate(signed);
                } else {
                    break :blk @truncate(val);
                }
            },
            .@"enum" => @enumFromInt(@as(std.meta.Tag(T), @truncate(val))),
            else => @bitCast(@as(usize, val)),
        };
    }

    /// Get next raw usize argument (internal use)
    fn argRaw(self: *VaList) usize {
        // Read current gp_offset
        const gp_offset = readU32(self.ptr + VA_GP_OFFSET);

        if (gp_offset < GP_REG_LIMIT) {
            // Argument is in register save area
            const reg_save_addr = readU64(self.ptr + VA_REG_SAVE_AREA);
            if (reg_save_addr != 0) {
                const reg_save: [*]const u8 = @ptrFromInt(reg_save_addr);
                const val = readU64(reg_save + gp_offset);

                // Advance gp_offset by 8 bytes
                writeU32(self.ptr + VA_GP_OFFSET, gp_offset + 8);

                return val;
            }
        }

        // Argument is on the stack (overflow area)
        const overflow_addr = readU64(self.ptr + VA_OVERFLOW_ARG_AREA);
        if (overflow_addr != 0) {
            const overflow: [*]const u8 = @ptrFromInt(overflow_addr);
            const val = readU64(overflow);

            // Advance overflow_arg_area by 8 bytes
            writeU64(self.ptr + VA_OVERFLOW_ARG_AREA, overflow_addr + 8);

            return val;
        }

        return 0;
    }

    /// Get next floating-point argument
    fn argFloat(self: *VaList, comptime T: type) T {
        // Read current fp_offset
        const fp_offset = readU32(self.ptr + VA_FP_OFFSET);

        if (fp_offset < FP_REG_LIMIT) {
            // Argument is in FP register save area
            const reg_save_addr = readU64(self.ptr + VA_REG_SAVE_AREA);
            if (reg_save_addr != 0) {
                const reg_save: [*]const u8 = @ptrFromInt(reg_save_addr);
                const val_bytes = reg_save + fp_offset;

                // Advance fp_offset by 16 bytes (XMM register size)
                writeU32(self.ptr + VA_FP_OFFSET, fp_offset + 16);

                // Read the float value (first 8 bytes of XMM for f64)
                if (T == f64) {
                    return @bitCast(readU64(val_bytes));
                } else if (T == f32) {
                    const bits = readU32(val_bytes);
                    return @bitCast(bits);
                } else {
                    return @bitCast(readU64(val_bytes));
                }
            }
        }

        // FP argument is on the stack (overflow area)
        const overflow_addr = readU64(self.ptr + VA_OVERFLOW_ARG_AREA);
        if (overflow_addr != 0) {
            const overflow: [*]const u8 = @ptrFromInt(overflow_addr);

            // Advance overflow_arg_area by 8 bytes
            writeU64(self.ptr + VA_OVERFLOW_ARG_AREA, overflow_addr + 8);

            if (T == f64) {
                return @bitCast(readU64(overflow));
            } else if (T == f32) {
                return @bitCast(readU32(overflow));
            } else {
                return @bitCast(readU64(overflow));
            }
        }

        return 0.0;
    }
};
