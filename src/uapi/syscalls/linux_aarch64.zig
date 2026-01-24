// Linux aarch64 (ARM64) ABI Syscalls
//
// These numbers match the standard Linux aarch64 syscall table.
// Source: https://arm64.syscall.sh/ and Linux kernel include/uapi/asm-generic/unistd.h
//
// Key differences from x86_64:
// - No legacy syscalls: open, pipe, fork, stat, lstat, access, dup2, select, epoll_wait, poll
// - Uses *at() variants exclusively: openat, pipe2, clone, newfstatat, faccessat, dup3, pselect6, epoll_pwait, ppoll
// - Completely different numbering scheme

// ============================================================================
// I/O Core
// ============================================================================

/// Read from a file descriptor
pub const SYS_READ: usize = 63;
/// Write to a file descriptor
pub const SYS_WRITE: usize = 64;
/// Perform device-specific control operations
pub const SYS_IOCTL: usize = 29;
/// Manipulate file descriptor flags (e.g., O_NONBLOCK)
pub const SYS_FCNTL: usize = 25;
/// Read from file at offset
pub const SYS_PREAD64: usize = 67;
/// Write to file at offset
pub const SYS_PWRITE64: usize = 68;
/// Read data into multiple buffers
pub const SYS_READV: usize = 65;
/// Write data from multiple buffers
pub const SYS_WRITEV: usize = 66;

// ============================================================================
// File Descriptors
// ============================================================================

/// Open file relative to a directory FD
pub const SYS_OPENAT: usize = 56;
/// Close a file descriptor
pub const SYS_CLOSE: usize = 57;
/// Reposition read/write file offset
pub const SYS_LSEEK: usize = 62;
/// Duplicate a file descriptor
pub const SYS_DUP: usize = 23;
/// Duplicate FD with flags
pub const SYS_DUP3: usize = 24;
/// Create pipe with flags
pub const SYS_PIPE2: usize = 59;
/// Create a file (legacy, use openat with O_CREAT)
pub const SYS_CREAT: usize = 500; // zk compat: not in Linux aarch64

// ============================================================================
// File Status
// ============================================================================

/// Get file status relative to directory FD
pub const SYS_NEWFSTATAT: usize = 79;
/// Get file status by fd
pub const SYS_FSTAT: usize = 80;
/// Get filesystem statistics
pub const SYS_STATFS: usize = 43;
/// Get filesystem statistics by fd
pub const SYS_FSTATFS: usize = 44;

// ============================================================================
// Directory Operations
// ============================================================================

/// Get current working directory
pub const SYS_GETCWD: usize = 17;
/// Change working directory
pub const SYS_CHDIR: usize = 49;
/// Change working directory by fd
pub const SYS_FCHDIR: usize = 50;
/// Create directory relative to directory FD
pub const SYS_MKDIRAT: usize = 34;
/// Delete file/directory relative to directory FD
pub const SYS_UNLINKAT: usize = 35;
/// Rename file relative to directory FDs
pub const SYS_RENAMEAT: usize = 38;
/// Rename file with flags (atomic exchange, noreplace)
pub const SYS_RENAMEAT2: usize = 276;
/// Create hard link relative to directory FDs
pub const SYS_LINKAT: usize = 37;
/// Create symlink relative to directory FD
pub const SYS_SYMLINKAT: usize = 36;
/// Read symlink relative to directory FD
pub const SYS_READLINKAT: usize = 78;
/// Create special/device file relative to directory FD
pub const SYS_MKNODAT: usize = 33;

// ============================================================================
// Permissions
// ============================================================================

/// Change file mode by fd
pub const SYS_FCHMOD: usize = 52;
/// Change permissions relative to directory FD
pub const SYS_FCHMODAT: usize = 53;
/// Change ownership relative to directory FD
pub const SYS_FCHOWNAT: usize = 54;
/// Change file owner by fd
pub const SYS_FCHOWN: usize = 55;
/// Set file creation mask
pub const SYS_UMASK: usize = 166;
/// Check access relative to directory FD
pub const SYS_FACCESSAT: usize = 48;

