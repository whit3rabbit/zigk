// Zscapek User API Root Module
//
// Provides constants shared between kernel and userland:
//   - Syscall numbers (Linux x86_64 ABI + Zscapek extensions)
//   - Error codes (errno values)
//
// This module is the single source of truth for ABI compatibility.

pub const syscalls = @import("syscalls/root.zig");
pub const errno = @import("base/errno.zig");
pub const poll = @import("io/poll.zig");
pub const abi = @import("base/abi.zig");
pub const signal = @import("process/signal.zig");
pub const stat = @import("fs/stat.zig");
pub const dirent = @import("fs/dirent.zig");
pub const sound = @import("dev/sound.zig");
pub const input = @import("dev/input.zig");
pub const mman = @import("base/mman.zig");
pub const sched = @import("process/sched.zig");
pub const futex = @import("ipc/futex.zig");
pub const epoll = @import("io/epoll.zig");
pub const io_ring = @import("io/io_ring.zig");
pub const net_ipc = @import("ipc/net_ipc.zig");
pub const ipc_msg = @import("ipc/ipc_msg.zig");
pub const ring = @import("ipc/ring.zig");
pub const virt_pci = @import("virt_pci/root.zig");


// Re-export commonly used types
pub const Errno = errno.Errno;

// Re-export syscall numbers at top level for convenience
// (Zig 0.15+ removed usingnamespace, so we explicitly re-export)
pub const SYS_READ = syscalls.SYS_READ;
pub const SYS_WRITE = syscalls.SYS_WRITE;
pub const SYS_OPEN = syscalls.SYS_OPEN;
pub const SYS_OPENAT = syscalls.SYS_OPENAT;
pub const SYS_CLOSE = syscalls.SYS_CLOSE;
pub const SYS_IOCTL = syscalls.SYS_IOCTL;
pub const SYS_POLL = syscalls.SYS_POLL;
pub const SYS_SELECT = syscalls.SYS_SELECT;
pub const SYS_MMAP = syscalls.SYS_MMAP;
pub const SYS_MPROTECT = syscalls.SYS_MPROTECT;
pub const SYS_MUNMAP = syscalls.SYS_MUNMAP;
pub const SYS_BRK = syscalls.SYS_BRK;
pub const SYS_SCHED_YIELD = syscalls.SYS_SCHED_YIELD;
pub const SYS_NANOSLEEP = syscalls.SYS_NANOSLEEP;
pub const SYS_DUP2 = syscalls.SYS_DUP2;
pub const SYS_GETPID = syscalls.SYS_GETPID;
pub const SYS_UNAME = syscalls.SYS_UNAME;
pub const SYS_FCNTL = syscalls.SYS_FCNTL;
pub const SYS_SOCKET = syscalls.SYS_SOCKET;
pub const SYS_CONNECT = syscalls.SYS_CONNECT;
pub const SYS_ACCEPT = syscalls.SYS_ACCEPT;
pub const SYS_BIND = syscalls.SYS_BIND;
pub const SYS_LISTEN = syscalls.SYS_LISTEN;
pub const SYS_SENDTO = syscalls.SYS_SENDTO;
pub const SYS_RECVFROM = syscalls.SYS_RECVFROM;
pub const SYS_SENDMSG = syscalls.SYS_SENDMSG;
pub const SYS_RECVMSG = syscalls.SYS_RECVMSG;
pub const SYS_SHUTDOWN = syscalls.SYS_SHUTDOWN;
pub const SYS_GETSOCKNAME = syscalls.SYS_GETSOCKNAME;
pub const SYS_GETPEERNAME = syscalls.SYS_GETPEERNAME;
pub const SYS_SETSOCKOPT = syscalls.SYS_SETSOCKOPT;
pub const SYS_GETSOCKOPT = syscalls.SYS_GETSOCKOPT;
pub const SYS_FORK = syscalls.SYS_FORK;
pub const SYS_EXECVE = syscalls.SYS_EXECVE;
pub const SYS_EXIT = syscalls.SYS_EXIT;
pub const SYS_WAIT4 = syscalls.SYS_WAIT4;
pub const SYS_SETHOSTNAME = syscalls.SYS_SETHOSTNAME;
pub const SYS_SETDOMAINNAME = syscalls.SYS_SETDOMAINNAME;
pub const SYS_GETUID = syscalls.SYS_GETUID;
pub const SYS_GETGID = syscalls.SYS_GETGID;
pub const SYS_GETPPID = syscalls.SYS_GETPPID;
pub const SYS_ARCH_PRCTL = syscalls.SYS_ARCH_PRCTL;
pub const SYS_CLOCK_GETTIME = syscalls.SYS_CLOCK_GETTIME;
pub const SYS_EXIT_GROUP = syscalls.SYS_EXIT_GROUP;
pub const SYS_DUP = syscalls.SYS_DUP;
pub const SYS_STAT = syscalls.SYS_STAT;
pub const SYS_FSTAT = syscalls.SYS_FSTAT;
pub const SYS_LSTAT = syscalls.SYS_LSTAT;
pub const SYS_PIPE = syscalls.SYS_PIPE;
pub const SYS_GETDENTS64 = syscalls.SYS_GETDENTS64;
pub const SYS_MKDIR = syscalls.SYS_MKDIR;
pub const SYS_CHDIR = syscalls.SYS_CHDIR;
pub const SYS_GETCWD = syscalls.SYS_GETCWD;
pub const SYS_EPOLL_WAIT = syscalls.SYS_EPOLL_WAIT;
pub const SYS_EPOLL_CTL = syscalls.SYS_EPOLL_CTL;
pub const SYS_EPOLL_CREATE1 = syscalls.SYS_EPOLL_CREATE1;
pub const SYS_GETRANDOM = syscalls.SYS_GETRANDOM;
pub const SYS_DEBUG_LOG = syscalls.SYS_DEBUG_LOG;
pub const SYS_GET_FB_INFO = syscalls.SYS_GET_FB_INFO;
pub const SYS_MAP_FB = syscalls.SYS_MAP_FB;
pub const SYS_READ_SCANCODE = syscalls.SYS_READ_SCANCODE;
pub const SYS_GETCHAR = syscalls.SYS_GETCHAR;
pub const SYS_PUTCHAR = syscalls.SYS_PUTCHAR;
pub const SYS_READ_INPUT_EVENT = syscalls.SYS_READ_INPUT_EVENT;
pub const SYS_GET_CURSOR_POSITION = syscalls.SYS_GET_CURSOR_POSITION;
pub const SYS_SET_CURSOR_BOUNDS = syscalls.SYS_SET_CURSOR_BOUNDS;
pub const SYS_SET_INPUT_MODE = syscalls.SYS_SET_INPUT_MODE;

// Shutdown flags
pub const SHUT_RD: i32 = 0;
pub const SHUT_WR: i32 = 1;
pub const SHUT_RDWR: i32 = 2;
