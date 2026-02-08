# Roadmap: ZK Kernel POSIX Syscall Coverage

## Overview

Systematic expansion of Linux/POSIX syscall coverage from 190 to 300+ syscalls across nine implementation phases. Each phase completes a coherent subsystem, validates on both x86_64 and aarch64, and maintains the existing 166 passing tests. The journey moves from trivial stubs (quick wins) through credential infrastructure, I/O multiplexing, event notification, vectored I/O, filesystem completeness, socket extras, process control, and legacy SysV IPC support.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Quick Wins - Trivial Stubs** - 14 missing syscalls (10 already implemented) returning defaults/no-ops
- [x] **Phase 2: Credentials & Ownership** - UID/GID infrastructure + chown family
- [x] **Phase 3: I/O Multiplexing** - epoll backend + select/pselect6
- [x] **Phase 4: Event Notification FDs** - eventfd, timerfd, signalfd
- [ ] **Phase 5: Vectored & Positional I/O** - readv/preadv/sendfile
- [ ] **Phase 6: Filesystem Extras** - readlinkat, linkat, symlinkat, utimensat
- [ ] **Phase 7: Socket Extras** - socketpair, shutdown, sendto/recvfrom, recvmsg/sendmsg
- [ ] **Phase 8: Process Control** - prctl, sched affinity
- [ ] **Phase 9: SysV IPC** - shared memory, semaphores, message queues

## Phase Details

### Phase 1: Quick Wins - Trivial Stubs
**Goal**: Implement 14 missing trivial syscalls (of 24 originally scoped -- 10 already exist) that return defaults, hardcoded values, or accept-but-ignore parameters to boost coverage and prevent programs from crashing when they probe capabilities
**Depends on**: Nothing (first phase)
**Requirements**: STUB-01 through STUB-24
**Success Criteria** (what must be TRUE):
  1. Programs can call dup3/accept4 with O_CLOEXEC/O_NONBLOCK flags and receive valid file descriptors
  2. Programs can query resource limits via getrlimit/prlimit64 and receive sensible defaults (no crashes)
  3. Programs can query scheduling parameters (sched_getscheduler, sched_get_priority_max/min) and receive valid values
  4. Programs can query filesystem stats (statfs/fstatfs) and receive basic metadata
  5. Programs can query signal/memory state (rt_sigpending, getresuid/getresgid, mincore) without ENOSYS errors
**Plans**: 4 plans

Plans:
- [x] 01-01-PLAN.md -- Infrastructure: syscall numbers, Process struct fields, memory no-ops (madvise, mlock, munlock, mlockall, munlockall, mincore)
- [x] 01-02-PLAN.md -- Scheduling stubs: sched_get/set_priority/scheduler/param, sched_rr_get_interval, ppoll
- [x] 01-03-PLAN.md -- Resource limits and signals: prlimit64, getrusage, rt_sigpending, rt_sigsuspend
- [x] 01-04-PLAN.md -- Integration tests and userspace wrappers for all 14 new syscalls

### Phase 2: Credentials & Ownership
**Goal**: Implement user/group ID tracking and manipulation infrastructure, enabling multi-user permission checks and file ownership changes
**Depends on**: Phase 1
**Requirements**: CRED-01, CRED-02, CRED-03, CRED-04, CRED-05, CRED-06, CRED-07, CRED-08, CRED-09, CRED-10, CRED-11, CRED-12, CRED-13, CRED-14
**Success Criteria** (what must be TRUE):
  1. Processes can change effective UID/GID via setuid/setgid syscalls and subsequent permission checks honor the new identity
  2. Processes can atomically set real/effective/saved UID/GID via setreuid/setregid/setresuid/setresgid
  3. Processes can manage supplementary groups via getgroups/setgroups and membership affects file access checks
  4. File owner and group can be changed via chown/fchown/lchown/fchownat with proper permission validation
  5. Filesystem UID/GID can be set independently for permission checks via setfsuid/setfsgid
**Plans**: 4 plans

