# Requirements: ZK Kernel POSIX Syscall Coverage

**Defined:** 2026-02-06
**Core Value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.

## v1 Requirements

Requirements for this milestone. Each maps to roadmap phases.

### Quick Wins - Trivial Stubs

- [ ] **STUB-01**: dup3 returns new fd with O_CLOEXEC flag support
- [ ] **STUB-02**: accept4 returns new socket fd with O_CLOEXEC/O_NONBLOCK flags
- [x] **STUB-03**: ppoll blocks on fd set with signal mask and timeout
- [ ] **STUB-04**: getrlimit returns per-process resource limits (hardcoded defaults)
- [ ] **STUB-05**: setrlimit sets per-process resource limits
- [x] **STUB-06**: prlimit64 gets/sets resource limits for any process
- [x] **STUB-07**: getrusage returns resource usage stats (user/system time, max RSS)
- [x] **STUB-08**: rt_sigpending returns set of pending signals
- [x] **STUB-09**: rt_sigsuspend atomically replaces signal mask and suspends
- [ ] **STUB-10**: sigaltstack sets/gets alternate signal stack
- [x] **STUB-11**: sched_get_priority_max returns max priority for scheduling policy
- [x] **STUB-12**: sched_get_priority_min returns min priority for scheduling policy
- [x] **STUB-13**: sched_getscheduler returns scheduling policy for process
- [x] **STUB-14**: sched_getparam returns scheduling parameters for process
- [x] **STUB-15**: sched_rr_get_interval returns round-robin time quantum
- [ ] **STUB-16**: statfs returns filesystem statistics for path
- [ ] **STUB-17**: fstatfs returns filesystem statistics for fd
- [x] **STUB-18**: madvise accepts memory usage hints (no-op initially)
- [x] **STUB-19**: mlock/munlock accept page locking requests (no-op initially)
- [x] **STUB-20**: mlockall/munlockall accept process-wide locking requests (no-op initially)
- [x] **STUB-21**: mincore reports page residency (all pages resident initially)
- [ ] **STUB-22**: getresuid/getresgid return real/effective/saved UID/GID
- [x] **STUB-23**: sched_setscheduler sets scheduling policy (validates args, stores policy)
- [x] **STUB-24**: sched_setparam sets scheduling parameters (validates args, stores params)

### Credentials & Ownership

- [x] **CRED-01**: setuid sets effective UID for calling process
- [x] **CRED-02**: setgid sets effective GID for calling process
- [x] **CRED-03**: setreuid sets real and effective UID atomically
- [x] **CRED-04**: setregid sets real and effective GID atomically
- [x] **CRED-05**: setresuid sets real, effective, and saved UID
- [x] **CRED-06**: setresgid sets real, effective, and saved GID
- [x] **CRED-07**: getgroups returns supplementary group list
- [x] **CRED-08**: setgroups sets supplementary group list
- [x] **CRED-09**: setfsuid sets filesystem UID for permission checks
- [x] **CRED-10**: setfsgid sets filesystem GID for permission checks
- [x] **CRED-11**: chown changes file owner and group by path
- [x] **CRED-12**: fchown changes file owner and group by fd
- [x] **CRED-13**: lchown changes symlink owner and group (no follow)
- [x] **CRED-14**: fchownat changes file owner and group with dirfd

### I/O Multiplexing

- [ ] **MUX-01**: epoll backend completes FileOps.poll for pipes
- [ ] **MUX-02**: epoll backend completes FileOps.poll for sockets
- [ ] **MUX-03**: epoll backend completes FileOps.poll for regular files (always ready)
- [ ] **MUX-04**: epoll_wait returns real events from monitored fds
- [ ] **MUX-05**: select blocks on fd sets (read/write/except) with timeout
- [ ] **MUX-06**: pselect6 provides select with signal mask atomicity

### Event Notification FDs

- [ ] **EVT-01**: eventfd2 creates event counter fd with O_CLOEXEC/O_NONBLOCK
- [ ] **EVT-02**: eventfd read/write semantics (counter increment/decrement/block)
- [ ] **EVT-03**: timerfd_create creates timer fd
- [ ] **EVT-04**: timerfd_settime arms/disarms timer with absolute or relative time
- [ ] **EVT-05**: timerfd_gettime returns time until next expiration
- [ ] **EVT-06**: signalfd4 creates signal fd with signal mask filter
- [ ] **EVT-07**: All event fds integrate with epoll (pollable)

### Vectored & Positional I/O

- [ ] **VIO-01**: readv reads into multiple buffers from single fd
- [ ] **VIO-02**: writev writes from multiple buffers (already exists, verify)
- [ ] **VIO-03**: preadv reads into multiple buffers at offset
- [ ] **VIO-04**: pwritev writes from multiple buffers at offset
- [ ] **VIO-05**: preadv2 adds per-call flags (RWF_NOWAIT, RWF_HIPRI)
- [ ] **VIO-06**: pwritev2 adds per-call flags
- [ ] **VIO-07**: sendfile copies data between fds in kernel space

### Filesystem Extras

