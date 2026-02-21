---
phase: 40-network-code-fixes
plan: 02
subsystem: network
tags: [tcp, raw-socket, locking, tcb-mutex, msg-dontwait, msg-peek, socket-options]

# Dependency graph
requires:
  - phase: 40-network-code-fixes
    provides: network socket infrastructure (options.zig, raw_api.zig, types.zig)
provides:
  - TCP_CORK uncork flush with correct tcb.mutex locking (options.zig)
  - MSG_DONTWAIT and MSG_PEEK flag handling for raw socket recv (raw_api.zig)
affects:
  - 42-network-loopback-test
  - 43-network-end-to-end

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "TCP_CORK flush: acquire tcb.mutex before transmitPendingData, same as all other TCB mutation paths"
    - "Raw socket flags: is_nonblocking combines MSG_DONTWAIT with sock.blocking; is_peek selects peekPacketIp vs dequeuePacketIp"

key-files:
  created: []
  modified:
    - src/net/transport/socket/options.zig
    - src/net/transport/socket/raw_api.zig

key-decisions:
  - "Lock order for TCP_CORK flush: sock.lock (level 6) -> tcb.mutex (level 7) -- safe per hierarchy in CLAUDE.md"
  - "MSG_DONTWAIT overrides sock.blocking with OR semantics: is_nonblocking = MSG_DONTWAIT_set OR !sock.blocking"

patterns-established:
  - "Pattern: Any TCB mutation path must hold tcb.mutex, even if caller holds sock.lock -- no exceptions"
  - "Pattern: Raw socket recv flags mirror TCP recv pattern (is_nonblocking/is_peek derived at function entry)"

requirements-completed:
  - NET-03
  - NET-04

# Metrics
duration: 1min
completed: 2026-02-21
---

# Phase 40 Plan 02: Network Socket Fixes (TCP_CORK Mutex + Raw Recv Flags) Summary

**TCP_CORK uncork flush now holds tcb.mutex matching all other TCB mutation paths; raw socket recvfromRaw/recvfromRaw6 handle MSG_DONTWAIT and MSG_PEEK flags**

## Performance

- **Duration:** 1 min
- **Started:** 2026-02-21T02:12:50Z
- **Completed:** 2026-02-21T02:14:36Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Fixed TCP_CORK setsockopt uncork path to acquire tcb.mutex before calling transmitPendingData(), preventing concurrent data corruption from RX path and timer retransmit
- Implemented MSG_DONTWAIT for both recvfromRaw (IPv4) and recvfromRaw6 (IPv6): flag overrides sock.blocking so call returns WouldBlock immediately if no data
- Implemented MSG_PEEK for both raw recv functions: uses peekPacketIp instead of dequeuePacketIp so data remains in queue for subsequent reads
- Both x86_64 and aarch64 builds compile cleanly after all changes

## Task Commits

Each task was committed atomically:

1. **Task 1: Acquire tcb.mutex before transmitPendingData in TCP_CORK uncork** - `6184cc3` (fix)
2. **Task 2: Implement MSG_DONTWAIT and MSG_PEEK for raw socket recv** - `0466e2d` (feat)

## Files Created/Modified
- `src/net/transport/socket/options.zig` - TCP_CORK uncork path acquires tcb.mutex before transmitPendingData; removed misleading comment justifying mutex skip
- `src/net/transport/socket/raw_api.zig` - recvfromRaw and recvfromRaw6 now parse MSG_DONTWAIT/MSG_PEEK flags; removed TODO `_ = flags` stubs

## Decisions Made
- Lock order for TCP_CORK flush: sock.lock (level 6) then tcb.mutex (level 7) -- exactly matches the hierarchy documented in CLAUDE.md, no inversion possible
- MSG_DONTWAIT uses OR semantics: `is_nonblocking = (flags & MSG_DONTWAIT) != 0 or !sock.blocking` -- both socket-level and call-level non-blocking take effect

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Both network socket fixes complete; raw socket recv now has parity with TCP recv for MSG_DONTWAIT and MSG_PEEK
- Phase 42 (loopback setup) and Phase 43 (end-to-end verification) can proceed with corrected socket primitives
- No blockers

## Self-Check: PASSED

- options.zig: FOUND
- raw_api.zig: FOUND
- 40-02-SUMMARY.md: FOUND
- Commit 6184cc3: FOUND
- Commit 0466e2d: FOUND

---
*Phase: 40-network-code-fixes*
*Completed: 2026-02-21*
