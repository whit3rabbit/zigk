// Framebuffer State Management
//
// Captures and stores framebuffer information from Multiboot2 boot info.
// Provides a global accessor for syscall handlers to query framebuffer state.
//
// The framebuffer physical address and dimensions are captured at boot time
// from the Multiboot2 framebuffer tag. This allows userspace programs to:
//   1. Query framebuffer info via sys_get_fb_info (1001)
//   2. Map framebuffer memory via sys_map_fb (1002)

const multiboot2 = @import("multiboot2");
const console = @import("console");

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

/// Initialize framebuffer state from Multiboot2 boot info
/// Called once during kernel initialization (after PMM, before scheduler)
pub fn init(boot_info: *const multiboot2.BootInfo) void {
    const fb_tag = multiboot2.findFramebufferTag(boot_info) orelse {
        console.warn("Framebuffer: No framebuffer tag found (serial-only mode)", .{});
        return;
    };

    // Capture basic framebuffer info
    state.phys_addr = fb_tag.framebuffer_addr;
    state.width = fb_tag.framebuffer_width;
    state.height = fb_tag.framebuffer_height;
    state.pitch = fb_tag.framebuffer_pitch;
    state.bpp = fb_tag.framebuffer_bpp;
    state.size = @as(usize, fb_tag.framebuffer_pitch) * @as(usize, fb_tag.framebuffer_height);

    // Extract RGB color info if available
    if (multiboot2.getRgbColorInfo(fb_tag)) |color_info| {
        state.red_shift = color_info.red_field_position;
        state.red_mask_size = color_info.red_mask_size;
        state.green_shift = color_info.green_field_position;
        state.green_mask_size = color_info.green_mask_size;
        state.blue_shift = color_info.blue_field_position;
        state.blue_mask_size = color_info.blue_mask_size;
    } else {
        // Default to common 32-bit BGRA format if no color info
        // This is typical for QEMU/GRUB framebuffers
        if (fb_tag.framebuffer_bpp == 32) {
            state.blue_shift = 0;
            state.blue_mask_size = 8;
            state.green_shift = 8;
            state.green_mask_size = 8;
            state.red_shift = 16;
            state.red_mask_size = 8;
        }
    }

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