// ============================================================================
// Memory Management
// ============================================================================

/// Map memory pages
pub const SYS_MMAP: usize = 222;
/// Set memory protection
pub const SYS_MPROTECT: usize = 226;
/// Unmap memory pages
pub const SYS_MUNMAP: usize = 215;
/// Change data segment size (heap)
pub const SYS_BRK: usize = 214;
/// Remap/resize a virtual memory area
pub const SYS_MREMAP: usize = 216;
/// Synchronize file with memory map
pub const SYS_MSYNC: usize = 227;
/// Determine whether pages are resident in memory
pub const SYS_MINCORE: usize = 232;
/// Give advice about memory usage patterns
pub const SYS_MADVISE: usize = 233;
/// Lock memory pages to prevent swapping
pub const SYS_MLOCK: usize = 228;
/// Unlock memory pages
pub const SYS_MUNLOCK: usize = 229;
/// Lock all memory pages
pub const SYS_MLOCKALL: usize = 230;
/// Unlock all memory pages
pub const SYS_MUNLOCKALL: usize = 231;

// ============================================================================
// Process Management
// ============================================================================

/// Get process ID
pub const SYS_GETPID: usize = 172;
/// Get parent process ID
pub const SYS_GETPPID: usize = 173;
/// Get thread ID
pub const SYS_GETTID: usize = 178;
/// Exit the current process
pub const SYS_EXIT: usize = 93;
/// Exit all threads in process
pub const SYS_EXIT_GROUP: usize = 94;
/// Create a child process with specified flags
pub const SYS_CLONE: usize = 220;
/// Create child process with clone_args struct
pub const SYS_CLONE3: usize = 435;
/// Execute a program
pub const SYS_EXECVE: usize = 221;
/// Wait for process state change
pub const SYS_WAIT4: usize = 260;
/// Wait for process/thread state change
pub const SYS_WAITID: usize = 95;
/// Create child process sharing VM until exec/exit
pub const SYS_VFORK: usize = 501; // zk compat: redirects to clone

// ============================================================================
// Signals
// ============================================================================

/// Examine and change signal actions
pub const SYS_RT_SIGACTION: usize = 134;
/// Examine and change blocked signals
pub const SYS_RT_SIGPROCMASK: usize = 135;
/// Return from signal handler
pub const SYS_RT_SIGRETURN: usize = 139;
/// Examine pending signals
pub const SYS_RT_SIGPENDING: usize = 136;
/// Synchronously wait for queued signals
pub const SYS_RT_SIGTIMEDWAIT: usize = 137;
/// Queue a signal with info to a process
pub const SYS_RT_SIGQUEUEINFO: usize = 138;
/// Wait for a signal, replacing signal mask
pub const SYS_RT_SIGSUSPEND: usize = 133;
/// Set/get signal stack context
pub const SYS_SIGALTSTACK: usize = 132;
/// Send signal to a process
pub const SYS_KILL: usize = 129;
/// Send signal to a specific thread
pub const SYS_TKILL: usize = 130;
/// Send signal to a thread in a thread group
pub const SYS_TGKILL: usize = 131;

// ============================================================================
// User/Group IDs
// ============================================================================

/// Get user ID
pub const SYS_GETUID: usize = 174;
/// Get effective user ID
pub const SYS_GETEUID: usize = 175;
/// Get group ID
pub const SYS_GETGID: usize = 176;
/// Get effective group ID
pub const SYS_GETEGID: usize = 177;
/// Set user ID
pub const SYS_SETUID: usize = 146;
/// Set group ID
pub const SYS_SETGID: usize = 144;
/// Set real, effective, and saved user IDs
pub const SYS_SETRESUID: usize = 147;
/// Get real, effective, and saved user IDs
pub const SYS_GETRESUID: usize = 148;
/// Set real, effective, and saved group IDs
pub const SYS_SETRESGID: usize = 149;
/// Get real, effective, and saved group IDs
pub const SYS_GETRESGID: usize = 150;

