# Roadmap: ZK Kernel - POSIX Syscall Coverage

## Milestones

- ✅ **v1.0 POSIX Syscall Coverage** - Phases 1-9 (shipped 2026-02-09)
- 🚧 **v1.1 Hardening & Debt Cleanup** - Phases 10-14 (in progress)

## Phases

<details>
<summary>✅ v1.0 POSIX Syscall Coverage (Phases 1-9) - SHIPPED 2026-02-09</summary>

**Delivered:** Expanded POSIX syscall coverage from ~190 to ~300+ syscalls across both x86_64 and aarch64, with 129 new integration tests covering all subsystems.

**Key accomplishments:**
1. Implemented 14 trivial stub syscalls
2. Built full UID/GID credential infrastructure
3. Completed I/O multiplexing with FileOps.poll
4. Added event notification FDs (eventfd, timerfd, signalfd)
5. Implemented vectored/positional I/O and sendfile
6. Fixed *at syscall double-copy bug
7. Fixed socket subsystem IrqLock init ordering
8. Added process control syscalls
9. Built complete SysV IPC subsystem

**Phase Summary:**
- [x] Phase 1: Quick Wins - Trivial Stubs (4/4 plans) -- completed 2026-02-06
- [x] Phase 2: Credentials & Ownership (4/4 plans) -- completed 2026-02-06
- [x] Phase 3: I/O Multiplexing (4/4 plans) -- completed 2026-02-07
- [x] Phase 4: Event Notification FDs (4/4 plans) -- completed 2026-02-07
- [x] Phase 5: Vectored & Positional I/O (3/3 plans) -- completed 2026-02-08
- [x] Phase 6: Filesystem Extras (3/3 plans) -- completed 2026-02-07
- [x] Phase 7: Socket Extras (2/2 plans) -- completed 2026-02-08
- [x] Phase 8: Process Control (2/2 plans) -- completed 2026-02-08
- [x] Phase 9: SysV IPC (3/3 plans) -- completed 2026-02-09

See milestones/v1-ROADMAP.md for full phase details.

</details>

### 🚧 v1.1 Hardening & Debt Cleanup (In Progress)

**Milestone Goal:** Fix all known bugs, eliminate tech debt from v1, and fill behavioral gaps (proper blocking, wait queues, SFS reliability).

#### Phase 10: Bug Fixes & Quick Wins
**Goal**: Fix critical bugs and verify stub implementations
**Depends on**: Phase 9
**Requirements**: BUGFIX-01, BUGFIX-02, BUGFIX-03, DOC-01, STUB-01, STUB-02, STUB-03, STUB-04, STUB-05, STUB-06, STUB-07, STUB-08
**Success Criteria** (what must be TRUE):
  1. Unprivileged processes cannot set arbitrary GIDs via setregid (POSIX permission checks enforced)
  2. SFS files can be chowned via fchown syscall (FileOps.chown implemented)
  3. Syscalls accept stack-allocated user buffers without EFAULT (copyStringFromUser validation fixed)
  4. dup3 with O_CLOEXEC sets close-on-exec flag correctly
  5. accept4 with SOCK_NONBLOCK/SOCK_CLOEXEC configures socket flags correctly
  6. getrlimit/setrlimit return and store meaningful resource limits
  7. sigaltstack configures alternate signal stack for signal delivery
  8. statfs/fstatfs return filesystem statistics (type, block size, free space)
  9. getresuid/getresgid return saved set-user-ID and set-group-ID values
  10. Phase 6 has a completed VERIFICATION.md documenting syscall coverage and test results
**Plans**: 4 plans in 1 wave

Plans:
- [x] 10-01-PLAN.md -- Critical bug fixes (setregid, copyStringFromUser, SFS chown)
- [x] 10-02-PLAN.md -- FD/Network stub verification (dup3, accept4)
- [x] 10-03-PLAN.md -- Resource/Signal stub verification (rlimit, sigaltstack, statfs, getresuid/getresgid)
- [x] 10-04-PLAN.md -- Phase 6 verification documentation

#### Phase 11: SFS Deadlock Resolution
**Goal**: Fix SFS close deadlock blocking 16+ tests
**Depends on**: Phase 10
**Requirements**: SFS-01, TEST-02
**Success Criteria** (what must be TRUE):
  1. SFS files can be closed reliably after 50+ file operations without deadlock
  2. SFS directories can be removed after many operations without deadlock
  3. SFS files can be renamed after many operations without deadlock
  4. All tests previously skipped due to SFS deadlock run to completion and pass
**Plans**: 2 plans in 2 waves