Plans:
- [x] 02-01-PLAN.md -- Infrastructure: fsuid/fsgid fields, syscall numbers (both arch), perms.zig fsuid, auto-sync, userspace wrappers
- [x] 02-02-PLAN.md -- Credential syscalls: setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid
- [x] 02-03-PLAN.md -- Chown family: enhanced sys_chown with POSIX enforcement, fchown, lchown, fchownat, FileOps.chown, suid/sgid clearing
- [x] 02-04-PLAN.md -- Integration tests: 21 tests with fork isolation covering all new syscalls

### Phase 3: I/O Multiplexing
**Goal**: Complete the existing epoll infrastructure by implementing FileOps.poll for pipes, sockets, and regular files, enabling select/pselect6 and functional epoll_wait
**Depends on**: Phase 2
**Requirements**: MUX-01, MUX-02, MUX-03, MUX-04, MUX-05, MUX-06
**Success Criteria** (what must be TRUE):
  1. Programs can use epoll_wait to monitor pipes and receive EPOLLIN events when data is available
  2. Programs can use epoll_wait to monitor sockets and receive EPOLLIN/EPOLLOUT events based on recv/send queue state
  3. Programs can use select/pselect6 to monitor multiple file descriptors with timeout support
  4. Programs like nginx, redis, and Python asyncio can use epoll for async I/O without errors
**Plans**: 4 plans

Plans:
- [x] 03-01-PLAN.md -- FileOps.poll implementations for pipes, regular files (initrd, SFS), and DevFS devices
- [x] 03-02-PLAN.md -- Upgrade sys_epoll_wait with real poll dispatch, blocking, edge-triggered, EPOLLONESHOT
- [x] 03-03-PLAN.md -- Upgrade sys_select/sys_poll/sys_ppoll to use FileOps.poll, add sys_pselect6, userspace wrappers
- [x] 03-04-PLAN.md -- Integration tests: epoll with pipes/files, select read/write/timeout, poll pipe events

### Phase 4: Event Notification FDs
**Goal**: Implement eventfd, timerfd, and signalfd as pollable file descriptor types that integrate with the completed epoll backend
**Depends on**: Phase 3
**Requirements**: EVT-01, EVT-02, EVT-03, EVT-04, EVT-05, EVT-06, EVT-07
**Success Criteria** (what must be TRUE):
  1. Programs can create eventfd with eventfd2 and use read/write to increment/decrement counters
  2. Programs can create timerfd with timerfd_create, arm it with timerfd_settime, and read expiration events
  3. Programs can query timer state with timerfd_gettime to get time until next expiration
  4. Programs can create signalfd with signalfd4 and receive signal information via read (filtered by signal mask)
  5. All event FDs (eventfd, timerfd, signalfd) can be monitored via epoll_wait and trigger EPOLLIN when ready
**Plans**: 4 plans

Plans:
- [x] 04-01-PLAN.md -- UAPI constants (all three types) + eventfd kernel implementation + userspace wrappers
- [x] 04-02-PLAN.md -- timerfd kernel implementation (polling-based expiration) + userspace wrappers
- [x] 04-03-PLAN.md -- signalfd kernel implementation (signal consumption via pending_signals) + userspace wrappers
- [x] 04-04-PLAN.md -- Integration tests: eventfd/timerfd/signalfd creation, read/write, epoll integration

### Phase 5: Vectored & Positional I/O
**Goal**: Implement readv/writev families and sendfile for efficient database and file server I/O patterns
**Depends on**: Phase 4
**Requirements**: VIO-01, VIO-02, VIO-03, VIO-04, VIO-05, VIO-06, VIO-07
**Success Criteria** (what must be TRUE):
  1. Programs can read into multiple buffers with readv and write from multiple buffers with writev
  2. Programs can perform positional I/O with preadv/pwritev at specified file offsets without changing file position
  3. Programs can use preadv2/pwritev2 with RWF_NOWAIT and RWF_HIPRI flags for advanced I/O control
  4. Programs can copy file data to sockets via sendfile without userspace buffer copies
  5. Database workloads (SQLite, Postgres patterns) show no errors when using vectored I/O APIs
**Plans**: TBD

Plans:
- [ ] 05-01: TBD

