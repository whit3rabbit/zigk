# Linux Syscall Coverage Analysis for zk Kernel

## Executive Summary

This document categorizes the 230 unimplemented Linux syscalls (out of 420 total) by importance for real-world program compatibility. Research shows that **only ~160 syscalls are needed to run complex applications** like Redis, SQLite, NGINX, and Python (per Unikraft study), suggesting zk's current 190 syscalls already cover most critical functionality.

## Methodology

Analysis based on:
- Real-world syscall tracing of common programs (busybox, dash, coreutils, musl-linked binaries)
- Server application requirements (nginx, redis, python, curl)
- Linux kernel documentation and implementation complexity
- Industry research (Unikraft compatibility studies, strace frequency analysis)

## Current Status: 190/420 Syscalls Implemented

**Already in zk:**
- File I/O: open, openat, read, write, close, lseek, dup, dup2, pipe, pipe2, fcntl, pread64, writev, flock, stat, fstat, lstat, chmod, access, truncate, rename, link, symlink, readlink
- Directory: mkdir, rmdir, chdir, getcwd, getdents64
- *at family: fstatat, mkdirat, unlinkat, renameat, fchmodat, faccessat
- Memory: mmap, munmap, brk, mprotect
- Process: fork, execve, clone, wait4, exit, exit_group, getpid, getppid, setpgid, getpgid, getpgrp, setsid, getsid
- Signals: rt_sigaction, rt_sigprocmask, rt_sigreturn, kill, tgkill
- Time: nanosleep, clock_gettime, clock_getres, gettimeofday, alarm, pause, getitimer, setitimer
- Network: socket, bind, listen, accept, connect, send, recv, setsockopt, getsockopt
- Misc: uname, umask, getrandom, sysinfo, times, poll, ioctl (partial)

---

## Category 1: Table Stakes (Critical - Programs Crash Without These)

These syscalls are called frequently by common programs. Missing implementations cause immediate failures with ENOSYS errors.

### 1.1 I/O Multiplexing (CRITICAL)
Programs that handle multiple connections or file descriptors simultaneously require these. Absence breaks servers and async I/O patterns.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **epoll_create** | Medium | nginx, redis, python (asyncio), node.js | Core event loop primitive. Creates epoll instance. |
| **epoll_create1** | Trivial | Modern programs (post-2008) | Like epoll_create but supports O_CLOEXEC flag. |
| **epoll_ctl** | Medium | All epoll users | Modifies epoll interest list. Needs per-fd tracking. |
| **epoll_wait** | Medium | All epoll users | Blocks until events ready. Scheduler integration required. |
| **epoll_pwait** | Medium | Signal-aware async programs | epoll_wait + sigmask atomicity. |
| **select** | Medium | Legacy programs, shell scripts | Older multiplexing API. Less efficient than epoll. |
| **pselect6** | Medium | Signal-safe select users | select + sigmask atomicity. |
| **poll** | Trivial | Already implemented (in misc) | Similar to select but different API. |
| **ppoll** | Trivial | Signal-safe poll users | poll + sigmask atomicity. |

**Priority: HIGHEST** - epoll family required for modern server software.

**Dependencies:**
- Needs: File descriptor event notification infrastructure
- Builds on: Existing poll() implementation
- Scheduler: Must integrate with blocking/wakeup mechanisms

### 1.2 Vectored I/O (HIGH)
Essential for efficient bulk I/O operations. Used by databases, file servers, network stacks.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **readv** | Trivial | nginx, databases, network daemons | Multi-buffer read. Iterate iovec array. |
| **preadv** | Trivial | Databases (SQLite, Postgres) | readv + offset (no lseek needed). |
| **preadv2** | Medium | Modern databases | preadv + flags (RWF_HIPRI, RWF_NOWAIT). |
| **pwritev** | Trivial | Databases, loggers | writev + offset. |
| **pwritev2** | Medium | Modern databases | pwritev + flags. |

**Priority: HIGH** - Required for database and network performance.

**Dependencies:**
- Needs: iovec struct handling, multi-buffer validation
- Builds on: Existing read/write/writev infrastructure

### 1.3 Zero-Copy I/O (MEDIUM)
Performance optimization for file serving and proxying.

