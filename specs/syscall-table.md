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
| 9 | sys_mmap | (addr, len, prot, flags, fd, off) -> addr | 005 |
| 10 | sys_mprotect | (addr, len, prot) -> int | 006 |
| 11 | sys_munmap | (addr, len) -> int | 005 |
| 12 | sys_brk | (brk) -> addr | 005 |
| 24 | sys_sched_yield | () -> int | 007 |
| 35 | sys_nanosleep | (req, rem) -> int | 007 |
| 39 | sys_getpid | () -> pid_t | 005 |
| 41 | sys_socket | (domain, type, protocol) -> fd | 007 |
| 44 | sys_sendto | (fd, buf, len, flags, addr, addrlen) -> ssize_t | 007 |
| 45 | sys_recvfrom | (fd, buf, len, flags, addr, addrlen) -> ssize_t | 007 |
| 57 | sys_fork | () -> pid_t | Future |
| 59 | sys_execve | (path, argv, envp) -> int | 006 |
| 60 | sys_exit | (code) -> noreturn | 005 |
| 61 | sys_wait4 | (pid, wstatus, options, rusage) -> pid_t | 007 |
| 102 | sys_getuid | () -> uid_t | 005 |
| 104 | sys_getgid | () -> gid_t | 005 |
| 110 | sys_getppid | () -> pid_t | 005 |
| 158 | sys_arch_prctl | (code, addr) -> int | 006 |
| 228 | sys_clock_gettime | (clk_id, tp) -> int | 007 |
| 231 | sys_exit_group | (code) -> noreturn | 005 |
| 318 | sys_getrandom | (buf, count, flags) -> ssize_t | 007 |

## ZigK Custom Extensions

Reserved range: 1000-1999

| Number | Name | Signature | Implementing Spec |
|--------|------|-----------|-------------------|
| 1000 | sys_debug_log | (buf, len) -> ssize_t | 007 |
| 1001 | sys_map_fb | (info_ptr) -> addr | 003 |
| 1002 | sys_read_scancode | () -> i32 | 003 |

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

## Notes

- All standard syscalls follow Linux x86_64 ABI for maximum compatibility
- Custom ZigK extensions (1000+) are for kernel-specific features not covered by Linux syscalls
- Error codes are returned as negative values (e.g., -ENOENT = -2)
- Syscall implementations may be spread across multiple specs; the "Implementing Spec" column indicates primary ownership
