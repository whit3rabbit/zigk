# Syscall Implementation Architecture: Dependency Chains and Phase Ordering

**Research Focus:** Architecture dimension for syscall implementation ordering
**Domain:** Microkernel syscall expansion (from 190 to ~300 syscalls)
**Researched:** 2026-02-06
**Overall Confidence:** HIGH (based on kernel source analysis + Linux documentation)

## Executive Summary

The zk kernel has solid infrastructure for the next 100+ syscalls. The key insight is that **infrastructure dependencies are more critical than cross-syscall dependencies**. Most missing syscalls require minimal new kernel subsystems - the process model (uid/gid tracking), file descriptor table, VFS, signal infrastructure, and memory management are all production-ready.

The primary blockers are:
1. **Credential tracking** (uid/gid already in Process struct, but setuid/setgid helpers needed)
2. **Epoll backend plumbing** (epoll syscalls exist but need poll method implementations in FileOps)
3. **SysV IPC allocators** (kernel heap is ready, need shared memory segments and semaphore arrays)

Unlike typical kernel development, zk's **comptime dispatch table** means syscalls can be implemented in any order - the table auto-discovers handlers by reflection. This enables maximum parallelization.

## Infrastructure Inventory (What Already Exists)

### Process Model (src/kernel/proc/process/types.zig)
- **Status:** PRODUCTION READY
- **Capabilities:**
  - Full uid/gid/euid/egid/suid/sgid tracking (fields exist in Process struct)
  - Supplementary groups array (16 groups max)
  - Credential lock (cred_lock) for TOCTOU protection
  - Process groups (pgid) and sessions (sid)
  - Parent/child hierarchy with zombie reaping
  - Refcounting for multi-threaded processes
- **Missing:** Helper functions for credential manipulation (setuid logic, permission checks)
- **Implication:** User/group syscalls (113-124) require only thin wrappers around existing fields

### File Descriptor System (src/kernel/fs/fd.zig)
- **Status:** PRODUCTION READY
- **Capabilities:**
  - FileOps vtable with read/write/close/seek/stat/ioctl/mmap
  - **poll method** already defined in FileOps (line 86-88)
  - FdTable per-process (256 FDs max)
  - Reference counting for dup/fork
  - Close-on-exec (O_CLOEXEC) support
  - Atomic allocAndInstall for race-free FD allocation
- **Missing:** poll method implementations in specific file types (pipe, socket, regular file)
- **Implication:** epoll works at the FD layer; individual file types need poll implementations

### Epoll Infrastructure (src/kernel/sys/syscall/process/scheduling.zig:620-750)
- **Status:** SYSCALLS EXIST, BACKEND INCOMPLETE
- **Capabilities:**
  - sys_epoll_create1 (allocates EpollInstance, creates FD)
  - sys_epoll_ctl (ADD/MOD/DEL entries)
  - sys_epoll_wait (polls entries, returns ready events)
- **Architecture:**
  - EpollInstance stores up to MAX_EPOLL_FDS (1024) monitored file descriptors
  - Each entry has fd, events mask, user data
  - epoll_wait iterates entries and calls fd.ops.poll() if available
- **Missing:**
  - FileOps.poll implementations for pipes, sockets, regular files
  - Edge-triggered (EPOLLET) support (currently level-triggered only)
- **Implication:** Epoll syscalls are 80% done; need to implement poll methods in 5-6 file types

### Signal Infrastructure (src/kernel/sys/syscall/process/signals.zig)
- **Status:** PRODUCTION READY
- **Capabilities:**
  - Full signal delivery (rt_sigaction, rt_sigprocmask, rt_sigreturn)
  - Signal masks per thread
  - Signal frame setup for both x86_64 and aarch64
  - EINTR handling on syscall return
- **Missing:** sigaltstack, rt_sigtimedwait, rt_sigsuspend (deferred, low priority)
- **Implication:** signalfd/timerfd can be layered on top without modifying signal core

