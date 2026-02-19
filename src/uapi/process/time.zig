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

// =============================================================================
// POSIX Timer API (timer_create, timer_settime, etc.)
// =============================================================================

/// ITimerspec structure (timer_settime/timer_gettime)
/// Uses timespec for nanosecond precision
pub const ITimerspec = extern struct {
    /// Interval for periodic timer (reload value). Zero = one-shot.
    it_interval: Timespec,
    /// Time until next expiration. Zero = disarm timer.
    it_value: Timespec,
};

/// Timespec for POSIX timers (matches Linux struct timespec)
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// Signal event notification structure (simplified for MVP)
/// Linux sigevent is 64 bytes. We match that layout: sigev_value (usize=8),
/// sigev_signo (i32=4), sigev_notify (i32=4), then padding to fill 64 bytes.
/// NOTE: Our SigEvent is 64 bytes to match Linux struct sigevent size.
/// We only use sigev_value/sigev_signo/sigev_notify fields; the padding
/// covers the _sigev_un union (thread ID, function pointer, etc.) that
/// we do not support in MVP.
pub const SigEvent = extern struct {
    /// Signal value (si_value) - application data passed with signal
    sigev_value: usize,
    /// Signal number to deliver (e.g., SIGALRM=14)
    sigev_signo: i32,
    /// Notification method (SIGEV_SIGNAL, SIGEV_NONE, etc.)
    sigev_notify: i32,
    /// Padding to match Linux 64-byte sigevent layout
    /// 64 total - @sizeOf(usize) [8] - @sizeOf(i32) [4] - @sizeOf(i32) [4] = 48 bytes padding
    _pad: [64 - @sizeOf(usize) - 8]u8,

    comptime {
        if (@sizeOf(SigEvent) != 64) @compileError("SigEvent must be 64 bytes to match Linux sigevent");
    }

    /// Extract _sigev_un._tid from padding (used by SIGEV_THREAD_ID)
    /// In Linux sigevent, _sigev_un._tid is at the start of the padding area
    /// (first 4 bytes of _pad), immediately after sigev_value + sigev_signo + sigev_notify.
    pub fn getTid(self: *const SigEvent) i32 {
        return @as(*const i32, @ptrCast(@alignCast(&self._pad[0]))).*;
    }
};

/// POSIX timer notification types
pub const SIGEV_SIGNAL: i32 = 0; // Deliver signal on timer expiration
pub const SIGEV_NONE: i32 = 1; // No notification (just track overruns)
pub const SIGEV_THREAD: i32 = 2; // Kernel-level: deliver signal (glibc wraps in thread callback)
pub const SIGEV_THREAD_ID: i32 = 4; // Deliver signal to specific thread by TID

/// Clock IDs (matching Linux values)
pub const CLOCK_REALTIME: usize = 0;
pub const CLOCK_MONOTONIC: usize = 1;

/// Timer settime flags
pub const TIMER_ABSTIME: u32 = 1;

/// Maximum timers per process (matches Linux POSIX_TIMER_MAX default)
pub const MAX_POSIX_TIMERS: usize = 32;
