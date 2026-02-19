# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-16)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** Phase 35 - VFS Page Cache and Zero-Copy (v1.3 Tech Debt Cleanup)

## Current Position

Phase: 35 of 35 (VFS Page Cache and Zero-Copy) - IN PROGRESS
Plan: 1 of 2 completed in phase 35 (35-01 done, 35-02 pending)
Status: Phase 35 plan 01 complete, plan 02 pending
Last activity: 2026-02-19 - Completed 35-01 (VFS page cache infrastructure with ref-counted pages, writeback, and FdTable.close integration)

Progress: [██████████████████████░] 94% (34/35 phases in progress, 66/67 plans complete)

## Performance Metrics

**Velocity:**
- Total plans completed: 66 (v1.0: 29, v1.1: 12, v1.2: 16, v1.3: 9)
- Average duration: ~8.2 min per plan
- Total execution time: ~8.6 hours over 11 days

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 12 | 2 days |
| v1.2 | 15-26 | 16 | 5 days |
| v1.3 | 27-35 | 9 (ongoing) | ~235 min |

**Recent Trend:**
- v1.2 phases averaged 1.3 plans per phase (down from 2.4 in v1.1, 3.2 in v1.0)
- Trend: Improving - larger phases with focused plans

*Updated after roadmap creation*
| Phase 31-inotify-completion P01 | 10 | 2 tasks | 11 files |
| Phase 32-timer-capacity-expansion P01 | 6 | 3 tasks | 6 files |
| Phase 33-timer-resolution-improvement P01 | 5 | 2 tasks | 7 files |
| Phase 33 P02 | 15 | 2 tasks | 11 files |
| Phase 33 P03 | 2 | 1 task | 2 files |
| Phase 34 P01 | 7 | 2 tasks | 5 files |
| Phase 34 P02 | 468 | 2 tasks | 5 files |
| Phase 35 P01 | 12 | 2 tasks | 4 files |

## Accumulated Context

### Decisions

Recent decisions from PROJECT.md affecting v1.3:

- **v1.2**: Bitmask-only signal tracking deferred proper siginfo queue to v1.3 (SIG-02)
- **v1.2**: signalfd 10ms polling instead of direct wakeup needs revisit in v1.3 (SIG-03)
- **v1.2**: 64KB kernel buffer for zero-copy I/O pending VFS page cache refactor (ZCIO-01, ZCIO-02)
- **v1.2**: Seccomp returns ENOSYS instead of delivering SIGSYS pending signal integration (SECC-01)
- **27-01**: Use DirTag enum to map directory FDs to canonical paths (InitRD root -> "/", DevFS root -> "/dev")
- **27-01**: mremap invalid address edge case verified working - no fix needed (VMA walk doesn't dereference user addresses)
- **27-02**: Use soft/hard pair fields per rlimit resource instead of array structure for clarity
- **27-02**: instruction_pointer accessed via SyscallFrame.getReturnRip() (arch-agnostic pattern)
- **28-01**: dispatch_syscall must skip setReturnSigned for SYS_RT_SIGRETURN (frame-restoring syscall pattern)
- **28-01**: Deferred mask restoration via saved_sigmask/has_saved_sigmask on Thread struct (Linux kernel pattern)
- **29-01**: Standard signals coalesce (no double-enqueue while pending); RT signals always enqueue
- **29-01**: General delivery (kill/tkill) uses best-effort silent drop on queue overflow
- **29-01**: rt_sigqueueinfo/rt_tgsigqueueinfo return EAGAIN on queue overflow (POSIX SIGQUEUE_MAX)
- **29-01**: siginfo threaded through setupSignalFrame as optional for Plan 02 SA_SIGINFO support
- **29-01**: SigInfoQueue capacity 32 entries; enqueue before bitmask set ensures metadata ready on consumption
- **29-02**: SA_SIGINFO x86_64 stack layout: siginfo at top (highest addr), ucontext below, restorer at bottom; ret in handler advances RSP to ucontext for rt_sigreturn
- **29-02**: Removed rdi/rsi/rdx zeroing from x86_64 sysretq path -- these carry SA_SIGINFO handler args (signum, siginfo_ptr, ucontext_ptr)
- **29-02**: RT signal tryDequeueSignal: only clear bitmask bit when hasSignal() returns false after dequeue (enables multiple RT signal instances)
- **30-01**: Use sched.waitOn (indefinite block) + sched.unblock wakeup for signalfd; WaitQueue.removeThread cleans stale entries at loop top
- **30-01**: SECCOMP_RET_KILL: deliver SIGSYS signal first, then run checkSignalsOnSyscallExit for immediate termination before userspace escape
- **30-01**: sched.exitWithStatus must mark Process zombie for single-thread process death via signal (bypasses process.exit() path)
- **30-01**: prlimit64 #GP crash (RAX=0xAAAAAAAA) was pre-existing use-after-free in destroyProcess -- FIXED in phase 31
- [Phase 31-01]: Use inotify_close_hook fn ptr on fd.zig to avoid circular dependency with inotify module
- [Phase 31-01]: Fire inotify notifications AFTER fd.lock release to respect lock ordering (inotify acquires global_instances_lock)
- [Phase 31-01]: IN_Q_OVERFLOW overwrites last real event in ring buffer when queue full (coalesced, no extra slot needed)
- [Phase 31-01]: vfs_path field 128-byte fixed array on FileDescriptor for path tracking at VFS open time, no heap alloc
- [Phase 32-01]: posix_timer_count field (u8) maintains active timer count via saturating add/sub; enables O(1) fast-path skip in processIntervalTimers when no timers active
- [Phase 32-01]: MAX_POSIX_TIMERS = 32 in uapi/process/time.zig as single canonical constant; posix_timer.zig no longer has local copy
- [Phase 32-01]: Dynamic timer growth deferred; 32-slot fixed array satisfies POSIX_TIMER_MAX, roadmap criterion met
- [Phase 33-01]: 1 tick = 1ms identity simplifies fallback paths (ticks *| 10 becomes just ticks); load avg interval 500->5000 ticks preserves 5-second period
- [Phase 33]: POSIX timer overrun test uses sched_yield polling: processIntervalTimers only runs for currently-scheduled thread; blocking sleep freezes timer counters
- [Phase 33]: testClockNanosleepSubTenMs skipped on aarch64: no TSC fallback clock_gettime has QEMU TCG scheduling overhead inflating measured elapsed time beyond tight upper bounds
- [Phase 33-03]: recvfromIp() /10 divisor was a latent bug; at 1000Hz 1 tick = 1ms so no divisor is needed; matches recvfrom() identity conversion
- [Phase 33-03]: Timer overrun discrimination threshold of 7: midpoint between 1ms expected (~11) and 10ms expected (~5), absorbs QEMU TCG jitter
- [Phase 34-01]: SIGEV_THREAD is identical to SIGEV_SIGNAL at the kernel level; glibc handles thread callback wrapping in userspace
- [Phase 34-01]: findThreadByTid safe in processIntervalTimers -- scheduler.lock acquired at timerTick line ~819, after processIntervalTimers call at line 806
- [Phase 34-01]: SIGEV_THREAD_ID falls back to current thread if target exited (no silent signal loss)
- [Phase 34]: Install SIG_IGN for SIGALRM before arming signal-delivering timers in tests -- SIGEV_THREAD and SIGEV_THREAD_ID deliver real signals that terminate the process with default disposition
- [Phase 34]: Restore SIG_DFL after each timer-fires test to avoid leaking SIG_IGN disposition into subsequent tests
- [Phase 35-01]: Fixed-size 256-bucket hash table with linked-list chaining for page cache; MAX_CACHED_PAGES=1024 (4MB)
- [Phase 35-01]: Lock ordering: page_cache.lock after fd.lock; lock dropped before read_fn/write_fn calls to avoid inversion
- [Phase 35-01]: Read-ahead: 1-page prefetch on cache miss; prefetched pages start with ref_count=0 (unreferenced)
- [Phase 35-01]: Writeback before close_fn in FdTable.close -- backing store must still be open for write_fn to succeed

### Pending Todos

None.

### Blockers/Concerns

**prlimit64 #GP -- FIXED:**
- Root cause: use-after-free in destroyProcess. When sys_fork failed at thread creation (TooManyThreads), the child was freed without being removed from parent's children list. Dangling pointer filled with 0xAA caused #GP on next tree traversal.
- Fix: destroyProcess now calls parent.removeChild(proc) before freeing (commit 7809739)
- Test still fails with OutOfMemory (thread limit exhaustion) but no longer crashes the kernel

**Phase 35 (VFS Page Cache) -- Plan 01 COMPLETE:**
- Page cache infrastructure built (page_cache.zig with full API)
- FdTable.close integrated with writeback/invalidate
- Plan 02 pending: wire page cache into splice/sendfile/tee/copy_file_range

## Session Continuity

Last session: 2026-02-19 (phase 35 execution)
Stopped at: Completed 35-01-PLAN.md (VFS page cache infrastructure)
Resume file: None

**Next action:** Execute 35-02-PLAN.md (wire page cache into splice/sendfile/tee/copy_file_range)

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-19 after completing plan 35-01 (VFS page cache infrastructure with ref-counted pages, writeback, FdTable.close integration)*