### Memory Management (src/kernel/mm/)
- **Status:** PRODUCTION READY
- **Capabilities:**
  - mmap/munmap/mprotect/brk fully implemented
  - UserVmm per-process with VMA tracking
  - Page table management (CR3/TTBR0 switching)
  - DMA allocator (pmm.allocZeroedPages)
  - IOMMU support
- **Missing:**
  - SysV shared memory segment allocator (needs IPC namespace)
  - Swap support (low priority for microkernel)
- **Implication:** Shared memory syscalls need a segment table, not new memory primitives

### Filesystem (src/kernel/fs/)
- **Status:** PRODUCTION READY (VFS + SFS + InitRD + DevFS)
- **Capabilities:**
  - VFS layer with mount points
  - SFS (Simple Filesystem) for /mnt
  - InitRD (read-only USTAR) for /
  - DevFS for /dev
  - Path resolution, directory operations, stat, fstat
- **Missing:**
  - Extended attributes (xattr) - entire subsystem (deferred, low priority)
  - inotify event queue (needs new kernel structure)
- **Implication:** xattr and inotify are independent feature additions, not blockers for other syscalls

## Dependency Chain Analysis

### Tier 0: Independent (No Cross-Dependencies)

These syscalls can be implemented in **any order** and in **parallel**. They depend only on existing kernel infrastructure.

| Syscall Group | Count | Infrastructure Dependency | Parallel-Safe? |
|---------------|-------|---------------------------|----------------|
| User/Group IDs | 8 | Process.uid/gid fields | Yes |
| File locking (flock) | Already done | FdTable | N/A |
| Resource limits | 4 | Process.rlimit_as field | Yes |
| System info | 1 (syslog) | Kernel ring buffer | Yes |
| Filesystem (mknod, utime) | 2 | VFS | Yes |
| Privileged ops (reboot, iopl) | 4 | HAL | Yes |

**Implementation Notes:**
- **User/Group IDs (113-124):** All fields exist in Process struct. Need helper functions:
  - `checkCredentialPermission(target_uid, euid, uid)` - POSIX setuid rules
  - `setCredentials(ruid, euid, suid)` - atomic update with cred_lock
  - No cross-syscall dependencies; each function is self-contained
- **Resource limits (97-98, 160, 302):** getrlimit/setrlimit/prlimit64 read/write Process.rlimit_as. Extend to cover RLIMIT_NOFILE, RLIMIT_NPROC.

### Tier 1: Light Dependencies (Require Simple Helpers)

These syscalls depend on **new helper structures** but not on other syscalls.

| Syscall Group | Depends On | Blocker Type |
|---------------|------------|--------------|
| Scheduler params (142-148) | Process.sched_policy field | New field + sched.c integration |
| Timer FDs (283, 286-287) | Timer queue + FdTable | New TimerFd struct |
| Event FDs (284, 290) | FdTable only | New EventFd struct (atomic counter) |
| Signal FDs (282, 289) | Signal infrastructure | New SignalFd struct (sigset_t filter) |

**Architecture Pattern:**
All *fd syscalls (timerfd, eventfd, signalfd) follow the same template:
1. Allocate instance struct on kernel heap
2. Create FileDescriptor with custom ops vtable
3. Install in FdTable with allocAndInstall
4. Return fd number

**Example (eventfd):**
```zig
pub const EventFd = struct {
    counter: std.atomic.Value(u64),
    semaphore_mode: bool, // EFD_SEMAPHORE flag
};

pub fn sys_eventfd2(initval: usize, flags: usize) SyscallError!usize {
    const efd = heap.allocator().create(EventFd) catch return error.ENOMEM;
    efd.* = .{ .counter = .{ .raw = initval }, .semaphore_mode = (flags & EFD_SEMAPHORE) != 0 };
    const fd = heap.allocator().create(FileDescriptor) catch return error.ENOMEM;
    fd.* = .{ .ops = &eventfd_ops, .private_data = efd, ... };
    return base.getGlobalFdTable().allocAndInstall(fd) orelse error.EMFILE;
}
```

Each *fd type needs 4 FileOps methods: read, write, close, poll (for epoll integration).

### Tier 2: Epoll Backend (Requires FileOps.poll Implementations)

