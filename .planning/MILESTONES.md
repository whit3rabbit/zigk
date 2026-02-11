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

