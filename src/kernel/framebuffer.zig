// Framebuffer State Management
//
// Captures and stores framebuffer information from bootloader.
// Provides a global accessor for syscall handlers to query framebuffer state.
//
// The framebuffer physical address and dimensions are captured at boot time.
// This allows userspace programs to:
//   1. Query framebuffer info via sys_get_fb_info (1001)
//   2. Map framebuffer memory via sys_map_fb (1002)

const std = @import("std");
const limine = @import("limine");
const console = @import("console");
const hal = @import("hal");

/// Framebuffer state captured at boot
/// Contains all information needed for sys_get_fb_info and sys_map_fb
pub const FramebufferState = struct {
    /// Physical address of framebuffer memory
    phys_addr: u64,
    /// Width in pixels
    width: u32,
    /// Height in pixels
    height: u32,
    /// Bytes per scanline (may include padding)
    pitch: u32,
    /// Bits per pixel (typically 32 for modern displays)
    bpp: u8,
    /// Bit position of red channel in pixel
    red_shift: u8,
    /// Number of bits in red channel
    red_mask_size: u8,
    /// Bit position of green channel in pixel
    green_shift: u8,
    /// Number of bits in green channel
    green_mask_size: u8,
    /// Bit position of blue channel in pixel
    blue_shift: u8,
    /// Number of bits in blue channel
    blue_mask_size: u8,
    /// Total framebuffer size in bytes (pitch * height)
    size: usize,
    /// Whether a valid framebuffer is available
    available: bool,
};

/// Global framebuffer state
/// Initialized to unavailable; set by init() at boot
var state: FramebufferState = .{
    .phys_addr = 0,
    .width = 0,
    .height = 0,
    .pitch = 0,
    .bpp = 0,
    .red_shift = 0,
    .red_mask_size = 0,
    .green_shift = 0,
    .green_mask_size = 0,
    .blue_shift = 0,
    .blue_mask_size = 0,
    .size = 0,
    .available = false,
};

/// Initialize framebuffer state from Limine framebuffer request
/// Called once during kernel initialization (after PMM, before scheduler)
pub fn initFromLimine(fb_request: *const limine.FramebufferRequest) void {
    const fb_response = fb_request.response orelse {
        console.warn("Framebuffer: No response (serial-only mode)", .{});
        return;
    };

    if (fb_response.framebuffer_count == 0) {
        console.warn("Framebuffer: No framebuffers available (serial-only mode)", .{});
        return;
    }

    // Use the first framebuffer
    const fb = fb_response.framebuffers()[0];

    // Capture basic framebuffer info
    // Limine protocol maps framebuffer in HHDM, so address is virtual.
    // Convert to physical address for sys_map_fb.
    if (fb.address >= hal.paging.HHDM_OFFSET) {
        state.phys_addr = fb.address - hal.paging.HHDM_OFFSET;
    } else {
        state.phys_addr = fb.address;
    }
    state.width = @intCast(fb.width);
    state.height = @intCast(fb.height);
    state.pitch = @intCast(fb.pitch);
    state.bpp = @truncate(fb.bpp);

    // Calculate size with overflow check (pitch * height)
    const pitch_usize: usize = @intCast(fb.pitch);
    const height_usize: usize = @intCast(fb.height);
    state.size = std.math.mul(usize, pitch_usize, height_usize) catch {
        console.err("Framebuffer: Size overflow pitch={d} height={d}", .{ fb.pitch, fb.height });
        return; // Leave state.available = false
    };

    // Extract RGB color info from Limine framebuffer structure
    state.red_shift = fb.red_mask_shift;
    state.red_mask_size = fb.red_mask_size;
    state.green_shift = fb.green_mask_shift;
    state.green_mask_size = fb.green_mask_size;
    state.blue_shift = fb.blue_mask_shift;
    state.blue_mask_size = fb.blue_mask_size;

    state.available = true;

    console.info("Framebuffer: {d}x{d}x{d} @ {x} (pitch={d}, size={d})", .{
        state.width,
        state.height,
        state.bpp,
        state.phys_addr,
        state.pitch,
        state.size,
    });

    console.debug("Framebuffer: RGB shift/size: R({d}/{d}) G({d}/{d}) B({d}/{d})", .{
        state.red_shift,
        state.red_mask_size,
        state.green_shift,
        state.green_mask_size,
        state.blue_shift,
        state.blue_mask_size,
    });
}

/// Get framebuffer state
/// Returns null if no framebuffer is available (serial-only mode)
pub fn getState() ?*const FramebufferState {
    if (!state.available) {
        return null;
    }
    return &state;
}

/// Get framebuffer physical address
/// Convenience function for sys_map_fb
pub fn getPhysAddr() ?u64 {
    if (!state.available) {
        return null;
    }
    return state.phys_addr;
}

/// Get framebuffer size in bytes
/// Convenience function for sys_map_fb
pub fn getSize() usize {
    return state.size;
}

/// Check if framebuffer is available
pub fn isAvailable() bool {
    return state.available;
}
