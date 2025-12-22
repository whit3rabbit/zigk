// UEFI Graphics Output Protocol (GOP) Handling
// Initializes framebuffer for kernel use

const std = @import("std");
const uefi = std.os.uefi;
const BootInfo = @import("boot_info");

pub const GraphicsError = error{
    LocateProtocolFailed,
    QueryModeFailed,
    SetModeFailed,
    NoSuitableMode,
};

/// Initialize GOP and get framebuffer info
pub fn initGraphics(bs: *uefi.tables.BootServices) GraphicsError!BootInfo.FramebufferInfo {
    // Locate GOP protocol
    const gop = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch {
        return GraphicsError.LocateProtocolFailed;
    } orelse return GraphicsError.LocateProtocolFailed;

    // Query current mode info
    const info = gop.queryMode(gop.mode.mode) catch {
        return GraphicsError.QueryModeFailed;
    };

    const mode = gop.mode;

    // Determine pixel format and masks from GOP info
    const pixel_info = switch (info.pixel_format) {
        .blue_green_red_reserved_8_bit_per_color => PixelInfo{
            .bpp = 32,
            .bytes_per_pixel = 4,
            .red_shift = 16,
            .red_size = 8,
            .green_shift = 8,
            .green_size = 8,
            .blue_shift = 0,
            .blue_size = 8,
        },
        .red_green_blue_reserved_8_bit_per_color => PixelInfo{
            .bpp = 32,
            .bytes_per_pixel = 4,
            .red_shift = 0,
            .red_size = 8,
            .green_shift = 8,
            .green_size = 8,
            .blue_shift = 16,
            .blue_size = 8,
        },
        .bit_mask => extractPixelInfoFromBitmask(info.pixel_information),
        .blt_only => return GraphicsError.NoSuitableMode, // No direct framebuffer access
    };

    // Build framebuffer info for kernel
    return .{
        .address = mode.frame_buffer_base,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = info.pixels_per_scan_line * pixel_info.bytes_per_pixel,
        .bpp = pixel_info.bpp,
        .blue_mask_shift = pixel_info.blue_shift,
        .blue_mask_size = pixel_info.blue_size,
        .green_mask_shift = pixel_info.green_shift,
        .green_mask_size = pixel_info.green_size,
        .red_mask_shift = pixel_info.red_shift,
        .red_mask_size = pixel_info.red_size,
    };
}

/// Pixel format information extracted from GOP
const PixelInfo = struct {
    bpp: u8,
    bytes_per_pixel: u8,
    red_shift: u8,
    red_size: u8,
    green_shift: u8,
    green_size: u8,
    blue_shift: u8,
    blue_size: u8,
};

/// Extract pixel info from bitmask (for PixelFormat.bit_mask mode)
fn extractPixelInfoFromBitmask(bitmask: uefi.protocol.GraphicsOutput.PixelBitmask) PixelInfo {
    return .{
        .bpp = 32, // Bitmask mode is typically 32bpp
        .bytes_per_pixel = 4,
        .red_shift = @intCast(@ctz(bitmask.red_mask)),
        .red_size = @intCast(@popCount(bitmask.red_mask)),
        .green_shift = @intCast(@ctz(bitmask.green_mask)),
        .green_size = @intCast(@popCount(bitmask.green_mask)),
        .blue_shift = @intCast(@ctz(bitmask.blue_mask)),
        .blue_size = @intCast(@popCount(bitmask.blue_mask)),
    };
}

/// Try to set a specific video mode
pub fn setMode(bs: *uefi.tables.BootServices, width: u32, height: u32) GraphicsError!BootInfo.FramebufferInfo {
    const gop = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch {
        return GraphicsError.LocateProtocolFailed;
    } orelse return GraphicsError.LocateProtocolFailed;

    // Search for matching mode
    var best_mode: ?u32 = null;
    var mode_idx: u32 = 0;

    while (mode_idx < gop.mode.max_mode) : (mode_idx += 1) {
        if (gop.queryMode(mode_idx)) |info| {
            if (info.horizontal_resolution == width and info.vertical_resolution == height) {
                best_mode = mode_idx;
                break;
            }
        } else |_| {}
    }

    if (best_mode) |mode| {
        gop.setMode(mode) catch {
            return GraphicsError.SetModeFailed;
        };
    } else {
        return GraphicsError.NoSuitableMode;
    }

    return initGraphics(bs);
}
