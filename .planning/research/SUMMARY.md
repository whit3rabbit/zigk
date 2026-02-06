# Project Research Summary

**Project:** zk kernel syscall expansion
**Domain:** Linux-compatible syscall implementation for hobby OS
**Researched:** 2026-02-06
**Confidence:** HIGH

## Executive Summary

The zk kernel is positioned to expand from 190 to 300+ Linux-compatible syscalls with minimal architectural changes. Research shows that the kernel's existing infrastructure (comptime dispatch table, process model, VFS, signals, memory management) is production-ready for 90% of the missing syscalls. The bottleneck is implementation time, not missing subsystems.

The critical finding is that **infrastructure dependencies matter more than cross-syscall dependencies**. Unlike typical kernel development, zk's comptime reflection dispatch allows fully parallelized implementation - multiple developers can work on different syscall modules simultaneously without merge conflicts. The primary blockers are three narrow gaps: (1) credential manipulation helpers for uid/gid syscalls, (2) FileOps.poll implementations to complete the existing epoll infrastructure, and (3) SysV IPC allocators for legacy compatibility.

Key risks center on three categories of bugs that plague even mature kernels: user memory access violations (30% of Linux CVEs), ABI structure mismatches (silent corruption), and TOCTOU races (security holes). Prevention requires strict adherence to existing patterns: always use `copyFromUser`/`copyToUser`, match Linux UAPI struct layouts exactly, and copy user data once at syscall entry. The existing testing infrastructure (186 tests across x86_64/aarch64) provides the validation framework.

## Key Findings

### Recommended Stack

The most effective stack for syscall implementation combines reference implementations from educational kernels with comprehensive testing infrastructure. The zk kernel already follows best practices with its UserPtr abstraction, SMAP compliance, and architecture-independent handler design.

**Core technologies:**
- **Linux kernel source** (fs/, kernel/, mm/, net/): Source of truth for behavior - validates error codes, race condition handling, boundary checks, and edge cases
- **xv6 RISC-V**: Educational reference for minimal correct implementations - 21 syscalls with excellent documentation explaining design decisions
- **Linux Test Project (LTP)**: 1200+ syscall conformance tests - industry standard from IBM/Red Hat/SUSE, covers success/error/race cases
- **Syzkaller**: Coverage-guided fuzzer finding edge cases and security bugs - found 5000+ Linux kernel bugs, detects integer overflows, TOCTOU races, use-after-free
- **strace**: Syscall tracing for behavior validation - compare zk output against Linux for exact errno/return value matching

**Testing strategy:**
- Use LTP for conformance testing (establish "passes X% of LTP" benchmark)
- Use custom tests for zk-specific features (capabilities, custom syscalls)
- Set up syzkaller within 2-3 milestones for continuous fuzzing
- Extend existing 186-test suite with 2+ tests per new syscall (success + error case)

### Expected Features

Research identifies 230 unimplemented syscalls (of 420 total Linux syscalls), categorized by real-world program requirements. Analysis of syscall traces from nginx, redis, Python, and busybox shows that **only ~160 syscalls are needed for complex applications** (per Unikraft study), suggesting zk's 190 already cover core functionality.

**Must have (table stakes):**
- **Epoll family** (epoll_create1, epoll_ctl, epoll_wait, epoll_pwait) - required for modern async I/O, used by nginx/redis/node.js/asyncio
- **Vectored I/O** (readv, preadv, pwritev, preadv2, pwritev2) - database performance primitive, used by SQLite/Postgres
- **Event notification FDs** (eventfd2, timerfd_*, signalfd4) - modern event loop integration
- **Resource limits** (getrlimit, setrlimit, prlimit64) - called by musl/glibc startup code
- **Modern fd creation** (accept4, dup3) - race-free fd allocation with O_CLOEXEC
- **Futex** (FUTEX_WAIT, FUTEX_WAKE) - foundation of pthread/Go/Rust synchronization

**Should have (competitive):**
- **Zero-copy I/O** (sendfile, splice, tee) - file serving performance optimization
- **Process control** (prctl, sched_setaffinity) - container/systemd compatibility
- **File ownership** (chown family, setuid/setgid) - multi-user system support
- **Unix sockets** (socketpair, recvmsg, sendmsg with SCM_RIGHTS) - fd passing for IPC
- **SysV IPC** (shmget, semget, msgget families) - legacy compatibility for Postgres/Redis

**Defer (v2+):**
- **Extended attributes** (setxattr family) - requires VFS extension, needed for SELinux
- **Inotify** (inotify_init1, inotify_add_watch) - file change monitoring for IDEs/build tools
- **Namespaces** (unshare, setns, clone3) - container isolation, major feature addition
- **SysV IPC** (recommend POSIX alternatives instead) - deprecated, not thread-safe, avoid implementing

