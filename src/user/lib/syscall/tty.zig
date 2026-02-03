//! Terminal (TTY) Control Syscall Wrappers
//!
//! Provides userspace wrappers for terminal ioctl commands used in job control.
//! These allow processes to control their controlling terminal, manage process
//! groups, and implement shell features like fg, bg, and jobs.

const syscall = @import("root.zig");
const uapi = @import("uapi");
const SyscallError = syscall.SyscallError;

// =============================================================================
// Controlling Terminal Operations
// =============================================================================

/// Make the given terminal the controlling terminal of the calling process
///
/// Requirements:
/// - Caller must be a session leader
/// - Session must not already have a controlling terminal
/// - arg: usually 0 (non-zero forces acquisition, Linux-specific)
///
/// Returns 0 on success, error on failure
pub fn tiocsctty(fd: i32, arg: i32) SyscallError!void {
    const arg_usize: usize = @bitCast(@as(isize, arg));
    _ = try syscall.ioctl(fd, uapi.tty.TIOCSCTTY, arg_usize);
}

/// Release the controlling terminal (give up control)
///
/// After this call, the session has no controlling terminal.
/// Typically called by shells when exiting or starting subshells.
///
/// Returns 0 on success, error on failure
pub fn tiocnotty(fd: i32) SyscallError!void {
    _ = try syscall.ioctl(fd, uapi.tty.TIOCNOTTY, 0);
}

// =============================================================================
// Process Group Operations
// =============================================================================

/// Get the foreground process group ID of the terminal
///
/// Returns the pgid of the foreground process group, or error
pub fn tiocgpgrp(fd: i32) SyscallError!i32 {
    var pgid: i32 = 0;
    _ = try syscall.ioctl(fd, uapi.tty.TIOCGPGRP, @intFromPtr(&pgid));
    return pgid;
}

/// Set the foreground process group ID of the terminal
///
/// Only the session leader or processes in the foreground group can do this.
/// Background processes attempting this will receive SIGTTOU.
///
/// Arguments:
/// - fd: file descriptor of the controlling terminal
/// - pgid: process group ID to make foreground
///
/// Returns 0 on success, error on failure
pub fn tiocspgrp(fd: i32, pgid: i32) SyscallError!void {
    var pgid_var = pgid;
    _ = try syscall.ioctl(fd, uapi.tty.TIOCSPGRP, @intFromPtr(&pgid_var));
}

// =============================================================================
// Terminal Attributes (termios)
// =============================================================================

/// Get terminal attributes (struct termios)
///
/// Note: zk currently has limited termios support. This returns
/// a basic termios structure but canonical mode settings may not
/// be fully implemented.
///
/// Arguments:
/// - fd: file descriptor of the terminal
/// - termios_ptr: pointer to termios structure to fill
///
/// Returns 0 on success, error on failure
pub fn tcgets(fd: i32, termios_ptr: *anyopaque) SyscallError!void {
    _ = try syscall.ioctl(fd, uapi.tty.TCGETS, @intFromPtr(termios_ptr));
}