- [ ] **FS-01**: readlinkat reads symlink target with dirfd
- [ ] **FS-02**: linkat creates hard link with dirfd
- [ ] **FS-03**: symlinkat creates symlink with dirfd
- [ ] **FS-04**: utimensat sets file timestamps with nanosecond precision
- [ ] **FS-05**: futimesat sets file timestamps (legacy, wraps utimensat)

### Socket Extras

- [ ] **SOCK-01**: socketpair creates connected AF_UNIX socket pair
- [ ] **SOCK-02**: shutdown disables send/receive on socket (SHUT_RD/WR/RDWR)
- [ ] **SOCK-03**: sendto sends datagram with destination address
- [ ] **SOCK-04**: recvfrom receives datagram with source address
- [ ] **SOCK-05**: recvmsg receives message with control data
- [ ] **SOCK-06**: sendmsg sends message with control data

### Process Control

- [ ] **PROC-01**: prctl performs process control operations (PR_SET_NAME, PR_GET_NAME minimum)
- [ ] **PROC-02**: sched_setaffinity pins process to CPU core set
- [ ] **PROC-03**: sched_getaffinity returns CPU affinity mask

### SysV IPC - Shared Memory

- [ ] **IPC-01**: shmget allocates shared memory segment
- [ ] **IPC-02**: shmat attaches shared memory to process address space
- [ ] **IPC-03**: shmdt detaches shared memory from process
- [ ] **IPC-04**: shmctl performs shared memory control (IPC_STAT, IPC_RMID)

### SysV IPC - Semaphores

- [ ] **IPC-05**: semget creates or gets semaphore set
- [ ] **IPC-06**: semop performs atomic semaphore operations
- [ ] **IPC-07**: semctl performs semaphore control (SETVAL, GETVAL, IPC_RMID)

### SysV IPC - Message Queues

- [ ] **IPC-08**: msgget creates or gets message queue
- [ ] **IPC-09**: msgsnd sends message to queue
- [ ] **IPC-10**: msgrcv receives message from queue
- [ ] **IPC-11**: msgctl performs message queue control (IPC_STAT, IPC_RMID)

### Testing

- [ ] **TEST-01**: Every new syscall has at least one success-path integration test
- [ ] **TEST-02**: Every new syscall has at least one error-path integration test
- [ ] **TEST-03**: All tests pass on both x86_64 and aarch64
- [ ] **TEST-04**: No regressions in existing 166 passing tests
- [ ] **TEST-05**: Userspace wrappers added to libc for all new syscalls

## v2 Requirements

Deferred to future milestone. Tracked but not in current roadmap.

### File Change Monitoring

- **WATCH-01**: inotify_init1 creates inotify instance
- **WATCH-02**: inotify_add_watch monitors file/directory for changes
- **WATCH-03**: inotify_rm_watch stops monitoring

### Zero-Copy Pipe Operations

- **ZERO-01**: splice moves data between pipe and fd without userspace copy
- **ZERO-02**: tee duplicates pipe data to another pipe
- **ZERO-03**: vmsplice maps user pages into pipe

### Advanced Memory

- **MEM-01**: mremap resizes or moves memory mapping
- **MEM-02**: msync flushes mmap changes to backing file

### Extended Attributes

- **XATTR-01**: setxattr/getxattr/listxattr/removexattr on paths
- **XATTR-02**: fsetxattr/fgetxattr/flistxattr/fremovexattr on fds
- **XATTR-03**: lsetxattr/lgetxattr/llistxattr/lremovexattr (no follow)

### Containers & Namespaces

- **NS-01**: unshare creates new namespaces
- **NS-02**: setns enters existing namespace
- **NS-03**: clone3 extended clone with struct args

## Out of Scope

| Feature | Reason |
|---------|--------|
| ptrace | Extremely complex, separate debugger project |
| Module loading (init_module, delete_module) | Microkernel, not applicable |
| Legacy signal syscalls (signal, sigaction, sigprocmask) | rt_* versions already implemented |
| Deprecated syscalls (uselib, _sysctl, create_module, remap_file_pages) | Removed from modern Linux |
| x86-specific (iopl, ioperm, modify_ldt, vm86) | Not portable, security risk |
| Kernel log (syslog) | No kernel ring buffer currently |
| Swap (swapon, swapoff) | No swap subsystem |
| Quotas (quotactl) | No quota subsystem |
| Filesystem mount rework (pivot_root, mount, umount) | VFS redesign is separate effort |
| Full futex (PI, requeue, robust lists) | Basic futex exists; advanced is separate |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| STUB-01 through STUB-24 | Phase 1 | Complete |
| CRED-01 through CRED-14 | Phase 2 | Pending |
| MUX-01 through MUX-06 | Phase 3 | Pending |
| EVT-01 through EVT-07 | Phase 4 | Pending |
| VIO-01 through VIO-07 | Phase 5 | Pending |
| FS-01 through FS-05 | Phase 6 | Pending |
| SOCK-01 through SOCK-06 | Phase 7 | Pending |
| PROC-01 through PROC-03 | Phase 8 | Pending |
| IPC-01 through IPC-11 | Phase 9 | Pending |
| TEST-01 through TEST-05 | All Phases | Pending |

**Coverage:**
- v1 requirements: 87 total
- Mapped to phases: 87
- Unmapped: 0

---
*Requirements defined: 2026-02-06*
*Last updated: 2026-02-06 after initial definition*
