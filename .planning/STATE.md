# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-16)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** Phase 31 - TCP FIN Teardown (v1.3 Tech Debt Cleanup)

## Current Position

Phase: 31 of 35 (Inotify Completion)
Plan: 1 completed in current phase (31-01 done)
Status: Phase 31 plan 01 complete
Last activity: 2026-02-18 - Completed 31-01 (inotify write/ftruncate/close hooks, IN_Q_OVERFLOW, capacity increase)

Progress: [█████████████████████░░] 88% (31/35 phases complete)

## Performance Metrics

**Velocity:**
- Total plans completed: 64 (v1.0: 29, v1.1: 12, v1.2: 16, v1.3: 7)
- Average duration: ~8.2 min per plan
- Total execution time: ~8.6 hours over 11 days

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 12 | 2 days |
| v1.2 | 15-26 | 16 | 5 days |
| v1.3 | 27-35 | 7 (ongoing) | ~221 min |

**Recent Trend:**
- v1.2 phases averaged 1.3 plans per phase (down from 2.4 in v1.1, 3.2 in v1.0)
- Trend: Improving - larger phases with focused plans

*Updated after roadmap creation*
| Phase 31-inotify-completion P01 | 10 | 2 tasks | 11 files |

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

### Pending Todos

None.

### Blockers/Concerns

**prlimit64 #GP -- FIXED:**
- Root cause: use-after-free in destroyProcess. When sys_fork failed at thread creation (TooManyThreads), the child was freed without being removed from parent's children list. Dangling pointer filled with 0xAA caused #GP on next tree traversal.
- Fix: destroyProcess now calls parent.removeChild(proc) before freeing (commit 7809739)
- Test still fails with OutOfMemory (thread limit exhaustion) but no longer crashes the kernel

**Phase 35 (VFS Page Cache):**
- Largest tech debt item by far
- Requires VFS refactor for page-based I/O
- May need to split into multiple plans

## Session Continuity

Last session: 2026-02-18 (phase 31 execution)
Stopped at: Completed 31-01-PLAN.md (inotify write/ftruncate/close hooks, IN_Q_OVERFLOW, capacity increase)
Resume file: None

**Next action:** Proceed to next plan in phase 31, or next phase

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-18 after completing plan 31-01 (inotify completion)*
