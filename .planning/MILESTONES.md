# Milestones

## v1 POSIX Syscall Coverage (Shipped: 2026-02-09)

**Phases:** 1-9 (29 plans)
**Commits:** 141
**Lines:** +9,767 / -345 across 64 source files
**Timeline:** 4 days (2026-02-06 to 2026-02-09)
**Total codebase:** 192,637 LOC Zig
**Tests:** 306 total (278-280 passing, 26-28 skipped, 0 failing)
**Git range:** 4c19fc7..24060e8

**Key accomplishments:**
1. Implemented 14 trivial stub syscalls (madvise, mlock, mincore, scheduling stubs, resource limits, signal ops)
2. Built full UID/GID credential infrastructure with fsuid/fsgid auto-sync and chown family (14 credential syscalls)
3. Completed I/O multiplexing: FileOps.poll for all FD types, upgraded epoll_wait/select/pselect6/ppoll
4. Added event notification FDs: eventfd, timerfd (polling-based), signalfd with epoll integration
5. Implemented vectored/positional I/O (readv, preadv, pwritev, preadv2/pwritev2) and sendfile
6. Fixed *at syscall double-copy bug, added filesystem timestamp manipulation (utimensat/futimesat)
7. Fixed socket subsystem IrqLock init ordering, added socketpair/shutdown/sendmsg/recvmsg
8. Added process control (prctl PR_SET_NAME/PR_GET_NAME, sched_setaffinity/getaffinity)
9. Built complete SysV IPC subsystem: shared memory, semaphores, message queues (11 syscalls)

**Delivered:** Expanded POSIX syscall coverage from ~190 to ~300+ syscalls across both x86_64 and aarch64, with 129 new integration tests covering all subsystems.

**Tech debt:** 14 items (SFS deadlock, yield-loop blocking in timerfd/signalfd, sendfile not zero-copy, SEM_UNDO deferred). See milestones/v1-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1-ROADMAP.md
- milestones/v1-REQUIREMENTS.md
- milestones/v1-MILESTONE-AUDIT.md

---


## v1.1 Hardening & Debt Cleanup (Shipped: 2026-02-11)

**Phases:** 10-14 (12 plans)
**Lines:** +6,396 / -664 across 60 files
**Timeline:** 2 days (2026-02-09 to 2026-02-10)
**Total codebase:** 194,415 LOC Zig
**Git range:** 24d7793..b2babe9

**Key accomplishments:**
1. Fixed critical kernel bugs (setregid POSIX permissions, SFS fchown, copyStringFromUser stack buffers)
2. Eliminated SFS close deadlock via io_lock + alloc_lock restructuring, unskipping 16+ tests
3. Added SFS hard link, symlink, and timestamp support with global nlink synchronization
4. Replaced CPU-wasting yield-loops with WaitQueue-based blocking for timerfd, signalfd, and SysV IPC
5. Implemented SEM_UNDO tracking with automatic cleanup on process exit
6. Optimized sendfile 16x (64KB buffer) and enabled AT_SYMLINK_NOFOLLOW

**Delivered:** Resolved all 14 v1.0 tech debt items, hardened SFS filesystem with proper locking and new features (links, symlinks, timestamps), replaced all yield-loop blocking with WaitQueue infrastructure, and verified 28 requirements across 8 E2E flows.

**Tech debt:** 3 items (signalfd 10ms polling, sendfile not true zero-copy, aarch64 test timeout). See milestones/v1.1-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1.1-ROADMAP.md
- milestones/v1.1-REQUIREMENTS.md
- milestones/v1.1-MILESTONE-AUDIT.md

---


## v1.2 Systematic Syscall Coverage (Shipped: 2026-02-16)

**Phases:** 15-26 (16 plans)
**Commits:** 71
**Lines:** +21,822 / -420 across 104 files
**Timeline:** 5 days (2026-02-11 to 2026-02-16)
**Total codebase:** 203,161 LOC Zig
**Tests:** ~123 new integration tests
**Git range:** b2babe9..3ee2fc4