// ============================================================================
// Sockets
// ============================================================================

/// Create a socket
pub const SYS_SOCKET: usize = 198;
/// Create connected socket pair
pub const SYS_SOCKETPAIR: usize = 199;
/// Bind a socket to an address
pub const SYS_BIND: usize = 200;
/// Listen for connections on socket
pub const SYS_LISTEN: usize = 201;
/// Accept connection on socket
pub const SYS_ACCEPT: usize = 202;
/// Accept connection with flags
pub const SYS_ACCEPT4: usize = 242;
/// Connect socket to address
pub const SYS_CONNECT: usize = 203;
/// Get local socket address
pub const SYS_GETSOCKNAME: usize = 204;
/// Get peer socket address
pub const SYS_GETPEERNAME: usize = 205;
/// Send a message on a socket
pub const SYS_SENDTO: usize = 206;
/// Receive a message from a socket
pub const SYS_RECVFROM: usize = 207;
/// Send a message on a socket with scatter/gather I/O
pub const SYS_SENDMSG: usize = 211;
/// Receive a message from a socket with scatter/gather I/O
pub const SYS_RECVMSG: usize = 212;
/// Set socket options
pub const SYS_SETSOCKOPT: usize = 208;
/// Get socket options
pub const SYS_GETSOCKOPT: usize = 209;
/// Shut down part of a full-duplex connection
pub const SYS_SHUTDOWN: usize = 210;

// ============================================================================
// Time
// ============================================================================

/// Get time of day (legacy)
pub const SYS_GETTIMEOFDAY: usize = 169;
/// Set time of day (requires root)
pub const SYS_SETTIMEOFDAY: usize = 170;
/// Get time from a clock
pub const SYS_CLOCK_GETTIME: usize = 113;
/// Get clock resolution
pub const SYS_CLOCK_GETRES: usize = 114;
/// High-resolution sleep with clock selection
pub const SYS_CLOCK_NANOSLEEP: usize = 115;
/// High-resolution sleep
pub const SYS_NANOSLEEP: usize = 101;
/// Get interval timer
pub const SYS_GETITIMER: usize = 102;
/// Set interval timer
pub const SYS_SETITIMER: usize = 103;
/// Create a POSIX per-process timer
pub const SYS_TIMER_CREATE: usize = 107;
/// Get POSIX per-process timer state
pub const SYS_TIMER_GETTIME: usize = 108;
/// Get overrun count for a POSIX timer
pub const SYS_TIMER_GETOVERRUN: usize = 109;
/// Arm/disarm a POSIX per-process timer
pub const SYS_TIMER_SETTIME: usize = 110;
/// Delete a POSIX per-process timer
pub const SYS_TIMER_DELETE: usize = 111;

// ============================================================================
// Epoll/Events
// ============================================================================

/// Create an epoll instance
pub const SYS_EPOLL_CREATE1: usize = 20;
/// Control an epoll instance
pub const SYS_EPOLL_CTL: usize = 21;
/// Wait for I/O events with signal mask
pub const SYS_EPOLL_PWAIT: usize = 22;
/// eventfd with flags
pub const SYS_EVENTFD2: usize = 19;
/// signalfd with flags
pub const SYS_SIGNALFD4: usize = 74;
/// Create timer as file descriptor
pub const SYS_TIMERFD_CREATE: usize = 85;
/// Arm/disarm timerfd
pub const SYS_TIMERFD_SETTIME: usize = 86;
/// Get timerfd state
pub const SYS_TIMERFD_GETTIME: usize = 87;

// ============================================================================
// Scheduling
// ============================================================================

