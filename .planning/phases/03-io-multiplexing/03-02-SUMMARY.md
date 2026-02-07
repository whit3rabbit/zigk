---
phase: 03-io-multiplexing
plan: 02
subsystem: io
tags: [epoll, syscalls, blocking, edge-triggered, oneshot]

# Dependency graph
requires:
  - phase: 03-01
    provides: FileOps.poll methods on all FD types
provides:
  - Real sys_epoll_wait implementation with poll dispatch
  - Blocking with timeout support (infinite, immediate, millisecond precision)
  - Edge-triggered mode (EPOLLET) via last_revents state tracking
  - One-shot mode (EPOLLONESHOT) for event delivery control
affects: [03-03-poll-syscall, 03-04-select-syscall, event-fd-integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Edge-triggered state tracking via last_revents field
    - Timeout handling via hal.timing.rdtsc + hasTimedOut + yield loop
    - Always report EPOLLERR/EPOLLHUP regardless of requested events mask

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/process/scheduling.zig

key-decisions:
  - "Use sched.yield() for blocking instead of sleep queues (matches sys_select pattern)"
  - "Store full revents in last_revents for next iteration's edge detection"
  - "EPOLLONESHOT disables by zeroing events field, not removing entry"

patterns-established:
  - "Edge-triggered: compare current revents with last_revents, report only delta"
  - "EPOLLONESHOT: disable entry (events=0) after one event until EPOLL_CTL_MOD"
  - "Timeout: -1=infinite, 0=immediate, >0=milliseconds converted to microseconds"

# Metrics
duration: 7min
completed: 2026-02-07
---

# Phase 03 Plan 02: epoll_wait Implementation Summary

**Real epoll_wait with FileOps.poll dispatch, timeout-based blocking, edge-triggered mode, and one-shot event delivery**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-07T13:16:57Z
- **Completed:** 2026-02-07T13:23:45Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments

- sys_epoll_wait queries real FileOps.poll on all monitored fds (replaces hardcoded stdin/stdout logic)
- Blocking with timeout: -1 (infinite), 0 (immediate), >0 (milliseconds via hal.timing.hasTimedOut)
- Edge-triggered mode (EPOLLET) via last_revents state tracking - reports only state transitions
- One-shot mode (EPOLLONESHOT) disables entry after one event delivery until re-armed
- EPOLLERR and EPOLLHUP always reported regardless of requested events mask

## Task Commits

Each task was committed atomically:

1. **Task 1: Add edge-triggered state tracking to EpollEntry** - `f3030c0` (feat)
2. **Task 2: Rewrite sys_epoll_wait with real poll dispatch and blocking** - `cc99167` (feat)

## Files Created/Modified

- `src/kernel/sys/syscall/process/scheduling.zig` - Enhanced EpollEntry with last_revents field, rewrote sys_epoll_wait with real poll dispatch, blocking, edge-triggered, and one-shot support

## Decisions Made

**Use sched.yield() for blocking instead of sleep queues:**
- Follows sys_select pattern (rdtsc + hasTimedOut + yield loop)
- Simpler than sleep queue integration for MVP
- Sufficient for epoll blocking semantics

**Store full revents in last_revents for edge detection:**
- Before edge filtering, store revents | entry_last_revents
- Ensures next iteration can detect state transitions correctly
- Edge-triggered: report only `revents & ~last_revents` (newly set bits)

**EPOLLONESHOT disables by zeroing events field:**
- Sets entry.events = 0 instead of removing entry
- Entry remains in watch list but won't report events
- Re-armed via EPOLL_CTL_MOD (resets events and last_revents)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - implementation straightforward following sys_select timeout pattern.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for 03-03 (sys_poll) and 03-04 (sys_select enhancement):**
- FileOps.poll foundation complete (03-01)
- epoll_wait fully functional with all modes (level, edge, oneshot)
- Timeout handling pattern established for other multiplexing syscalls

**Tested:**
- Both x86_64 and aarch64 compile cleanly
- Existing test suite passes on x86_64 (207 tests)

**Blockers:**
None

## Self-Check: PASSED

All files and commits verified.

---
*Phase: 03-io-multiplexing*
*Completed: 2026-02-07*