**Key accomplishments:**
1. Implemented splice/tee/vmsplice/copy_file_range, fallocate, and renameat2 for kernel-side data transfer and atomic file operations
2. Delivered clone3 and waitid with struct-based args and siginfo_t output for modern process management
3. Added rt_sigtimedwait, rt_sigqueueinfo, clock_nanosleep, and POSIX timers (5 syscalls) with scheduler-integrated signal delivery
4. Built inotify file monitoring subsystem with VFS hooks, ring buffer event queue, and epoll integration
5. Integrated Linux capability model (capget/capset) and seccomp syscall filtering with classic BPF interpreter
6. Expanded test suite with 20 targeted coverage tests, implemented memfd_create/mremap/msync, fixed mincore security vulnerability

**Delivered:** Added 31 new syscalls across 12 categories (file sync, zero-copy I/O, memory management, process control, signals, timers, monitoring, capabilities, seccomp), a BPF interpreter for syscall filtering, and comprehensive dual-arch test coverage. Total kernel syscall count now exceeds 330.

**Tech debt:** 15 items (inotify VFS hooks partial, rt_sigsuspend race, zero-copy uses kernel buffers, seccomp SIGSYS not delivered, bitmask-only signals, POSIX timer limits). See milestones/v1.2-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1.2-ROADMAP.md
- milestones/v1.2-REQUIREMENTS.md
- milestones/v1.2-MILESTONE-AUDIT.md

---


## v1.3 Tech Debt Cleanup (Shipped: 2026-02-19)

**Phases:** 27-35 (15 plans)
**Commits:** 78
**Lines:** +12,026 / -495 across 92 files
**Timeline:** 4 days (2026-02-16 to 2026-02-19)
**Total codebase:** 206,097 LOC Zig
**Git range:** f767febd..3c23038

**Key accomplishments:**
1. Built per-thread siginfo queue (KernelSigInfo, SigInfoQueue) replacing bitmask-only signal tracking, with SA_SIGINFO three-argument handler support on both architectures
2. Replaced signalfd 10ms polling with direct wakeup via sched.waitOn/unblock and delivered SIGSYS for seccomp SECCOMP_RET_KILL
3. Completed inotify VFS hooks (write, ftruncate, close, link, symlink) with IN_Q_OVERFLOW handling, vfs_path tracking, and capacity increase
4. Upgraded system timer from 100Hz to 1000Hz for 1ms tick resolution, updated all peripheral tick constants across both architectures
5. Added SIGEV_THREAD and SIGEV_THREAD_ID notification modes for POSIX timers with sys_gettid and SI_TIMER siginfo delivery
6. Built VFS page cache (256-bucket hash, 1024 page limit) and refactored splice/sendfile/tee/copy_file_range for true zero-copy I/O

**Delivered:** Resolved all 16 v1.2 tech debt items. Signal infrastructure rebuilt from bitmask-only to full siginfo queues with direct wakeup. Timer subsystem upgraded from 10ms to 1ms resolution with expanded capacity (32 timers) and new notification modes. VFS page cache enables true zero-copy I/O. Four bonus bug fixes (destroyProcess use-after-free, rt_sigreturn rax clobber, recvfromIp /10 divisor, exitWithStatus zombie marking).

**Tech debt:** 1 minor item (SIGEV_THREAD_ID does not call sched.unblock on blocked target). See milestones/v1.3-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1.3-ROADMAP.md
- milestones/v1.3-REQUIREMENTS.md
- milestones/v1.3-MILESTONE-AUDIT.md

---


## v1.4 Network Stack Hardening (Shipped: 2026-02-20)

**Phases:** 36-39 (9 plans)
**Commits:** 42
**Lines:** +6,864 / -196 across 56 files
**Timeline:** 2 days (2026-02-19 to 2026-02-20)
**Total codebase:** 212,270 LOC Zig
**Git range:** 911e8f2..35a13c3

