// Zscapek Syscall Numbers
//
// Single source of truth for syscall numbers matching specs/syscall-table.md.
// All kernel and userland code MUST use these constants.
//
// Convention:
//   - Linux x86_64 ABI syscalls use standard numbers (0-999)
//   - Zscapek custom extensions use range 1000-1999
//
// Register Convention (x86_64):
//   Entry: RAX=number, RDI=arg1, RSI=arg2, RDX=arg3, R10=arg4, R8=arg5, R9=arg6
//   Return: RAX=result (if >= 0) or -errno (if < 0)
//   Clobbers: RCX, R11 (as per SYSCALL instruction)

// =============================================================================
// Linux x86_64 ABI Syscalls (numerical order)
// =============================================================================

/// Read from a file descriptor
/// (fd, buf, count) -> ssize_t
pub const SYS_READ: usize = 0;

/// Write to a file descriptor
/// (fd, buf, count) -> ssize_t
pub const SYS_WRITE: usize = 1;

/// Open a file
/// (path, flags, mode) -> fd
pub const SYS_OPEN: usize = 2;

/// Close a file descriptor
/// (fd) -> int
pub const SYS_CLOSE: usize = 3;

/// Get file status
/// (path, statbuf) -> int
pub const SYS_STAT: usize = 4;

/// Get file status by fd
/// (fd, statbuf) -> int
pub const SYS_FSTAT: usize = 5;

/// Get file status (do not follow symlinks)
/// (path, statbuf) -> int
pub const SYS_LSTAT: usize = 6;

/// Wait for some event on a set of file descriptors
/// (ufds, nfds, timeout) -> int
pub const SYS_POLL: usize = 7;

/// Reposition read/write file offset
/// (fd, offset, whence) -> off_t
/// whence: 0=SEEK_SET, 1=SEEK_CUR, 2=SEEK_END
pub const SYS_LSEEK: usize = 8;

/// Map memory pages
/// (addr, len, prot, flags, fd, off) -> addr
pub const SYS_MMAP: usize = 9;

/// Set memory protection
/// (addr, len, prot) -> int
pub const SYS_MPROTECT: usize = 10;

/// Unmap memory pages
/// (addr, len) -> int
pub const SYS_MUNMAP: usize = 11;

/// Change data segment size (heap)
/// (brk) -> addr
pub const SYS_BRK: usize = 12;

/// Examine and change signal actions
/// (sig, act, oldact, sigsetsize) -> int
pub const SYS_RT_SIGACTION: usize = 13;

/// Examine and change blocked signals
/// (how, set, oldset, sigsetsize) -> int
pub const SYS_RT_SIGPROCMASK: usize = 14;

/// Return from signal handler
/// () -> noreturn
pub const SYS_RT_SIGRETURN: usize = 15;

/// Perform device-specific control operations
/// (fd, cmd, arg) -> int
pub const SYS_IOCTL: usize = 16;

/// Read from file at offset
/// (fd, buf, count, offset) -> ssize_t
pub const SYS_PREAD64: usize = 17;

/// Write to file at offset
/// (fd, buf, count, offset) -> ssize_t
pub const SYS_PWRITE64: usize = 18;

/// Read data into multiple buffers
/// (fd, iov, iovcnt) -> ssize_t
pub const SYS_READV: usize = 19;

/// Write data from multiple buffers
/// (fd, iov, iovcnt) -> ssize_t
pub const SYS_WRITEV: usize = 20;

/// Check user's permissions for a file
/// (pathname, mode) -> int
pub const SYS_ACCESS: usize = 21;

/// Create a pipe
/// (pipefd) -> int
pub const SYS_PIPE: usize = 22;

/// Examine multiple file descriptors
/// (nfds, readfds, writefds, exceptfds, timeout) -> int
pub const SYS_SELECT: usize = 23;

/// Yield the processor
/// () -> int
pub const SYS_SCHED_YIELD: usize = 24;

/// Duplicate a file descriptor
/// (oldfd) -> newfd
pub const SYS_DUP: usize = 32;

/// Duplicate a file descriptor to specific number
/// (oldfd, newfd) -> int
pub const SYS_DUP2: usize = 33;

/// High-resolution sleep
/// (req, rem) -> int
pub const SYS_NANOSLEEP: usize = 35;

/// Get process ID
/// () -> pid_t
pub const SYS_GETPID: usize = 39;

/// Create a socket
/// (domain, type, protocol) -> fd
pub const SYS_SOCKET: usize = 41;

