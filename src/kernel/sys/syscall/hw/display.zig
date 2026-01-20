//! Display Mode Syscalls
//!
//! Provides userspace interface for display resolution management.
//! Used by SPICE agent and display servers to synchronize resolution
//! with hypervisor/host.
//!
//! Security:
//! - Requires DisplayServer capability
//! - Dimensions validated against reasonable maximums (8192x8192)
//! - Uses checked arithmetic to prevent overflow

const std = @import("std");
const uapi = @import("uapi");
const sched = @import("sched");
const process_mod = @import("process");
const console = @import("console");
const video_driver = @import("video_driver");
const virtio_gpu = video_driver.virtio_gpu;

const SyscallError = uapi.errno.SyscallError;

/// Maximum display dimensions (8K resolution)
const MAX_DISPLAY_WIDTH: u32 = 8192;
const MAX_DISPLAY_HEIGHT: u32 = 8192;

/// Minimum display dimensions
const MIN_DISPLAY_WIDTH: u32 = 640;
const MIN_DISPLAY_HEIGHT: u32 = 480;

/// sys_set_display_mode (1070) - Set display resolution
///
/// Changes the display resolution for the primary display.
/// This is used by SPICE agent for display synchronization with host.
///
/// Arguments:
///   width: Display width in pixels
///   height: Display height in pixels
///   flags: Reserved for future use (must be 0)
///
/// Returns: 0 on success, -errno on failure
///
/// Errors:
///   EPERM - Process lacks DisplayServer capability
///   EINVAL - Invalid dimensions or non-zero flags
///   ENODEV - No display device available
///   ENOMEM - Failed to allocate framebuffer memory
///   EIO - Hardware operation failed
///
/// Security:
/// - Requires DisplayServer capability
/// - Validates dimensions against max bounds
/// - Uses checked arithmetic for size calculations
pub fn sys_set_display_mode(width: usize, height: usize, flags: usize) SyscallError!usize {
    // Get current process for capability check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process_mod.Process = @ptrCast(@alignCast(proc_opaque));

    // Check for DisplayServer capability
    if (!proc.hasDisplayServerCapability()) {
        console.warn("sys_set_display_mode: Process {} lacks DisplayServer capability", .{proc.pid});
        return error.EPERM;
    }

    // Validate flags (reserved, must be 0)
    if (flags != 0) {
        return error.EINVAL;
    }

    // Validate dimensions fit in u32
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) {
        return error.EINVAL;
    }

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    // Validate dimensions against bounds
    if (w < MIN_DISPLAY_WIDTH or w > MAX_DISPLAY_WIDTH) {
        console.warn("sys_set_display_mode: Invalid width {} (must be {}-{})", .{ w, MIN_DISPLAY_WIDTH, MAX_DISPLAY_WIDTH });
        return error.EINVAL;
    }

    if (h < MIN_DISPLAY_HEIGHT or h > MAX_DISPLAY_HEIGHT) {
        console.warn("sys_set_display_mode: Invalid height {} (must be {}-{})", .{ h, MIN_DISPLAY_HEIGHT, MAX_DISPLAY_HEIGHT });
        return error.EINVAL;
    }

    // Get VirtIO-GPU driver
    const drv = virtio_gpu.getDriver() orelse {
        console.warn("sys_set_display_mode: No VirtIO-GPU driver available", .{});
        return error.ENODEV;
    };

    // Get current dimensions to check if change is needed
    const current_mode = drv.device().vtable.getMode(drv);
    if (current_mode.width == w and current_mode.height == h) {
        // No change needed
        return 0;
    }

    console.info("sys_set_display_mode: Changing resolution from {}x{} to {}x{}", .{
        current_mode.width,
        current_mode.height,
        w,
        h,
    });

    // Call driver to change display mode
    drv.setDisplayMode(w, h) catch |err| {
        console.err("sys_set_display_mode: Failed to set mode: {}", .{err});
        return switch (err) {
            error.OutOfMemory => error.ENOMEM,
            error.InvalidDimensions => error.EINVAL,
            error.DeviceFailed => error.EIO,
        };
    };

    return 0;
}
