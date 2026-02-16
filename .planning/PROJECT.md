# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Shipped v1.2 with 330+ syscalls implemented across 12 categories including file sync, zero-copy I/O, memory management extensions, modern process control, signal handling, POSIX timers, inotify file monitoring, Linux capabilities, and seccomp syscall filtering with a classic BPF interpreter. Dual-architecture (x86_64 + aarch64) with 203K LOC Zig and comprehensive integration test suite.

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
- v File synchronization (fsync, fdatasync, sync, syncfs as validation-only) -- v1.2
- v Advanced file operations (fallocate mode=0+KEEP_SIZE, renameat2 NOREPLACE+EXCHANGE) -- v1.2
- v Zero-copy I/O (splice, tee, vmsplice, copy_file_range with 64KB kernel buffers) -- v1.2
- v Memory management extensions (memfd_create PMM-backed, mremap resize/move, msync validation) -- v1.2
- v Modern process control (clone3 struct-based, waitid with siginfo_t) -- v1.2
- v Signal handling extensions (rt_sigtimedwait, rt_sigqueueinfo, rt_tgsigqueueinfo, clock_nanosleep) -- v1.2
- v epoll_pwait with atomic signal mask handling -- v1.2
- v inotify file monitoring (init1, add_watch, rm_watch, event read with VFS hooks) -- v1.2
- v POSIX timers (timer_create/settime/gettime/getoverrun/delete with scheduler integration) -- v1.2
- v Linux capabilities (capget/capset with v1+v3 formats, per-process bitmasks) -- v1.2
- v Seccomp syscall filtering (STRICT mode, FILTER mode with classic BPF interpreter) -- v1.2
- v Test coverage expansion (20 tests for lchown, settimeofday, signals, select/epoll edges, madvise, mincore, rlimit) -- v1.2

### Active

(No active requirements -- next milestone not yet defined)

### Out of Scope

- Extended attributes (setxattr family) -- complex, depends on security model not yet designed
- Module loading (init_module, delete_module) -- microkernel, not applicable
- Legacy/deprecated syscalls (uselib, _sysctl, create_module, get_kernel_syms, query_module, nfsservctl) -- removed from modern Linux
- ptrace -- very complex, debugger support is a separate project
- io_uring expansion -- already has basic support, full completion is a separate effort
- Swap management (swapon, swapoff) -- no swap subsystem planned
- Filesystem-level features (pivot_root, mount/umount rework) -- VFS redesign is separate
- SFS nested subdirectory support -- fundamental SFS architecture change
- SFS file count limit increase (64 max) -- requires on-disk format change
- Multi-CPU affinity enforcement -- single-CPU kernel, separate project
- Full seccomp BPF JIT -- v1.2 implements interpreter only, JIT is future work
- Container/namespace support (unshare, setns) -- requires kernel architecture changes
- True zero-copy I/O via VFS page cache -- splice/sendfile use 64KB kernel buffers for now

## Context

Shipped v1.2 with 203,161 LOC Zig across x86_64 and aarch64.
Tech stack: Zig 0.16.x, custom UEFI bootloader, QEMU TCG.
330+ syscalls implemented. Comprehensive integration test suite on both architectures.

v1.0 shipped 300+ syscalls from ~190 baseline. v1.1 resolved all 14 v1.0 tech debt items
(SFS deadlock, yield-loop blocking, hard links, symlinks, timestamps, SEM_UNDO).
v1.2 added 31 new syscalls across 12 categories: file sync, zero-copy I/O, memory management,
modern process control, signal handling, POSIX timers, inotify, capabilities, and seccomp.

Remaining tech debt (15 items from v1.2):
- inotify VFS hooks incomplete (ftruncate events don't fire)
- rt_sigsuspend pending signal race (architectural fix needed)
- Per-process rlimit persistence not implemented
- SIGSYS delivery not implemented for seccomp (ENOSYS used instead)
- Bitmask-only signal tracking (no siginfo queue)
- POSIX timer 10ms resolution, 8 per process limit
- Zero-copy I/O uses kernel buffers (true zero-copy requires page cache)
- signalfd uses 10ms polling timeout
- fchdir syscall not implemented
- See milestones/v1.2-MILESTONE-AUDIT.md for full list

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
| File sync as validation-only | No buffer cache in zk, data already on disk | v Good -- correct semantics |
| 64KB kernel buffer for zero-copy I/O | True zero-copy requires VFS page cache | -- Revisit -- same pattern as sendfile |
| Classic BPF interpreter for seccomp | Simpler than eBPF, sufficient for syscall filtering | v Good -- MVP approach |
| Seccomp ENOSYS instead of SIGSYS | Signal queue integration complex, ENOSYS sufficient | -- Revisit -- correct behavior deferred |
| Per-process capability bitmasks | All processes run as root, CAP_FULL_SET default | v Good -- foundation for future restriction |
| POSIX timer scheduler integration | Inline expiration check in processIntervalTimers | v Good -- minimal overhead |
| Bitmask-only signal tracking | No per-thread siginfo queue for MVP | -- Revisit -- limits rt_sigqueueinfo usefulness |
| inotify MVP with EAGAIN reads | epoll integration is primary use case | v Good -- avoids blocking complexity |

---
*Last updated: 2026-02-16 after v1.2 milestone*
