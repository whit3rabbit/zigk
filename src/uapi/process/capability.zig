//! Linux Capability UAPI Types
//!
//! Defines the structures and constants for the Linux capability model.
//! Linux capabilities are a bitmask-based permission system where each bit
//! represents a specific privilege (CAP_CHOWN, CAP_NET_RAW, etc.).
//!
//! Three sets per process:
//! - Effective: Currently active capabilities (checked for permission)
//! - Permitted: Maximum capabilities that can be made effective
//! - Inheritable: Capabilities preserved across execve
//!
//! Versions:
//! - v1 (0x19980330): Single __user_cap_data_struct, 32-bit bitmasks
//! - v3 (0x20080522): Two __user_cap_data_struct entries, 64-bit bitmasks

// =============================================================================
// Header Version Constants
// =============================================================================

/// Capability version 1 (32-bit, single data struct)
pub const _LINUX_CAPABILITY_VERSION_1: u32 = 0x19980330;
/// Capability version 2 (64-bit, two data structs) -- deprecated, same layout as v3
pub const _LINUX_CAPABILITY_VERSION_2: u32 = 0x20071026;
/// Capability version 3 (64-bit, two data structs) -- current
pub const _LINUX_CAPABILITY_VERSION_3: u32 = 0x20080522;

/// Preferred version for new code
pub const _LINUX_CAPABILITY_VERSION: u32 = _LINUX_CAPABILITY_VERSION_3;

// =============================================================================
// Linux Capability Structures (ABI-compatible)
// =============================================================================

/// cap_user_header_t -- header for capget/capset
/// Linux: struct __user_cap_header_struct
pub const CapUserHeader = extern struct {
    /// Version magic (one of _LINUX_CAPABILITY_VERSION_*)
    version: u32,
    /// Target process PID (0 = current process)
    pid: i32,
};

/// cap_user_data_t -- data for capget/capset (one entry for v1, two for v3)
/// Linux: struct __user_cap_data_struct
pub const CapUserData = extern struct {
    /// Effective capability bitmask (this word)
    effective: u32,
    /// Permitted capability bitmask (this word)
    permitted: u32,
    /// Inheritable capability bitmask (this word)
    inheritable: u32,
};

// =============================================================================
// Linux Capability Constants
// =============================================================================
// Standard Linux capability numbers (CAP_LAST_CAP = 40 as of Linux 6.x)
// Values MUST match the Linux kernel exactly.

/// Override file ownership checks (chown)
pub const CAP_CHOWN: u6 = 0;
/// Override all DAC access restrictions
pub const CAP_DAC_OVERRIDE: u6 = 1;
/// Override DAC read restrictions
pub const CAP_DAC_READ_SEARCH: u6 = 2;
/// Override file ownership restrictions for signals, utime
pub const CAP_FOWNER: u6 = 3;
/// Override file set-user-ID and set-group-ID mode bits
pub const CAP_FSETID: u6 = 4;
/// Override restrictions on sending signals
pub const CAP_KILL: u6 = 5;
/// Set group ID for process
pub const CAP_SETGID: u6 = 6;
/// Set user ID for process
pub const CAP_SETUID: u6 = 7;
/// Transfer/remove capabilities
pub const CAP_SETPCAP: u6 = 8;
/// Make files immutable
pub const CAP_LINUX_IMMUTABLE: u6 = 9;
/// Bind to privileged ports (<1024)
pub const CAP_NET_BIND_SERVICE: u6 = 10;
/// Allow broadcast/multicast
pub const CAP_NET_BROADCAST: u6 = 11;
/// Various network admin operations
pub const CAP_NET_ADMIN: u6 = 12;
/// Create raw sockets (ping, etc.)
pub const CAP_NET_RAW: u6 = 13;
/// Lock memory (mlock, mlockall)
pub const CAP_IPC_LOCK: u6 = 14;
/// Override IPC ownership checks
pub const CAP_IPC_OWNER: u6 = 15;
/// Load and unload kernel modules
pub const CAP_SYS_MODULE: u6 = 16;
/// Perform raw I/O (iopl, ioperm)
pub const CAP_SYS_RAWIO: u6 = 17;
/// Allow chroot
pub const CAP_SYS_CHROOT: u6 = 18;
/// Trace arbitrary processes (ptrace)
pub const CAP_SYS_PTRACE: u6 = 19;
/// Configure process accounting
pub const CAP_SYS_PACCT: u6 = 20;
/// System administration (mount, sethostname, etc.)
pub const CAP_SYS_ADMIN: u6 = 21;
/// Reboot system
pub const CAP_SYS_BOOT: u6 = 22;
/// Set process nice value and scheduling priority
pub const CAP_SYS_NICE: u6 = 23;
/// Override resource limits
pub const CAP_SYS_RESOURCE: u6 = 24;
/// Set system clock (settimeofday, adjtimex)
pub const CAP_SYS_TIME: u6 = 25;
/// Configure tty devices
pub const CAP_SYS_TTY_CONFIG: u6 = 26;
/// Create special files using mknod
pub const CAP_MKNOD: u6 = 27;
/// Set file leases
pub const CAP_LEASE: u6 = 28;
/// Write audit log
pub const CAP_AUDIT_WRITE: u6 = 29;
/// Configure audit subsystem
pub const CAP_AUDIT_CONTROL: u6 = 30;
/// Set file capabilities on files
pub const CAP_SETFCAP: u6 = 31;
/// Override MAC (Mandatory Access Control)
pub const CAP_MAC_OVERRIDE: u6 = 32;
/// Configure MAC
pub const CAP_MAC_ADMIN: u6 = 33;
/// Configure kernel logging
pub const CAP_SYSLOG: u6 = 34;
/// Trigger wake-up events
pub const CAP_WAKE_ALARM: u6 = 35;
/// Administer block devices
pub const CAP_BLOCK_SUSPEND: u6 = 36;
/// Allow reading audit log
pub const CAP_AUDIT_READ: u6 = 37;
/// Allow perfmon access
pub const CAP_PERFMON: u6 = 38;
/// Allow BPF operations
pub const CAP_BPF: u6 = 39;
/// Allow checkpoint/restore
pub const CAP_CHECKPOINT_RESTORE: u6 = 40;

/// Highest capability number
pub const CAP_LAST_CAP: u6 = 40;

/// All capabilities bitmask (bits 0-40 set)
/// Use u7 for shift amount since 40+1=41 needs 7 bits
pub const CAP_FULL_SET: u64 = (@as(u64, 1) << (@as(u7, CAP_LAST_CAP) + 1)) - 1;

/// Empty capability set
pub const CAP_EMPTY_SET: u64 = 0;

/// Convert capability number to bitmask bit
pub fn capToBit(cap: u6) u64 {
    return @as(u64, 1) << @as(u6, cap);
}

/// Check if a capability is set in a bitmask
pub fn capIsSet(caps: u64, cap: u6) bool {
    return (caps & capToBit(cap)) != 0;
}
