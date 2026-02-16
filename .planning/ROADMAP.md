# Roadmap: ZK Kernel v1.2 Systematic Syscall Coverage

## Milestones

- ✅ **v1.0 POSIX Syscall Coverage** - Phases 1-9 (shipped 2026-02-09)
- ✅ **v1.1 Hardening & Debt Cleanup** - Phases 10-14 (shipped 2026-02-11)
- 🚧 **v1.2 Systematic Syscall Coverage** - Phases 15-26 (in progress)

## Phases

<details>
<summary>✅ v1.0 POSIX Syscall Coverage (Phases 1-9) - SHIPPED 2026-02-09</summary>

### Phase 1: Trivial Stubs
- [x] 01-01: Implement madvise, mlock, mincore stubs
- [x] 01-02: Implement scheduling stubs (sched_yield, sched_getscheduler, sched_setscheduler)
- [x] 01-03: Implement resource limit stubs (getrlimit, prlimit64)
- [x] 01-04: Implement signal operation stubs (rt_sigpending, rt_sigsuspend)

### Phase 2: UID/GID Infrastructure
- [x] 02-01: Add UID/GID tracking to Process struct
- [x] 02-02: Implement fsuid/fsgid setters with auto-sync
- [x] 02-03: Implement credential syscalls (setreuid, setregid, getgroups, setgroups)

### Phase 3: File Ownership
- [x] 03-01: Implement chown, fchown, lchown
- [x] 03-02: Add SFS FileOps.chown support

### Phase 4: I/O Multiplexing Infrastructure
- [x] 04-01: Add FileOps.poll to all FD types
- [x] 04-02: Upgrade epoll_wait to real dispatch
- [x] 04-03: Implement select/pselect6/ppoll

### Phase 5: Event Notification FDs
- [x] 05-01: Implement eventfd with epoll integration
- [x] 05-02: Implement timerfd (polling-based)
- [x] 05-03: Implement signalfd with epoll integration

### Phase 6: Vectored & Positional I/O
- [x] 06-01: Implement readv, preadv
- [x] 06-02: Implement pwritev, preadv2, pwritev2
- [x] 06-03: Implement sendfile

### Phase 7: Filesystem Extras
- [x] 07-01: Fix *at syscall double-copy bug
- [x] 07-02: Implement utimensat, futimesat
- [x] 07-03: Implement readlinkat, linkat, symlinkat

### Phase 8: Socket Extras
- [x] 08-01: Fix IrqLock initialization ordering
- [x] 08-02: Implement socketpair, shutdown
- [x] 08-03: Implement sendto/recvfrom, sendmsg/recvmsg

### Phase 9: Process Control & SysV IPC
- [x] 09-01: Implement prctl (PR_SET_NAME, PR_GET_NAME)
- [x] 09-02: Implement sched_setaffinity, sched_getaffinity
- [x] 09-03: Implement SysV shared memory (shmget, shmat, shmdt, shmctl)
- [x] 09-04: Implement SysV semaphores (semget, semop, semctl)
- [x] 09-05: Implement SysV message queues (msgget, msgsnd, msgrcv, msgctl)

</details>

<details>
<summary>✅ v1.1 Hardening & Debt Cleanup (Phases 10-14) - SHIPPED 2026-02-11</summary>

### Phase 10: Critical Kernel Bugs
- [x] 10-01: Fix setregid POSIX permission checks
- [x] 10-02: Implement SFS fchown via FileOps.chown
- [x] 10-03: Add stack buffer support to copyStringFromUser

### Phase 11: SFS Deadlock Fix
- [x] 11-01: Eliminate SFS close deadlock via io_lock + alloc_lock restructuring

### Phase 12: SFS Hard Link Support
- [x] 12-01: Implement SFS hard link with global nlink synchronization
- [x] 12-02: Add link/linkat with inode sharing