/// Connect socket to address
/// (fd, addr, addrlen) -> int
pub const SYS_CONNECT: usize = 42;

/// Accept connection on socket
/// (fd, addr, addrlen) -> fd
pub const SYS_ACCEPT: usize = 43;

/// Send a message on a socket
/// (fd, buf, len, flags, addr, addrlen) -> ssize_t
pub const SYS_SENDTO: usize = 44;

/// Receive a message from a socket
/// (fd, buf, len, flags, addr, addrlen) -> ssize_t
pub const SYS_RECVFROM: usize = 45;

/// Send a message on a socket with scatter/gather I/O
/// (fd, msg, flags) -> ssize_t
pub const SYS_SENDMSG: usize = 46;

/// Receive a message from a socket with scatter/gather I/O
/// (fd, msg, flags) -> ssize_t
pub const SYS_RECVMSG: usize = 47;

/// Shut down part of a full-duplex connection
/// (fd, how) -> int
/// how: 0=SHUT_RD, 1=SHUT_WR, 2=SHUT_RDWR
pub const SYS_SHUTDOWN: usize = 48;

/// Bind a socket to an address
/// (fd, addr, addrlen) -> int
pub const SYS_BIND: usize = 49;

/// Listen for connections on socket
/// (fd, backlog) -> int
pub const SYS_LISTEN: usize = 50;

/// Get local socket address
/// (fd, addr, addrlen) -> int
pub const SYS_GETSOCKNAME: usize = 51;

/// Get peer socket address
/// (fd, addr, addrlen) -> int
pub const SYS_GETPEERNAME: usize = 52;

/// Set socket options
/// (fd, level, optname, optval, optlen) -> int
pub const SYS_SETSOCKOPT: usize = 54;

/// Get socket options
/// (fd, level, optname, optval, optlen) -> int
pub const SYS_GETSOCKOPT: usize = 55;

/// Create a child process with specified flags
/// (flags, stack, parent_tid, child_tid, tls) -> pid_t
pub const SYS_CLONE: usize = 56;

/// Create a child process
/// () -> pid_t
pub const SYS_FORK: usize = 57;

/// Execute a program
/// (path, argv, envp) -> int
pub const SYS_EXECVE: usize = 59;

/// Exit the current process
/// (code) -> noreturn
pub const SYS_EXIT: usize = 60;

/// Wait for process state change
/// (pid, wstatus, options, rusage) -> pid_t
pub const SYS_WAIT4: usize = 61;

/// Send signal to a process
/// (pid, sig) -> int
pub const SYS_KILL: usize = 62;

/// Get system information
/// (name) -> int
pub const SYS_UNAME: usize = 63;

/// Manipulate file descriptor flags (e.g., O_NONBLOCK)
/// (fd, cmd, arg) -> int
pub const SYS_FCNTL: usize = 72;

/// Synchronize file's in-core state with storage
/// (fd) -> int
pub const SYS_FSYNC: usize = 74;

/// Synchronize file data (not metadata)
/// (fd) -> int
pub const SYS_FDATASYNC: usize = 75;

/// Truncate a file to specified length
/// (path, length) -> int
pub const SYS_TRUNCATE: usize = 76;

/// Truncate file by fd to specified length
/// (fd, length) -> int
pub const SYS_FTRUNCATE: usize = 77;

/// Get directory entries
/// (fd, dirp, count) -> int
pub const SYS_GETDENTS: usize = 78;

/// Get current working directory
/// (buf, size) -> char *
pub const SYS_GETCWD: usize = 79;

/// Change working directory
/// (path) -> int
pub const SYS_CHDIR: usize = 80;

/// Change working directory by fd
/// (fd) -> int
pub const SYS_FCHDIR: usize = 81;

/// Rename a file
/// (oldpath, newpath) -> int
pub const SYS_RENAME: usize = 82;

/// Create a directory
/// (path, mode) -> int
pub const SYS_MKDIR: usize = 83;

/// Remove a directory
/// (path) -> int
pub const SYS_RMDIR: usize = 84;

/// Create a file (legacy, use open with O_CREAT)
/// (path, mode) -> fd
pub const SYS_CREAT: usize = 85;

/// Create a hard link
/// (oldpath, newpath) -> int
pub const SYS_LINK: usize = 86;

/// Delete a file
/// (path) -> int
pub const SYS_UNLINK: usize = 87;

