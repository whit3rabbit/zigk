# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-06)

**Core value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.
**Current focus:** Phase 2 in progress - Credentials & Ownership

## Current Position

Phase: 2 of 9 (Credentials & Ownership)
Plan: 4 of 4 in current phase
Status: Phase complete
Last activity: 2026-02-07 - Completed 02-04-PLAN.md (integration tests)

Progress: [████████░░] 80%

## Performance Metrics

**Velocity:**
- Total plans completed: 8
- Average duration: 5 min
- Total execution time: 0.70 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1 | 4 | 21 min | 5 min |
| 2 | 4 | 20 min | 5 min |

**Recent Trend:**
- Last 5 plans: 02-01 (5min), 02-02 (4min), 02-03 (5min), 02-04 (6min)
- Trend: Steady 4-6min for syscall implementation and testing

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

### Pending Todos

**Kernel Bugs Exposed by Tests:**
- sys_setregid permission check - after setresgid(1000,1000,1000), should not allow setregid(2000,2000)
- SFS FileOps.chown - fchown not implemented for SFS filesystem

### Blockers/Concerns

**Phase 7 Risk (Socket Extras):**
- Socket tests currently trigger kernel panic (IrqLock initialization order)
- Socket extras implementation may be blocked until IrqLock bug is fixed
- Workaround: Defer Phase 7 if panic is not resolved by Phase 6 completion

**Phase 3 Dependency (I/O Multiplexing):**
- Epoll infrastructure exists but FileOps.poll methods are unimplemented
- Requires poll implementations for pipes, sockets, regular files
- Success of Phase 3 directly unlocks Phase 4 (event FDs need epoll integration)
- **01-02:** ppoll stub returns 0 (no FDs ready) - needs real FD monitoring when Phase 3 implements poll infrastructure

**Phase 9 Considerations (SysV IPC):**
- SFS filesystem has close deadlock and 64-file limit
- SysV IPC shared memory will need kernel-only memory allocation, not SFS
- Research suggests POSIX IPC alternatives may be preferable for modern apps

**Phase 2 Complete - Test Coverage:**
- 207 total tests (up from 186 at start of Phase 2)
- All credential and chown syscalls tested on both x86_64 and aarch64
- 2 tests skipped due to kernel bugs (setregid perms, SFS fchown)

## Session Continuity

Last session: 2026-02-07 (plan execution)
Stopped at: Completed 02-04-PLAN.md (integration tests) - Phase 2 complete
Resume file: None

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-07*
