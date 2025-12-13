// Signal API
//
// Defines signal sets and operations compatible with Linux x86_64.

pub const SIG_BLOCK: usize = 0;
pub const SIG_UNBLOCK: usize = 1;
pub const SIG_SETMASK: usize = 2;

pub const SIGKILL: usize = 9;
pub const SIGSTOP: usize = 19;

/// Signal set (64 bits)
/// Compatible with Linux sigset_t for x86_64 which is 1024 bits (128 bytes),
/// but sys_rt_sigprocmask usually deals with 8 bytes (64 bits) unless sigsetsize is larger.
/// However, zig's integer types are handy.
///
/// Linux kernel treats sigset_t as an array of longs.
///
/// For MVP, we will assume 64 signals.
pub const SigSet = u64;

/// Helper to check if a signal is in the set
pub fn sigismember(set: SigSet, sig: usize) bool {
    if (sig == 0 or sig > 64) return false;
    return (set & (@as(u64, 1) << @truncate(sig - 1))) != 0;
}

/// Helper to add a signal to the set
pub fn sigaddset(set: *SigSet, sig: usize) void {
    if (sig == 0 or sig > 64) return;
    set.* |= (@as(u64, 1) << @truncate(sig - 1));
}

/// Helper to remove a signal from the set
pub fn sigdelset(set: *SigSet, sig: usize) void {
    if (sig == 0 or sig > 64) return;
    set.* &= ~(@as(u64, 1) << @truncate(sig - 1));
}