/// Yield the processor
pub const SYS_SCHED_YIELD: usize = 124;
/// Fast userspace locking
pub const SYS_FUTEX: usize = 98;
/// Set pointer to thread ID
pub const SYS_SET_TID_ADDRESS: usize = 96;

// ============================================================================
// Filesystem Operations
// ============================================================================

/// Commit buffer cache to disk
pub const SYS_SYNC: usize = 81;
/// Synchronize file's in-core state with storage
pub const SYS_FSYNC: usize = 82;
/// Synchronize file data (not metadata)
pub const SYS_FDATASYNC: usize = 83;
/// Sync single filesystem to disk
pub const SYS_SYNCFS: usize = 267;
/// Truncate a file to specified length
pub const SYS_TRUNCATE: usize = 45;
/// Truncate file by fd to specified length
pub const SYS_FTRUNCATE: usize = 46;
/// Pre-allocate file space
pub const SYS_FALLOCATE: usize = 47;
/// Mount a filesystem
pub const SYS_MOUNT: usize = 40;
/// Unmount a filesystem
pub const SYS_UMOUNT2: usize = 39;

// ============================================================================
// Advanced I/O
// ============================================================================

/// Transfer data between file descriptors (zero-copy)
pub const SYS_SENDFILE: usize = 71;
/// Splice data between file descriptors
pub const SYS_SPLICE: usize = 76;
/// Duplicate pipe content
pub const SYS_TEE: usize = 77;
/// Splice user pages into pipe
pub const SYS_VMSPLICE: usize = 75;
/// Copy data between file descriptors (server-side)
pub const SYS_COPY_FILE_RANGE: usize = 285;
/// Get directory entries (64-bit)
pub const SYS_GETDENTS64: usize = 61;
/// Read data at offset into multiple buffers
pub const SYS_PREADV: usize = 69;
/// Write data from multiple buffers at offset
pub const SYS_PWRITEV: usize = 70;

// ============================================================================
// Misc
// ============================================================================

/// Get system information
pub const SYS_UNAME: usize = 160;
/// Set host name
pub const SYS_SETHOSTNAME: usize = 161;
/// Set domain name
pub const SYS_SETDOMAINNAME: usize = 162;
/// Get resource limits
pub const SYS_GETRLIMIT: usize = 163;
/// Set resource limits
pub const SYS_SETRLIMIT: usize = 164;
/// Get/set resource limits for any process
pub const SYS_PRLIMIT64: usize = 261;
/// Get resource usage statistics
pub const SYS_GETRUSAGE: usize = 165;
/// Process control operations
pub const SYS_PRCTL: usize = 167;
/// Get random bytes
pub const SYS_GETRANDOM: usize = 278;
/// Create anonymous file for memory sharing
pub const SYS_MEMFD_CREATE: usize = 279;
/// Secure computing mode (syscall filtering)
pub const SYS_SECCOMP: usize = 277;

// ============================================================================
// inotify
// ============================================================================

/// Initialize inotify instance with flags
pub const SYS_INOTIFY_INIT1: usize = 26;
/// Add watch to inotify instance
pub const SYS_INOTIFY_ADD_WATCH: usize = 27;
/// Remove watch from inotify instance
pub const SYS_INOTIFY_RM_WATCH: usize = 28;

// ============================================================================
// Capabilities & Debugging
// ============================================================================

/// Get thread capabilities
pub const SYS_CAPGET: usize = 90;
/// Set thread capabilities
pub const SYS_CAPSET: usize = 91;
/// Process tracing and debugging
pub const SYS_PTRACE: usize = 117;

// ============================================================================
// Container/Namespace
// ============================================================================

/// Disassociate parts of execution context
pub const SYS_UNSHARE: usize = 97;
/// Reassociate thread with a namespace
pub const SYS_SETNS: usize = 268;

// ============================================================================
// io_uring
// ============================================================================