| Syscall | Complexity | Medium | Users | Implementation Notes |
|---------|------------|--------|-------|---------------------|
| **sendfile** | Medium | nginx, Apache, file servers | Copy between file descriptors in kernel space. |
| **splice** | Medium | Proxies, data pipelines | Move data between pipes/files without userspace copy. |
| **tee** | Low | Log multiplexing | Duplicate pipe data. |
| **vmsplice** | Low | Rare (specialized pipe users) | Splice user pages into pipe. |

**Priority: MEDIUM** - Nice performance boost but not required for correctness.

**Dependencies:**
- Needs: Kernel buffer management, pipe infrastructure
- Builds on: Existing pipe implementation

### 1.4 Modern fd Creation (HIGH)
Programs expect these for race-free fd creation with flags.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **dup3** | Trivial | Modern programs using O_CLOEXEC | dup2 + O_CLOEXEC flag support. |
| **accept4** | Trivial | Network servers | accept + O_CLOEXEC/O_NONBLOCK flags. |

**Priority: HIGH** - Standard pattern in modern code.

**Dependencies:**
- Builds on: Existing dup2/accept implementations
- Just adds flag handling

### 1.5 Resource Limits (HIGH)
Almost all programs query limits at startup (stack size, fd limits, etc.).

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **getrlimit** | Trivial | Almost all programs | Return per-process resource limits. |
| **setrlimit** | Trivial | Shells, daemons | Set resource limits. |
| **prlimit64** | Trivial | Modern programs (glibc 2.13+) | Combines get/setrlimit, supports other PIDs. |

**Priority: HIGH** - Called by musl/glibc startup code.

**Dependencies:**
- Needs: Per-process rlimit tracking
- Integration: Process control block

### 1.6 Event Notification FDs (MEDIUM-HIGH)
Modern async I/O patterns rely on these.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **eventfd** | Low | Threading libraries, event loops | Lightweight event counter as fd. |
| **eventfd2** | Trivial | Modern programs | eventfd + O_CLOEXEC/O_NONBLOCK flags. |
| **signalfd** | Medium | Async signal handling | Converts signals to readable fd events. |
| **signalfd4** | Trivial | Modern programs | signalfd + flags. |
| **timerfd_create** | Medium | Event loops with timers | Creates timer as fd. |
| **timerfd_settime** | Medium | All timerfd users | Arms/disarms timer. |
| **timerfd_gettime** | Trivial | Timer query | Returns time until expiration. |

**Priority: MEDIUM-HIGH** - Required for modern async frameworks (node.js, tokio, asyncio).

**Dependencies:**
- Needs: fd-based event infrastructure
- Integration: epoll support (to monitor these fds)

---

## Category 2: Important (Needed for Specific Program Categories)

Missing these breaks specific classes of programs but not general-purpose utilities.

### 2.1 Advanced Process Control (HIGH)
Required for containers, systemd-style init, and CPU-bound workloads.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **prctl** | Medium | systemd, containers, security tools | ~40 operations. Start with PR_SET_NAME, PR_GET_NAME. |
| **sched_setaffinity** | Medium | NUMA-aware apps, CPU pinning | Bind process to CPU cores. |
| **sched_getaffinity** | Trivial | CPU topology queries | Return affinity mask. |
| **sched_setscheduler** | Medium | Real-time apps | Set SCHED_FIFO, SCHED_RR policies. |
| **sched_getscheduler** | Trivial | Scheduler queries | Return current policy. |
| **sched_setparam** | Low | Priority tuning | Set scheduling parameters. |
| **sched_getparam** | Trivial | Priority queries | Get scheduling parameters. |
| **sched_get_priority_max** | Trivial | RT policy queries | Return max priority for policy. |
| **sched_get_priority_min** | Trivial | RT policy queries | Return min priority for policy. |

**Priority: HIGH for containers/init, MEDIUM otherwise**

**Dependencies:**
- Needs: Scheduler policy support (SCHED_FIFO, SCHED_RR)
- Integration: Per-process scheduling state

