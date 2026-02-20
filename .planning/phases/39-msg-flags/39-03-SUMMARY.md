---
phase: 39-msg-flags
plan: 03
subsystem: net
tags: [tcp, signals, eintr, msg-waitall, msg-peek, scheduler]

# Dependency graph
requires:
  - phase: 39-msg-flags
    provides: tcpRecvWaitall accumulation loop and MSG_WAITALL dispatch (39-02)
  - phase: 39-msg-flags
    provides: MSG_PEEK/MSG_DONTWAIT/MSG_WAITALL constants and flags threading (39-01)
provides:
  - hasPendingSignal() callback in socket scheduler shim
  - EINTR termination for blocking MSG_PEEK recv waits
  - EINTR termination for MSG_WAITALL with zero bytes accumulated
  - Partial count return for MSG_WAITALL when signal arrives after bytes received
affects: [net, syscall-net, tcp, signals]

# Tech tracking
tech-stack:
  added: []
  patterns: [scheduler-callback-extension, eintr-check-after-block]

key-files:
  created: []
  modified:
    - src/net/transport/socket/scheduler.zig
    - src/net/transport/socket/tcp_api.zig
    - src/kernel/sys/syscall/net/net.zig

key-decisions:
  - "hasPendingSignal callback stored in scheduler.zig shim behind spinlock -- same pattern as wake/block/getCurrent callbacks"
  - "tcpRecvWaitall returns WouldBlock (not EINTR) on signal; syscall layer converts to EINTR -- keeps transport layer independent of syscall error types"
  - "HLT fallback path in tcpRecvWaitall intentionally excludes signal check -- no signal delivery infrastructure exists without scheduler"
  - "Default blocking TCP recv loop and MSG_PEEK loop both check hasPendingSignal() after sched.block() for consistent EINTR behavior"

patterns-established:
  - "Pattern: signal check after block_fn()/sched.block() -- all blocking loops in net.zig and tcp_api.zig now check hasPendingSignal() post-wakeup"
  - "Pattern: EINTR conversion at syscall boundary -- transport layer uses WouldBlock, syscall layer converts using hasPendingSignal() check"

requirements-completed: [API-01, API-02, API-03]

# Metrics
duration: 2min
completed: 2026-02-20
---

# Phase 39 Plan 03: MSG-Flags EINTR Gap Closure Summary

**Signal-aware recv loops: hasPendingSignal() callback added to socket scheduler shim, wired through MSG_PEEK, MSG_WAITALL, and default TCP blocking paths to return EINTR on pending signal after wakeup**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-20T00:25:46Z
- **Completed:** 2026-02-20T00:27:31Z
- **Tasks:** 1
- **Files modified:** 3

## Accomplishments

- Added `HasPendingSignalFn` callback type and `has_pending_signal_fn` storage to `scheduler.zig`; extended `setSchedulerFunctions` to accept 4th parameter; added `hasPendingSignal()` public accessor with safe false-default when no callback registered
- Registered `hasPendingSignalImpl()` callback in `net.zig init()` delegating to existing `poll_mod.hasPendingSignal`
- Added EINTR check after `sched.block()` in both the MSG_PEEK blocking loop and default blocking TCP recv loop in `sys_recvfrom`
- Added hasPendingSignal check in MSG_WAITALL error handler converting WouldBlock to EINTR when signal pending
- Added signal check in `tcpRecvWaitall` after `block_fn()` returning partial count or WouldBlock per POSIX MSG_WAITALL semantics
- Both x86_64 and aarch64 compile cleanly with no regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Add hasPendingSignal callback to scheduler shim and wire EINTR checks** - `def5f6c` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/net/transport/socket/scheduler.zig` - Added HasPendingSignalFn type, has_pending_signal_fn storage, 4th param to setSchedulerFunctions, hasPendingSignal() accessor
- `src/net/transport/socket/tcp_api.zig` - Added signal check in tcpRecvWaitall blocking sub-loop; added comment to HLT fallback path
- `src/kernel/sys/syscall/net/net.zig` - Added hasPendingSignalImpl() callback, 4th arg to setSchedulerFunctions call, EINTR checks in MSG_PEEK loop, MSG_WAITALL error handler, and default blocking TCP recv loop

## Decisions Made

- `hasPendingSignal` callback stored in `scheduler.zig` shim behind spinlock -- same security pattern as the existing wake/block/getCurrent callbacks
- `tcpRecvWaitall` returns `WouldBlock` (not `EINTR`) when a signal is pending; the syscall layer converts it using `hasPendingSignal()` check -- keeps transport layer independent of syscall error vocabulary
- HLT fallback path in `tcpRecvWaitall` intentionally excludes signal check -- without a scheduler, `hasPendingSignal()` always returns false and signal delivery is not operational; comment added to document this
- Default blocking TCP recv loop also gets the EINTR check for completeness -- consistency across all TCP blocking paths

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 39 EINTR gap is fully closed: all three MSG flag blocking paths (MSG_PEEK, MSG_WAITALL, default) return EINTR when a signal is pending after wakeup
- ROADMAP success criterion #3 ("SO_RCVTIMEO and EINTR terminate the wait early" for MSG_WAITALL) is now fully satisfied
- Phase 39 (all 3 plans) complete

---
*Phase: 39-msg-flags*
*Completed: 2026-02-20*