/// Setup io_uring instance
pub const SYS_IO_URING_SETUP: usize = 425;
/// Submit and wait for io_uring operations
pub const SYS_IO_URING_ENTER: usize = 426;
/// Register buffers/files with io_uring
pub const SYS_IO_URING_REGISTER: usize = 427;

// ============================================================================
// Legacy Syscall Compatibility Stubs (zk-specific, 500-599 range)
// These are NOT part of Linux aarch64 ABI but provided for source compatibility
// with code that uses legacy syscall names. Handlers redirect to modern *at() variants.
// ============================================================================

/// Open a file (zk compat: redirects to openat with AT_FDCWD)
pub const SYS_OPEN: usize = 500;
/// Create a pipe (zk compat: redirects to pipe2 with flags=0)
pub const SYS_PIPE: usize = 502;
/// Get file status (zk compat: redirects to newfstatat with AT_FDCWD)
pub const SYS_STAT: usize = 503;
/// Get file status (do not follow symlinks) (zk compat: redirects to newfstatat)
pub const SYS_LSTAT: usize = 504;
/// Check user's permissions for a file (zk compat: redirects to faccessat)
pub const SYS_ACCESS: usize = 505;
/// Duplicate a file descriptor to specific number (zk compat: redirects to dup3)
pub const SYS_DUP2: usize = 506;
/// Create a child process (zk compat: redirects to clone)
pub const SYS_FORK: usize = 507;
/// Examine multiple file descriptors (zk compat: redirects to pselect6)
pub const SYS_SELECT: usize = 508;
/// Wait for I/O events on an epoll instance (zk compat: redirects to epoll_pwait)
pub const SYS_EPOLL_WAIT: usize = 509;
/// Wait for some event on a set of file descriptors (zk compat: redirects to ppoll)
pub const SYS_POLL: usize = 510;
/// Rename a file (zk compat: redirects to renameat)
pub const SYS_RENAME: usize = 511;
/// Create a directory (zk compat: redirects to mkdirat)
pub const SYS_MKDIR: usize = 512;
/// Remove a directory (zk compat: redirects to unlinkat with AT_REMOVEDIR)
pub const SYS_RMDIR: usize = 513;
/// Delete a file (zk compat: redirects to unlinkat)
pub const SYS_UNLINK: usize = 514;
/// Create a symbolic link (zk compat: redirects to symlinkat)
pub const SYS_SYMLINK: usize = 515;
/// Read value of symbolic link (zk compat: redirects to readlinkat)
pub const SYS_READLINK: usize = 516;
/// Create a hard link (zk compat: redirects to linkat)
pub const SYS_LINK: usize = 517;
/// Change file mode (zk compat: redirects to fchmodat)
pub const SYS_CHMOD: usize = 518;
/// Change file owner (zk compat: redirects to fchownat)
pub const SYS_CHOWN: usize = 519;
/// Change symlink owner (don't follow) (zk compat: redirects to fchownat)
pub const SYS_LCHOWN: usize = 520;
/// Get directory entries (zk compat: redirects to getdents64)
pub const SYS_GETDENTS: usize = 521;
/// Initialize an inotify instance (zk compat: redirects to inotify_init1)
pub const SYS_INOTIFY_INIT: usize = 522;
/// Create file descriptor for signal handling (zk compat: redirects to signalfd4)
pub const SYS_SIGNALFD: usize = 523;
/// Create event notification file descriptor (zk compat: redirects to eventfd2)
pub const SYS_EVENTFD: usize = 524;

// ============================================================================
// NOT available on aarch64 - x86_64 specific
// ============================================================================

/// Set architecture-specific thread state (x86_64 only, use prctl on aarch64)
pub const SYS_ARCH_PRCTL: usize = 525; // zk compat: emulated via prctl where possible

// ============================================================================
// Additional syscalls implemented in zk
// ============================================================================

/// Sync file segment with disk
pub const SYS_SYNC_FILE_RANGE: usize = 84;