### 2.2 File Ownership & Permissions (MEDIUM)
Needed by package managers, backup tools, file servers.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **chown** | Trivial | coreutils (chown), tar, rsync | Change file owner/group. |
| **fchown** | Trivial | Same | fd-based chown. |
| **lchown** | Trivial | Same | Don't follow symlinks. |
| **fchownat** | Trivial | Modern file tools | chown with *at semantics. |
| **setuid** | Low | Login programs, sudo | Set real/effective UID. |
| **setgid** | Low | Login programs, sudo | Set real/effective GID. |
| **setreuid** | Low | Privilege management | Set real+effective UID atomically. |
| **setregid** | Low | Privilege management | Set real+effective GID atomically. |
| **setresuid** | Low | Secure privilege dropping | Set real+effective+saved UID. |
| **setresgid** | Low | Secure privilege dropping | Set real+effective+saved GID. |
| **getresuid** | Trivial | Query privilege state | Get all three UIDs. |
| **getresgid** | Trivial | Query privilege state | Get all three GIDs. |
| **getgroups** | Trivial | Permission checks | Get supplementary groups. |
| **setgroups** | Low | Login/init | Set supplementary groups. |

**Priority: MEDIUM** - Required for multi-user systems and file management tools.

**Dependencies:**
- Needs: Filesystem uid/gid support
- Security: Capability checks for setuid/setgid

### 2.3 Filesystem Metadata (MEDIUM)
Used by df, du, mount tools.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **statfs** | Low | df, du, mount | Return filesystem stats (blocks, inodes). |
| **fstatfs** | Low | Same | fd-based statfs. |

**Priority: MEDIUM** - Common utilities but can stub with fake data initially.

**Dependencies:**
- Needs: Filesystem superblock metadata
- Per-FS: Each filesystem type must report stats

### 2.4 Remaining *at Syscalls (LOW-MEDIUM)
Complete the *at family for modern POSIX compliance.

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **readlinkat** | Trivial | Modern coreutils | readlink with dirfd. |
| **linkat** | Trivial | Modern coreutils | link with dirfd. |
| **symlinkat** | Trivial | Modern coreutils | symlink with dirfd. |
| **utimensat** | Low | Modern touch/tar | Set file times with nanosecond precision. |

**Priority: LOW-MEDIUM** - Mostly for newer coreutils versions.

**Dependencies:**
- Builds on: Existing syscall implementations
- Just adds *at semantics (dirfd resolution)

### 2.5 IPC - Unix Sockets (HIGH for local IPC)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **socketpair** | Low | IPC between related processes | Creates connected socket pair (AF_UNIX). |
| **shutdown** | Trivial | Graceful connection shutdown | SHUT_RD, SHUT_WR, SHUT_RDWR on sockets. |
| **recvfrom** | Trivial | UDP, raw sockets | recv + source address. |
| **sendto** | Trivial | UDP, raw sockets | send + destination address. |
| **recvmsg** | Medium | Advanced socket I/O | Receive with control messages (SCM_RIGHTS). |
| **sendmsg** | Medium | Advanced socket I/O | Send with control messages. |

**Priority: HIGH for IPC, MEDIUM for network**

**Dependencies:**
- Builds on: Existing socket infrastructure
- Advanced: recvmsg/sendmsg need control message handling (fd passing)

### 2.6 Resource Accounting (LOW-MEDIUM)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **getrusage** | Low | time command, profilers | Return CPU time, memory usage stats. |

**Priority: LOW-MEDIUM** - Useful for diagnostics but not critical.

**Dependencies:**
- Needs: Per-process accounting (already have some in sysinfo/times)

---

## Category 3: Nice to Have (Rarely Called, Can Be Stubs)

These syscalls are called infrequently or have workarounds. Can return ENOSYS initially.

### 3.1 Advanced Memory (LOW)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **madvise** | Low | Performance hints | MADV_DONTNEED, MADV_WILLNEED. Can ignore. |
| **mlock** | Low | Security-sensitive data | Lock pages in RAM. |
| **munlock** | Trivial | Unlock mlock. |
| **mlockall** | Low | Real-time systems | Lock all process memory. |
| **munlockall** | Trivial | Unlock mlockall. |
| **mincore** | Low | Page cache queries | Check if pages are in RAM. |
| **msync** | Medium | mmap'd file coherency | Flush mmap'd changes to disk. |
| **mremap** | Medium | Realloc for mmap | Resize/move memory mapping. |
| **remap_file_pages** | Low | **DEPRECATED** (since Linux 3.16) | Nonlinear mappings. Don't implement. |

