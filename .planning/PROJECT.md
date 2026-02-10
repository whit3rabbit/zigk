# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Shipped v1 with ~300+ syscalls implemented (up from ~190), covering credential management, I/O multiplexing, event notification FDs, vectored I/O, filesystem timestamps, BSD socket extras, process control, and SysV IPC. Dual-architecture (x86_64 + aarch64) with 306 integration tests.

## Core Value

Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.

## Requirements

### Validated

- v Syscall dispatch infrastructure (comptime table, dual-arch numbers) -- existing
- v File I/O syscalls (open, read, write, close, lseek, dup, dup2, pipe, fcntl, pread64, writev, flock) -- existing
- v File info syscalls (stat, fstat, lstat, chmod, access, truncate, rename, link, symlink, readlink) -- existing
- v Directory syscalls (mkdir, rmdir, chdir, getcwd, getdents64) -- existing
- v *at family syscalls (openat, fstatat, mkdirat, unlinkat, renameat, fchmodat, faccessat) -- existing
- v Memory syscalls (mmap, munmap, brk, mprotect) -- existing
- v Process syscalls (fork, execve, clone, wait4, exit, exit_group, getpid, getppid) -- existing
- v Process groups/sessions (setpgid, getpgid, getpgrp, setsid, getsid) -- existing
- v Signal syscalls (rt_sigaction, rt_sigprocmask, rt_sigreturn, kill, tgkill) -- existing
- v Timers/alarms (nanosleep, clock_gettime, clock_getres, gettimeofday, alarm, pause, getitimer, setitimer) -- existing
- v Misc (uname, umask, getrandom, sysinfo, times, poll) -- existing
- v Network syscalls (socket, bind, listen, accept, connect, send, recv, setsockopt, getsockopt) -- existing
- v Integration test harness (306 tests, TAP output, dual-arch CI) -- v1
- v Trivial stub syscalls (madvise, mlock, mincore, scheduling stubs, resource limits, signal ops) -- v1
- v I/O multiplexing (epoll_wait real dispatch, select/pselect6/ppoll with FileOps.poll) -- v1
- v Vectored and positional I/O (readv, preadv, pwritev, preadv2/pwritev2, sendfile) -- v1
- v Event notification FDs (eventfd, timerfd, signalfd with epoll integration) -- v1
- v Process credentials (fsuid/fsgid, setreuid/setregid, getgroups/setgroups, chown family) -- v1
- v Filesystem extras (utimensat, futimesat, readlinkat, linkat, symlinkat, *at double-copy fix) -- v1
- v Socket extras (socketpair, shutdown, sendto/recvfrom, sendmsg/recvmsg, IrqLock fix) -- v1
- v Process control (prctl PR_SET_NAME/PR_GET_NAME, sched_setaffinity/getaffinity) -- v1
- v SysV IPC (shmget/shmat/shmdt/shmctl, semget/semop/semctl, msgget/msgsnd/msgrcv/msgctl) -- v1

### Active

## Current Milestone: v1.1 Hardening & Debt Cleanup

**Goal:** Fix all known bugs, eliminate tech debt from v1, and fill behavioral gaps (proper blocking, wait queues, SFS reliability).

**Target features:**
- Fix kernel bugs (setregid permissions, SFS fchown, copyStringFromUser stack buffers)
- Fix SFS close deadlock affecting 16+ tests
- Replace yield-loop blocking with proper wait queues (timerfd, signalfd)
- Implement blocking behavior for semop/msgsnd/msgrcv
- Implement SEM_UNDO tracking
- Add sendfile zero-copy path
- Add SFS link/symlink/timestamp support
- Fix event FD test pointer casting issues
- Verify/implement unchecked stub syscalls (dup3, accept4, getrlimit, setrlimit, sigaltstack, statfs, fstatfs, getresuid/getresgid)
- Fix AT_SYMLINK_NOFOLLOW for utimensat
- Complete Phase 6 verification documentation

### Out of Scope

- Extended attributes (setxattr family) -- complex, depends on security model not yet designed
- Module loading (init_module, delete_module) -- microkernel, not applicable
- Legacy/deprecated syscalls (uselib, _sysctl, create_module, get_kernel_syms, query_module, nfsservctl) -- removed from modern Linux
- ptrace -- very complex, debugger support is a separate project
- io_uring expansion -- already has basic support, full completion is a separate effort
- Swap management (swapon, swapoff) -- no swap subsystem planned
- Filesystem-level features (pivot_root, mount/umount rework) -- VFS redesign is separate
- Timer expiry for setitimer/getitimer -- signal delivery from timer interrupt not wired yet, deferred

## Context

Shipped v1 with 192,637 LOC Zig across x86_64 and aarch64.
Tech stack: Zig 0.16.x, custom UEFI bootloader, QEMU TCG.
306 integration tests (278-280 passing, 26-28 skipped, 0 failing).

Known tech debt from v1 (14 items):
- SFS filesystem close deadlock after 50+ operations (affects ~16 tests)
- timerfd/signalfd blocking reads use yield loops instead of proper wait queues
- sendfile uses 4KB kernel buffer copy, not true zero-copy
- SEM_UNDO flag accepted but not tracked
- semop/msgsnd/msgrcv return EAGAIN/ENOMSG instead of blocking
- copyStringFromUser rejects stack-allocated buffers (1 test skipped)
- Phase 6 missing formal VERIFICATION.md

IrqLock socket initialization bug fixed in v1 (Phase 7).
*at syscall double-copy EFAULT bug fixed in v1 (Phase 6).
aarch64 copy_from_user fixup and TTBR0 exec bug fixed pre-v1.

## Constraints

- **Dual-arch**: Every syscall must work on both x86_64 and aarch64. No x86-only implementations.
- **ABI correctness**: Syscall numbers must match Linux ABI for each architecture. Use 500+ range only for legacy compat on aarch64.
- **Test coverage**: Every new syscall gets at least one integration test in the test runner.
- **No regressions**: Existing 306 passing tests must continue to pass after each phase.
- **SFS deadlock**: Tests creating many SFS files must account for the known deadlock. Prefer kernel-memory-based tests where possible.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Trivial stubs before real implementations | Quick wins boost coverage count and let more programs probe without ENOSYS crashes | Good -- 14 stubs in 1 day, unblocked later phases |
| epoll before SysV IPC | I/O multiplexing is more commonly needed by real programs than legacy IPC | Good -- epoll foundation enabled eventfd/timerfd/signalfd integration |
| UID/GID tracking as infrastructure | Many syscalls (chown, setuid, access checks) depend on per-process credential state | Good -- fsuid/fsgid auto-sync worked cleanly |
| Skip ptrace entirely | Extremely complex, separate debugger project | Good -- kept scope focused |
| Polling-based timerfd expiration | Simpler MVP, avoids IoRequest/TimerWheel complexity | Revisit -- yield loops burn CPU, need proper wait queues |
| Kernel-only memory for SysV shared memory | SFS has close deadlock and 64-file limit | Good -- PMM allocation with MAP_DEVICE flag worked |
| initInPlace for large structs | UnixSocketPair (11KB) overflows 64KB kernel stack on aarch64 | Good -- pattern should be used for any struct > 4KB |
| SEM_UNDO deferred | Requires per-process undo lists and exit cleanup | Revisit -- needed for Postgres compatibility |

---
*Last updated: 2026-02-09 after v1.1 milestone started*
