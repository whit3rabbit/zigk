// Signalfd API Definitions (Linux x86_64 compatible)
//
// signalfd is a file descriptor-based signal delivery mechanism.
// Used to receive signals via read() instead of signal handlers.

/// signalfd4 flags
pub const SFD_CLOEXEC: u32 = 0x80000; // Set close-on-exec flag (same as O_CLOEXEC)
pub const SFD_NONBLOCK: u32 = 0x800; // Set non-blocking mode (same as O_NONBLOCK)

/// Signal information structure returned by read() on signalfd
/// Must be exactly 128 bytes to match Linux ABI
pub const SignalFdSigInfo = extern struct {
    ssi_signo: u32, // Signal number
    ssi_errno: i32, // Error number (usually 0)
    ssi_code: i32, // Signal code (SI_USER, SI_KERNEL, etc.)
    ssi_pid: u32, // PID of sender
    ssi_uid: u32, // Real UID of sender
    ssi_fd: i32, // File descriptor (for SIGIO)
    ssi_tid: u32, // Kernel timer ID (for timer signals)
    ssi_band: u32, // Band event (for SIGIO)
    ssi_overrun: u32, // Timer overrun count (for timer signals)
    ssi_trapno: u32, // Trap number that caused signal (SIGILL, SIGFPE, SIGSEGV, SIGBUS)
    ssi_status: i32, // Exit status or signal (for SIGCHLD)
    ssi_int: i32, // Integer sent with sigqueue()
    ssi_ptr: u64, // Pointer sent with sigqueue()
    ssi_utime: u64, // User CPU time consumed (for SIGCHLD)
    ssi_stime: u64, // System CPU time consumed (for SIGCHLD)
    ssi_addr: u64, // Address that caused fault (for SIGILL, SIGFPE, SIGSEGV, SIGBUS)
    ssi_addr_lsb: u16, // Least significant bit of address (for SIGBUS)
    _pad: [46]u8, // Padding to 128 bytes

    comptime {
        const std = @import("std");
        // Verify struct layout matches Linux ABI (128 bytes exactly)
        std.debug.assert(@sizeOf(SignalFdSigInfo) == 128);
    }
};
