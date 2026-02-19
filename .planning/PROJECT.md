# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Shipped v1.3 with 330+ syscalls across 12 categories. Signal infrastructure rebuilt from bitmask-only to full siginfo queues with direct wakeup. Timer subsystem upgraded to 1ms resolution with 32-timer capacity and SIGEV_THREAD/SIGEV_THREAD_ID support. VFS page cache enables true zero-copy splice/sendfile/tee/copy_file_range. Dual-architecture (x86_64 + aarch64) with 206K LOC Zig and comprehensive integration test suite.

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

- v Complete inotify VFS hooks (ftruncate, write, close, link, symlink) -- v1.3
- v Fix rt_sigsuspend pending signal race (deferred mask restoration) -- v1.3
- v Implement per-process rlimit persistence (soft/hard pairs) -- v1.3
- v SIGSYS delivery for seccomp SECCOMP_RET_KILL -- v1.3
- v Per-thread siginfo queue with SA_SIGINFO handler support -- v1.3
- v POSIX timer resolution 1ms (1000Hz) and limit increased to 32 -- v1.3
- v VFS page cache with true zero-copy splice/sendfile/tee/copy_file_range -- v1.3
- v signalfd direct wakeup via sched.waitOn/unblock -- v1.3
- v fchdir syscall via DirTag enum mapping -- v1.3
- v mremap invalid address edge case verified (no fix needed) -- v1.3
- v inotify capacity increased (instances, watches, queued events) -- v1.3
- v SeccompData instruction_pointer via getReturnRip() -- v1.3
- v inotify event queue overflow with IN_Q_OVERFLOW -- v1.3
- v SIGEV_THREAD/SIGEV_THREAD_ID for POSIX timers -- v1.3
- v clock_nanosleep sub-10ms granularity -- v1.3

### Active

- [ ] TCP congestion control (slow start, congestion avoidance, fast retransmit/recovery per RFC 5681)
- [ ] Dynamic TCP window management (replace fixed 8KB with proper sliding windows and flow control)
- [ ] Socket API completeness (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL, SO_REUSEPORT, TCP_CORK, raw socket recv)
- [ ] Buffer and queue sizing (configurable SO_SNDBUF/SO_RCVBUF, increased accept backlog, RX queue expansion)

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

## Current Milestone: v1.4 Network Stack Hardening

**Goal:** Harden the existing TCP/UDP networking stack with proper congestion control, dynamic window management, complete socket API flags, and configurable buffer sizing.

**Target features:**
- TCP congestion control (RFC 5681: slow start, congestion avoidance, fast retransmit, fast recovery)
- Dynamic TCP send/receive windows replacing fixed 8KB buffers
- Socket message flags (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL) and options (SO_REUSEPORT, TCP_CORK)
- Raw socket recv implementation
- Configurable SO_SNDBUF/SO_RCVBUF with per-socket buffer management
- Increased accept backlog and RX queue capacity

## Last Milestone: v1.3 Tech Debt Cleanup (Shipped 2026-02-19)

Resolved all 16 tech debt items from v1.0-v1.2. Signal infrastructure rebuilt, timer subsystem upgraded, VFS page cache built. See MILESTONES.md for details.

## Context

Shipped v1.3 with 206,097 LOC Zig across x86_64 and aarch64.
Tech stack: Zig 0.16.x, custom UEFI bootloader, QEMU TCG.
330+ syscalls implemented. Comprehensive integration test suite on both architectures.

v1.0 shipped 300+ syscalls from ~190 baseline. v1.1 resolved all 14 v1.0 tech debt items.
v1.2 added 31 new syscalls across 12 categories. v1.3 resolved all 16 v1.2 tech debt items
(siginfo queues, signalfd wakeup, inotify VFS hooks, 1ms timers, page cache zero-copy).
Four milestones shipped over 14 days with 73 plans across 35 phases.

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
| signalfd 10ms polling instead of direct wakeup | Direct wakeup requires global watcher registry | v Fixed v1.3 -- sched.waitOn/unblock pattern |
| sendfile 64KB buffer instead of zero-copy | True zero-copy requires VFS page cache refactor | v Fixed v1.3 -- page cache zero-copy |
| WaitQueue replaces blocked_readers atomics | Cleaner lifecycle management | v Good -- consistent pattern |
| Process lifecycle includes SEM_UNDO cleanup | After virt_pci but before resource freeing | v Good -- POSIX-compliant |
| File sync as validation-only | No buffer cache in zk, data already on disk | v Good -- correct semantics |
| 64KB kernel buffer for zero-copy I/O | True zero-copy requires VFS page cache | v Fixed v1.3 -- page cache with read-ahead |
| Classic BPF interpreter for seccomp | Simpler than eBPF, sufficient for syscall filtering | v Good -- MVP approach |
| Seccomp ENOSYS instead of SIGSYS | Signal queue integration complex, ENOSYS sufficient | v Fixed v1.3 -- SIGSYS delivered via siginfo queue |
| Per-process capability bitmasks | All processes run as root, CAP_FULL_SET default | v Good -- foundation for future restriction |
| POSIX timer scheduler integration | Inline expiration check in processIntervalTimers | v Good -- minimal overhead |
| Bitmask-only signal tracking | No per-thread siginfo queue for MVP | v Fixed v1.3 -- SigInfoQueue with SA_SIGINFO |
| inotify MVP with EAGAIN reads | epoll integration is primary use case | v Good -- avoids blocking complexity |

| 1000Hz timer (1ms ticks) | Sub-10ms timer resolution needed | v Good v1.3 -- all tick constants updated |
| Per-thread SigInfoQueue (32 entries) | Signals need metadata (si_code, si_pid) | v Good v1.3 -- enables SA_SIGINFO, SIGSYS |
| VFS page cache (256-bucket, 1024 pages) | Zero-copy needs page references not buffer copies | v Good v1.3 -- splice/sendfile/tee/copy_file_range |
| SIGEV_THREAD same as SIGEV_SIGNAL at kernel level | glibc handles thread callback wrapping | v Good v1.3 -- matches Linux kernel behavior |

---
*Last updated: 2026-02-19 after v1.4 milestone start*
