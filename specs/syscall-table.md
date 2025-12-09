# ZigK Authoritative Syscall Table

This is the single source of truth for all syscall numbers in ZigK.
All specifications MUST reference this table.

## Linux x86_64 ABI Syscalls

| Number | Name | Signature | Implementing Spec |
|--------|------|-----------|-------------------|
| 0 | sys_read | (fd, buf, count) -> ssize_t | 005 |
| 1 | sys_write | (fd, buf, count) -> ssize_t | 005 |
| 2 | sys_open | (path, flags, mode) -> fd | 007 |
| 3 | sys_close | (fd) -> int | 005 |
| 7 | sys_poll | (ufds, nfds, timeout) -> int | Future |
| 9 | sys_mmap | (addr, len, prot, flags, fd, off) -> addr | 005 |
| 10 | sys_mprotect | (addr, len, prot) -> int | 006 |
| 11 | sys_munmap | (addr, len) -> int | 005 |
| 12 | sys_brk | (brk) -> addr | 005 |
| 16 | sys_ioctl | (fd, cmd, arg) -> int | Future |
| 23 | sys_select | (nfds, readfds, writefds, exceptfds, timeout) -> int | Future |
| 24 | sys_sched_yield | () -> int | 007 |
| 33 | sys_dup2 | (oldfd, newfd) -> int | Future |
| 35 | sys_nanosleep | (req, rem) -> int | 007 |
| 39 | sys_getpid | () -> pid_t | 005 |
| 41 | sys_socket | (domain, type, protocol) -> fd | 007 |
| 42 | sys_connect | (fd, addr, addrlen) -> int | 010 |
| 43 | sys_accept | (fd, addr, addrlen) -> fd | 010 |
| 44 | sys_sendto | (fd, buf, len, flags, addr, addrlen) -> ssize_t | 007 |
| 45 | sys_recvfrom | (fd, buf, len, flags, addr, addrlen) -> ssize_t | 007 |
| 46 | sys_sendmsg | (fd, msg, flags) -> ssize_t | Future |
| 47 | sys_recvmsg | (fd, msg, flags) -> ssize_t | Future |
| 48 | sys_shutdown | (fd, how) -> int | Future |
| 49 | sys_bind | (fd, addr, addrlen) -> int | 007 |
| 50 | sys_listen | (fd, backlog) -> int | 010 |
| 51 | sys_getsockname | (fd, addr, addrlen) -> int | Future |
| 52 | sys_getpeername | (fd, addr, addrlen) -> int | Future |
| 54 | sys_setsockopt | (fd, level, optname, optval, optlen) -> int | 009 |
| 55 | sys_getsockopt | (fd, level, optname, optval, optlen) -> int | 009 |
| 57 | sys_fork | () -> pid_t | Future |
| 59 | sys_execve | (path, argv, envp) -> int | 006 |
| 60 | sys_exit | (code) -> noreturn | 005 |
| 61 | sys_wait4 | (pid, wstatus, options, rusage) -> pid_t | 007 |
| 63 | sys_uname | (name) -> int | Future |
| 72 | sys_fcntl | (fd, cmd, arg) -> int | Future |
| 102 | sys_getuid | () -> uid_t | 005 |
| 104 | sys_getgid | () -> gid_t | 005 |
| 110 | sys_getppid | () -> pid_t | 005 |
| 158 | sys_arch_prctl | (code, addr) -> int | 006 |
| 170 | sys_gethostname | (name, len) -> int | Future |
| 171 | sys_sethostname | (name, len) -> int | Future |
| 228 | sys_clock_gettime | (clk_id, tp) -> int | 007 |
| 231 | sys_exit_group | (code) -> noreturn | 005 |
| 232 | sys_epoll_wait | (epfd, events, maxevents, timeout) -> int | Future |
| 233 | sys_epoll_ctl | (epfd, op, fd, event) -> int | Future |
| 257 | sys_openat | (dfd, filename, flags, mode) -> int | Future |
| 291 | sys_epoll_create1 | (flags) -> int | Future |
| 318 | sys_getrandom | (buf, count, flags) -> ssize_t | 007 |

## ZigK Custom Extensions

Reserved range: 1000-1999

| Number | Name | Signature | Implementing Spec |
|--------|------|-----------|-------------------|
| 1000 | sys_debug_log | (buf, len) -> ssize_t | 007 |
| 1001 | sys_get_fb_info | (info_ptr) -> i32 | 003 |
| 1002 | sys_map_fb | () -> addr | 003 |
| 1003 | sys_read_scancode | () -> i32 | 003 |
| 1004 | sys_getchar | () -> i32 | 003 |
| 1005 | sys_putchar | (c: u8) -> i32 | 003 |

## Register Convention

```
Entry:
  RAX = syscall number
  RDI = arg1, RSI = arg2, RDX = arg3
  R10 = arg4, R8 = arg5, R9 = arg6

Return:
  RAX = result or -errno
  RCX, R11 = destroyed
```

## Error Codes

| Errno | Value | Description |
|-------|-------|-------------|
| EPERM | 1 | Operation not permitted |
| ENOENT | 2 | No such file or directory |
| ESRCH | 3 | No such process |
| EINTR | 4 | Interrupted system call |
| EIO | 5 | I/O error |
| EBADF | 9 | Bad file descriptor |
| ECHILD | 10 | No child processes |
| EAGAIN | 11 | Resource temporarily unavailable |
| ENOMEM | 12 | Out of memory |
| EACCES | 13 | Permission denied |
| EFAULT | 14 | Bad address |
| EINVAL | 22 | Invalid argument |
| EMFILE | 24 | Too many open files |
| ENOSYS | 38 | Function not implemented |
| ENOTSOCK | 88 | Socket operation on non-socket |
| ESOCKTNOSUPPORT | 94 | Socket type not supported |
| EAFNOSUPPORT | 97 | Address family not supported |
| EADDRINUSE | 98 | Address already in use |
| ENETDOWN | 100 | Network is down |
| ENETUNREACH | 101 | Network is unreachable |
| ECONNRESET | 104 | Connection reset by peer |
| EISCONN | 106 | Transport endpoint is already connected |
| ENOTCONN | 107 | Transport endpoint is not connected |
| ETIMEDOUT | 110 | Connection timed out |
| ECONNREFUSED | 111 | Connection refused |

## Notes

- All standard syscalls follow Linux x86_64 ABI for maximum compatibility
- Custom ZigK extensions (1000+) are for kernel-specific features not covered by Linux syscalls
- Error codes are returned as negative values (e.g., -ENOENT = -2)
- Syscall implementations may be spread across multiple specs; the "Implementing Spec" column indicates primary ownership
