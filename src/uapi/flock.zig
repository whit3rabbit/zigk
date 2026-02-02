// flock(2) operation constants
//
// Advisory file locking operations for sys_flock syscall.
// These match the Linux flock(2) API.

/// Shared lock (multiple readers allowed)
pub const LOCK_SH: u32 = 1;

/// Exclusive lock (single writer, no readers)
pub const LOCK_EX: u32 = 2;

/// Unlock
pub const LOCK_UN: u32 = 8;

/// Non-blocking mode (return EWOULDBLOCK instead of blocking)
pub const LOCK_NB: u32 = 4;

/// Operation mask (extracts lock type from flags)
pub const LOCK_MASK: u32 = LOCK_SH | LOCK_EX | LOCK_UN;
