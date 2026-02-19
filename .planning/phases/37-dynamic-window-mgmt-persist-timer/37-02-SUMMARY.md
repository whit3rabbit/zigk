---
phase: 37-dynamic-window-mgmt-persist-timer
plan: 02
subsystem: network
tags: [tcp, window-management, SWS, RFC-1122, silly-window-syndrome]

# Dependency graph
requires:
  - phase: 37-01
    provides: currentRecvWindow() SWS floor (WIN-04), persist timer (WIN-02)

provides:
  - Sender SWS avoidance gate in transmitPendingData() (WIN-05)
  - Post-drain window update ACK in recv() (WIN-03)

affects: [api.zig, tx/data.zig]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Sender SWS: hold segment unless is_full_segment || is_half_window || is_last_data"
    - "Window update threshold: c.DEFAULT_MSS (local receive MSS), not tcb.mss (peer send MSS)"
    - "Unscaled byte comparison for window update trigger (recvBufferAvailable)"

key-files:
  created: []
  modified:
    - src/net/transport/tcp/tx/data.zig
    - src/net/transport/tcp/api.zig

key-decisions:
  - "Sender SWS gate placed after Nagle check -- Nagle gates on flight_size (in-flight data), SWS gates on segment size vs window; both are complementary suppressors"
  - "Window update threshold uses c.DEFAULT_MSS (local receive MSS) not tcb.mss (peer send MSS) -- semantically correct for receive-side decision"
  - "Freed space computed as old_used - new_used with defensive if (old_used > new_used) guard -- equals copy_len in normal case, guards against concurrent recv_head updates"
  - "sendAck call is safe under tcb.mutex -- research confirmed pattern (Pitfall 3 in RESEARCH.md)"

requirements-completed: [WIN-03, WIN-05]

# Metrics
duration: 1min
completed: 2026-02-19
---

# Phase 37 Plan 02: Sender SWS Avoidance and Window Update ACK Summary

**Sender SWS avoidance gate in transmitPendingData() suppressing tiny segments (RFC 1122 S4.2.3.4), plus post-drain window update ACK in recv() proactively advertising freed buffer space (RFC 1122 S4.2.3.3)**

## Performance

- **Duration:** 1min
- **Started:** 2026-02-19T21:40:51Z
- **Completed:** 2026-02-19T21:41:59Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Added sender SWS avoidance gate in `transmitPendingData()` after the Nagle check: holds back segments unless they are a full MSS, cover at least half the peer's advertised window, or exhaust all remaining send buffer data (RFC 1122 S4.2.3.4)
- Nagle algorithm remains intact at line 69; SWS gate at line 77 -- ordering preserved
- Added post-drain window update ACK logic in `recv()`: snapshots `recvBufferAvailable()` before drain, recomputes after, sends ACK via `tx.sendAck(tcb)` when freed bytes >= `c.DEFAULT_MSS` (RFC 1122 S4.2.3.3)
- Threshold uses `c.DEFAULT_MSS` (local receive MSS constant), not `tcb.mss` (peer-advertised send MSS) -- semantically correct for a receive-side decision
- Both x86_64 and aarch64 compile cleanly

## Task Commits

Each task was committed atomically:

1. **Task 1: Add sender SWS avoidance gate in transmitPendingData()** - `cac3554` (feat)
2. **Task 2: Add post-drain window update ACK in recv()** - `3897d88` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/net/transport/tcp/tx/data.zig` - Sender SWS avoidance gate added after Nagle check (lines 73-83)
- `src/net/transport/tcp/api.zig` - Post-drain window update ACK in recv() using recvBufferAvailable() + DEFAULT_MSS threshold

## Decisions Made

- Sender SWS gate placed after Nagle, not before: Nagle is the cheaper check (single comparison on flight_size). SWS is the more specific check requiring division. Nagle before SWS is also the RFC-natural ordering since Nagle governs coalescing (in-flight vs window), while SWS governs segment sizing (segment vs peer window).
- Window update threshold uses `c.DEFAULT_MSS` (local receive MSS), not `tcb.mss` (peer's send MSS): the receive-side buffer freeing decision should use the local MSS since it represents the minimum segment size meaningful to advertise recovering space for.
- `freed` computed as `old_used - new_used` with a defensive `if (old_used > new_used)` guard: equals `copy_len` in the normal case, but guards against theoretical edge cases where concurrent recv_head writes from the RX path could have grown old_used between the snapshot and the drain.
- `sendAck` call under `tcb.mutex`: research (Pitfall 3 in RESEARCH.md) confirmed this is the correct pattern -- the lock is held for the duration of the recv() call, and sendAck must see consistent TCB state.

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

Pre-existing `zig build test` failure in `tests/unit/slab_bench.zig:29` using `std.time.Timer` removed in Zig 0.16.x. This is unrelated to the TCP window changes -- 15/15 unit tests that compile pass. Documented in STATE.md as a pre-existing known issue.

## Next Phase Readiness

- WIN-03 (window update ACK): complete -- receiver sends proactive ACK when drain frees >= DEFAULT_MSS bytes
- WIN-05 (sender SWS avoidance): complete -- transmitPendingData() suppresses tiny segments per RFC 1122 S4.2.3.4
- WIN-01, WIN-02, WIN-04 already complete from Plan 01
- Phase 37 Plan 03 (if any) can proceed; or phase 37 is complete if all WIN requirements are satisfied

---
*Phase: 37-dynamic-window-mgmt-persist-timer*
*Completed: 2026-02-19*

## Self-Check: PASSED

Files verified present:
- src/net/transport/tcp/tx/data.zig: FOUND (is_full_segment, is_half_window, Nagle at line 69 before SWS at line 77 -- confirmed)
- src/net/transport/tcp/api.zig: FOUND (window update, tx.sendAck, DEFAULT_MSS in recv() -- confirmed)

Commits verified:
- cac3554: FOUND (Task 1 -- data.zig sender SWS gate)
- 3897d88: FOUND (Task 2 -- api.zig window update ACK)
