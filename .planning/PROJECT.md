# ZK Kernel: POSIX Syscall Coverage

## What This Is

Systematic expansion of Linux/POSIX syscall coverage in the zk microkernel. Shipped v1.5 with 330+ syscalls across 12 categories plus hardened TCP/UDP networking with live loopback verification. TCP stack has RFC-compliant Reno congestion control, dynamic window management with SWS avoidance, configurable buffer sizing, full MSG flag support, and timer-driven retransmission. Dual-architecture (x86_64 + aarch64) with ~216K LOC Zig and comprehensive integration test suite (480 tests).

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
- v TCP congestion control (Reno: slow start, congestion avoidance, fast retransmit/recovery per RFC 5681, IW10 per RFC 6928) -- v1.4
- v Dynamic TCP window management (currentRecvWindow() in all ACKs, SWS avoidance, independent persist timer per RFC 1122) -- v1.4
- v Socket API completeness (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL with EINTR, SO_REUSEPORT, TCP_CORK, MSG_NOSIGNAL, raw socket blocking recv) -- v1.4
- v Buffer and queue sizing (SO_RCVBUF/SO_SNDBUF with Linux ABI doubling, RX queue 64, accept backlog 128) -- v1.4
- v Fix stale tcb.blocked_thread on EINTR, SO_RCVBUF/SO_SNDBUF pre-connect propagation, TCP_CORK mutex, raw socket MSG flags -- v1.5
- v Remove dead code (Tcb.send_acked, recvfromRaw/recvfromRaw6), fix slab_bench Zig 0.16.x compat -- v1.5
- v Close v1.4 documentation gaps (requirements checkboxes, SUMMARY frontmatter, ROADMAP formatting) -- v1.5
- v QEMU loopback networking for test environment (lo0 at 127.0.0.1, async packet queue, full TCP/IP stack) -- v1.5
- v Verify 8 network features under live loopback (zero-window, SWS, raw socket ICMP, SO_REUSEPORT, SIGPIPE, MSG flags) -- v1.5

### Active

(None -- between milestones)

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
- MSG_OOB / TCP urgent data -- RFC 6093 recommends against new implementations
- CUBIC/BBR congestion control -- zero benefit in QEMU loopback; add when real-hardware networking supported
- True dynamic buffer resize (heap-allocated TCB buffers) -- requires TCB struct refactor across 18 BUFFER_SIZE sites
- Multipath TCP (MPTCP) -- requires scheduler-level subflow management

## Last Milestone: v1.5 Tech Debt Cleanup (Shipped 2026-02-22)

Resolved all 18 v1.4 tech debt items. Fixed 4 TCP/raw socket defects, brought up loopback networking with full TCP/IP stack (fixing 10 pre-existing bugs), added 8 network verification tests, wired TCP timer system, removed dead code, and closed all documentation gaps. All 12 requirements satisfied. See MILESTONES.md for details.

## Context

Shipped v1.5 with ~216K LOC Zig across x86_64 and aarch64.
Tech stack: Zig 0.16.x, custom UEFI bootloader, QEMU TCG.
330+ syscalls implemented. Integration test suite: 480 tests (463 passing x86_64, 460 passing aarch64).

v1.0 shipped 300+ syscalls from ~190 baseline. v1.1 resolved all 14 v1.0 tech debt items.
v1.2 added 31 new syscalls across 12 categories. v1.3 resolved all 16 v1.2 tech debt items.
v1.4 hardened TCP/UDP stack with congestion control, window management, socket options, MSG flags.
v1.5 resolved all 18 v1.4 tech debt items and brought up loopback networking for live verification.
Six milestones shipped over 17 days with 91 plans across 44 phases.

Known issues: kernel stack at 192KB due to comptime dispatch table growth; 3 pre-existing aarch64 test failures (wait4 nohang, waitid WNOHANG, timerfd expiration); SFS close deadlock after many operations; QEMU TCG uncalibrated TSC prevents timer-based test paths.

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
| Extracted congestion/reno.zig before window wiring | Module boundary must exist before algorithm work | v Good v1.4 -- clean separation |
| Fixed 8KB arrays with rcv_buf_size cap field | Avoids heap allocation in IRQ-context recv path | v Good v1.4 -- no Tcb.reset() leak risk |
| SO_REUSEPORT blanket bind allow with FIFO dispatch | Minimal data structure change for bind table | v Good v1.4 -- listen_accept_count on Tcb avoids lock ordering issues |
| Persist timer separate from retransmit timer | Running both causes duplicate zero-window probes | v Good v1.4 -- mutual exclusion via retrans_timer==0 |
| Sender SWS gate after Nagle check | Complementary suppressors: Nagle gates on flight_size, SWS on segment size | v Good v1.4 -- both coexist cleanly |
| hasPendingSignal callback in scheduler shim | Socket layer stays independent of syscall error vocabulary | v Good v1.4 -- transport returns WouldBlock, syscall converts to EINTR |
| Kernel stack 96KB to 192KB | Comptime dispatch table expansion across phases 24-39 | v Good v1.4 -- resolved double fault regression |
| Async loopback (queue + drain) | Synchronous loopback re-enters TCP RX from TX, deadlocking state.lock | v Good v1.5 -- MAX_DRAIN_PER_TICK=64 prevents storms |
| @byteSwap on all TX checksum stores | onesComplement() computes big-endian, struct fields are native-endian | v Good v1.5 -- fixed silent packet drops |
| processTimers() wired to net.tick() | Was defined/exported but never called; delayed ACKs never fired | v Good v1.5 -- TCP timers now functional |
| Re-fetch TCB via getTcb() after sched.block() | TCB may be freed during sleep; stale pointer causes use-after-free | v Good v1.5 -- safe pattern for all blocking paths |

---
*Last updated: 2026-02-22 after v1.5 milestone*
