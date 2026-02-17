# Roadmap: ZK Kernel

## Milestones

- ✅ **v1.0 POSIX Syscall Coverage** - Phases 1-9 (shipped 2026-02-09)
- ✅ **v1.1 Hardening & Debt Cleanup** - Phases 10-14 (shipped 2026-02-11)
- ✅ **v1.2 Systematic Syscall Coverage** - Phases 15-26 (shipped 2026-02-16)
- 🚧 **v1.3 Tech Debt Cleanup** - Phases 27-35 (in progress)

## Phases

<details>
<summary>v1.0 POSIX Syscall Coverage (Phases 1-9) - SHIPPED 2026-02-09</summary>

- [x] Phase 1: Trivial Stubs (4/4 plans) - completed 2026-02-06
- [x] Phase 2: UID/GID Infrastructure (3/3 plans) - completed 2026-02-06
- [x] Phase 3: File Ownership (2/2 plans) - completed 2026-02-06
- [x] Phase 4: I/O Multiplexing Infrastructure (3/3 plans) - completed 2026-02-07
- [x] Phase 5: Event Notification FDs (3/3 plans) - completed 2026-02-07
- [x] Phase 6: Vectored & Positional I/O (3/3 plans) - completed 2026-02-08
- [x] Phase 7: Filesystem Extras (3/3 plans) - completed 2026-02-08
- [x] Phase 8: Socket Extras (3/3 plans) - completed 2026-02-08
- [x] Phase 9: Process Control & SysV IPC (5/5 plans) - completed 2026-02-09

</details>

<details>
<summary>v1.1 Hardening & Debt Cleanup (Phases 10-14) - SHIPPED 2026-02-11</summary>

- [x] Phase 10: Critical Kernel Bugs (3/3 plans) - completed 2026-02-09
- [x] Phase 11: SFS Deadlock Fix (1/1 plans) - completed 2026-02-09
- [x] Phase 12: SFS Hard Link Support (2/2 plans) - completed 2026-02-10
- [x] Phase 13: SFS Symlink & Timestamp Support (2/2 plans) - completed 2026-02-10
- [x] Phase 14: WaitQueue Blocking & Optimizations (7/7 plans) - completed 2026-02-11

</details>

<details>
<summary>v1.2 Systematic Syscall Coverage (Phases 15-26) - SHIPPED 2026-02-16</summary>

- [x] Phase 15: File Synchronization (1/1 plans) - completed 2026-02-12
- [x] Phase 16: Advanced File Operations (1/1 plans) - completed 2026-02-12
- [x] Phase 17: Zero-Copy I/O (2/2 plans) - completed 2026-02-13
- [x] Phase 18: Memory Management Extensions (1/1 plans) - completed 2026-02-13
- [x] Phase 19: Process Control Extensions (1/1 plans) - completed 2026-02-14
- [x] Phase 20: Signal Handling Extensions (1/1 plans) - completed 2026-02-14
- [x] Phase 21: I/O Multiplexing Extension (1/1 plans) - completed 2026-02-15
- [x] Phase 22: File Monitoring (1/1 plans) - completed 2026-02-15
- [x] Phase 23: POSIX Timers (1/1 plans) - completed 2026-02-15
- [x] Phase 24: Capabilities (1/1 plans) - completed 2026-02-16
- [x] Phase 25: Seccomp (1/1 plans) - completed 2026-02-16
- [x] Phase 26: Test Coverage Expansion (2/2 plans) - completed 2026-02-16

</details>

### v1.3 Tech Debt Cleanup (In Progress)

**Milestone Goal:** Resolve all 15 tech debt items from v1.0-v1.2, hardening existing implementations with proper wakeups, signal queues, and VFS page cache infrastructure.

- [x] **Phase 27: Quick Wins** - Edge case fixes and simple additions (completed 2026-02-16)
- [x] **Phase 28: rt_sigsuspend Race Fix** - Fix pending signal delivery race (completed 2026-02-17)
- [x] **Phase 29: Siginfo Queue** - Replace bitmask-only signal tracking (completed 2026-02-17)
- [ ] **Phase 30: Signal Wakeup Integration** - Direct wakeup for signalfd and SIGSYS delivery
- [ ] **Phase 31: Inotify Completion** - Complete VFS hooks and overflow handling
- [ ] **Phase 32: Timer Capacity Expansion** - Increase per-process timer limit
- [ ] **Phase 33: Timer Resolution Improvement** - Improve timer and clock_nanosleep granularity
- [ ] **Phase 34: Timer Notification Modes** - Add SIGEV_THREAD and SIGEV_THREAD_ID
- [ ] **Phase 35: VFS Page Cache and Zero-Copy** - True zero-copy I/O infrastructure