**Priority: LOW** - Performance hints can be ignored, locking rarely used outside RT systems.

**Dependencies:**
- madvise: Can be no-op initially
- mlock: Needs page pinning if implemented
- msync: Requires page cache flush

### 3.2 File Locking (LOW)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **flock** | Already implemented | File locking primitive. |
| **fcntl** (F_SETLK) | Already implemented (partial) | POSIX record locking. |

**Status:** Already have flock. fcntl record locking may need expansion.

### 3.3 Directory Change Notification (LOW)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **inotify_init** | Medium | File watchers (editors, build tools) | Create inotify instance. |
| **inotify_init1** | Trivial | Modern programs | inotify_init + O_CLOEXEC. |
| **inotify_add_watch** | Medium | All inotify users | Watch file/directory for changes. |
| **inotify_rm_watch** | Trivial | Stop watching. |

**Priority: LOW** - Useful for development tools but not critical.

**Dependencies:**
- Needs: Filesystem event hooks (on write, unlink, rename, etc.)
- Complex: Cross-filesystem coordination

### 3.4 Extended Attributes (LOW)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **setxattr** | Low | SELinux, capabilities, user metadata | Set extended attribute. |
| **lsetxattr** | Low | Don't follow symlinks. |
| **fsetxattr** | Low | fd-based setxattr. |
| **getxattr** | Low | Get extended attribute. |
| **lgetxattr** | Low | Don't follow symlinks. |
| **fgetxattr** | Low | fd-based getxattr. |
| **listxattr** | Low | List all xattrs. |
| **llistxattr** | Low | Don't follow symlinks. |
| **flistxattr** | Low | fd-based listxattr. |
| **removexattr** | Low | Remove xattr. |
| **lremovexattr** | Low | Don't follow symlinks. |
| **fremovexattr** | Low | fd-based removexattr. |

**Priority: LOW** - Needed for SELinux, capabilities (security), user metadata.

**Dependencies:**
- Needs: Per-file xattr storage in filesystem
- SFS: Would need schema change
- InitRD: Read-only, can't support

### 3.5 Quotas (LOW)

| Syscall | Complexity | Users | Implementation Notes |
|---------|------------|-------|---------------------|
| **quotactl** | Medium | Multi-user systems with disk quotas | Manage filesystem quotas. |

**Priority: LOW** - Not needed for single-user or embedded systems.

---

## Category 4: Not Needed (Legacy, Deprecated, or Very Specialized)

These syscalls can safely return ENOSYS or be stubbed indefinitely.

### 4.1 SysV IPC (DEPRECATED - Use POSIX Alternatives)

**Status:** SysV IPC is superseded by POSIX IPC (which is already thread-safe and better designed).

| Syscall | Replacement | Notes |
|---------|-------------|-------|
| shmget, shmat, shmdt, shmctl | POSIX shm_open + mmap | SysV shared memory. |
| semget, semop, semctl | POSIX sem_open, sem_wait | SysV semaphores. |
| msgget, msgsnd, msgrcv, msgctl | POSIX mq_open, mq_send | SysV message queues. |

**Priority: DO NOT IMPLEMENT** - Advise users to use POSIX IPC (via mmap, pipes, Unix sockets).

**Rationale:**
- SysV IPC is NOT thread-safe
- POSIX alternatives are cleaner and more secure
- Modern programs avoid SysV IPC
- See: System V IPC has effectively been replaced by POSIX IPC

### 4.2 Legacy Process/Signal (OBSOLETE)

| Syscall | Status | Notes |
|---------|--------|-------|
| **signal** | Use rt_sigaction | Deprecated signal handler API. |
| **sigprocmask** | Use rt_sigprocmask | Deprecated signal masking. |
| **sigreturn** | Use rt_sigreturn | Legacy signal return. |
| **sigpending** | Use rt_sigpending | Legacy pending signals query. |
| **sigsuspend** | Use rt_sigsuspend | Legacy signal wait. |
| **sigaction** | Use rt_sigaction | Legacy sigaction. |

