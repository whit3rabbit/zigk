// TTY ioctl commands for job control
//
// These are the standard Linux ioctl commands for terminal job control.
// See: linux/include/uapi/asm-generic/ioctls.h

/// Make the given terminal the controlling terminal of the calling process
/// Requirements:
/// - Caller must be a session leader
/// - Session must not already have a controlling terminal
/// - arg: ignored (traditionally 0 or 1 for "steal")
pub const TIOCSCTTY: u32 = 0x540E;

/// Give up the controlling terminal
/// If the process is the session leader, sends SIGHUP to the foreground
/// process group of the terminal.
/// arg: ignored
pub const TIOCNOTTY: u32 = 0x5422;

/// Get the process group ID of the foreground process group
/// arg: pointer to i32 to store the result
pub const TIOCGPGRP: u32 = 0x540F;

/// Set the foreground process group ID
/// Requirements:
/// - Caller must have this terminal as its controlling terminal
/// - Caller must be in the same session as the terminal
/// arg: pointer to i32 containing the new pgid
pub const TIOCSPGRP: u32 = 0x5410;

/// Check if this is a terminal device (always succeeds for ttys)
/// Used by isatty() in libc
/// arg: ignored
pub const TCGETS: u32 = 0x5401;