/// Create a symbolic link
/// (target, linkpath) -> int
pub const SYS_SYMLINK: usize = 88;

/// Read value of symbolic link
/// (path, buf, bufsize) -> ssize_t
pub const SYS_READLINK: usize = 89;

/// Change file mode
/// (path, mode) -> int
pub const SYS_CHMOD: usize = 90;

/// Change file mode by fd
/// (fd, mode) -> int
pub const SYS_FCHMOD: usize = 91;

/// Change file owner
/// (path, uid, gid) -> int
pub const SYS_CHOWN: usize = 92;

/// Change file owner by fd
/// (fd, uid, gid) -> int
pub const SYS_FCHOWN: usize = 93;

/// Change symlink owner (don't follow)
/// (path, uid, gid) -> int
pub const SYS_LCHOWN: usize = 94;

/// Set file creation mask
/// (mask) -> mode_t
pub const SYS_UMASK: usize = 95;

/// Get time of day (legacy)
/// (tv, tz) -> int
pub const SYS_GETTIMEOFDAY: usize = 96;

/// Get resource limits
/// (resource, rlim) -> int
pub const SYS_GETRLIMIT: usize = 97;

/// Get user ID
/// () -> uid_t
pub const SYS_GETUID: usize = 102;

/// Get group ID
/// () -> gid_t
pub const SYS_GETGID: usize = 104;

/// Set user ID
/// (uid) -> int
pub const SYS_SETUID: usize = 105;

/// Set group ID
/// (gid) -> int
pub const SYS_SETGID: usize = 106;

/// Get effective user ID
/// () -> uid_t
pub const SYS_GETEUID: usize = 107;

/// Get effective group ID
/// () -> gid_t
pub const SYS_GETEGID: usize = 108;

/// Get parent process ID
/// () -> pid_t
pub const SYS_GETPPID: usize = 110;

/// Set architecture-specific thread state
/// (code, addr) -> int
pub const SYS_ARCH_PRCTL: usize = 158;

/// Set resource limits
/// (resource, rlim) -> int
pub const SYS_SETRLIMIT: usize = 160;

/// Set host name
/// (name, len) -> int
pub const SYS_SETHOSTNAME: usize = 170;

/// Set domain name
/// (name, len) -> int
pub const SYS_SETDOMAINNAME: usize = 171;

/// Fast userspace locking
/// (uaddr, op, val, timeout, uaddr2, val3) -> int
pub const SYS_FUTEX: usize = 202;

/// Get directory entries (64-bit)
/// (fd, dirp, count) -> int
pub const SYS_GETDENTS64: usize = 217;

/// Set pointer to thread ID
/// (tidptr) -> pid_t
pub const SYS_SET_TID_ADDRESS: usize = 218;

/// Get time from a clock
/// (clk_id, tp) -> int
pub const SYS_CLOCK_GETTIME: usize = 228;

/// Get clock resolution
/// (clk_id, res) -> int
pub const SYS_CLOCK_GETRES: usize = 229;

/// Exit all threads in process
/// (code) -> noreturn
pub const SYS_EXIT_GROUP: usize = 231;

/// Wait for I/O events on an epoll instance
/// (epfd, events, maxevents, timeout) -> int
pub const SYS_EPOLL_WAIT: usize = 232;

/// Control an epoll instance
/// (epfd, op, fd, event) -> int
pub const SYS_EPOLL_CTL: usize = 233;

/// Send signal to a specific thread
/// (tid, sig) -> int
pub const SYS_TKILL: usize = 200;

/// Open file relative to a directory FD
/// (dfd, filename, flags, mode) -> int
pub const SYS_OPENAT: usize = 257;

/// Send signal to a thread in a thread group
/// (tgid, tid, sig) -> int
pub const SYS_TGKILL: usize = 234;

/// Create an epoll instance
/// (flags) -> int
pub const SYS_EPOLL_CREATE1: usize = 291;

/// Duplicate FD with flags
/// (oldfd, newfd, flags) -> int
pub const SYS_DUP3: usize = 292;

/// Create pipe with flags
/// (pipefd, flags) -> int
pub const SYS_PIPE2: usize = 293;

/// Get random bytes
/// (buf, count, flags) -> ssize_t
pub const SYS_GETRANDOM: usize = 318;

// =============================================================================
// io_uring Syscalls (425-427)
// =============================================================================

/// Create an io_uring instance
/// (entries, params) -> ring_fd
pub const SYS_IO_URING_SETUP: usize = 425;