### Phase 6: Filesystem Extras
**Goal**: Fix *at syscall double-copy bugs and implement timestamp manipulation for filesystem completeness
**Depends on**: Phase 5
**Requirements**: FS-01, FS-02, FS-03, FS-04, FS-05
**Success Criteria** (what must be TRUE):
  1. Programs can read symlink targets via readlinkat with directory file descriptors
  2. Programs can create hard links via linkat and symbolic links via symlinkat with AT_FDCWD and explicit dirfd support
  3. Programs can set file timestamps with nanosecond precision via utimensat (replaces futimesat)
  4. File management tools (tar, rsync patterns) work correctly with *at family syscalls
**Plans**: 3 plans

Plans:
- [ ] 06-01-PLAN.md -- Fix *at double-copy bugs (linkKernel/symlinkKernel/readlinkKernel helpers) + VFS timestamp infrastructure + syscall numbers
- [ ] 06-02-PLAN.md -- Implement sys_utimensat + sys_futimesat + userspace wrappers
- [ ] 06-03-PLAN.md -- Integration tests: 12 tests covering readlinkat, linkat, symlinkat, utimensat, futimesat

### Phase 7: Socket Extras
**Goal**: Implement socketpair, shutdown, and sendto/recvfrom/sendmsg/recvmsg for complete BSD socket API coverage
**Depends on**: Phase 6
**Requirements**: SOCK-01, SOCK-02, SOCK-03, SOCK-04, SOCK-05, SOCK-06
**Success Criteria** (what must be TRUE):
  1. Programs can create connected AF_UNIX socket pairs via socketpair for bidirectional IPC
  2. Programs can shutdown send/receive on sockets via shutdown with SHUT_RD/WR/RDWR
  3. Programs can send/receive datagrams with destination/source addresses via sendto/recvfrom
  4. Programs can send/receive messages with control data (ancillary data) via sendmsg/recvmsg
**Plans**: TBD

Plans:
- [ ] 07-01: TBD

### Phase 8: Process Control
**Goal**: Implement prctl for process naming and sched_setaffinity/getaffinity for CPU pinning
**Depends on**: Phase 7
**Requirements**: PROC-01, PROC-02, PROC-03
**Success Criteria** (what must be TRUE):
  1. Programs can set/get process name via prctl with PR_SET_NAME/PR_GET_NAME
  2. Programs can pin processes to specific CPU cores via sched_setaffinity and query affinity via sched_getaffinity
  3. Container-style init systems and NUMA-aware applications can control process-CPU affinity
**Plans**: TBD

Plans:
- [ ] 08-01: TBD

### Phase 9: SysV IPC
**Goal**: Implement legacy SysV IPC shared memory, semaphores, and message queues for Postgres/Redis compatibility
**Depends on**: Phase 8
**Requirements**: IPC-01, IPC-02, IPC-03, IPC-04, IPC-05, IPC-06, IPC-07, IPC-08, IPC-09, IPC-10, IPC-11
**Success Criteria** (what must be TRUE):
  1. Programs can allocate shared memory segments via shmget and attach them to address space via shmat
  2. Programs can detach shared memory via shmdt and control segments via shmctl (IPC_STAT, IPC_RMID)
  3. Programs can create semaphore sets via semget, perform atomic operations via semop, and control semaphores via semctl
  4. Programs can create message queues via msgget, send/receive messages via msgsnd/msgrcv, and control queues via msgctl
  5. Legacy applications like Postgres (using SysV shared memory) can run without IPC-related errors
**Plans**: TBD

Plans:
- [ ] 09-01: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Quick Wins - Trivial Stubs | 4/4 | Complete | 2026-02-06 |
| 2. Credentials & Ownership | 4/4 | Complete | 2026-02-06 |
| 3. I/O Multiplexing | 4/4 | Complete | 2026-02-07 |
| 4. Event Notification FDs | 4/4 | Complete | 2026-02-07 |
| 5. Vectored & Positional I/O | 0/TBD | Not started | - |
| 6. Filesystem Extras | 0/3 | Planned | - |
| 7. Socket Extras | 0/TBD | Not started | - |
| 8. Process Control | 0/TBD | Not started | - |
| 9. SysV IPC | 0/TBD | Not started | - |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-08*
