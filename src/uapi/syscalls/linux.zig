// Linux x86_64 ABI Syscalls
//
// These numbers match the standard Linux x86_64 syscall table.

/// Read from a file descriptor
pub const SYS_READ: usize = 0;
/// Write to a file descriptor
pub const SYS_WRITE: usize = 1;
/// Open a file
pub const SYS_OPEN: usize = 2;
/// Close a file descriptor
pub const SYS_CLOSE: usize = 3;
/// Get file status
pub const SYS_STAT: usize = 4;
/// Get file status by fd
pub const SYS_FSTAT: usize = 5;
/// Get file status (do not follow symlinks)
pub const SYS_LSTAT: usize = 6;
/// Wait for some event on a set of file descriptors
pub const SYS_POLL: usize = 7;
/// Reposition read/write file offset
pub const SYS_LSEEK: usize = 8;
/// Map memory pages
pub const SYS_MMAP: usize = 9;
/// Set memory protection
pub const SYS_MPROTECT: usize = 10;
/// Unmap memory pages
pub const SYS_MUNMAP: usize = 11;
/// Change data segment size (heap)
pub const SYS_BRK: usize = 12;
/// Examine and change signal actions
pub const SYS_RT_SIGACTION: usize = 13;
/// Examine and change blocked signals
pub const SYS_RT_SIGPROCMASK: usize = 14;
/// Return from signal handler
pub const SYS_RT_SIGRETURN: usize = 15;
/// Perform device-specific control operations
pub const SYS_IOCTL: usize = 16;
/// Read from file at offset
pub const SYS_PREAD64: usize = 17;
/// Write to file at offset
pub const SYS_PWRITE64: usize = 18;
/// Read data into multiple buffers
pub const SYS_READV: usize = 19;
/// Write data from multiple buffers
pub const SYS_WRITEV: usize = 20;
/// Check user's permissions for a file
pub const SYS_ACCESS: usize = 21;
/// Create a pipe
pub const SYS_PIPE: usize = 22;
/// Examine multiple file descriptors
pub const SYS_SELECT: usize = 23;
/// Yield the processor
pub const SYS_SCHED_YIELD: usize = 24;
/// Remap/resize a virtual memory area
pub const SYS_MREMAP: usize = 25;
/// Synchronize file with memory map
pub const SYS_MSYNC: usize = 26;
/// Determine whether pages are resident in memory
pub const SYS_MINCORE: usize = 27;
/// Give advice about memory usage patterns
pub const SYS_MADVISE: usize = 28;
/// Duplicate a file descriptor
pub const SYS_DUP: usize = 32;
/// Duplicate a file descriptor to specific number
pub const SYS_DUP2: usize = 33;
/// High-resolution sleep
pub const SYS_NANOSLEEP: usize = 35;
/// Get process ID
pub const SYS_GETPID: usize = 39;
/// Transfer data between file descriptors (zero-copy)
pub const SYS_SENDFILE: usize = 40;
/// Create a socket
pub const SYS_SOCKET: usize = 41;
/// Connect socket to address
pub const SYS_CONNECT: usize = 42;
/// Accept connection on socket
pub const SYS_ACCEPT: usize = 43;
/// Send a message on a socket
pub const SYS_SENDTO: usize = 44;
/// Receive a message from a socket
pub const SYS_RECVFROM: usize = 45;
/// Send a message on a socket with scatter/gather I/O
pub const SYS_SENDMSG: usize = 46;
/// Receive a message from a socket with scatter/gather I/O
pub const SYS_RECVMSG: usize = 47;
/// Shut down part of a full-duplex connection
pub const SYS_SHUTDOWN: usize = 48;
/// Bind a socket to an address
pub const SYS_BIND: usize = 49;
/// Listen for connections on socket
pub const SYS_LISTEN: usize = 50;
/// Get local socket address
pub const SYS_GETSOCKNAME: usize = 51;
/// Get peer socket address
pub const SYS_GETPEERNAME: usize = 52;
/// Create connected socket pair
pub const SYS_SOCKETPAIR: usize = 53;
/// Set socket options
pub const SYS_SETSOCKOPT: usize = 54;
/// Get socket options
pub const SYS_GETSOCKOPT: usize = 55;
/// Create a child process with specified flags
pub const SYS_CLONE: usize = 56;
/// Create a child process
pub const SYS_FORK: usize = 57;
/// Create child process sharing VM until exec/exit
pub const SYS_VFORK: usize = 58;
/// Execute a program
pub const SYS_EXECVE: usize = 59;
/// Exit the current process
pub const SYS_EXIT: usize = 60;
/// Wait for process state change
pub const SYS_WAIT4: usize = 61;
/// Send signal to a process
pub const SYS_KILL: usize = 62;
/// Get system information
pub const SYS_UNAME: usize = 63;
/// Manipulate file descriptor flags (e.g., O_NONBLOCK)
pub const SYS_FCNTL: usize = 72;
/// Synchronize file's in-core state with storage
pub const SYS_FSYNC: usize = 74;
/// Synchronize file data (not metadata)
pub const SYS_FDATASYNC: usize = 75;
/// Truncate a file to specified length
pub const SYS_TRUNCATE: usize = 76;
/// Truncate file by fd to specified length
pub const SYS_FTRUNCATE: usize = 77;
/// Get directory entries
pub const SYS_GETDENTS: usize = 78;
/// Get current working directory
pub const SYS_GETCWD: usize = 79;
/// Change working directory
pub const SYS_CHDIR: usize = 80;
/// Change working directory by fd
pub const SYS_FCHDIR: usize = 81;
/// Rename a file
pub const SYS_RENAME: usize = 82;
/// Create a directory
pub const SYS_MKDIR: usize = 83;
/// Remove a directory
pub const SYS_RMDIR: usize = 84;
/// Create a file (legacy, use open with O_CREAT)
pub const SYS_CREAT: usize = 85;
/// Create a hard link
pub const SYS_LINK: usize = 86;
/// Delete a file
pub const SYS_UNLINK: usize = 87;
/// Create a symbolic link
pub const SYS_SYMLINK: usize = 88;
/// Read value of symbolic link
pub const SYS_READLINK: usize = 89;
/// Change file mode
pub const SYS_CHMOD: usize = 90;
/// Change file mode by fd
pub const SYS_FCHMOD: usize = 91;
/// Change file owner
pub const SYS_CHOWN: usize = 92;
/// Change file owner by fd
pub const SYS_FCHOWN: usize = 93;
/// Change symlink owner (don't follow)
pub const SYS_LCHOWN: usize = 94;
/// Set file creation mask
pub const SYS_UMASK: usize = 95;
/// Get time of day (legacy)
pub const SYS_GETTIMEOFDAY: usize = 96;
/// Get resource limits
pub const SYS_GETRLIMIT: usize = 97;
/// Get resource usage statistics
pub const SYS_GETRUSAGE: usize = 98;
/// Process tracing and debugging
pub const SYS_PTRACE: usize = 101;
/// Get user ID
pub const SYS_GETUID: usize = 102;
/// Get group ID
pub const SYS_GETGID: usize = 104;
/// Set user ID
pub const SYS_SETUID: usize = 105;
/// Set group ID
pub const SYS_SETGID: usize = 106;
/// Get effective user ID
pub const SYS_GETEUID: usize = 107;
/// Get effective group ID
pub const SYS_GETEGID: usize = 108;
/// Get parent process ID
pub const SYS_GETPPID: usize = 110;
/// Set real, effective, and saved user IDs
pub const SYS_SETRESUID: usize = 117;
/// Get real, effective, and saved user IDs
pub const SYS_GETRESUID: usize = 118;
/// Set real, effective, and saved group IDs
pub const SYS_SETRESGID: usize = 119;
/// Get real, effective, and saved group IDs
pub const SYS_GETRESGID: usize = 120;
/// Get filesystem statistics
pub const SYS_STATFS: usize = 137;
/// Get filesystem statistics by fd
pub const SYS_FSTATFS: usize = 138;
/// Get thread capabilities
pub const SYS_CAPGET: usize = 125;
/// Set thread capabilities
pub const SYS_CAPSET: usize = 126;
/// Examine pending signals
pub const SYS_RT_SIGPENDING: usize = 127;
/// Synchronously wait for queued signals
pub const SYS_RT_SIGTIMEDWAIT: usize = 128;
/// Queue a signal with info to a process
pub const SYS_RT_SIGQUEUEINFO: usize = 129;
/// Wait for a signal, replacing signal mask
pub const SYS_RT_SIGSUSPEND: usize = 130;
/// Set/get signal stack context
pub const SYS_SIGALTSTACK: usize = 131;
/// Lock memory pages to prevent swapping
pub const SYS_MLOCK: usize = 149;
/// Unlock memory pages
pub const SYS_MUNLOCK: usize = 150;
/// Lock all memory pages
pub const SYS_MLOCKALL: usize = 151;
/// Unlock all memory pages
pub const SYS_MUNLOCKALL: usize = 152;
/// Process control operations
pub const SYS_PRCTL: usize = 157;
/// Set architecture-specific thread state
pub const SYS_ARCH_PRCTL: usize = 158;
/// Set resource limits
pub const SYS_SETRLIMIT: usize = 160;
/// Commit buffer cache to disk
pub const SYS_SYNC: usize = 162;
/// Mount a filesystem
pub const SYS_MOUNT: usize = 165;
/// Unmount a filesystem
pub const SYS_UMOUNT2: usize = 166;
/// Set host name
pub const SYS_SETHOSTNAME: usize = 170;
/// Set domain name
pub const SYS_SETDOMAINNAME: usize = 171;
/// Fast userspace locking
pub const SYS_FUTEX: usize = 202;
/// Get directory entries (64-bit)
pub const SYS_GETDENTS64: usize = 217;
/// Set pointer to thread ID
pub const SYS_SET_TID_ADDRESS: usize = 218;
/// Get time from a clock
pub const SYS_CLOCK_GETTIME: usize = 228;
/// Get clock resolution
pub const SYS_CLOCK_GETRES: usize = 229;
/// Exit all threads in process
pub const SYS_EXIT_GROUP: usize = 231;
/// Wait for I/O events on an epoll instance
pub const SYS_EPOLL_WAIT: usize = 232;
/// Control an epoll instance
pub const SYS_EPOLL_CTL: usize = 233;
/// Get thread ID
pub const SYS_GETTID: usize = 186;
/// Send signal to a specific thread
pub const SYS_TKILL: usize = 200;
/// Create a POSIX per-process timer
pub const SYS_TIMER_CREATE: usize = 222;
/// Arm/disarm a POSIX per-process timer
pub const SYS_TIMER_SETTIME: usize = 223;
/// Get POSIX per-process timer state
pub const SYS_TIMER_GETTIME: usize = 224;
/// Get overrun count for a POSIX timer
pub const SYS_TIMER_GETOVERRUN: usize = 225;
/// Delete a POSIX per-process timer
pub const SYS_TIMER_DELETE: usize = 226;
/// High-resolution sleep with clock selection
pub const SYS_CLOCK_NANOSLEEP: usize = 230;
/// Initialize an inotify instance
pub const SYS_INOTIFY_INIT: usize = 253;
/// Add watch to inotify instance
pub const SYS_INOTIFY_ADD_WATCH: usize = 254;
/// Remove watch from inotify instance
pub const SYS_INOTIFY_RM_WATCH: usize = 255;
/// Open file relative to a directory FD
pub const SYS_OPENAT: usize = 257;
/// Create directory relative to directory FD
pub const SYS_MKDIRAT: usize = 258;
/// Create special/device file relative to directory FD
pub const SYS_MKNODAT: usize = 259;
/// Change ownership relative to directory FD
pub const SYS_FCHOWNAT: usize = 260;
/// Get file status relative to directory FD
pub const SYS_NEWFSTATAT: usize = 262;
/// Delete file/directory relative to directory FD
pub const SYS_UNLINKAT: usize = 263;
/// Rename file relative to directory FDs
pub const SYS_RENAMEAT: usize = 264;
/// Create hard link relative to directory FDs
pub const SYS_LINKAT: usize = 265;
/// Create symlink relative to directory FD
pub const SYS_SYMLINKAT: usize = 266;
/// Read symlink relative to directory FD
pub const SYS_READLINKAT: usize = 267;
/// Change permissions relative to directory FD
pub const SYS_FCHMODAT: usize = 268;
/// Check access relative to directory FD
pub const SYS_FACCESSAT: usize = 269;
/// Disassociate parts of execution context
pub const SYS_UNSHARE: usize = 272;
/// Splice data between file descriptors
pub const SYS_SPLICE: usize = 275;
/// Duplicate pipe content
pub const SYS_TEE: usize = 276;
/// Sync file segment with disk
pub const SYS_SYNC_FILE_RANGE: usize = 277;
/// Splice user pages into pipe
pub const SYS_VMSPLICE: usize = 278;
/// Wait for I/O events with signal mask
pub const SYS_EPOLL_PWAIT: usize = 281;
/// Create file descriptor for signal handling
pub const SYS_SIGNALFD: usize = 282;
/// Create timer as file descriptor
pub const SYS_TIMERFD_CREATE: usize = 283;
/// Create event notification file descriptor
pub const SYS_EVENTFD: usize = 284;
/// Pre-allocate file space
pub const SYS_FALLOCATE: usize = 285;
/// Arm/disarm timerfd
pub const SYS_TIMERFD_SETTIME: usize = 286;
/// Get timerfd state
pub const SYS_TIMERFD_GETTIME: usize = 287;
/// signalfd with flags
pub const SYS_SIGNALFD4: usize = 289;
/// eventfd with flags
pub const SYS_EVENTFD2: usize = 290;
/// Send signal to a thread in a thread group
pub const SYS_TGKILL: usize = 234;
/// Create an epoll instance
pub const SYS_EPOLL_CREATE1: usize = 291;
/// Duplicate FD with flags
pub const SYS_DUP3: usize = 292;
/// Create pipe with flags
pub const SYS_PIPE2: usize = 293;
/// Initialize inotify instance with flags
pub const SYS_INOTIFY_INIT1: usize = 294;
/// Read data at offset into multiple buffers
pub const SYS_PREADV: usize = 295;
/// Write data from multiple buffers at offset
pub const SYS_PWRITEV: usize = 296;
/// Get/set resource limits for any process
pub const SYS_PRLIMIT64: usize = 302;
/// Sync single filesystem to disk
pub const SYS_SYNCFS: usize = 306;
/// Reassociate thread with a namespace
pub const SYS_SETNS: usize = 308;
/// Rename file with flags (atomic exchange, noreplace)
pub const SYS_RENAMEAT2: usize = 316;
/// Secure computing mode (syscall filtering)
pub const SYS_SECCOMP: usize = 317;
/// Get random bytes
pub const SYS_GETRANDOM: usize = 318;
/// Create anonymous file for memory sharing
pub const SYS_MEMFD_CREATE: usize = 319;
/// Copy data between file descriptors (server-side)
pub const SYS_COPY_FILE_RANGE: usize = 326;

// io_uring
pub const SYS_IO_URING_SETUP: usize = 425;
pub const SYS_IO_URING_ENTER: usize = 426;
pub const SYS_IO_URING_REGISTER: usize = 427;

// Modern Process Creation
pub const SYS_CLONE3: usize = 435;