**Priority: DO NOT IMPLEMENT** - zk already has rt_* versions.

### 4.3 Obsolete System Calls

| Syscall | Status | Notes |
|---------|--------|-------|
| **uselib** | **REMOVED** (Linux 5.1) | Load shared library. Use dlopen. |
| **_sysctl** | **REMOVED** (Linux 5.5) | Deprecated kernel param interface. Use /proc/sys. |
| **remap_file_pages** | **DEPRECATED** (Linux 3.16) | Nonlinear mappings. Never implement. |
| **create_module**, **delete_module**, **init_module**, **finit_module** | Kernel modules | Not applicable to microkernel architecture. |
| **ioperm**, **iopl** | x86-specific I/O port access | Use /dev/port or capabilities. |
| **modify_ldt** | x86 LDT manipulation | Rare, security risk. |
| **vm86**, **vm86old** | x86 VM86 mode | 16-bit DOS emulation. |

**Priority: DO NOT IMPLEMENT**

### 4.4 Architecture-Specific (Not Portable)

| Syscall | Architecture | Notes |
|---------|--------------|-------|
| **arch_prctl** | x86_64 only | Set FS/GS base registers. Already implemented? |
| **iopl**, **ioperm** | x86 only | I/O port permissions. |
| **vm86** | x86 only | Virtual 8086 mode. |
| **s390_***, **ppc_***, **arm_*** | Arch-specific | Ignore if not on that arch. |

**Priority: LOW** - Implement only if needed for specific architecture support.

### 4.5 Containers/Namespaces (Specialized)

| Syscall | Complexity | Users | Notes |
|---------|------------|-------|-------|
| **unshare** | High | Containers (Docker, LXC) | Create new namespaces. |
| **setns** | Medium | Container tools | Enter existing namespace. |
| **clone3** | High | Modern clone API | Extended clone with struct args. |
| **pivot_root** | Medium | Container init | Change root mount. |

**Priority: LOW initially, HIGH if targeting container support**

**Rationale:** Containers are a major use case but require extensive namespace infrastructure. Defer until core functionality is solid.

---

## Implementation Roadmap

### Phase 1: Core Multiplexing (Highest Impact)
**Goal:** Enable nginx, redis, modern network servers.

1. epoll family (epoll_create1, epoll_ctl, epoll_wait, epoll_pwait)
2. select, pselect6
3. eventfd2, signalfd4, timerfd_*
4. accept4, dup3 (modern fd creation)

**Estimated effort:** 2-3 weeks
**Unlocks:** Modern async I/O patterns, event loops

### Phase 2: Efficient I/O (Performance)
**Goal:** Database and bulk I/O performance.

1. readv, preadv, preadv2
2. pwritev, pwritev2
3. sendfile (for file serving)
4. getrlimit, setrlimit, prlimit64 (resource limits)

**Estimated effort:** 1 week
**Unlocks:** Database compatibility, file server performance

### Phase 3: Process & Resource Control (Multi-user)
**Goal:** Init systems, containers, security.

1. prctl (start with PR_SET_NAME, PR_GET_NAME)
2. sched_setaffinity, sched_getaffinity
3. chown family (chown, fchown, lchown, fchownat)
4. setuid/setgid family
5. getrusage

**Estimated effort:** 2 weeks
**Unlocks:** systemd-style init, privilege management

### Phase 4: Filesystem Completeness (Compatibility)
**Goal:** Full coreutils, file manager support.

1. statfs, fstatfs
2. Remaining *at syscalls (readlinkat, linkat, symlinkat, utimensat)
3. socketpair, shutdown (for IPC)
4. recvmsg, sendmsg (for fd passing)

**Estimated effort:** 1-2 weeks
**Unlocks:** Advanced file tools, IPC-heavy applications

### Phase 5: Optional Enhancements (Polish)
**Goal:** Development tools, advanced features.

1. inotify family (file change monitoring)
2. splice, tee (zero-copy pipe operations)
3. Extended attributes (if security model requires)
4. Advanced memory (madvise, mlock - performance hints)

**Estimated effort:** 2-3 weeks
**Unlocks:** IDEs, build tools, security frameworks

