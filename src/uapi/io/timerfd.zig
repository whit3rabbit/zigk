// Timerfd API Definitions (Linux x86_64 compatible)
//
// timerfd is a file descriptor-based timer notification mechanism.
// Used for timer events in epoll/select/poll contexts.

const abi = @import("../base/abi.zig");

/// timerfd_create flags
pub const TFD_CLOEXEC: u32 = 0x80000; // Set close-on-exec flag (same as O_CLOEXEC)
pub const TFD_NONBLOCK: u32 = 0x800; // Set non-blocking mode (same as O_NONBLOCK)

/// timerfd_settime flags
pub const TFD_TIMER_ABSTIME: u32 = 0x1; // Absolute time (instead of relative)
pub const TFD_TIMER_CANCEL_ON_SET: u32 = 0x2; // Cancel on CLOCK_REALTIME discontinuous change

/// Clock types (for timerfd_create)
pub const CLOCK_REALTIME: i32 = 0; // Wall clock time (affected by NTP/settimeofday)
pub const CLOCK_MONOTONIC: i32 = 1; // Monotonic time (not affected by jumps)
pub const CLOCK_BOOTTIME: i32 = 7; // Monotonic time including suspend time

/// Interval timer specification (timerfd_settime/timerfd_gettime)
/// Contains the interval (periodic reload value) and the initial expiration time.
pub const ITimerSpec = extern struct {
    /// Interval for periodic timer (reload value after each expiration)
    /// Set to 0 for one-shot timer
    it_interval: abi.Timespec,

    /// Time until next expiration
    /// Set to 0 to disarm the timer
    it_value: abi.Timespec,
};
