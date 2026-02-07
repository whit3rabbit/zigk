---
phase: 01-quick-wins-trivial-stubs
plan: 03
subsystem: process-management
tags: [syscalls, resource-limits, signals, prlimit64, getrusage, rt-signals]

# Dependency graph
requires:
  - phase: 01-01
    provides: Process syscall infrastructure
  - phase: 01-02
    provides: Scheduling syscall stubs
provides:
  - sys_prlimit64: Modern get/set resource limits API (supersedes getrlimit/setrlimit)
  - sys_getrusage: Resource usage statistics query (RUSAGE_SELF/CHILDREN/THREAD)
  - sys_rt_sigpending: Query pending & blocked signals
  - sys_rt_sigsuspend: Atomic signal mask swap with suspend
affects: [process-control, signal-handling, shell-integration]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Resource limits: RLIMIT_AS enforced, others accepted but not enforced (MVP pattern)"
    - "Signal masking: SIGKILL/SIGSTOP always unblockable per POSIX"
    - "Zeroed stats pattern: getrusage returns zeroes for MVP (no tracking yet)"

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/process/process.zig
    - src/kernel/sys/syscall/process/signals.zig

key-decisions:
  - "prlimit64 enforces only RLIMIT_AS, accepts others for compatibility"
  - "getrusage returns zeroed Rusage struct (kernel doesn't track usage yet)"
  - "rt_sigsuspend always returns EINTR per POSIX (not an error condition)"

patterns-established:
  - "Resource limits: Validate soft <= hard, check permissions for raising hard limit"
  - "Signal syscalls: Validate sigsetsize == @sizeOf(SigSet) before processing"
  - "RUSAGE_CHILDREN constant: Use @bitCast(@as(isize, -1)) for usize representation"

# Metrics
duration: 3min
completed: 2026-02-06
---

# Phase 1 Plan 3: Resource Limits and Signals Summary

**Four syscalls complete the resource and signal management API: prlimit64 (modern rlimit API), getrusage (usage stats query), rt_sigpending (pending signal query), and rt_sigsuspend (atomic mask swap with suspend).**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-07T00:13:08Z
- **Completed:** 2026-02-07T00:16:31Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- sys_prlimit64: Get/set resource limits for any process (pid=0 for self), validates permissions, enforces RLIMIT_AS
- sys_getrusage: Returns resource usage stats for SELF/CHILDREN/THREAD (zeroed for MVP)
- sys_rt_sigpending: Returns intersection of pending_signals & sigmask (pending blocked signals)
- sys_rt_sigsuspend: Atomically replaces sigmask, blocks until signal, restores mask, returns EINTR

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement prlimit64 and getrusage in process.zig** - `2d48df8` (feat)
   - sys_prlimit64: 80 lines, handles pid=0 (current), reads old limits, sets new with validation
   - sys_getrusage: 55 lines, validates RUSAGE_SELF/CHILDREN/THREAD, returns zeroed Rusage struct

2. **Task 2: Implement rt_sigpending and rt_sigsuspend in signals.zig** - `b58e0b8` (feat)
   - sys_rt_sigpending: 25 lines, computes pending & blocked, writes to userspace
   - sys_rt_sigsuspend: 39 lines, saves mask, sets new, blocks, restores, returns EINTR

## Files Created/Modified
- `src/kernel/sys/syscall/process/process.zig` - Added sys_prlimit64 (modern rlimit API) and sys_getrusage (usage query). Imported std for std.mem.zeroes.
- `src/kernel/sys/syscall/process/signals.zig` - Added sys_rt_sigpending (pending signal query) and sys_rt_sigsuspend (atomic mask swap with suspend).

## Decisions Made

1. **prlimit64 enforcement scope:** Only RLIMIT_AS is enforced (stored in proc.rlimit_as). Other resources (STACK, NOFILE, etc.) are accepted but not enforced for MVP. This matches the existing pattern in sys_getrlimit/sys_setrlimit.

2. **getrusage zeroed stats:** Returns std.mem.zeroes(Rusage) for all valid `who` values. The kernel does not currently track CPU time, RSS, page faults, or I/O stats. This provides a valid ABI-compatible response for programs that check getrusage but don't rely on the stats (common in shell/libc initialization).

3. **RUSAGE_CHILDREN representation:** Linux defines RUSAGE_CHILDREN as -1 (signed). As usize, this is @bitCast(@as(isize, -1)). The syscall validates who against this constant to accept both RUSAGE_SELF (0), RUSAGE_CHILDREN (-1), and RUSAGE_THREAD (1).

4. **rt_sigsuspend always returns EINTR:** Per POSIX, sigsuspend always fails with EINTR (after a signal is delivered and handled). This is expected behavior, not an error condition.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Issue 1: Duplicate std import in process.zig**
- **Problem:** Added `const std = @import("std");` at top of file, but comptime block inside Rlimit struct already had `const std = @import("std");` at line 467, causing shadowing error.
- **Resolution:** Removed the local `const std` from inside the comptime block since std is now available file-wide.
- **Impact:** None - compilation succeeded after fix.

## Next Phase Readiness

- Resource limit API complete: Programs can query/set limits via prlimit64, compatible with shell builtins (ulimit)
- Signal management API complete: rt_sigpending and rt_sigsuspend finish the signal control suite started in 01-01
- Ready for Phase 2: More complex syscall implementations that use these primitives

**Blockers:** None

**Concerns:** None

## Self-Check: PASSED

All files and commits verified:
- ✓ src/kernel/sys/syscall/process/process.zig exists
- ✓ src/kernel/sys/syscall/process/signals.zig exists
- ✓ Commit 2d48df8 exists
- ✓ Commit b58e0b8 exists

---
*Phase: 01-quick-wins-trivial-stubs*
*Completed: 2026-02-06*