---

## Complexity Ratings Explained

**Trivial (1-2 days):**
- Simple wrappers around existing functionality
- Examples: dup3 (dup2 + flags), accept4 (accept + flags), trivial getters

**Low (3-5 days):**
- Single-purpose syscall with straightforward logic
- Examples: chown, statfs, eventfd

**Medium (1-2 weeks):**
- Requires new infrastructure or moderate state management
- Examples: epoll_ctl (per-fd event tracking), sendfile (kernel buffer copy), prctl (multiple operations)

**High (2-4 weeks):**
- Major subsystem or extensive state machine
- Examples: Full epoll implementation, namespace support, futex (complex synchronization)

---

## Testing Strategy

### Compatibility Tiers

**Tier 1: Shell & Coreutils (Current + Phase 1)**
- Target: busybox, dash, coreutils
- Required: Current syscalls + epoll + select + resource limits
- Test: Boot to shell, run basic commands

**Tier 2: Network Servers (Phase 1 + Phase 2)**
- Target: nginx (static files), redis (no persistence)
- Required: + vectored I/O, sendfile, event notification fds
- Test: Serve files, handle 1000 concurrent connections

**Tier 3: Databases (Phase 2 + Phase 3)**
- Target: SQLite, simple key-value stores
- Required: + preadv2/pwritev2, process control
- Test: ACID transactions, concurrent access

**Tier 4: Language Runtimes (Phase 1-4)**
- Target: Python, Ruby (limited stdlib)
- Required: Full async I/O, IPC, filesystem metadata
- Test: Run test suites, simple web frameworks

**Tier 5: Containers (Phase 5+)**
- Target: Docker, LXC
- Required: Namespaces, cgroups, pivot_root
- Test: Run containerized workloads

### Syscall Tracing for Validation

Use strace on target programs to verify syscall coverage:

```bash
# Trace nginx startup and request handling
strace -c -f nginx -g 'daemon off;'

# Trace redis-server
strace -c redis-server --daemonize no

# Trace Python importing common libraries
strace -c python3 -c "import socket, asyncio, multiprocessing"

# Summary of coreutils
for cmd in ls cat grep find tar; do
    strace -c $cmd [args] 2>&1 | head -20
done
```

Focus on syscalls with:
- High call count (frequency)
- Non-zero error count (programs expect these to work)
- Called during startup (blocking progress)

---

## Dependencies Between Syscalls

### Event Infrastructure
```
epoll_create1
  └─ epoll_ctl
      └─ epoll_wait / epoll_pwait
          ├─ eventfd2 (events to monitor)
          ├─ signalfd4 (events to monitor)
          └─ timerfd_create (events to monitor)
```

### Vectored I/O Evolution
```
readv ──┐
        ├─ preadv ── preadv2 (adds flags)
writev ─┘
        └─ pwritev ── pwritev2 (adds flags)
```

### Modern fd Creation
```
dup ── dup2 ── dup3 (adds O_CLOEXEC)
accept ────── accept4 (adds O_CLOEXEC/O_NONBLOCK)
pipe ──────── pipe2 (adds O_CLOEXEC/O_NONBLOCK, already implemented)
```

### Resource Limits
```
getrlimit ──┐
            ├─ prlimit64 (combines both, supports other PIDs)
setrlimit ──┘
```

### Signal Handling
```
rt_sigaction (already implemented)
  └─ signalfd4 (converts signals to fd events)
      └─ requires epoll for async monitoring
```

---

## Notes on Specific Syscalls

### futex (Not Covered Above - Deserves Special Mention)

**Complexity:** **VERY HIGH** (4-6 weeks)
**Users:** pthread mutexes, condition variables, Go runtime, Rust async
**Status:** **Critical but complex**

futex is the foundation of all modern userspace synchronization primitives. It's used by:
- glibc/musl pthread implementation
- Go scheduler
- Rust tokio runtime
- Any language with threading

**Implementation challenges:**
- Must be atomic (FUTEX_WAIT checks value, adds to queue, releases lock atomically)
- Hash table of futex queues (keyed by address)
- Priority inheritance (FUTEX_LOCK_PI) for real-time
- Timeout support (absolute/relative time)
- Requeue operations (FUTEX_CMP_REQUEUE for condition variables)
- Signal handling (EINTR semantics)

