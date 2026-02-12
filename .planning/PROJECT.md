# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Shipped v1.1 with 300+ syscalls implemented, hardened SFS filesystem with proper locking/links/symlinks/timestamps, WaitQueue-based blocking for all event FDs and IPC, and full SEM_UNDO lifecycle management. Dual-architecture (x86_64 + aarch64) with 306 integration tests.

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
- v Integration test harness (306 tests, TAP output, dual-arch CI) -- v1.0
- v Trivial stub syscalls (madvise, mlock, mincore, scheduling stubs, resource limits, signal ops) -- v1.0
- v I/O multiplexing (epoll_wait real dispatch, select/pselect6/ppoll with FileOps.poll) -- v1.0
- v Vectored and positional I/O (readv, preadv, pwritev, preadv2/pwritev2, sendfile) -- v1.0
- v Event notification FDs (eventfd, timerfd, signalfd with epoll integration) -- v1.0
- v Process credentials (fsuid/fsgid, setreuid/setregid, getgroups/setgroups, chown family) -- v1.0
- v Filesystem extras (utimensat, futimesat, readlinkat, linkat, symlinkat, *at double-copy fix) -- v1.0
- v Socket extras (socketpair, shutdown, sendto/recvfrom, sendmsg/recvmsg, IrqLock fix) -- v1.0
- v Process control (prctl PR_SET_NAME/PR_GET_NAME, sched_setaffinity/getaffinity) -- v1.0
- v SysV IPC (shmget/shmat/shmdt/shmctl, semget/semop/semctl, msgget/msgsnd/msgrcv/msgctl) -- v1.0
- v setregid POSIX permission checks (unprivileged cannot set arbitrary GIDs) -- v1.1
- v SFS fchown via FileOps.chown -- v1.1
- v copyStringFromUser stack buffer support (isValidUserPtr + assembly fixup) -- v1.1
- v SFS close deadlock fix (io_lock + alloc_lock restructuring) -- v1.1
- v SFS hard link support (link/linkat with global nlink sync) -- v1.1
- v SFS symbolic link support (symlink/symlinkat/readlink/readlinkat) -- v1.1
- v SFS timestamp modification (utimensat/futimesat with UTIME_OMIT) -- v1.1
- v WaitQueue-based blocking for timerfd (replaces yield-loop) -- v1.1
- v WaitQueue-based blocking for signalfd (10ms polling) -- v1.1
- v WaitQueue-based blocking for semop/msgsnd/msgrcv -- v1.1
- v SEM_UNDO per-process tracking with process exit cleanup -- v1.1
- v semop IPC_NOWAIT returns EAGAIN (non-blocking path) -- v1.1
- v sendfile 64KB optimized buffer (16x improvement) -- v1.1
- v AT_SYMLINK_NOFOLLOW in utimensat -- v1.1
- v dup3 O_CLOEXEC, accept4 flags, getrlimit/setrlimit, sigaltstack, statfs/fstatfs, getresuid/getresgid -- v1.1

### Active

## Current Milestone: v1.2 Systematic Syscall Coverage

**Goal:** Audit the Linux ABI for commonly-needed missing syscalls, implement the highest-value ones, and expand integration test coverage for both new and existing syscalls.

**Target features:**
- Systematic audit of missing Linux syscalls vs implemented
- Implementation of highest-value missing syscalls
- Integration tests for new syscalls and untested existing ones
- Dual-arch (x86_64 + aarch64) for all additions

### Out of Scope

- Extended attributes (setxattr family) -- complex, depends on security model not yet designed
- Module loading (init_module, delete_module) -- microkernel, not applicable
- Legacy/deprecated syscalls (uselib, _sysctl, create_module, get_kernel_syms, query_module, nfsservctl) -- removed from modern Linux
- ptrace -- very complex, debugger support is a separate project
- io_uring expansion -- already has basic support, full completion is a separate effort
- Swap management (swapon, swapoff) -- no swap subsystem planned
- Filesystem-level features (pivot_root, mount/umount rework) -- VFS redesign is separate
- Timer expiry for setitimer/getitimer -- signal delivery from timer interrupt not wired yet, deferred
- SFS nested subdirectory support -- fundamental SFS architecture change
- SFS file count limit increase (64 max) -- requires on-disk format change
- Multi-CPU affinity enforcement -- single-CPU kernel, separate project

## Context

Shipped v1.1 with 194,415 LOC Zig across x86_64 and aarch64.
Tech stack: Zig 0.16.x, custom UEFI bootloader, QEMU TCG.
306 integration tests (all passing or documented-skip, 0 failing).

v1.0 shipped 300+ syscalls from ~190 baseline. v1.1 resolved all 14 tech debt items from v1.0:
- SFS deadlock eliminated via io_lock + alloc_lock restructuring
- All yield-loop blocking replaced with WaitQueue infrastructure
- SFS expanded with hard links, symlinks, timestamps
- SEM_UNDO lifecycle fully implemented
- sendfile optimized from 4KB to 64KB buffer

Remaining tech debt (3 items from v1.1):
- signalfd uses 10ms polling timeout instead of direct signal delivery wakeup
- sendfile uses 64KB buffer copy, not true zero-copy (requires VFS page cache)
- aarch64 test suite timeout in later tests (pre-existing infrastructure issue)

## Constraints

- **Dual-arch**: Every syscall must work on both x86_64 and aarch64. No x86-only implementations.
- **ABI correctness**: Syscall numbers must match Linux ABI for each architecture. Use 500+ range only for legacy compat on aarch64.
- **Test coverage**: Every new syscall gets at least one integration test in the test runner.
- **No regressions**: Existing passing tests must continue to pass after each phase.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Trivial stubs before real implementations | Quick wins boost coverage count | v Good -- 14 stubs in 1 day |
| epoll before SysV IPC | I/O multiplexing more commonly needed | v Good -- enabled eventfd/timerfd/signalfd |
| UID/GID tracking as infrastructure | Many syscalls depend on credential state | v Good -- fsuid/fsgid auto-sync clean |
| Skip ptrace entirely | Extremely complex, separate project | v Good -- kept scope focused |
| Kernel-only memory for SysV shared memory | SFS had close deadlock and 64-file limit | v Good -- PMM allocation worked |
| initInPlace for large structs | 11KB UnixSocketPair overflows 64KB stack on aarch64 | v Good -- pattern for any struct > 4KB |
| SFS deadlock fix EARLY in v1.1 | Unblocks 16+ tests, prerequisite for SFS features | v Good -- enabled Phase 12 |
| io_lock ordering: alloc_lock before io_lock | Prevents deadlock in nested lock scenarios | v Good -- consistent two-phase locking |
| Global nlink sync for hard links | All entries sharing start_block need identical nlink | v Good -- POSIX-compliant behavior |
| SFS timestamps as u32 seconds | Nanosecond precision lost, acceptable for SFS | v Good -- simpler implementation |
| signalfd 10ms polling instead of direct wakeup | Direct wakeup requires global watcher registry | -- Revisit -- better than yield-loop but not ideal |
| sendfile 64KB buffer instead of zero-copy | True zero-copy requires VFS page cache refactor | -- Revisit -- 16x improvement is significant |
| WaitQueue replaces blocked_readers atomics | Cleaner lifecycle management | v Good -- consistent pattern |
| Process lifecycle includes SEM_UNDO cleanup | After virt_pci but before resource freeing | v Good -- POSIX-compliant |

---
*Last updated: 2026-02-11 after v1.1 milestone*