## Phase Details

### Phase 27: Quick Wins
**Goal**: Fix edge cases and add simple syscalls that don't require complex infrastructure
**Depends on**: Phase 26
**Requirements**: MEM-01, RSRC-01, RSRC-02, SECC-02
**Success Criteria** (what must be TRUE):
  1. testMremapInvalidAddr edge case passes on both architectures
  2. User can change working directory via fchdir with an open directory FD
  3. Per-process resource limits persist across setrlimit/getrlimit calls
  4. SeccompData structure includes instruction_pointer field for trapped syscalls
**Plans**: 2 plans
Plans:
- [ ] 27-01-PLAN.md -- Fix mremap edge case and implement fchdir
- [ ] 27-02-PLAN.md -- rlimit persistence and seccomp instruction_pointer

### Phase 28: rt_sigsuspend Race Fix
**Goal**: Fix race condition where pending signals are not delivered when rt_sigsuspend atomically restores signal mask
**Depends on**: Phase 27
**Requirements**: SIG-01
**Success Criteria** (what must be TRUE):
  1. rt_sigsuspend delivers signals that were pending before the mask was restored
  2. rt_sigsuspend correctly blocks until a signal is delivered
  3. Test demonstrates signal delivery during mask restoration works reliably
**Plans**: 1 plan
Plans:
- [ ] 28-01-PLAN.md -- Fix mask restoration race with deferred restoration pattern

### Phase 29: Siginfo Queue
**Goal**: Replace bitmask-only signal tracking with per-thread siginfo queue to carry signal metadata
**Depends on**: Phase 28
**Requirements**: SIG-02
**Success Criteria** (what must be TRUE):
  1. Signals carry siginfo data (si_signo, si_code, si_pid, si_uid, si_value)
  2. Multiple instances of the same signal can be queued and delivered in order
  3. rt_sigqueueinfo delivers signals with correct metadata to target thread
  4. Signal handlers receive correct siginfo_t via rt_sigaction
**Plans**: 2 plans
Plans:
- [ ] 29-01-PLAN.md -- Core siginfo queue infrastructure and delivery/consumption wiring
- [ ] 29-02-PLAN.md -- SA_SIGINFO handler support and integration tests

### Phase 30: Signal Wakeup Integration
**Goal**: Use siginfo queue for direct signalfd wakeup and SIGSYS delivery
**Depends on**: Phase 29
**Requirements**: SIG-03, SECC-01
**Success Criteria** (what must be TRUE):
  1. signalfd read wakes immediately when signal is delivered (no 10ms polling delay)
  2. Seccomp SECCOMP_RET_KILL delivers SIGSYS to the offending thread
  3. SIGSYS signal carries correct si_syscall and si_arch in siginfo_t
  4. signalfd read returns correct signal metadata from siginfo queue
**Plans**: TBD

### Phase 31: Inotify Completion
**Goal**: Complete inotify implementation with full VFS hook coverage and overflow handling
**Depends on**: Phase 27
**Requirements**: INOT-01, INOT-02, INOT-03
**Success Criteria** (what must be TRUE):
  1. VFS operations (ftruncate, write, rename, unlink) generate corresponding inotify events
  2. Event queue overflow generates IN_Q_OVERFLOW notification to userspace
  3. Inotify supports increased capacity (more instances, watches per instance, queued events)
  4. Inotify events carry correct wd, mask, cookie, and name fields
**Plans**: TBD

### Phase 32: Timer Capacity Expansion
**Goal**: Increase per-process POSIX timer limit beyond 8 timers
**Depends on**: Phase 27
**Requirements**: PTMR-01
**Success Criteria** (what must be TRUE):
  1. Process can create more than 8 POSIX timers without EAGAIN
  2. Timer storage scales dynamically based on actual usage
  3. Timer cleanup on process exit handles increased capacity correctly
**Plans**: TBD

### Phase 33: Timer Resolution Improvement
**Goal**: Improve POSIX timer and clock_nanosleep resolution beyond 10ms tick granularity
**Depends on**: Phase 32
**Requirements**: PTMR-02
**Success Criteria** (what must be TRUE):
  1. POSIX timers expire with sub-10ms precision
  2. clock_nanosleep wakes with sub-10ms precision for short sleeps
  3. clock_getres reports improved resolution for CLOCK_REALTIME and CLOCK_MONOTONIC
  4. Scheduler timer infrastructure supports higher frequency ticks
