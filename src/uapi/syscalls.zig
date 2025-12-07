// ZigK Syscall Numbers
//
// Single source of truth for syscall numbers matching specs/syscall-table.md.
// All kernel and userland code MUST use these constants.
//
// Convention:
//   - Linux x86_64 ABI syscalls use standard numbers (0-999)
//   - ZigK custom extensions use range 1000-1999
//
// Register Convention (x86_64):
//   Entry: RAX=number, RDI=arg1, RSI=arg2, RDX=arg3, R10=arg4, R8=arg5, R9=arg6
//   Return: RAX=result or -errno

// =============================================================================
// Linux x86_64 ABI Syscalls
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

/// Yield the processor
/// () -> int
pub const SYS_SCHED_YIELD: usize = 24;

/// High-resolution sleep
/// (req, rem) -> int
pub const SYS_NANOSLEEP: usize = 35;

/// Get process ID
/// () -> pid_t
pub const SYS_GETPID: usize = 39;

/// Create a socket
/// (domain, type, protocol) -> fd
pub const SYS_SOCKET: usize = 41;

/// Bind a socket to an address
/// (fd, addr, addrlen) -> int
pub const SYS_BIND: usize = 49;

/// Send a message on a socket
/// (fd, buf, len, flags, addr, addrlen) -> ssize_t
pub const SYS_SENDTO: usize = 44;

/// Receive a message from a socket
/// (fd, buf, len, flags, addr, addrlen) -> ssize_t
pub const SYS_RECVFROM: usize = 45;

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

/// Get user ID
/// () -> uid_t
pub const SYS_GETUID: usize = 102;

/// Get group ID
/// () -> gid_t
pub const SYS_GETGID: usize = 104;

/// Get parent process ID
/// () -> pid_t
pub const SYS_GETPPID: usize = 110;

/// Set architecture-specific thread state
/// (code, addr) -> int
pub const SYS_ARCH_PRCTL: usize = 158;

/// Get time from a clock
/// (clk_id, tp) -> int
pub const SYS_CLOCK_GETTIME: usize = 228;

/// Exit all threads in process
/// (code) -> noreturn
pub const SYS_EXIT_GROUP: usize = 231;

/// Get random bytes
/// (buf, count, flags) -> ssize_t
pub const SYS_GETRANDOM: usize = 318;

// =============================================================================
// ZigK Custom Extensions (1000-1999)
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
