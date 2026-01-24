// aarch64 AAPCS64 va_list implementation
//
// Implements the ARM 64-bit Procedure Call Standard (AAPCS64) va_list format.
// This allows manual varargs traversal without relying on LLVM's @cVaArg.
//
// AAPCS64 va_list structure (32 bytes total):
// - __stack (8 bytes at offset 0): pointer to next stack argument
// - __gr_top (8 bytes at offset 8): end of GP register save area
// - __vr_top (8 bytes at offset 16): end of vector register save area
// - __gr_offs (4 bytes at offset 24): negative offset from gr_top
// - __vr_offs (4 bytes at offset 28): negative offset from vr_top
//
// Register areas:
// - GP registers: x0-x7 (8 registers x 8 bytes = 64 bytes)
// - Vector registers: v0-v7 (8 registers x 16 bytes = 128 bytes)
//
// Offset semantics:
// - __gr_offs starts at -64 (8 regs x 8 bytes) and increments toward 0
// - __vr_offs starts at -128 (8 regs x 16 bytes) and increments toward 0
// - When offset >= 0, read from __stack instead

const std = @import("std");

/// va_list structure field offsets
const VA_STACK = 0;
const VA_GR_TOP = 8;
const VA_VR_TOP = 16;
const VA_GR_OFFS = 24;
const VA_VR_OFFS = 28;

/// Read a u64 from potentially unaligned memory (little-endian)
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

/// Read a i32 from potentially unaligned memory (little-endian)
inline fn readI32(ptr: [*]const u8) i32 {
    const unsigned: u32 = @as(u32, ptr[0]) |
        (@as(u32, ptr[1]) << 8) |
        (@as(u32, ptr[2]) << 16) |
        (@as(u32, ptr[3]) << 24);
    return @bitCast(unsigned);
}

/// Write a u64 to potentially unaligned memory (little-endian)
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

/// Write an i32 to potentially unaligned memory (little-endian)
inline fn writeI32(ptr: [*]u8, val: i32) void {
    const unsigned: u32 = @bitCast(val);
    ptr[0] = @truncate(unsigned);
    ptr[1] = @truncate(unsigned >> 8);
    ptr[2] = @truncate(unsigned >> 16);
    ptr[3] = @truncate(unsigned >> 24);
}

/// Size of the aarch64 va_list structure (__stack + __gr_top + __vr_top + __gr_offs + __vr_offs)
const VA_LIST_SIZE = 32;

/// Saved va_list state for va_copy semantics.
/// Stores a snapshot of the 32-byte va_list structure that can be independently traversed.
pub const VaListState = struct {
    data: [VA_LIST_SIZE]u8,

    /// Create a VaList pointing to this saved state
    pub fn toVaList(self: *VaListState) VaList {
        return .{ .ptr = &self.data };
    }
};

/// aarch64 VaList wrapper for manual argument extraction
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

    /// Save the current va_list state (va_copy semantics).
    /// The returned VaListState can be independently traversed without
    /// affecting the original va_list.
    pub fn save(self: *VaList) VaListState {
        var state: VaListState = undefined;
        for (0..VA_LIST_SIZE) |i| {
            state.data[i] = self.ptr[i];
        }
        return state;
    }

    /// Get next argument of type T from va_list (advances the va_list state)
    pub fn arg(self: *VaList, comptime T: type) T {
        const type_info = @typeInfo(T);

        // Handle floating-point types via vector register area
        if (type_info == .float) {
            return self.argFloat(T);
        }

        // GP types: integers, pointers, enums
        const val = self.argGP();

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

    /// Get next GP (general-purpose) register argument
    fn argGP(self: *VaList) usize {
        // Read current __gr_offs
        const gr_offs = readI32(self.ptr + VA_GR_OFFS);

        if (gr_offs < 0) {
            // Argument is in GP register save area
            const gr_top = readU64(self.ptr + VA_GR_TOP);
            if (gr_top != 0) {
                // Compute address: gr_top + gr_offs (gr_offs is negative)
                const arg_addr = @as(i64, @bitCast(gr_top)) + @as(i64, gr_offs);
                const arg_ptr: [*]const u8 = @ptrFromInt(@as(u64, @bitCast(arg_addr)));
                const val = readU64(arg_ptr);

                // Advance __gr_offs by 8 bytes (toward 0)
                writeI32(self.ptr + VA_GR_OFFS, gr_offs + 8);

                return val;
            }
        }

        // Argument is on the stack
        const stack_addr = readU64(self.ptr + VA_STACK);
        if (stack_addr != 0) {
            const stack_ptr: [*]const u8 = @ptrFromInt(stack_addr);
            const val = readU64(stack_ptr);

            // Advance __stack by 8 bytes
            writeU64(self.ptr + VA_STACK, stack_addr + 8);

            return val;
        }

        return 0;
    }

    /// Get next floating-point argument from vector register area
    fn argFloat(self: *VaList, comptime T: type) T {
        // Read current __vr_offs
        const vr_offs = readI32(self.ptr + VA_VR_OFFS);

        if (vr_offs < 0) {
            // Argument is in vector register save area
            const vr_top = readU64(self.ptr + VA_VR_TOP);
            if (vr_top != 0) {
                // Compute address: vr_top + vr_offs (vr_offs is negative)
                const arg_addr = @as(i64, @bitCast(vr_top)) + @as(i64, vr_offs);
                const arg_ptr: [*]const u8 = @ptrFromInt(@as(u64, @bitCast(arg_addr)));

                // Advance __vr_offs by 16 bytes (vector register size)
                writeI32(self.ptr + VA_VR_OFFS, vr_offs + 16);

                // Read the float value (first bytes of vector register)
                if (T == f64) {
                    return @bitCast(readU64(arg_ptr));
                } else if (T == f32) {
                    const bits: u32 = @as(u32, arg_ptr[0]) |
                        (@as(u32, arg_ptr[1]) << 8) |
                        (@as(u32, arg_ptr[2]) << 16) |
                        (@as(u32, arg_ptr[3]) << 24);
                    return @bitCast(bits);
                } else {
                    return @bitCast(readU64(arg_ptr));
                }
            }
        }

        // FP argument is on the stack
        const stack_addr = readU64(self.ptr + VA_STACK);
        if (stack_addr != 0) {
            const stack_ptr: [*]const u8 = @ptrFromInt(stack_addr);

            // Advance __stack by 8 bytes
            writeU64(self.ptr + VA_STACK, stack_addr + 8);

            if (T == f64) {
                return @bitCast(readU64(stack_ptr));
            } else if (T == f32) {
                const bits: u32 = @as(u32, stack_ptr[0]) |
                    (@as(u32, stack_ptr[1]) << 8) |
                    (@as(u32, stack_ptr[2]) << 16) |
                    (@as(u32, stack_ptr[3]) << 24);
                return @bitCast(bits);
            } else {
                return @bitCast(readU64(stack_ptr));
            }
        }

        return 0.0;
    }
};