**Key accomplishments:**
1. Created TCP Reno congestion control module (RFC 5681/6928) with IW10 initial window, Karn's Algorithm in all retransmit paths, and MAX_CWND cap
2. Implemented dynamic receive window management with SWS avoidance on both sender and receiver, and independent persist timer with 60s-capped exponential backoff (RFC 1122)
3. Added configurable socket buffer options (SO_RCVBUF, SO_SNDBUF with Linux ABI doubling, SO_REUSEPORT with FIFO dispatch, TCP_CORK with flush-on-uncork)
4. Threaded MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL flags through TCP and UDP recv stack with correct per-flag semantics
5. Implemented raw socket blocking recv via scheduler wake pattern and MSG_NOSIGNAL/SIGPIPE suppression
6. Added signal-aware recv loops with hasPendingSignal callback for EINTR support in all TCP blocking paths

**Delivered:** Hardened the TCP/UDP networking stack with RFC-compliant congestion control, dynamic window management, complete socket option support, and MSG flag threading. All 21 requirements satisfied across 4 phases. Kernel stack increased to 192KB to accommodate comptime dispatch table growth.

**Tech debt:** 18 items (8 human verification items requiring live QEMU networking, 1 low-severity stale blocked_thread pointer on EINTR, 2 minor integration concerns, documentation gaps). See milestones/v1.4-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1.4-ROADMAP.md
- milestones/v1.4-REQUIREMENTS.md
- milestones/v1.4-MILESTONE-AUDIT.md

---


## v1.5 Tech Debt Cleanup (Shipped: 2026-02-22)

**Phases:** 40-44 (9 plans)
**Commits:** 44
**Lines:** +4,317 / -473 across 68 files
**Timeline:** 3 days (2026-02-20 to 2026-02-22)
**Total codebase:** ~216K LOC Zig
**Tests:** 480 total (463 passing x86_64, 460 passing aarch64)
**Git range:** 6184cc3..bc8bb67

**Key accomplishments:**
1. Fixed 4 TCP/raw socket defects: stale tcb.blocked_thread use-after-free, SO_RCVBUF/SO_SNDBUF pre-connect propagation, TCP_CORK uncork mutex locking, raw socket MSG_DONTWAIT/MSG_PEEK flags
2. Brought up loopback networking (lo0 at 127.0.0.1) with full TCP/IP stack, fixing 10 pre-existing network bugs (checksum byte-order across all TX paths, TCP SYN_SENT state machine, re-entrant loopback deadlock, ARP for loopback, MSG_WAITALL blocked_thread)
3. Added 8 network verification tests: zero-window recovery, SWS/Nagle avoidance, raw socket ICMP echo round-trip, SO_REUSEPORT dual bind, SIGPIPE/MSG_NOSIGNAL, MSG_PEEK+DONTWAIT UDP, MSG_WAITALL multi-segment, SO_RCVTIMEO+MSG_WAITALL
4. Wired TCP processTimers() into net.tick() -- delayed ACKs and retransmission timers had never been firing since they were implemented
5. Removed dead code (Tcb.send_acked field, recvfromRaw/recvfromRaw6 functions), fixed slab_bench.zig Zig 0.16.x compatibility, closed all v1.4 documentation gaps

**Delivered:** Resolved all 18 v1.4 tech debt items. Network stack now verified under live loopback with 8 feature tests. TCP timer system fully wired. All checksum TX paths produce correct byte-order. Dual-architecture test suite at 480 tests with zero failures on x86_64.

**Tech debt:** 5 items (3 ROADMAP formatting defects in progress table, 5 human verification items requiring calibrated hardware or packet capture, NET-04 attribution gap). See milestones/v1.5-MILESTONE-AUDIT.md.

**Archives:**
- milestones/v1.5-ROADMAP.md
- milestones/v1.5-REQUIREMENTS.md
- milestones/v1.5-MILESTONE-AUDIT.md

---

