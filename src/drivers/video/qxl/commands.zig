//! QXL Command Builders
//!
//! Provides helper functions to construct QXL 2D acceleration commands.
//! Commands are built using drawables from the DrawablePool and submitted
//! via the RamManager command ring.

const std = @import("std");
const hw = @import("hardware.zig");
const drawable_mod = @import("drawable.zig");
const ram = @import("ram.zig");

pub const QxlDrawable = drawable_mod.QxlDrawable;
pub const DrawablePool = drawable_mod.DrawablePool;
pub const RamManager = ram.RamManager;

/// Build a fill rectangle command
///
/// Allocates a drawable from the pool and configures it for a solid color fill.
/// The caller is responsible for:
/// 1. Submitting the command via RamManager.pushCommand()
/// 2. Waiting for completion via RamManager.popRelease()
/// 3. Freeing the drawable via DrawablePool.free()
///
/// Parameters:
/// - pool: Drawable pool to allocate from
/// - x, y: Top-left corner of rectangle
/// - width, height: Dimensions of rectangle
/// - color: 32-bit ARGB color value
/// - release_id: Unique ID for tracking command completion
///
/// Returns: Pointer to configured drawable, or null if allocation fails
pub fn buildFill(
    pool: *DrawablePool,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    color: u32,
    release_id: u64,
) ?*QxlDrawable {
    // Allocate drawable from pool
    const drawable = pool.alloc() orelse return null;

    // Calculate bounding box with overflow protection
    const right = std.math.add(i32, x, @as(i32, @intCast(@min(width, @as(u32, std.math.maxInt(i32)))))) catch {
        pool.free(drawable);
        return null;
    };
    const bottom = std.math.add(i32, y, @as(i32, @intCast(@min(height, @as(u32, std.math.maxInt(i32)))))) catch {
        pool.free(drawable);
        return null;
    };

    // Configure release info
    drawable.release_info = .{
        .id = release_id,
        .next = 0,
    };

    // Primary surface
    drawable.surface_id = 0;
    drawable.effect = 0;
    drawable.type = @intFromEnum(hw.DrawType.fill);
    drawable._pad = .{0} ** 2;

    // Bounding box
    drawable.bbox = .{
        .left = x,
        .top = y,
        .right = right,
        .bottom = bottom,
    };

    // No clipping
    drawable.clip = .{
        .type = hw.CLIP_TYPE_NONE,
        ._pad = .{0} ** 7,
        .data = 0,
    };

    // Fill command data
    drawable.u.fill = .{
        .brush = .{
            .type = hw.BRUSH_TYPE_SOLID,
            ._pad = .{0} ** 3,
            .color = color,
        },
        .rop_descriptor = hw.ROP_COPY,
        ._pad = .{0} ** 6,
        .mask = .{
            .flags = 0,
            ._pad = .{0} ** 3,
            .pos = .{ .x = 0, .y = 0 },
            .bitmap = 0,
        },
    };

    return drawable;
}

/// Build a copy bits (blit) command
///
/// Copies a rectangular region from one location to another on the same surface.
/// Useful for scrolling and window movement acceleration.
///
/// Parameters:
/// - pool: Drawable pool to allocate from
/// - src_x, src_y: Source rectangle top-left corner
/// - dst_x, dst_y: Destination rectangle top-left corner
/// - width, height: Dimensions of region to copy
/// - release_id: Unique ID for tracking command completion
///
/// Returns: Pointer to configured drawable, or null if allocation fails
pub fn buildCopyBits(
    pool: *DrawablePool,
    src_x: i32,
    src_y: i32,
    dst_x: i32,
    dst_y: i32,
    width: u32,
    height: u32,
    release_id: u64,
) ?*QxlDrawable {
    // Allocate drawable from pool
    const drawable = pool.alloc() orelse return null;

    // Calculate destination bounding box
    const right = std.math.add(i32, dst_x, @as(i32, @intCast(@min(width, @as(u32, std.math.maxInt(i32)))))) catch {
        pool.free(drawable);
        return null;
    };
    const bottom = std.math.add(i32, dst_y, @as(i32, @intCast(@min(height, @as(u32, std.math.maxInt(i32)))))) catch {
        pool.free(drawable);
        return null;
    };

    // Configure release info
    drawable.release_info = .{
        .id = release_id,
        .next = 0,
    };

    // Primary surface
    drawable.surface_id = 0;
    drawable.effect = 0;
    drawable.type = @intFromEnum(hw.DrawType.copy_bits);
    drawable._pad = .{0} ** 2;

    // Destination bounding box
    drawable.bbox = .{
        .left = dst_x,
        .top = dst_y,
        .right = right,
        .bottom = bottom,
    };

    // No clipping
    drawable.clip = .{
        .type = hw.CLIP_TYPE_NONE,
        ._pad = .{0} ** 7,
        .data = 0,
    };

    // Copy bits command data - source position
    drawable.u.copy_bits = .{
        .src_pos = .{
            .x = src_x,
            .y = src_y,
        },
    };

    return drawable;
}

/// Submit a drawable command to the device
///
/// Convenience function that gets the physical address and pushes to command ring.
///
/// Parameters:
/// - ram_mgr: RAM manager for command submission
/// - pool: Drawable pool (for address translation)
/// - drawable: Configured drawable to submit
/// - cmd_type: Command type (typically .draw)
///
/// Returns: true if command was submitted, false if ring is full
pub fn submitDrawable(
    ram_mgr: *RamManager,
    pool: *const DrawablePool,
    drawable: *const QxlDrawable,
    cmd_type: hw.CmdType,
) bool {
    const phys_addr = pool.toPhysical(drawable) orelse return false;
    return ram_mgr.pushCommand(phys_addr, cmd_type);
}

/// Convert RGBA color components to 32-bit ARGB format
///
/// QXL uses ARGB format: 0xAARRGGBB
pub fn rgbaToArgb(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// Convert RGB color components to 32-bit xRGB format (alpha = 0xFF)
pub fn rgbToXrgb(r: u8, g: u8, b: u8) u32 {
    return (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}