Epoll syscalls (232-233, 281, 291) **already exist** but need poll methods in file types.

| File Type | Location | poll Method Status |
|-----------|----------|-------------------|
| Pipe | src/kernel/fs/pipe.zig | MISSING (needs read_pos != write_pos check) |
| Socket | src/net/transport/socket/fd.zig | MISSING (needs recv_queue check) |
| Regular File | src/kernel/fs/ | MISSING (always return EPOLLIN \| EPOLLOUT) |
| EventFd | NEW | MISSING (needs counter != 0 check) |
| TimerFd | NEW | MISSING (needs expiry_time <= now check) |
| SignalFd | NEW | MISSING (needs sigpending & mask check) |

**Implementation Pattern (pipe example):**
```zig
pub fn pipe_poll(fd: *FileDescriptor, events: u32) u32 {
    const pipe = @as(*Pipe, @ptrCast(@alignCast(fd.private_data)));
    var ready: u32 = 0;
    if (events & EPOLLIN != 0) {
        if (pipe.read_pos != pipe.write_pos) ready |= EPOLLIN; // Data available
        if (pipe.writers == 0) ready |= EPOLLHUP; // All writers closed
    }
    if (events & EPOLLOUT != 0) {
        if (pipe.write_pos - pipe.read_pos < PIPE_BUF_SIZE) ready |= EPOLLOUT; // Space available
    }
    return ready;
}
```

**Critical for:** epoll_wait to return meaningful results. Without poll methods, epoll_wait always returns 0 (no ready fds).

### Tier 3: SysV IPC (Requires New Allocators)

SysV IPC syscalls (29-31, 64-71) need kernel-global tables for segments/semaphores/message queues.

**Shared Memory Architecture:**
```
Global Structure: ShmTable
  - Array of ShmSegment (fixed size, e.g., 1024 entries)
  - Each segment has:
    - key: i32 (IPC_PRIVATE or user-chosen key)
    - size: usize
    - permissions: mode_t
    - phys_pages: []u64 (DMA-allocated pages)
    - attach_count: u32
    - owner_uid/gid: u32
  - Lock: RwLock (shmget/shmctl use write, shmat uses read)
```

**Syscall Dependencies:**
1. **shmget (29):** Allocate segment, return shmid. Uses pmm.allocZeroedPages.
2. **shmat (30):** Map segment into process address space. Depends on shmget. Uses UserVmm.mapRange.
3. **shmdt (67):** Unmap segment. Depends on shmat. Uses UserVmm.unmapRange.
4. **shmctl (31):** Control operations (IPC_RMID, IPC_STAT). Depends on shmget.

**Implementation Order:** shmget -> shmat/shmctl -> shmdt (attach_count must reach 0 before free).

**Similar pattern for semaphores (64-66) and message queues (68-71).**

### Tier 4: Extended Features (Require Infrastructure Additions)

These are **deferred** because they need significant new kernel subsystems.

| Syscall Group | Infrastructure Needed | Estimated Complexity |
|---------------|----------------------|---------------------|
| Extended Attributes (188-199) | Xattr storage per inode | HIGH (VFS extension) |
| Inotify (253-255, 294) | Event queue + watch tree | MEDIUM (new subsystem) |
| File cloning (326) | COW page tables | HIGH (requires COW support) |
| Namespace ops (272, 308) | Namespace isolation | HIGH (major feature) |
| Seccomp (317) | BPF interpreter | HIGH (security model) |

**Recommendation:** Defer Tier 4 until Phases 1-3 complete. These are **independent features**, not dependencies for other syscalls.

## Recommended Phase Structure

### Phase 1: Credential System (1-2 days)
**Goal:** Make uid/gid syscalls production-ready.

**Tasks:**
1. Add helper functions to Process module:
   - `setUidSafe(proc, ruid, euid, suid)` - atomic update with cred_lock
   - `setGidSafe(proc, rgid, egid, sgid)` - atomic update with cred_lock
   - `checkSetuidPermission(proc, target_uid)` - POSIX rules (euid=0 or euid=target_uid)