### Architecture Approach

The zk kernel's comptime dispatch table architecture eliminates traditional syscall implementation bottlenecks. Unlike monolithic tables requiring manual registration, the dispatch system uses reflection to auto-discover handlers by name pattern (`pub fn sys_*`). This enables maximum parallelization and namespace isolation - each phase can use separate .zig files without merge conflicts.

**Infrastructure readiness by subsystem:**

1. **Process Model** (src/kernel/proc/process/types.zig) - PRODUCTION READY
   - All uid/gid/euid/egid fields exist, supplementary groups array ready
   - Missing only helper functions for credential manipulation
   - Implication: User/group syscalls need thin wrappers

2. **File Descriptor System** (src/kernel/fs/fd.zig) - PRODUCTION READY
   - FileOps.poll method defined but not implemented in file types
   - FdTable, refcounting, O_CLOEXEC all working
   - Implication: Epoll backend 80% complete, needs 5-6 poll implementations

3. **Epoll Infrastructure** (src/kernel/sys/syscall/process/scheduling.zig) - SYSCALLS EXIST, BACKEND INCOMPLETE
   - sys_epoll_create1/ctl/wait handlers implemented
   - Missing FileOps.poll in pipes, sockets, regular files
   - Implication: Epoll works at FD layer, file types need poll methods

4. **Memory Management** (src/kernel/mm/) - PRODUCTION READY
   - mmap/munmap/mprotect/brk complete
   - DMA allocator for SysV shared memory ready
   - Missing only IPC segment table structure

**Major components:**

1. **Comptime Dispatch Table** - auto-discovers handlers via reflection, enables parallel development
2. **UserPtr Abstraction** - SMAP-compliant user memory access, prevents 30% of CVEs
3. **Cross-Architecture Support** - x86_64/aarch64 differences handled at compile time, no per-syscall arch code needed
4. **VFS Layer** - InitRD, SFS, DevFS production-ready, xattr/inotify are independent feature additions

### Critical Pitfalls

Based on Linux kernel CVE analysis and hobby OS project post-mortems, the top security and correctness bugs:

1. **User Pointer Dereference** - Never use `@ptrFromInt` on user addresses without validation. Always call `isValidUserAccess` first and use `copyFromUser`/`copyToUser`. This prevents 30% of syscall CVEs. Test with kernel addresses (0xffff0000_00000000), NULL, and overflow cases (ptr + len wraps).

2. **TOCTOU Races** - Copy user data to kernel memory once at syscall entry, never access user memory multiple times. Attackers modify buffers between check and use (pass /bin/true, change to /bin/sh after permission check). Double-fetch vulnerabilities found in hundreds of Linux/FreeBSD/Android syscalls. Use kernel copy exclusively after first read.

3. **Struct Layout Mismatches** - Match Linux UAPI definitions exactly, not glibc. Critical case: `socklen_t` is u32 (4 bytes), not usize (8 bytes). Reading 8 bytes from 4-byte stack variable picks up garbage on aarch64. Use `pahole -C struct_stat` to verify layouts. Test on both 32-bit and 64-bit.

4. **Architecture Syscall Number Collisions** - aarch64 syscall numbers differ from x86_64. If two SYS_* constants have same number, comptime dispatch silently drops one handler. Use 500+ range for legacy compat syscalls on aarch64. Add compile-time uniqueness assertion.

5. **EINTR Signal Handling** - Blocking syscalls must check for signals and respect SA_RESTART flag. Without this, processes become unkillable or syscalls always interrupt. Check at every block point, follow POSIX restartable syscall rules. Never auto-restart select/poll/epoll_wait.

## Implications for Roadmap

Based on infrastructure analysis and feature dependencies, suggested phase structure prioritizes completing existing infrastructure before adding new subsystems. Each phase unlocks specific application categories.

### Phase 1: Credential System (1-2 days)
**Rationale:** All uid/gid fields exist in Process struct, only helpers missing. Fastest win for multi-user system support.
**Delivers:** Production-ready setuid/setgid syscalls for privilege management
**Addresses:** User/Group IDs (setreuid, setregid, getgroups, setgroups, setfsuid, setfsgid) - 6 syscalls
**Avoids:** TOCTOU races via cred_lock atomic updates, permission checks before modification
**Unlocks:** sudo, login programs, package managers

### Phase 2: Epoll Backend (2-3 days)
**Rationale:** Epoll syscalls exist but return empty results. Completing FileOps.poll implementations makes existing syscalls functional.
**Delivers:** Functional epoll_wait with real event detection
**Uses:** Existing FileOps vtable with poll method, scheduler block/wakeup
**Implements:** Poll methods for pipes (check read_pos != write_pos), sockets (recv_queue.len > 0), regular files (always ready)
**Addresses:** I/O multiplexing already implemented but non-functional
**Avoids:** Edge-triggered starvation (implement level-triggered first, document EPOLLET not supported)
**Unlocks:** nginx, redis, Python asyncio

