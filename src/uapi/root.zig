// ZigK User API Root Module
//
// Provides constants shared between kernel and userland:
//   - Syscall numbers (Linux x86_64 ABI + ZigK extensions)
//   - Error codes (errno values)
//
// This module is the single source of truth for ABI compatibility.

pub const syscalls = @import("syscalls.zig");
pub const errno = @import("errno.zig");

// Re-export commonly used types
pub const Errno = errno.Errno;

// Re-export syscall numbers at top level for convenience
// (Zig 0.15.x removed usingnamespace, so we explicitly re-export)
pub const SYS_READ = syscalls.SYS_READ;
pub const SYS_WRITE = syscalls.SYS_WRITE;
pub const SYS_OPEN = syscalls.SYS_OPEN;
pub const SYS_CLOSE = syscalls.SYS_CLOSE;
pub const SYS_MMAP = syscalls.SYS_MMAP;
pub const SYS_MPROTECT = syscalls.SYS_MPROTECT;
pub const SYS_MUNMAP = syscalls.SYS_MUNMAP;
pub const SYS_BRK = syscalls.SYS_BRK;
pub const SYS_SCHED_YIELD = syscalls.SYS_SCHED_YIELD;
pub const SYS_NANOSLEEP = syscalls.SYS_NANOSLEEP;
pub const SYS_GETPID = syscalls.SYS_GETPID;
pub const SYS_SOCKET = syscalls.SYS_SOCKET;
pub const SYS_SENDTO = syscalls.SYS_SENDTO;
pub const SYS_RECVFROM = syscalls.SYS_RECVFROM;
pub const SYS_FORK = syscalls.SYS_FORK;
pub const SYS_EXECVE = syscalls.SYS_EXECVE;
pub const SYS_EXIT = syscalls.SYS_EXIT;
pub const SYS_WAIT4 = syscalls.SYS_WAIT4;
pub const SYS_GETUID = syscalls.SYS_GETUID;
pub const SYS_GETGID = syscalls.SYS_GETGID;
pub const SYS_GETPPID = syscalls.SYS_GETPPID;
pub const SYS_ARCH_PRCTL = syscalls.SYS_ARCH_PRCTL;
pub const SYS_CLOCK_GETTIME = syscalls.SYS_CLOCK_GETTIME;
pub const SYS_EXIT_GROUP = syscalls.SYS_EXIT_GROUP;
pub const SYS_GETRANDOM = syscalls.SYS_GETRANDOM;
pub const SYS_DEBUG_LOG = syscalls.SYS_DEBUG_LOG;
pub const SYS_GET_FB_INFO = syscalls.SYS_GET_FB_INFO;
pub const SYS_MAP_FB = syscalls.SYS_MAP_FB;
pub const SYS_READ_SCANCODE = syscalls.SYS_READ_SCANCODE;
pub const SYS_GETCHAR = syscalls.SYS_GETCHAR;
pub const SYS_PUTCHAR = syscalls.SYS_PUTCHAR;
