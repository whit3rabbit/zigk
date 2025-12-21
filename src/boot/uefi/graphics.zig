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

    // Build framebuffer info for kernel
    return .{
        .address = mode.frame_buffer_base,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pitch = info.pixels_per_scan_line * 4, // Assuming 32bpp
        .bpp = 32,
        // Assuming BGRA pixel format (most common for UEFI)
        .blue_mask_shift = 0,
        .blue_mask_size = 8,
        .green_mask_shift = 8,
        .green_mask_size = 8,
        .red_mask_shift = 16,
        .red_mask_size = 8,
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