**Plans**: TBD

### Phase 34: Timer Notification Modes
**Goal**: Add SIGEV_THREAD and SIGEV_THREAD_ID notification modes for POSIX timers
**Depends on**: Phase 33
**Requirements**: PTMR-03
**Success Criteria** (what must be TRUE):
  1. timer_create accepts SIGEV_THREAD mode and spawns notification thread on expiration
  2. timer_create accepts SIGEV_THREAD_ID mode and delivers signal to specific thread
  3. SIGEV_THREAD notification passes correct sigval to the notification function
  4. SIGEV_THREAD_ID delivers signal to correct thread via tgkill
**Plans**: TBD

### Phase 35: VFS Page Cache and Zero-Copy
**Goal**: Build VFS page cache infrastructure to enable true zero-copy I/O without kernel buffer copies
**Depends on**: Phase 34
**Requirements**: ZCIO-01, ZCIO-02
**Success Criteria** (what must be TRUE):
  1. VFS maintains page cache for regular files with read-ahead and write-back
  2. splice operation transfers data via page references without copying to kernel buffer
  3. sendfile transfers file data via page references without kernel buffer copy
  4. tee duplicates pipe data via page references without kernel buffer copy
  5. copy_file_range transfers file data via page cache without kernel buffer copy
**Plans**: TBD

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Trivial Stubs | v1.0 | 4/4 | Complete | 2026-02-06 |
| 2. UID/GID Infrastructure | v1.0 | 3/3 | Complete | 2026-02-06 |
| 3. File Ownership | v1.0 | 2/2 | Complete | 2026-02-06 |
| 4. I/O Multiplexing Infrastructure | v1.0 | 3/3 | Complete | 2026-02-07 |
| 5. Event Notification FDs | v1.0 | 3/3 | Complete | 2026-02-07 |
| 6. Vectored & Positional I/O | v1.0 | 3/3 | Complete | 2026-02-08 |
| 7. Filesystem Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 8. Socket Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 9. Process Control & SysV IPC | v1.0 | 5/5 | Complete | 2026-02-09 |
| 10. Critical Kernel Bugs | v1.1 | 3/3 | Complete | 2026-02-09 |
| 11. SFS Deadlock Fix | v1.1 | 1/1 | Complete | 2026-02-09 |
| 12. SFS Hard Link Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 13. SFS Symlink & Timestamp Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 14. WaitQueue Blocking & Optimizations | v1.1 | 7/7 | Complete | 2026-02-11 |
| 15. File Synchronization | v1.2 | 1/1 | Complete | 2026-02-12 |
| 16. Advanced File Operations | v1.2 | 1/1 | Complete | 2026-02-12 |
| 17. Zero-Copy I/O | v1.2 | 2/2 | Complete | 2026-02-13 |
| 18. Memory Management Extensions | v1.2 | 1/1 | Complete | 2026-02-13 |
| 19. Process Control Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 20. Signal Handling Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 21. I/O Multiplexing Extension | v1.2 | 1/1 | Complete | 2026-02-15 |
| 22. File Monitoring | v1.2 | 1/1 | Complete | 2026-02-15 |
| 23. POSIX Timers | v1.2 | 1/1 | Complete | 2026-02-15 |
| 24. Capabilities | v1.2 | 1/1 | Complete | 2026-02-16 |
| 25. Seccomp | v1.2 | 1/1 | Complete | 2026-02-16 |
| 26. Test Coverage Expansion | v1.2 | 2/2 | Complete | 2026-02-16 |
| 27. Quick Wins | v1.3 | Complete    | 2026-02-16 | - |
| 28. rt_sigsuspend Race Fix | v1.3 | Complete    | 2026-02-17 | - |
| 29. Siginfo Queue | v1.3 | Complete    | 2026-02-17 | - |
| 30. Signal Wakeup Integration | v1.3 | 0/? | Not started | - |
| 31. Inotify Completion | v1.3 | 0/? | Not started | - |
| 32. Timer Capacity Expansion | v1.3 | 0/? | Not started | - |
| 33. Timer Resolution Improvement | v1.3 | 0/? | Not started | - |
| 34. Timer Notification Modes | v1.3 | 0/? | Not started | - |
| 35. VFS Page Cache and Zero-Copy | v1.3 | 0/? | Not started | - |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-17 after Phase 29 planning*