### Phase 13: SFS Symlink & Timestamp Support
- [x] 13-01: Implement SFS symbolic links (symlink/symlinkat/readlink/readlinkat)
- [x] 13-02: Implement SFS timestamp modification (utimensat/futimesat)

### Phase 14: WaitQueue Blocking & Optimizations
- [x] 14-01: Optimize sendfile buffer (4KB to 64KB)
- [x] 14-02: Add AT_SYMLINK_NOFOLLOW support in utimensat
- [x] 14-03: Replace timerfd yield-loop with WaitQueue blocking
- [x] 14-04: Replace signalfd yield-loop with WaitQueue blocking
- [x] 14-05: Replace semop/msgsnd/msgrcv blocking with WaitQueue
- [x] 14-06: Implement SEM_UNDO tracking with process exit cleanup
- [x] 14-07: Add dup3, accept4, getrlimit/setrlimit, sigaltstack, statfs/fstatfs, getresuid/getresgid

</details>

### 🚧 v1.2 Systematic Syscall Coverage (In Progress)

**Milestone Goal:** Systematic audit and implementation of missing high-value Linux syscalls across 12 categories, with comprehensive dual-arch test coverage.

#### Phase 15: File Synchronization
**Goal**: File data and metadata can be explicitly synchronized to storage
**Depends on**: Phase 14
**Requirements**: FSYNC-01, FSYNC-02, FSYNC-03, FSYNC-04
**Success Criteria** (what must be TRUE):
  1. User can call fsync on a file descriptor to flush data and metadata to disk
  2. User can call fdatasync to flush data without forcing metadata sync
  3. User can call sync to trigger global filesystem buffer flush
  4. User can call syncfs to flush buffers for a specific mounted filesystem
  5. All sync syscalls work on both x86_64 and aarch64

**Plans**: 1 plan

Plans:
- [x] 15-01-PLAN.md -- Implement fsync, fdatasync, sync, syncfs syscalls with wrappers and tests

#### Phase 16: Advanced File Operations
**Goal**: File space can be pre-allocated and renamed atomically with flags
**Depends on**: Phase 15
**Requirements**: FOPS-01, FOPS-02
**Success Criteria** (what must be TRUE):
  1. User can call fallocate to pre-allocate space for a file with mode flags (FALLOC_FL_KEEP_SIZE, FALLOC_FL_PUNCH_HOLE)
  2. User can call renameat2 with RENAME_NOREPLACE to fail if destination exists
  3. User can call renameat2 with RENAME_EXCHANGE to atomically swap two files
  4. Both syscalls work correctly on SFS and InitRD where applicable

**Plans**: 1 plan

Plans:
- [x] 16-01-PLAN.md -- Implement fallocate and renameat2 syscalls with VFS/SFS support and tests

#### Phase 17: Zero-Copy I/O
**Goal**: Data can be moved between file descriptors and pipes without user-space copies
**Depends on**: Phase 16
**Requirements**: ZCIO-01, ZCIO-02, ZCIO-03, ZCIO-04
**Success Criteria** (what must be TRUE):
  1. User can call splice to move data from a file to a pipe (or vice versa) without copying through user space
  2. User can call tee to duplicate pipe data to another pipe without consuming the source
  3. User can call vmsplice to map user memory pages directly into a pipe buffer
  4. User can call copy_file_range to copy data between two files within the kernel
  5. All operations return correct byte counts and handle partial transfers

**Plans**: 2 plans

Plans:
- [x] 17-01-PLAN.md -- Implement splice, tee, vmsplice, copy_file_range syscalls with pipe helpers and tests
- [x] 17-02-PLAN.md -- Fix tee repeated-peek bug, rewrite copy_file_range tests to avoid SFS deadlock

