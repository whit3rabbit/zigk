# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-06)

**Core value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.
**Current focus:** Phase 3 complete. Ready for Phase 4 - Event Notification FDs

## Current Position

Phase: 3 of 9 (I/O Multiplexing)
Plan: 4 of 4 in current phase
Status: Phase complete
Last activity: 2026-02-07 - Completed 03-04-PLAN.md (I/O multiplexing integration tests)

Progress: [████░░░░░░] 33%

## Performance Metrics

**Velocity:**
- Total plans completed: 12
- Average duration: 5.2 min
- Total execution time: 1.05 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1 | 4 | 21 min | 5 min |
| 2 | 4 | 20 min | 5 min |
| 3 | 4 | 26 min | 6.5 min |

**Recent Trend:**
- Last 5 plans: 03-01 (4min), 03-02 (7min), 03-03 (6min), 03-04 (9min)
- Trend: Testing phases take longer (9min vs 4-6min for implementation)

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Trivial stubs before real implementations - Quick wins boost coverage count and let more programs probe without ENOSYS crashes
- epoll before SysV IPC - I/O multiplexing is more commonly needed by real programs than legacy IPC
- UID/GID tracking as infrastructure - Many syscalls (chown, setuid, access checks) depend on per-process credential state
- Skip ptrace entirely - Extremely complex, separate debugger project
- **01-02:** ppoll implemented as standalone stub instead of delegating to net/poll.zig to avoid cross-module dependencies for MVP
- **01-03:** prlimit64 enforces only RLIMIT_AS, accepts others for compatibility (MVP pattern)
- **01-03:** getrusage returns zeroed Rusage struct - kernel doesn't track usage yet
- **01-03:** RUSAGE_CHILDREN uses @bitCast(@as(isize, -1)) for usize representation of -1
- **01-04:** Timespec type separation - resource.zig defines TimespecLocal to avoid circular dependency on time.zig
- **01-04:** mlockall accepts flags=0 as no-op (bitwise validation allows zero)
- **02-01:** fsuid/fsgid replace euid/egid only in filesystem permission checks (open, access, stat, chown), not signal delivery or ptrace
- **02-01:** Auto-sync fsuid/fsgid whenever euid/egid changes to maintain default POSIX behavior
- **02-01:** Syscall numbers follow standard Linux ABI values (x86_64 and aarch64 have different numbering)
- **02-02:** setfsuid/setfsgid return previous value even on 'failure' (Linux ABI, not POSIX error convention)
- **02-02:** setreuid/setregid follow POSIX saved-set-user-ID rule (if ruid set, suid = new euid)
- **02-02:** Supplementary groups limited to 16 (NGROUPS_MAX historical value, sufficient for MVP)
- **02-03:** Use fsuid (not euid) for chown permission checks per 02-01 infrastructure
- **02-03:** Clear suid/sgid bits on ownership change for POSIX security compliance
- **02-03:** fchown uses FileOps.chown for direct fd access, avoiding path TOCTOU
- **02-03:** chownKernel helper consolidates POSIX permission logic for all chown variants
- **02-04:** Fork isolation for privilege-drop tests (runInChild helper prevents test pollution)
- **02-04:** SFS deadlock workaround - don't close/unlink SFS files in tests
- **02-04:** Bitcast pattern for i32/u32 to usize - use @as(usize, @as(u32, @bitCast(i32)))
- **03-01:** FileOps.poll methods for all FD types - pipes state-dependent, regular files always ready, sockets delegate to transport
- **03-01:** Pipes follow Linux semantics - POLLERR/POLLHUP always reported regardless of requested_events
- **03-01:** Socket readiness via checkPollEvents - POLLIN when recv data, POLLOUT when send space, POLLHUP on peer close
- **03-02:** Use sched.yield() for epoll_wait blocking instead of sleep queues (matches sys_select pattern)
- **03-02:** Store full revents in last_revents for edge-triggered detection (revents | entry_last_revents)
- **03-02:** EPOLLONESHOT disables by zeroing events field, not removing entry from watch list
- **03-03:** pselect6 6th arg is struct { sigset_t *ss; size_t ss_len; }, not direct sigset pointer (Linux ABI)
- **03-03:** sys_poll uses FileOps.poll uniformly - no socket special-casing needed
- **03-03:** PollFd.revents is i16, truncate u32 FileOps.poll result with @bitCast(@as(u16, @truncate))
- **03-03:** Old sys_poll blocking mechanism (sock.blocked_thread) kept for backward compat, will be replaced with futex

### Pending Todos

**Kernel Bugs Exposed by Tests:**
- sys_setregid permission check - after setresgid(1000,1000,1000), should not allow setregid(2000,2000)
- SFS FileOps.chown - fchown not implemented for SFS filesystem

### Blockers/Concerns

**Phase 7 Risk (Socket Extras):**
- Socket tests currently trigger kernel panic (IrqLock initialization order)
- Socket extras implementation may be blocked until IrqLock bug is fixed
- Workaround: Defer Phase 7 if panic is not resolved by Phase 6 completion

**Phase 3 Complete (I/O Multiplexing):**
- ✅ FileOps.poll foundation complete (03-01) - all FD types now have poll methods
- ✅ sys_epoll_wait implementation complete (03-02) - blocking, edge-triggered, oneshot modes
- ✅ select/pselect6/poll/ppoll upgrade complete (03-03) - uniform FileOps.poll, userspace wrappers
- ✅ Integration tests complete (03-04) - 10 tests covering epoll, select, poll on both architectures
- Test count: 217 total (up from 207)
- Ready for Phase 4 (Event FDs) which will integrate with epoll infrastructure

**Phase 9 Considerations (SysV IPC):**
- SFS filesystem has close deadlock and 64-file limit
- SysV IPC shared memory will need kernel-only memory allocation, not SFS
- Research suggests POSIX IPC alternatives may be preferable for modern apps

**Phase 2 Complete - Test Coverage:**
- 207 total tests (up from 186 at start of Phase 2)
- All credential and chown syscalls tested on both x86_64 and aarch64
- 2 tests skipped due to kernel bugs (setregid perms, SFS fchown)

**Phase 3 Complete - Test Coverage:**
- 217 total tests (up from 207)
- All I/O multiplexing syscalls tested: epoll_create1, epoll_ctl, epoll_wait, select, poll
- Tests cover pipes, regular files, HUP detection, edge-triggered mode
- No new skipped tests - all functionality working

## Session Continuity

Last session: 2026-02-07 (plan execution)
Stopped at: Completed 03-04-PLAN.md (I/O multiplexing integration tests) - Phase 3 complete
Resume file: None

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-07*