**Recommendation:**
- **Phase 1.5** (between Phase 1 and 2): Implement basic FUTEX_WAIT, FUTEX_WAKE first
- Defer advanced operations (FUTEX_LOCK_PI, FUTEX_REQUEUE) to Phase 5
- See: "Futexes Are Tricky" (Ulrich Drepper) for implementation guide

---

## Quick Reference: Missing Syscalls by Category

### Critical (Implement First)
- epoll_create1, epoll_ctl, epoll_wait, epoll_pwait
- select, pselect6
- readv, preadv, preadv2, pwritev, pwritev2
- getrlimit, setrlimit, prlimit64
- eventfd2, signalfd4, timerfd_create, timerfd_settime, timerfd_gettime
- accept4, dup3
- **futex** (FUTEX_WAIT, FUTEX_WAKE minimum)

### Important (Second Priority)
- sendfile, splice, tee
- prctl, sched_setaffinity, sched_getaffinity
- chown, fchown, lchown, fchownat
- setuid, setgid, setreuid, setregid, setresuid, setresgid, getresuid, getresgid
- getgroups, setgroups
- statfs, fstatfs
- readlinkat, linkat, symlinkat, utimensat
- socketpair, shutdown, recvfrom, sendto, recvmsg, sendmsg
- getrusage

### Nice to Have (Lower Priority)
- inotify_init1, inotify_add_watch, inotify_rm_watch
- madvise, mlock, munlock, mlockall, munlockall, mincore, msync, mremap
- Extended attributes (setxattr family)
- ppoll (poll + sigmask)

### Don't Implement
- SysV IPC (shmget, semget, msgget families) - use POSIX alternatives
- Legacy signal syscalls (signal, sigaction) - use rt_* versions
- Obsolete (uselib, _sysctl, remap_file_pages)
- Kernel modules (create_module, etc.) - microkernel doesn't need
- Architecture-specific (vm86, iopl) - unless required for arch support

---

## Sources

Research based on:
- [BusyBox - The Swiss Army Knife of Embedded Linux](https://busybox.net/downloads/BusyBox.html)
- [musl libc - Design Concepts](https://wiki.musl-libc.org/design-concepts.html)
- [Strace: A Deep Dive into System Call Tracing](https://medium.com/@nuwanwe/strace-a-deep-dive-into-system-call-tracing-9ec9fc77c745)
- [Unikraft Compatibility - 160+ syscalls for complex apps](https://unikraft.org/docs/concepts/compatibility)
- [Async IO on Linux: select, poll, and epoll](https://jvns.ca/blog/2017/06/03/async-io-on-linux--select--poll--and-epoll/)
- [getrlimit(2) - Linux manual page](https://man7.org/linux/man-pages/man2/getrlimit.2.html)
- [socketpair(2) - Linux manual page](https://man7.org/linux/man-pages/man2/socketpair.2.html)
- [chown(2) - Linux manual page](https://man7.org/linux/man-pages/man2/chown.2.html)
- [eventfd(2) - Linux manual page](https://man7.org/linux/man-pages/man2/eventfd.2.html)
- [System V IPC and POSIX IPC](http://ranler.github.io/2013/07/01/System-V-and-POSIX-IPC/)
- [Scheduler-Related System Calls - Linux Process Scheduler](https://www.informit.com/articles/article.aspx?p=101760&seqNum=5)
- [symlink(7) - Linux manual page](https://man7.org/linux/man-pages/man7/symlink.7.html)
- [statfs(2) - Linux manual page](https://www.man7.org/linux/man-pages/man2/statfs.2.html)
- [futex(2) - Linux manual page](https://man7.org/linux/man-pages/man2/futex.2.html)
- [Basics of Futexes](https://eli.thegreenplace.net/2018/basics-of-futexes/)
- [pipe(2) - Linux manual page (O_CLOEXEC)](https://man7.org/linux/man-pages/man2/pipe.2.html)

---

**Document Version:** 1.0
**Last Updated:** 2026-02-06
**Author:** Claude (Sonnet 4.5) via Project Research Agent
