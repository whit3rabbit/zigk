const std = @import("std");
const interface = @import("interface.zig");

const pmm = @import("pmm");
const hal = @import("hal");


/// Comptime-generic framebuffer driver that eliminates per-pixel runtime branching.
/// When buffered=true, all operations target a back buffer and present() copies to VRAM.
/// When buffered=false, all operations write directly to VRAM.
pub fn FramebufferDriver(comptime buffered: bool) type {
    return struct {
        mode: interface.VideoMode,
        back_buffer: if (buffered) [*]u32 else void,
        back_buffer_size: if (buffered) usize else void,

        const Self = @This();

        pub fn device(self: *Self) interface.GraphicsDevice {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        const vtable = interface.GraphicsDevice.VTable{
            .getMode = getMode,
            .putPixel = putPixel,
            .fillRect = fillRect,
            .drawBuffer = drawBuffer,
            .copyRect = copyRect,
            .present = present,
        };

        fn calcIndex(stride_u32: u64, x: u64, y: u64) ?u64 {
            const row = std.math.mul(u64, y, stride_u32) catch return null;
            return std.math.add(u64, row, x) catch return null;
        }

        fn calcOffsetBytes(pitch: u64, x_bytes: u64, y: u64) ?u64 {
            const row = std.math.mul(u64, y, pitch) catch return null;
            return std.math.add(u64, row, x_bytes) catch return null;
        }

        /// Initialize a buffered driver with back buffer from PMM.
        /// Only available when buffered=true.
        pub fn initWithBackBuffer(mode: interface.VideoMode) ?Self {
            if (!buffered) {
                @compileError("initWithBackBuffer only available for buffered driver");
            }

            const size_bytes = @as(usize, mode.height) * mode.pitch;
            const pages_needed = (size_bytes + 0x1000 - 1) / 0x1000;

            if (pmm.allocZeroedPages(pages_needed)) |bb_phys| {
                const bb_virt_addr = @intFromPtr(hal.paging.physToVirt(bb_phys));
                const bb_ptr: [*]u32 = @ptrFromInt(bb_virt_addr);

                return Self{
                    .mode = mode,
                    .back_buffer = bb_ptr,
                    .back_buffer_size = size_bytes,
                };
            }
            return null;
        }

        /// Initialize a direct driver (no back buffer).
        /// Only available when buffered=false.
        pub fn initDirect(mode: interface.VideoMode) Self {
            if (buffered) {
                @compileError("initDirect only available for direct driver");
            }

            return Self{
                .mode = mode,
                .back_buffer = {},
                .back_buffer_size = {},
            };
        }

        fn getMode(ctx: *anyopaque) interface.VideoMode {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.mode;
        }

        fn putPixel(ctx: *anyopaque, x: u32, y: u32, color: interface.Color) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (x >= self.mode.width or y >= self.mode.height) return;

            const val: u32 =
                (@as(u32, color.r) >> @intCast(8 - self.mode.red_mask_size) << @intCast(self.mode.red_field_position)) |
                (@as(u32, color.g) >> @intCast(8 - self.mode.green_mask_size) << @intCast(self.mode.green_field_position)) |
                (@as(u32, color.b) >> @intCast(8 - self.mode.blue_mask_size) << @intCast(self.mode.blue_field_position)) |
                if (self.mode.alpha_mask_size > 0) (@as(u32, 255) >> @intCast(8 - self.mode.alpha_mask_size) << @intCast(self.mode.alpha_field_position)) else 0;

            if (buffered) {
                // Comptime: this branch is eliminated when buffered=false
                const stride_u32 = @as(u64, self.mode.pitch) / 4;
                const index = calcIndex(stride_u32, @as(u64, x), @as(u64, y)) orelse return;
                self.back_buffer[index] = val;
            } else {
                // Direct VRAM write
                const pitch = @as(u64, self.mode.pitch);
                const x_bytes = std.math.mul(u64, x, 4) catch return;
                const offset = calcOffsetBytes(pitch, x_bytes, @as(u64, y)) orelse return;
                const ptr: [*]u32 = @ptrFromInt(self.mode.addr + offset);
                ptr[0] = val;
            }
        }

        /// Optimized fillRect using row-based @memset instead of per-pixel loops.
        fn fillRect(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: interface.Color) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (x >= self.mode.width or y >= self.mode.height) return;
            const clip_w = if (x + w > self.mode.width) self.mode.width - x else w;
            const clip_h = if (y + h > self.mode.height) self.mode.height - y else h;
            if (clip_w == 0 or clip_h == 0) return;

            const val: u32 =
                (@as(u32, color.r) >> @intCast(8 - self.mode.red_mask_size) << @intCast(self.mode.red_field_position)) |
                (@as(u32, color.g) >> @intCast(8 - self.mode.green_mask_size) << @intCast(self.mode.green_field_position)) |
                (@as(u32, color.b) >> @intCast(8 - self.mode.blue_mask_size) << @intCast(self.mode.blue_field_position)) |
                if (self.mode.alpha_mask_size > 0) (@as(u32, 255) >> @intCast(8 - self.mode.alpha_mask_size) << @intCast(self.mode.alpha_field_position)) else 0;

            const stride_u32 = self.mode.pitch / 4;
            const stride_u64: u64 = @as(u64, stride_u32);
            const pitch = @as(u64, self.mode.pitch);
            const x_bytes = std.math.mul(u64, @as(u64, x), 4) catch return;

            var row: u32 = 0;
            while (row < clip_h) : (row += 1) {
                if (buffered) {
                    const row_start = calcIndex(stride_u64, @as(u64, x), @as(u64, y + row)) orelse return;
                    @memset(self.back_buffer[row_start .. row_start + clip_w], val);
                } else {
                    const row_offset = calcOffsetBytes(pitch, x_bytes, @as(u64, y + row)) orelse return;
                    const row_ptr: [*]u32 = @ptrFromInt(self.mode.addr + row_offset);
                    @memset(row_ptr[0..clip_w], val);
                }
            }
        }

        fn drawBuffer(ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, buf: []const u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (x >= self.mode.width or y >= self.mode.height) return;
            const clip_w = if (x + w > self.mode.width) self.mode.width - x else w;
            const clip_h = if (y + h > self.mode.height) self.mode.height - y else h;
            if (clip_w == 0 or clip_h == 0) return;

            // Validation: Ensure buffer is large enough
            if (buf.len < @as(usize, w) * h) return;

            const stride_u32 = self.mode.pitch / 4;
            const stride_u64: u64 = @as(u64, stride_u32);
            const pitch = @as(u64, self.mode.pitch);
            const x_bytes = std.math.mul(u64, @as(u64, x), 4) catch return;

            var row: u32 = 0;
            while (row < clip_h) : (row += 1) {
                const buf_offset = row * w;
                const src_ptr = buf.ptr + buf_offset;

                if (buffered) {
                    const fb_offset = calcIndex(stride_u64, @as(u64, x), @as(u64, y + row)) orelse return;
                    @memcpy(self.back_buffer[fb_offset .. fb_offset + clip_w], src_ptr[0..clip_w]);
                } else {
                    const fb_offset = calcOffsetBytes(pitch, x_bytes, @as(u64, y + row)) orelse return;
                    const fb_ptr: [*]u32 = @ptrFromInt(self.mode.addr + fb_offset);
                    @memcpy(fb_ptr[0..clip_w], src_ptr[0..clip_w]);
                }
            }
        }

        fn copyRect(ctx: *anyopaque, src_x: u32, src_y: u32, dst_x: u32, dst_y: u32, w: u32, h: u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (src_x >= self.mode.width or src_y >= self.mode.height) return;
            if (dst_x >= self.mode.width or dst_y >= self.mode.height) return;

            const clip_w = if (src_x + w > self.mode.width) self.mode.width - src_x else w;
            const final_w = if (dst_x + clip_w > self.mode.width) self.mode.width - dst_x else clip_w;

            const clip_h = if (src_y + h > self.mode.height) self.mode.height - src_y else h;
            const final_h = if (dst_y + clip_h > self.mode.height) self.mode.height - dst_y else clip_h;

            if (final_w == 0 or final_h == 0) return;

            const stride_u32 = self.mode.pitch / 4;
            const stride_u64: u64 = @as(u64, stride_u32);
            const pitch = @as(u64, self.mode.pitch);
            const src_x_bytes = std.math.mul(u64, @as(u64, src_x), 4) catch return;
            const dst_x_bytes = std.math.mul(u64, @as(u64, dst_x), 4) catch return;

            // Determine copy direction to handle overlapping regions
            const copy_backwards = src_y < dst_y;

            if (buffered) {
                if (copy_backwards) {
                    var i: u32 = 0;
                    while (i < final_h) : (i += 1) {
                        const row = final_h - 1 - i;
                        const src_offset = calcIndex(stride_u64, @as(u64, src_x), @as(u64, src_y + row)) orelse return;
                        const dst_offset = calcIndex(stride_u64, @as(u64, dst_x), @as(u64, dst_y + row)) orelse return;
                        // Using explicit forward/backward copy for safety, although separate rows are generally safe
                        // unless src_y == dst_y (which shouldn't happen in this branch unless logic is weird)
                        // But horizontal overlap within a row is possible if src_y == dst_y and src_x != dst_x.
                        // Here we handle row order. Within row, if src_y == dst_y, we need overlap protection.
                        if (src_y == dst_y) {
                            std.mem.copyBackwards(u32, self.back_buffer[dst_offset .. dst_offset + final_w], self.back_buffer[src_offset .. src_offset + final_w]);
                        } else {
                            @memcpy(self.back_buffer[dst_offset .. dst_offset + final_w], self.back_buffer[src_offset .. src_offset + final_w]);
                        }
                    }
                } else {
                    var row: u32 = 0;
                    while (row < final_h) : (row += 1) {
                        const src_offset = calcIndex(stride_u64, @as(u64, src_x), @as(u64, src_y + row)) orelse return;
                        const dst_offset = calcIndex(stride_u64, @as(u64, dst_x), @as(u64, dst_y + row)) orelse return;
                        if (src_y == dst_y) {
                             std.mem.copyForwards(u32, self.back_buffer[dst_offset .. dst_offset + final_w], self.back_buffer[src_offset .. src_offset + final_w]);
                        } else {
                             @memcpy(self.back_buffer[dst_offset .. dst_offset + final_w], self.back_buffer[src_offset .. src_offset + final_w]);
                        }
                    }
                }
            } else {
                // Direct VRAM copy
                if (copy_backwards) {
                    var i: u32 = 0;
                    while (i < final_h) : (i += 1) {
                        const row = final_h - 1 - i;
                        const src_offset = calcOffsetBytes(pitch, src_x_bytes, @as(u64, src_y + row)) orelse return;
                        const dst_offset = calcOffsetBytes(pitch, dst_x_bytes, @as(u64, dst_y + row)) orelse return;

                        const src_ptr: [*]u32 = @ptrFromInt(self.mode.addr + src_offset);
                        const dst_ptr: [*]u32 = @ptrFromInt(self.mode.addr + dst_offset);

                        @memcpy(dst_ptr[0..final_w], src_ptr[0..final_w]);
                    }
                } else {
                    var row: u32 = 0;
                    while (row < final_h) : (row += 1) {
                        const src_offset = calcOffsetBytes(pitch, src_x_bytes, @as(u64, src_y + row)) orelse return;
                        const dst_offset = calcOffsetBytes(pitch, dst_x_bytes, @as(u64, dst_y + row)) orelse return;

                        const src_ptr: [*]u32 = @ptrFromInt(self.mode.addr + src_offset);
                        const dst_ptr: [*]u32 = @ptrFromInt(self.mode.addr + dst_offset);

                        @memcpy(dst_ptr[0..final_w], src_ptr[0..final_w]);
                    }
                }
            }
        }

        fn present(ctx: *anyopaque, dirty_rect: ?interface.Rect) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (buffered) {
                const vram: [*]u32 = @ptrFromInt(self.mode.addr);
                const stride_u32 = self.mode.pitch / 4;
                const stride_u64: u64 = @as(u64, stride_u32);
                
                if (dirty_rect) |rect| {
                    // Optimized update for dirty region
                    const x = rect.x;
                    const y = rect.y;
                    var w = rect.width;
                    var h = rect.height;
                    
                    if (x >= self.mode.width or y >= self.mode.height) return;
                    if (x + w > self.mode.width) w = self.mode.width - x;
                    if (y + h > self.mode.height) h = self.mode.height - y;
                    
                    var row: u32 = 0;
                    while (row < h) : (row += 1) {
                        const offset = calcIndex(stride_u64, @as(u64, x), @as(u64, y + row)) orelse return;
                        @memcpy(vram[offset .. offset + w], self.back_buffer[offset .. offset + w]);
                    }
                } else {
                    // Full update
                    const len = std.math.mul(u64, stride_u64, self.mode.height) catch return;
                    @memcpy(vram[0..len], self.back_buffer[0..len]);
                }
            }
            // Direct mode: no-op, writes went directly to VRAM
        }
    };
}

/// Buffered framebuffer driver - renders to back buffer, present() copies to VRAM.
pub const BufferedFramebufferDriver = FramebufferDriver(true);

/// Direct framebuffer driver - renders directly to VRAM.
pub const DirectFramebufferDriver = FramebufferDriver(false);