#### Phase 18: Memory Management Extensions
**Goal**: Advanced memory operations (anonymous files, remap, sync) are available
**Depends on**: Phase 17
**Requirements**: MEM-01, MEM-02, MEM-03
**Success Criteria** (what must be TRUE):
  1. User can call memfd_create to create an anonymous memory-backed file descriptor
  2. User can call mremap to resize or move an existing memory mapping with MREMAP_MAYMOVE flag
  3. User can call msync to flush changes in a memory-mapped region back to the underlying file
  4. memfd files can be mmap'd, written to, and shared across processes

**Plans**: 1 plan

Plans:
- [x] 18-01-PLAN.md -- Implement memfd_create, mremap, msync with PMM-backed memfd FileOps and tests

#### Phase 19: Process Control Extensions
**Goal**: Modern process creation and waiting mechanisms are available
**Depends on**: Phase 18
**Requirements**: PROC-01, PROC-02
**Success Criteria** (what must be TRUE):
  1. User can call clone3 with struct clone_args for fine-grained control over process creation
  2. User can call waitid to wait for child process state changes with extended options (WEXITED, WSTOPPED, WCONTINUED)
  3. waitid supports P_PID, P_PGID, P_ALL id types
  4. Both syscalls work on x86_64 and aarch64 with identical behavior

**Plans**: 1 plan

Plans:
- [x] 19-01-PLAN.md -- Implement clone3 and waitid syscalls with struct-based args, siginfo_t output, and tests

#### Phase 20: Signal Handling Extensions
**Goal**: Synchronous signal waiting and queuing with extended options are available
**Depends on**: Phase 19
**Requirements**: SIG-01, SIG-02, SIG-03
**Success Criteria** (what must be TRUE):
  1. User can call rt_sigtimedwait to synchronously wait for a signal with a timeout
  2. User can call rt_sigqueueinfo to send a signal with associated siginfo_t data
  3. User can call clock_nanosleep to sleep using a specific clock source (CLOCK_REALTIME, CLOCK_MONOTONIC) with TIMER_ABSTIME flag
  4. Signal operations integrate correctly with existing rt_sigaction/rt_sigprocmask

**Plans**: 1 plan

Plans:
- [x] 20-01-PLAN.md -- Implement rt_sigtimedwait, rt_sigqueueinfo, rt_tgsigqueueinfo, clock_nanosleep with wrappers and tests

#### Phase 21: I/O Multiplexing Extension
**Goal**: epoll supports signal mask atomicity for race-free event waiting
**Depends on**: Phase 20
**Requirements**: EPOLL-01
**Success Criteria** (what must be TRUE):
  1. User can call epoll_pwait to wait for events while atomically setting a signal mask
  2. Signal mask is applied before event check and restored after return, preventing TOCTTOU races
  3. Behavior matches epoll_wait when sigmask is NULL

**Plans**: 1 plan

Plans:
- [x] 21-01-PLAN.md -- Implement epoll_pwait syscall with signal mask atomicity, userspace wrapper, and integration tests

#### Phase 22: File Monitoring
**Goal**: File and directory changes can be monitored via inotify
**Depends on**: Phase 21
**Requirements**: INOT-01, INOT-02, INOT-03, INOT-04
**Success Criteria** (what must be TRUE):
  1. User can call inotify_init1 to create an inotify instance with IN_NONBLOCK and IN_CLOEXEC flags
  2. User can call inotify_add_watch to monitor a file or directory for events (IN_MODIFY, IN_CREATE, IN_DELETE, etc.)
  3. User can call inotify_rm_watch to stop monitoring a watch descriptor
  4. User can read inotify_event structures from the inotify file descriptor via read()
  5. inotify FDs work with epoll for efficient event-driven monitoring

**Plans**: 1 plan

Plans:
- [x] 22-01-PLAN.md -- Implement inotify subsystem with init1/add_watch/rm_watch syscalls, VFS event hooks, and integration tests