### Phase 3: Event Notification FDs (3-4 days)
**Rationale:** Modern async I/O requires eventfd/timerfd/signalfd for event loop integration. Builds on completed epoll backend.
**Delivers:** eventfd2, timerfd_create/settime/gettime, signalfd4 - 6 syscalls
**Uses:** FdTable infrastructure, FileOps pattern from Phase 2
**Implements:** EventFd (atomic counter), TimerFd (expiry check), SignalFd (signal filter)
**Avoids:** Timer list traversal overhead (use min-heap keyed by expiry), signal mask corruption (filter only, don't modify sigmask)
**Unlocks:** Node.js, tokio, asyncio frameworks

### Phase 4: Vectored I/O (1 week)
**Rationale:** Database performance primitive. Independent implementation, no cross-dependencies.
**Delivers:** readv, preadv, preadv2, pwritev, pwritev2, sendfile - 6 syscalls
**Uses:** Existing read/write infrastructure, iovec validation
**Addresses:** Efficient bulk I/O for databases and file servers
**Avoids:** Integer overflow in multi-buffer size calculations (use checked arithmetic), user pointer validation per iovec entry
**Unlocks:** SQLite, Postgres, nginx file serving

### Phase 5: SysV IPC (4-5 days)
**Rationale:** Legacy compatibility for Postgres/Redis. Requires new global allocators but uses existing PMM/UserVmm.
**Delivers:** Shared memory (shmget, shmat, shmdt, shmctl), semaphores (semget, semop, semctl), message queues (msgget, msgsnd, msgrcv, msgctl) - 12 syscalls
**Uses:** pmm.allocZeroedPages for segments, UserVmm.mapRange for attachments
**Implements:** Global IPC tables (ShmTable, SemTable, MsgTable) with RwLocks
**Avoids:** Key collisions (IPC_PRIVATE allocates unique segment), attach_count race conditions
**Unlocks:** Postgres, Redis (without persistence), legacy apps

### Phase 6: Process Control Extensions (2-3 days)
**Rationale:** Container and real-time support. Extends existing scheduler without architectural changes.
**Delivers:** prctl, sched_setaffinity/getaffinity, scheduler params (setparam, getparam, setscheduler) - 8 syscalls
**Uses:** Process struct extensions (sched_policy field), scheduler integration
**Addresses:** CPU pinning, real-time scheduling policies (SCHED_FIFO, SCHED_RR)
**Avoids:** Scheduler policy complexity (start with SCHED_FIFO only, defer priority inheritance)
**Unlocks:** systemd-style init, NUMA-aware apps, real-time workloads

### Phase 7: Filesystem Completeness (1-2 weeks)
**Rationale:** Remaining high-value syscalls for full coreutils/file tool support.
**Delivers:** Resource limits (getrlimit, setrlimit, prlimit64), ownership (chown family), remaining *at syscalls, Unix sockets (socketpair, shutdown, recvmsg, sendmsg), filesystem metadata (statfs) - 20+ syscalls
**Uses:** Existing VFS, socket infrastructure
**Addresses:** File management tools, IPC-heavy apps, multi-user systems
**Avoids:** AT_FDCWD handling (check for -100 in all *at syscalls), chown permission checks
**Unlocks:** tar, rsync, package managers, advanced IPC

### Phase Ordering Rationale

- **Infrastructure completion before feature addition:** Phases 1-3 finish existing subsystems (credentials, epoll, *fd) rather than starting new ones. This validates the architecture before expanding scope.
- **Dependency chains:** Epoll backend (Phase 2) must complete before eventfd/timerfd (Phase 3) because poll methods enable epoll integration. SysV IPC (Phase 5) is independent and can run in parallel with other phases.
- **Application unlock strategy:** Phase 1-3 unlocks modern servers (nginx, redis). Phase 4-5 unlocks databases (SQLite, Postgres). Phase 6-7 unlocks containers and system tools.
- **Testing incrementalism:** Each phase adds 6-20 syscalls, allowing thorough LTP testing before moving forward. Smaller phases reduce merge conflicts and simplify rollback.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 5 (SysV IPC):** Complex synchronization primitives (semop atomicity), segment lifetime management. Recommend detailed review of Linux ipc/ subsystem and POSIX IPC alternatives.
- **Phase 6 (Scheduler):** Real-time scheduling policies (SCHED_FIFO, SCHED_RR) interact with existing round-robin scheduler. Need priority inheritance research for futex integration.

Phases with standard patterns (skip research-phase):
- **Phase 1 (Credentials):** POSIX setuid semantics well-documented, existing Process struct covers all fields.
- **Phase 2 (Epoll Backend):** FileOps.poll pattern established, Linux epoll documentation is comprehensive.
- **Phase 3 (*fd Syscalls):** eventfd/timerfd/signalfd are simple FD wrappers, man pages cover all edge cases.
- **Phase 4 (Vectored I/O):** iovec pattern identical across readv/writev/preadv/pwritev, no new concepts.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | LTP, syzkaller, strace are industry standard. xv6 and Linux source are authoritative. Setup instructions verified. |
| Features | HIGH | Syscall categorization based on real-world strace analysis (nginx, redis, Python). Unikraft study validates 160-syscall threshold. |
| Architecture | HIGH | Infrastructure audit based on actual zk kernel source code. Phase dependencies validated against existing implementations. |
| Pitfalls | HIGH | CVE analysis and Linux kernel documentation. All pitfalls have corresponding prevention patterns and test cases. |

**Overall confidence:** HIGH

The research is grounded in authoritative sources (Linux kernel, POSIX specs, LTP), validated with real-world usage data (strace analysis), and cross-referenced with hobby OS post-mortems. The zk kernel codebase audit confirms infrastructure readiness claims.

### Gaps to Address

- **Futex complexity:** Research identifies futex as critical (FUTEX_WAIT/WAKE minimum) but defers advanced operations (FUTEX_LOCK_PI, FUTEX_REQUEUE). During Phase 2-3 implementation, validate pthread mutex requirements and prioritize basic futex if blocking multi-threading.

- **SysV IPC alternatives:** Research recommends NOT implementing SysV IPC due to deprecation, but Phase 5 includes it for legacy compatibility. During planning, validate if target applications (Postgres, Redis) can use POSIX IPC instead (shm_open + mmap, sem_open). May skip entire phase if not required.

- **Cross-architecture testing:** All phases assume x86_64/aarch64 parity. During implementation, validate socklen_t size (u32 vs usize), syscall number uniqueness, and TLS handling differences. Use `RUN_BOTH=true ./scripts/run_tests.sh` continuously.

- **Epoll edge-triggered mode:** Phase 2 implements level-triggered only. If real-world testing (nginx, redis) requires EPOLLET, allocate 1-2 days in Phase 2 for edge-triggered support and starvation prevention patterns.

## Sources

### Primary (HIGH confidence)
- [Linux kernel source](https://github.com/torvalds/linux) - GPL-2.0 - Syscall implementations in fs/, kernel/, mm/, net/
- [Linux manual pages](https://man7.org/linux/man-pages/) - GPLv2+ - Canonical syscall specifications with error codes and edge cases
- [POSIX.1-2017](https://pubs.opengroup.org/onlinepubs/9699919799/) - IEEE standard - Cross-platform syscall behavior
- [Linux Test Project](https://github.com/linux-test-project/ltp) - GPL-2.0 - 1200+ conformance tests
- [Syzkaller](https://github.com/google/syzkaller) - Apache-2.0 - Coverage-guided fuzzing infrastructure
- [xv6 RISC-V](https://github.com/mit-pdos/xv6-riscv) - MIT License - Educational reference implementation
- [xv6 Book](https://pdos.csail.mit.edu/6.828/2023/xv6/book-riscv-rev3.pdf) - Design rationale documentation

### Secondary (MEDIUM confidence)
- [Unikraft Compatibility Study](https://unikraft.org/docs/concepts/compatibility) - 160+ syscalls for complex apps
- [Tilck Linux-compatible kernel](https://github.com/vvaltchev/tilck) - BSD 2-Clause - ~100 syscall hobby kernel
- [BusyBox syscall analysis](https://busybox.net/downloads/BusyBox.html) - Embedded Linux syscall requirements
- [Linux System Call Table](https://filippo.io/linux-syscall-table/) - x86_64 reference
- [Double-Fetch Bug Study (USENIX)](https://www.usenix.org/sites/default/files/conference/protected-files/usenixsecurity_slides_wang_pengfei_.pdf) - TOCTOU vulnerability research
- [Hardened User Copy (LWN)](https://lwn.net/Articles/695991/) - User memory access security
- [Linux Kernel System Calls Documentation](https://linux-kernel-labs.github.io/refs/heads/master/lectures/syscalls.html) - Educational resource
- [OSDev Wiki - System Calls](https://wiki.osdev.org/System_Calls) - Community-maintained patterns

### Architecture-Specific
- [Linux syscall table for multiple architectures](https://marcin.juszkiewicz.com.pl/download/tables/syscalls.html) - aarch64/x86_64 differences
- [Chromium OS Syscall Table](https://chromium.googlesource.com/chromiumos/docs/+/master/constants/syscalls.md) - Cross-platform validation

---
*Research completed: 2026-02-06*
*Ready for roadmap: yes*