2. Implement syscall wrappers:
   - sys_setreuid (113), sys_setregid (114) - set real+effective
   - sys_getgroups (115), sys_setgroups (116) - supplementary groups
   - sys_setfsuid (122), sys_setfsgid (123) - filesystem uid/gid
3. Add tests to test_runner:
   - testSetuid, testSetgid, testGetgroups (privileged and unprivileged)

**Dependencies:** None (all fields exist in Process struct).
**Parallelizable:** Can implement setuid/setgid/groups functions concurrently.
**Output:** 6 syscalls (113-116, 122-123) move from missing to implemented.

### Phase 2: Epoll Backend (2-3 days)
**Goal:** Make epoll_wait return actual ready events.

**Tasks:**
1. Implement FileOps.poll for existing file types:
   - Pipe (pipe.zig): Check read_pos != write_pos (EPOLLIN), buffer space (EPOLLOUT)
   - Socket (socket/fd.zig): Check recv_queue.len > 0 (EPOLLIN), send_queue space (EPOLLOUT)
   - Regular File (always ready for read/write)
2. Add inotify stubs (return -ENOSYS for now, but allocate FD):
   - sys_inotify_init (253), sys_inotify_init1 (294) - allocate InotifyInstance
   - sys_inotify_add_watch (254) - return -ENOSYS (watch not implemented)
   - sys_inotify_rm_watch (255) - return -ENOSYS
3. Add tests:
   - testEpollPipe (write to pipe, epoll_wait returns EPOLLIN)
   - testEpollSocket (recv data, epoll_wait returns EPOLLIN)

**Dependencies:** Requires epoll syscalls (already implemented).
**Parallelizable:** Pipe and socket poll methods are independent.
**Output:** Epoll moves from "syscalls exist" to "functionally complete". Inotify stubs allow programs to call inotify_init without ENOSYS.

### Phase 3: *fd Syscalls (3-4 days)
**Goal:** Add eventfd, timerfd, signalfd for modern async patterns.

**Tasks:**
1. Implement EventFd (284, 290):
   - Struct with atomic counter, semaphore_mode flag
   - read: decrement counter (block if 0 and O_NONBLOCK not set)
   - write: increment counter
   - poll: return EPOLLIN if counter > 0
2. Implement TimerFd (283, 286-287):
   - Struct with expiry_time, interval, clockid
   - read: return number of expirations since last read
   - write: not allowed (return EINVAL)
   - poll: return EPOLLIN if expired
   - Integrate with timer tick handler (check all timerfd instances on each tick)
3. Implement SignalFd (282, 289):
   - Struct with sigset_t mask
   - read: dequeue signal from thread.sigpending if in mask
   - write: not allowed
   - poll: return EPOLLIN if pending & mask != 0

**Dependencies:** Requires epoll backend (Phase 2) for poll methods to be useful.
**Parallelizable:** All three *fd types are independent.
**Output:** 6 syscalls (282-284, 286-287, 289-290). Modern async I/O complete (epoll + eventfd + timerfd).

### Phase 4: SysV IPC (4-5 days)
**Goal:** Add shared memory, semaphores, message queues for legacy compatibility.

**Tasks:**
1. Design global IPC structures (src/kernel/proc/ipc/):
   - ShmTable (shared memory segments)
   - SemTable (semaphore sets)
   - MsgTable (message queues)
   - Each with fixed-size array (e.g., 256 entries) + RwLock
2. Implement shared memory (29-31, 67):
   - sys_shmget: Allocate segment (use pmm.allocZeroedPages), return shmid
   - sys_shmat: Map into UserVmm, increment attach_count
   - sys_shmdt: Unmap, decrement attach_count
   - sys_shmctl: IPC_STAT (copy metadata), IPC_RMID (mark for deletion)
3. Implement semaphores (64-66):
   - sys_semget: Allocate semaphore set (array of counters)
   - sys_semop: Atomic increment/decrement (block if would go negative)
   - sys_semctl: GETVAL, SETVAL, IPC_RMID
