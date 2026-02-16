// Process Control Operations (prctl)
//
// Constants for sys_prctl operation codes.
// These match Linux prctl() option numbers for ABI compatibility.

/// Set process/thread name (first 16 bytes of arg2, null-terminated)
pub const PR_SET_NAME: usize = 15;

/// Get process/thread name (copy to buffer at arg2, 16 bytes)
pub const PR_GET_NAME: usize = 16;

/// Set no_new_privs flag (required before installing seccomp filters)
pub const PR_SET_NO_NEW_PRIVS: usize = 38;

/// Get no_new_privs flag
pub const PR_GET_NO_NEW_PRIVS: usize = 39;
