# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Currently at 190/420 (45%) of Linux x86_64 syscalls. The goal is to round out coverage to 70-80% by implementing missing syscalls in priority order -- trivial stubs first, then real implementations for program compatibility, then heavier subsystems like SysV IPC.

## Core Value

Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.

## Requirements

### Validated

- ✓ Syscall dispatch infrastructure (comptime table, dual-arch numbers) -- existing
- ✓ File I/O syscalls (open, read, write, close, lseek, dup, dup2, pipe, fcntl, pread64, writev, flock) -- existing
- ✓ File info syscalls (stat, fstat, lstat, chmod, access, truncate, rename, link, symlink, readlink) -- existing
- ✓ Directory syscalls (mkdir, rmdir, chdir, getcwd, getdents64) -- existing
- ✓ *at family syscalls (openat, fstatat, mkdirat, unlinkat, renameat, fchmodat, faccessat) -- existing
- ✓ Memory syscalls (mmap, munmap, brk, mprotect) -- existing
- ✓ Process syscalls (fork, execve, clone, wait4, exit, exit_group, getpid, getppid) -- existing
- ✓ Process groups/sessions (setpgid, getpgid, getpgrp, setsid, getsid) -- existing
- ✓ Signal syscalls (rt_sigaction, rt_sigprocmask, rt_sigreturn, kill, tgkill) -- existing
- ✓ Timers/alarms (nanosleep, clock_gettime, clock_getres, gettimeofday, alarm, pause, getitimer, setitimer) -- existing
- ✓ Misc (uname, umask, getrandom, sysinfo, times, poll) -- existing
- ✓ Network syscalls (socket, bind, listen, accept, connect, send, recv, setsockopt, getsockopt) -- existing
- ✓ Integration test harness (186 tests, TAP output, dual-arch CI) -- existing

### Active

- [ ] Trivial stub syscalls (30-40 syscalls returning defaults/ENOSYS/EPERM)
- [ ] I/O multiplexing (epoll_create, epoll_ctl, epoll_wait, select, pselect6, ppoll)
- [ ] Vectored and positional I/O (readv, preadv, pwritev, sendfile)
- [ ] Event/signal/timer file descriptors (eventfd, signalfd, timerfd_create/settime/gettime)
- [ ] Process credentials (UID/GID tracking, setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid, chown, fchown, lchown)
- [ ] Resource limits (getrlimit, setrlimit, prlimit64, getrusage)
- [ ] Scheduler queries (sched_getscheduler, sched_setscheduler, sched_getparam, sched_setparam, sched_get_priority_max/min, sched_rr_get_interval)
- [ ] Filesystem extras (utimensat, futimesat, readlinkat, fchownat, linkat, symlinkat, statfs, fstatfs)
- [ ] Socket extras (socketpair, shutdown, sendto, recvfrom, sendmsg, recvmsg)
- [ ] SysV IPC shared memory (shmget, shmat, shmctl, shmdt)
- [ ] SysV IPC semaphores (semget, semop, semctl)
- [ ] SysV IPC message queues (msgget, msgsnd, msgrcv, msgctl)
- [ ] Timer expiry (make getitimer/setitimer actually fire signals)
- [ ] Integration tests for all new syscalls (both architectures)

### Out of Scope

- Extended attributes (setxattr family) -- complex, depends on security model not yet designed
- Module loading (init_module, delete_module) -- monolithic kernel, not applicable
- Legacy/deprecated syscalls (uselib, _sysctl, create_module, get_kernel_syms, query_module, nfsservctl) -- removed from modern Linux
- ptrace -- very complex, debugger support is a separate project
- io_uring expansion -- already has basic support, full completion is a separate effort
- Swap management (swapon, swapoff) -- no swap subsystem planned
- Filesystem-level features (pivot_root, mount/umount rework) -- VFS redesign is separate

## Context

- Kernel runs on QEMU with UEFI boot, tested on both x86_64 (TCG) and aarch64
- aarch64 has fewer native Linux syscalls; legacy syscalls use 500+ compat range
- SFS filesystem has a close deadlock after 50+ operations and a 64-file limit -- SysV IPC shared memory will need kernel-only memory, not SFS
- Socket tests currently trigger a kernel panic (IrqLock initialization order) -- socket extras may be blocked until that is fixed
- The comptime dispatch table auto-registers handlers by matching SYS_NAME to sys_name -- adding a new syscall requires: number in uapi, handler function, and that's it
- Every SYS_* constant must have a unique number per architecture or the dispatch table silently drops one

## Constraints

- **Dual-arch**: Every syscall must work on both x86_64 and aarch64. No x86-only implementations.
- **ABI correctness**: Syscall numbers must match Linux ABI for each architecture. Use 500+ range only for legacy compat on aarch64.
- **Test coverage**: Every new syscall gets at least one integration test in the test runner.
- **No regressions**: Existing 166 passing tests must continue to pass after each phase.
- **SFS deadlock**: Tests creating many SFS files must account for the known deadlock. Prefer kernel-memory-based tests where possible.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Trivial stubs before real implementations | Quick wins boost coverage count and let more programs probe without ENOSYS crashes | -- Pending |
| epoll before SysV IPC | I/O multiplexing is more commonly needed by real programs than legacy IPC | -- Pending |
| UID/GID tracking as infrastructure | Many syscalls (chown, setuid, access checks) depend on per-process credential state | -- Pending |
| Skip ptrace entirely | Extremely complex, separate debugger project | -- Pending |

---
*Last updated: 2026-02-06 after initialization*