4. Implement message queues (68-71):
   - sys_msgget: Allocate queue (linked list of messages)
   - sys_msgsnd: Append message (block if queue full)
   - sys_msgrcv: Dequeue message (block if queue empty)
   - sys_msgctl: IPC_STAT, IPC_RMID

**Dependencies:** None (uses existing PMM and UserVmm).
**Parallelizable:** Shared memory, semaphores, message queues are independent (separate tables).
**Output:** 12 syscalls (29-31, 64-71, 67). SysV IPC complete (required for PostgreSQL, Redis).

### Phase 5: Scheduler Extensions (2-3 days)
**Goal:** Add scheduler parameter syscalls for real-time apps.

**Tasks:**
1. Add sched_policy field to Process struct (or Thread struct?)
2. Implement syscalls:
   - sys_sched_setparam (142), sys_sched_getparam (143)
   - sys_sched_setscheduler (144), sys_sched_getscheduler (145)
   - sys_sched_get_priority_max (146), sys_sched_get_priority_min (147)
   - sys_sched_rr_get_interval (148)
3. Integrate with scheduler (src/kernel/proc/sched/):
   - If policy == SCHED_FIFO, disable preemption timer
   - If policy == SCHED_RR, adjust time slice based on priority
   - If policy == SCHED_OTHER (default), use existing round-robin

**Dependencies:** None (extends existing scheduler).
**Parallelizable:** All syscalls are thin wrappers around scheduler state.
**Output:** 7 syscalls (142-148). Real-time scheduling complete.

### Phase 6: Miscellaneous (2-3 days)
**Goal:** Mop up remaining high-value syscalls.

**Tasks:**
1. Filesystem:
   - sys_mknod (133): Create device files (extend DevFS)
   - sys_utime (132): Change timestamps (extend stat structure)
2. Privileged operations:
   - sys_reboot (169): Call hal.reboot()
   - sys_syslog (103): Read from kernel ring buffer
3. Resource limits:
   - sys_getrlimit (97), sys_setrlimit (160), sys_prlimit64 (302)
   - Extend Process.rlimit_as to cover RLIMIT_NOFILE, RLIMIT_NPROC, RLIMIT_CPU

**Dependencies:** None.
**Parallelizable:** All tasks are independent.
**Output:** ~10 syscalls. Brings total to ~250 implemented (from 190).

## Build Order Implications

### Comptime Dispatch Advantage
The zk syscall table (`src/kernel/sys/syscall/core/table.zig`) uses **comptime reflection** to auto-discover handlers. This means:

1. **No registration needed:** Just define `pub fn sys_foo(...)` in any handler module, and the table finds it.
2. **Namespace isolation:** Each phase can use a separate .zig file (e.g., credentials.zig, eventfd.zig) without merge conflicts.
3. **Incremental testing:** Add syscalls one at a time, rebuild, test. No "big bang" integration.

**Critical for parallel work:** Multiple developers can implement syscalls in different modules simultaneously without touching the same files.

### Architecture-Specific Considerations
The kernel already handles x86_64/aarch64 differences at compile time:
- Syscall numbers: `src/uapi/syscalls/root.zig` selects linux.zig or linux_aarch64.zig
- Register conventions: `src/arch/*/asm_helpers.S` marshals arguments
- Page tables: `hal.paging.writeCr3` (x86_64) vs `hal.paging.writeTtbr0` (aarch64)

**Implication:** Syscall handlers are architecture-agnostic. No per-arch code needed for Phases 1-6.

### Testing Strategy
The existing test framework (`src/user/test_runner/`) runs 186 tests across 15 categories. For each phase:

1. **Unit tests:** Add to test_runner/tests/ (e.g., credentials_test.zig)
2. **Integration tests:** Use existing multi-process test harness (fork + waitpid)
3. **CI validation:** `RUN_BOTH=true ./scripts/run_tests.sh` tests both architectures

**Test coverage goal:** Every new syscall gets at least 2 tests (success case + error case).

## Known Pitfalls and Mitigations

