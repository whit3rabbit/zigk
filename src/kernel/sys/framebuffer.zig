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

// =============================================================================
// Framebuffer Ownership Tracking
// =============================================================================
//
// Ensures exclusive framebuffer access. Only one process can map the
// framebuffer at a time. This prevents race conditions and display corruption
// when multiple processes attempt to write to the framebuffer.
//
// The display server model: a single compositor/display server process owns
// the framebuffer, and GUI applications communicate via IPC.

/// PID of process that currently owns the framebuffer (0 = kernel/no owner)
var owner_pid: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Attempt to claim exclusive framebuffer ownership.
/// Returns true if ownership was granted, false if already owned by another process.
/// A process can call this multiple times (idempotent for same PID).
pub fn claimOwnership(pid: u32) bool {
    // Atomically try to claim ownership (0 -> pid)
    if (owner_pid.cmpxchgStrong(0, pid, .acquire, .monotonic) == null) {
        console.info("Framebuffer: Ownership claimed by pid={}", .{pid});
        return true;
    }
    // Check if already owned by this pid
    if (owner_pid.load(.acquire) == pid) {
        return true;
    }
    console.warn("Framebuffer: Ownership denied to pid={} (owned by pid={})", .{ pid, owner_pid.load(.acquire) });
    return false;
}

/// Release framebuffer ownership.
/// Only releases if the given PID is the current owner.
/// Called on process exit to prevent resource leaks.
pub fn releaseOwnership(pid: u32) void {
    // Atomically release if we're the owner (pid -> 0)
    if (owner_pid.cmpxchgStrong(pid, 0, .release, .monotonic) == null) {
        console.info("Framebuffer: Ownership released by pid={}", .{pid});
    }
}

/// Get current owner PID (0 = no owner)
pub fn getOwnerPid() u32 {
    return owner_pid.load(.acquire);
}

/// Check if framebuffer is currently owned by any process
pub fn isOwned() bool {
    return getOwnerPid() != 0;
}