#### Phase 23: POSIX Timers
**Goal**: Per-process interval timers with signal delivery are available
**Depends on**: Phase 22
**Requirements**: PTMR-01, PTMR-02, PTMR-03, PTMR-04, PTMR-05
**Success Criteria** (what must be TRUE):
  1. User can call timer_create to create a POSIX timer with a specific clock source and signal notification
  2. User can call timer_settime to arm a timer with initial expiration and interval
  3. User can call timer_gettime to query remaining time until next expiration
  4. User can call timer_getoverrun to get the overrun count after a signal delivery
  5. User can call timer_delete to destroy a timer and free resources
  6. Timers deliver signals (SIGALRM or custom) on expiration

**Plans**: 1 plan

Plans:
- [x] 23-01-PLAN.md -- Implement POSIX timer syscalls with per-process storage, scheduler integration, and tests

#### Phase 24: Capabilities
**Goal**: Process capability bitmaps can be queried and modified
**Depends on**: Phase 23
**Requirements**: CAP-01, CAP-02
**Success Criteria** (what must be TRUE):
  1. User can call capget to retrieve effective/permitted/inheritable capability sets for a process
  2. User can call capset to modify capability sets (subject to security rules)
  3. Capability checks integrate with existing permission checks in syscalls
  4. Capabilities support both v1 (32-bit) and v3 (64-bit) formats

**Plans**: 1 plan

Plans:
- [ ] 24-01-PLAN.md -- Implement capget/capset syscalls with per-process bitmasks, v1/v3 format support, and tests

#### Phase 25: Seccomp
**Goal**: Syscall filtering via seccomp for sandboxing is available
**Depends on**: Phase 24
**Requirements**: SEC-01, SEC-02
**Success Criteria** (what must be TRUE):
  1. User can call seccomp with SECCOMP_SET_MODE_STRICT to restrict to read/write/exit/sigreturn
  2. User can call seccomp with SECCOMP_SET_MODE_FILTER to install a BPF program that filters syscalls
  3. BPF filter returns are honored (SECCOMP_RET_ALLOW, SECCOMP_RET_KILL, SECCOMP_RET_ERRNO)
  4. Seccomp state is inherited across fork and enforced on both architectures
  5. Attempting a disallowed syscall results in process termination or error

**Plans**: TBD

Plans:
- [ ] 25-01: TBD

#### Phase 26: Test Coverage Expansion
**Goal**: Integration tests exist for all previously-untested existing syscalls
**Depends on**: Phase 25
**Requirements**: TEST-01, TEST-02, TEST-03, TEST-04, TEST-05, TEST-06, TEST-07, TEST-08
**Success Criteria** (what must be TRUE):
  1. Integration tests exist for file ownership syscalls (fchown, lchown, fchdir) covering success and error cases
  2. Integration tests exist for memory advisory syscalls (madvise, mincore) verifying stub behavior
  3. Integration tests exist for signal state syscalls (rt_sigpending, rt_sigsuspend) with blocked/pending signal scenarios
  4. Integration tests exist for resource limit syscalls (setrlimit, getrusage) covering basic operations
  5. Integration tests exist for credential variants (setreuid, setregid, setfsuid, setfsgid) with permission checks
  6. Integration tests exist for time setter syscalls (settimeofday) with privilege enforcement
  7. Integration tests exist for select() and epoll edge cases (timeout, empty sets, maxfd boundaries)
  8. Integration tests exist for scheduling syscalls (sched_rr_get_interval) verifying return values
  9. All new tests pass on both x86_64 and aarch64

**Plans**: TBD

Plans:
- [ ] 26-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 15 -> 16 -> 17 -> 18 -> 19 -> 20 -> 21 -> 22 -> 23 -> 24 -> 25 -> 26

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
| 24. Capabilities | v1.2 | Complete    | 2026-02-16 | - |
| 25. Seccomp | v1.2 | 0/TBD | Not started | - |
| 26. Test Coverage Expansion | v1.2 | 0/TBD | Not started | - |

---
*Roadmap created: 2026-02-11*
*Last updated: 2026-02-15 (Phase 24 planned)*
