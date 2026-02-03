//! Time and resource information structures
//!
//! POSIX-compatible structures for sysinfo, times, and interval timers

const abi = @import("../base/abi.zig");

/// System information structure (sys_sysinfo)
/// Linux-compatible 104-byte structure
pub const SysInfo = extern struct {
    /// Seconds since boot
    uptime: i64,
    /// 1, 5, and 15 minute load averages (fixed-point * 65536)
    loads: [3]usize,
    /// Total usable main memory size (bytes)
    totalram: usize,
    /// Available memory size (bytes)
    freeram: usize,
    /// Amount of shared memory (bytes)
    sharedram: usize,
    /// Memory used by buffers (bytes)
    bufferram: usize,
    /// Total swap space size (bytes)
    totalswap: usize,
    /// Swap space still available (bytes)
    freeswap: usize,
    /// Number of current processes
    procs: u16,
    /// Padding for alignment
    pad: u16,
    /// Total high memory size (bytes, 0 on 64-bit)
    totalhigh: usize,
    /// Available high memory size (bytes, 0 on 64-bit)
    freehigh: usize,
    /// Memory unit size in bytes (1 = bytes)
    mem_unit: u32,
    /// Reserved padding to match Linux structure size
    _reserved: [20]u8,
};

// Note: SysInfo size varies by architecture and compiler padding
// On 64-bit systems with this layout, size is typically 112-128 bytes
// Linux accepts different sizes as long as the structure layout matches

/// Process times structure (sys_times)
/// Contains CPU time consumed by process and its children
pub const Tms = extern struct {
    /// User CPU time (ticks)
    tms_utime: i64,
    /// System CPU time (ticks)
    tms_stime: i64,
    /// User CPU time of children (ticks)
    tms_cutime: i64,
    /// System CPU time of children (ticks)
    tms_cstime: i64,
};

/// Interval timer value structure (getitimer/setitimer)
pub const ITimerVal = extern struct {
    /// Interval for periodic timer (reload value)
    it_interval: abi.TimeVal,
    /// Time until next expiration
    it_value: abi.TimeVal,
};

/// Interval timer types
pub const ITIMER_REAL: u32 = 0; // Wall clock time (SIGALRM)
pub const ITIMER_VIRTUAL: u32 = 1; // User CPU time (SIGVTALRM)
pub const ITIMER_PROF: u32 = 2; // User + Kernel CPU time (SIGPROF)
