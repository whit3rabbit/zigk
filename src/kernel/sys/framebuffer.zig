//! Framebuffer State Management
//!
//! Captures and stores framebuffer information provided by the bootloader.
//! Provides a global accessor for syscall handlers to query framebuffer state.
//!
//! The framebuffer physical address and dimensions are captured at boot time.
//! This allows userspace programs to:
//!   1. Query framebuffer info via `sys_get_fb_info` (1001)
//!   2. Map framebuffer memory via `sys_map_fb` (1002)

const std = @import("std");
const console = @import("console");
const BootInfo = @import("boot_info");

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

/// Initialize framebuffer state from generic BootInfo
pub fn initFromInfo(info: *const BootInfo.FramebufferInfo, hhdm_offset: u64) void {
    // Capture basic framebuffer info
    // BootInfo addresses are physical? No, usually physical for Framebuffer in UEFI.
    // However, if we are mapping it, we need to know.
    // The BootInfo struct says "address".
    
    // In UEFI, the framebuffer address from GOP is physical.
    // In Limine, it maps it to HHDM.
    // Let's assume the BootInfo carries the address provided by the loader.
    // If it's Limine shim, we'll pass the HHDM address.
    // If it's UEFI, we likely want to map it ourselves or it's identity mapped?
    // Actually, our kernel runs in higher half. We need to access it.
    // If it's not mapped in HHDM yet, we might have trouble if we don't map it.
    // But PMM controls mappings.
    
    // STARTING ASSUMPTION: The address in BootInfo is ACCESSIBLE (e.g. HHDM mapped).
    
    // Allow converting virtual HHDM address back to physical if needed for storage
    if (info.address >= hhdm_offset) {
        state.phys_addr = info.address - hhdm_offset;
    } else {
        state.phys_addr = info.address;
    }

    state.width = @intCast(info.width);
    state.height = @intCast(info.height);
    state.pitch = @intCast(info.pitch);
    state.bpp = @truncate(info.bpp);

    // Calculate size with overflow check (pitch * height)
    const pitch_usize: usize = @intCast(info.pitch);
    const height_usize: usize = @intCast(info.height);
    state.size = std.math.mul(usize, pitch_usize, height_usize) catch {
        console.err("Framebuffer: Size overflow pitch={d} height={d}", .{ info.pitch, info.height });
        return; // Leave state.available = false
    };

    // Extract RGB color info
    state.red_shift = info.red_mask_shift;
    state.red_mask_size = info.red_mask_size;
    state.green_shift = info.green_mask_shift;
    state.green_mask_size = info.green_mask_size;
    state.blue_shift = info.blue_mask_shift;
    state.blue_mask_size = info.blue_mask_size;

    state.available = true;

    console.info("Framebuffer: {d}x{d}x{d} @ {x} (pitch={d}, size={d})", .{
        state.width,
        state.height,
        state.bpp,
        state.phys_addr,
        state.pitch,
        state.size,
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