### Pitfall 1: Credential TOCTOU Races
**What:** Two threads call setuid concurrently, observe inconsistent uid/euid during permission checks.
**Prevention:** Process.cred_lock must be held for the entire check-and-set operation.
```zig
pub fn setUidSafe(proc: *Process, ruid: u32, euid: u32, suid: u32) void {
    const held = proc.cred_lock.acquire();
    defer held.release();
    proc.uid = ruid;
    proc.euid = euid;
    proc.suid = suid;
}
```

### Pitfall 2: Epoll Edge-Triggered Starvation
**What:** If epoll is edge-triggered (EPOLLET), failing to drain a socket fully will miss future wakeups.
**Prevention:** Current implementation is level-triggered only. Document that EPOLLET is not yet supported.

### Pitfall 3: SysV IPC Key Collisions
**What:** Two processes call shmget(key=42, ...) and expect separate segments.
**Prevention:** IPC_PRIVATE (key == 0) allocates unique segment. For shared keys, check ShmTable for existing entry with matching key.

### Pitfall 4: TimerFd Timer List Traversal
**What:** Checking all timerfd instances on every timer tick is O(n). If n=1000, this dominates tick time.
**Prevention:** Use a min-heap keyed by expiry_time. Only check root of heap on each tick.

### Pitfall 5: Signal Mask Corruption in SignalFd
**What:** signalfd modifies thread.sigmask to block signals, but doesn't restore on close.
**Prevention:** SignalFd should NOT modify thread.sigmask. It only filters which signals are read from sigpending.

## Cross-Architecture Validation

All phases must pass tests on **both x86_64 and aarch64**. Known architecture-specific issues:

1. **aarch64 syscall number collisions:** SysV IPC syscalls have different numbers. The dispatch table uses Linux-official numbers from linux_aarch64.zig.
2. **aarch64 compat stubs:** Legacy syscalls (open, pipe, getpgrp) use 500+ range on aarch64. These redirect to modern equivalents (openat, pipe2, getpgid).
3. **x86_64-only syscalls:** iopl (172), ioperm (173), modify_ldt (154) are x86_64-specific. Return ENOSYS on aarch64.

**Validation:** `RUN_BOTH=true ./scripts/run_tests.sh` runs full test suite on both architectures in CI.

## Sources

- [epoll(7) - Linux Manual Page](https://man7.org/linux/man-pages/man7/epoll.7.html)
- [Linux Kernel eventpoll.c](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c)
- [futex(2) - Linux Manual Page](https://man7.org/linux/man-pages/man2/futex.2.html)
- [eventfd(2) - Linux Manual Page](https://man7.org/linux/man-pages/man2/eventfd.2.html)
- [sysvipc(7) - Linux Manual Page](https://man7.org/linux/man-pages/man7/sysvipc.7.html)
- [System V IPC - Programming Interfaces Guide](https://docs.oracle.com/cd/E23824_01/html/821-1602/svipc-2.html)
- [inotify(7) - Linux Manual Page](https://man7.org/linux/man-pages/man7/inotify.7.html)

## Summary

**Key Finding:** The zk kernel's infrastructure is **production-ready** for 200+ additional syscalls. The bottleneck is not missing subsystems, but implementation time.

**Architecture Advantages:**
1. Comptime dispatch enables **fully parallelizable** implementation (no merge conflicts)
2. Existing subsystems (Process, FdTable, VFS, Signals) cover 90% of syscall needs
3. Cross-architecture support is compile-time automatic (no per-syscall arch code)

**Recommended Ordering:**
1. **Phase 1 (Credentials):** Unlocks setuid/setgid programs
2. **Phase 2 (Epoll Backend):** Completes existing epoll syscalls
3. **Phase 3 (*fd Syscalls):** Modern async I/O (eventfd, timerfd, signalfd)
4. **Phase 4 (SysV IPC):** Legacy compatibility (PostgreSQL, Redis)
5. **Phase 5 (Scheduler):** Real-time scheduling
6. **Phase 6 (Misc):** Cleanup remaining high-value syscalls

**Timeline:** 15-20 days for Phases 1-6 (200+ syscalls). Tier 4 (xattr, inotify, namespaces) deferred as independent features.