/// Submit operations and/or wait for completions
/// (ring_fd, to_submit, min_complete, flags, sig) -> submitted_count
pub const SYS_IO_URING_ENTER: usize = 426;

/// Register resources with io_uring
/// (ring_fd, opcode, arg, nr_args) -> int
pub const SYS_IO_URING_REGISTER: usize = 427;

// =============================================================================
// Zscapek Custom Extensions (1000-1999)
// =============================================================================

/// Write debug message to kernel log
/// (buf, len) -> ssize_t
pub const SYS_DEBUG_LOG: usize = 1000;

/// Get framebuffer info
/// (info_ptr) -> i32
pub const SYS_GET_FB_INFO: usize = 1001;

/// Map framebuffer into process address space
/// () -> addr
pub const SYS_MAP_FB: usize = 1002;

/// Read raw keyboard scancode (non-blocking)
/// () -> i32 (scancode or -EAGAIN)
pub const SYS_READ_SCANCODE: usize = 1003;

/// Read ASCII character from input buffer (blocking)
/// () -> i32 (char or -errno)
pub const SYS_GETCHAR: usize = 1004;

/// Write character to console
/// (c: u8) -> i32
pub const SYS_PUTCHAR: usize = 1005;

// =============================================================================
// Input/Mouse Syscalls (1010-1019)
// =============================================================================

/// Read next input event (non-blocking)
/// (event_ptr) -> i32 (0 = success, -EAGAIN = no event)
pub const SYS_READ_INPUT_EVENT: usize = 1010;

/// Get current cursor position
/// (position_ptr) -> i32 (0 = success)
pub const SYS_GET_CURSOR_POSITION: usize = 1011;

/// Set cursor bounds (screen dimensions)
/// (bounds_ptr) -> i32 (0 = success)
pub const SYS_SET_CURSOR_BOUNDS: usize = 1012;

/// Set input mode (relative/absolute/raw)
/// (mode) -> i32 (0 = success)
pub const SYS_SET_INPUT_MODE: usize = 1013;

// =============================================================================
// IPC & Microkernel Syscalls (1020-1029)
// =============================================================================

/// Send an IPC message to a process (blocking)
/// (target_pid, msg_ptr, len) -> i32
pub const SYS_SEND: usize = 1020;

/// Receive an IPC message (blocking)
/// (msg_ptr, len) -> i32 (returns sender_pid)
pub const SYS_RECV: usize = 1021;

/// Wait for a hardware interrupt (blocking)
/// (irq) -> i32
pub const SYS_WAIT_INTERRUPT: usize = 1022;

/// Connect kernel logger to IPC backend
/// () -> i32
pub const SYS_REGISTER_IPC_LOGGER: usize = 1025;

/// Register the current process as a named service
/// (name_ptr, name_len) -> 0 or -errno
pub const SYS_REGISTER_SERVICE: usize = 1026;

/// Lookup a service PID by name
/// (name_ptr, name_len) -> pid or -errno
pub const SYS_LOOKUP_SERVICE: usize = 1027;

// =============================================================================
// DMA/MMIO Syscalls (1030-1039)
// =============================================================================

/// Map physical MMIO region into userspace
/// (phys_addr, size) -> virt_addr
/// Requires Mmio capability for the physical address range
pub const SYS_MMAP_PHYS: usize = 1030;

/// Allocate DMA-capable memory with known physical address
/// (result_ptr, page_count) -> 0 or -errno
/// Returns DmaAllocResult{virt_addr, phys_addr, size} at result_ptr
/// Requires DmaMemory capability for the page count
pub const SYS_ALLOC_DMA: usize = 1031;

/// Free DMA memory previously allocated with SYS_ALLOC_DMA
/// (virt_addr, size) -> 0 or -errno
pub const SYS_FREE_DMA: usize = 1032;

/// Enumerate PCI devices
/// (buf_ptr, max_count) -> actual_count
/// Copies up to max_count PciDeviceInfo structs to buf_ptr
pub const SYS_PCI_ENUMERATE: usize = 1033;

/// Read PCI configuration space register
/// (bus, device, func, offset) -> value (32-bit)
/// Requires PciConfig capability for the device
pub const SYS_PCI_CONFIG_READ: usize = 1034;

/// Write PCI configuration space register
/// (bus, device, func, offset, value) -> 0 or -errno
/// Requires PciConfig capability for the device
pub const SYS_PCI_CONFIG_WRITE: usize = 1035;
