// Input Syscall Handlers
//
// Implements syscalls for mouse/input device access:
// - sys_read_input_event: Read next input event (non-blocking)
// - sys_get_cursor_position: Get current cursor position
// - sys_set_cursor_bounds: Set screen dimensions for cursor clamping
// - sys_set_input_mode: Set input mode (relative/absolute/raw)

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const input = @import("input");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

// =============================================================================
// Input Syscall Handlers
// =============================================================================

/// sys_read_input_event (1010) - Read next input event
/// Non-blocking: returns EAGAIN if no events available
pub fn sys_read_input_event(event_ptr: usize) SyscallError!usize {
    if (event_ptr == 0) {
        return error.EFAULT;
    }

    // Check if input subsystem is initialized
    if (!input.isInitialized()) {
        return error.ENODEV;
    }

    // Try to pop an event
    const event = input.popEvent() orelse {
        return error.EAGAIN;
    };

    // Copy event to userspace
    const uptr = UserPtr.from(event_ptr);
    const event_bytes = std.mem.asBytes(&event);
    _ = uptr.copyFromKernel(event_bytes) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_get_cursor_position (1011) - Get current cursor position
pub fn sys_get_cursor_position(position_ptr: usize) SyscallError!usize {
    if (position_ptr == 0) {
        return error.EFAULT;
    }

    // Check if input subsystem is initialized
    if (!input.isInitialized()) {
        return error.ENODEV;
    }

    // Get cursor position and button state
    const pos = input.getCursorPosition();
    const buttons = input.getButtonState();

    const result = uapi.input.CursorPosition{
        .x = pos.x,
        .y = pos.y,
        .buttons = buttons,
    };

    // Copy to userspace
    const uptr = UserPtr.from(position_ptr);
    const result_bytes = std.mem.asBytes(&result);
    _ = uptr.copyFromKernel(result_bytes) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_set_cursor_bounds (1012) - Set screen dimensions for cursor clamping
pub fn sys_set_cursor_bounds(bounds_ptr: usize) SyscallError!usize {
    if (bounds_ptr == 0) {
        return error.EFAULT;
    }

    // Check if input subsystem is initialized
    if (!input.isInitialized()) {
        return error.ENODEV;
    }

    // Copy bounds from userspace
    var bounds: uapi.input.CursorBounds = undefined;
    const uptr = UserPtr.from(bounds_ptr);
    const bounds_bytes = std.mem.asBytes(&bounds);
    _ = uptr.copyToKernel(bounds_bytes) catch {
        return error.EFAULT;
    };

    // Validate bounds
    if (bounds.width == 0 or bounds.height == 0) {
        return error.EINVAL;
    }

    // Reasonable limits
    if (bounds.width > 16384 or bounds.height > 16384) {
        return error.EINVAL;
    }

    // Set the bounds
    input.setCursorBounds(bounds.width, bounds.height);

    return 0;
}

/// sys_set_input_mode (1013) - Set input mode
/// Mode 0: relative (mouse deltas)
/// Mode 1: absolute (tablet coordinates)
/// Mode 2: raw (no cursor tracking)
pub fn sys_set_input_mode(mode: usize) SyscallError!usize {
    // Check if input subsystem is initialized
    if (!input.isInitialized()) {
        return error.ENODEV;
    }

    // Validate mode
    if (mode > 2) {
        return error.EINVAL;
    }

    // Mode is currently informational only - the input subsystem
    // always provides both relative events and cursor tracking.
    // Future: could disable cursor tracking in raw mode.

    return 0;
}