Plans:
- [x] 11-01-PLAN.md -- Fix SFS I/O serialization and alloc_lock restructure
- [x] 11-02-PLAN.md -- Add SFS rename, unskip deadlock tests, remove close workarounds

#### Phase 12: SFS Feature Expansion
**Goal**: Add link/symlink/timestamp support to SFS
**Depends on**: Phase 11
**Requirements**: SFS-02, SFS-03, SFS-04, TEST-03
**Success Criteria** (what must be TRUE):
  1. Hard links can be created on SFS via link/linkat syscalls (same inode, multiple names)
  2. Symbolic links can be created on SFS via symlink/symlinkat syscalls
  3. Symbolic link targets can be read via readlink/readlinkat syscalls
  4. File timestamps (atime, mtime) can be modified via utimensat/futimesat syscalls on SFS
  5. SFS link/symlink/timestamp tests unskipped and passing
**Plans**: 2 plans in 2 waves

Plans:
- [x] 12-01-PLAN.md -- SFS hard link and timestamp support (DirEntry nlink/atime, sfsLink, sfsSetTimestamps)
- [x] 12-02-PLAN.md -- SFS symbolic link support and test verification (sfsSymlink, sfsReadlink, unskip tests)

#### Phase 13: Wait Queue Infrastructure
**Goal**: Replace yield-loops with proper wait queues for blocking operations
**Depends on**: Phase 10
**Requirements**: WAIT-01, WAIT-02, WAIT-03, WAIT-04, WAIT-05, IPC-01, IPC-02, TEST-01
**Success Criteria** (what must be TRUE):
  1. timerfd blocking reads sleep on a wait queue (no CPU spinning) until timer expires
  2. signalfd blocking reads sleep on a wait queue (no CPU spinning) until signal arrives
  3. semop blocks efficiently on a wait queue when semaphore value is insufficient
  4. msgsnd blocks efficiently on a wait queue when message queue is full (no IPC_NOWAIT)
  5. msgrcv blocks efficiently on a wait queue when no matching message is available (no IPC_NOWAIT)
  6. SEM_UNDO adjustments are tracked per-process and applied on process exit
  7. semop with IPC_NOWAIT returns EAGAIN immediately without blocking (non-blocking path preserved)
  8. 4 event FD tests pass (eventfd write/read, semaphore mode, timerfd disarm, signalfd read)
**Plans**: TBD

Plans:
- [ ] 13-01: [TBD]

#### Phase 14: I/O Improvements
**Goal**: Zero-copy sendfile and AT_SYMLINK_NOFOLLOW support
**Depends on**: Phase 10
**Requirements**: IO-01, IO-02
**Success Criteria** (what must be TRUE):
  1. sendfile uses zero-copy path (direct page mapping from source to destination) instead of 4KB buffer copy
  2. utimensat with AT_SYMLINK_NOFOLLOW flag modifies symlink timestamps (not target)
  3. sendfile performance improves measurably on large file transfers (>1MB)
**Plans**: TBD

Plans:
- [ ] 14-01: [TBD]

## Progress

**Execution Order:**
Phases execute in numeric order: 10 -> 11 -> 12 -> 13 -> 14

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Trivial Stubs | v1.0 | 4/4 | Complete | 2026-02-06 |
| 2. UID/GID Infrastructure | v1.0 | 4/4 | Complete | 2026-02-06 |
| 3. I/O Multiplexing | v1.0 | 4/4 | Complete | 2026-02-07 |
| 4. Event Notification FDs | v1.0 | 4/4 | Complete | 2026-02-07 |
| 5. Vectored I/O | v1.0 | 3/3 | Complete | 2026-02-08 |
| 6. Filesystem Extras | v1.0 | 3/3 | Complete | 2026-02-07 |
| 7. Socket Extras | v1.0 | 2/2 | Complete | 2026-02-08 |
| 8. Process Control | v1.0 | 2/2 | Complete | 2026-02-08 |
| 9. SysV IPC | v1.0 | 3/3 | Complete | 2026-02-09 |
| 10. Bug Fixes & Quick Wins | v1.1 | 4/4 | Complete | 2026-02-09 |
| 11. SFS Deadlock Resolution | v1.1 | 2/2 | Complete | 2026-02-10 |
| 12. SFS Feature Expansion | v1.1 | 2/2 | Complete | 2026-02-10 |
| 13. Wait Queue Infrastructure | v1.1 | 0/? | Not started | - |
| 14. I/O Improvements | v1.1 | 0/? | Not started | - |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-10 after Phase 12 execution complete*
