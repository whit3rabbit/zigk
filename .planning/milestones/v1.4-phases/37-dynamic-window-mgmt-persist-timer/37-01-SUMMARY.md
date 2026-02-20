---
phase: 37-dynamic-window-mgmt-persist-timer
plan: 01
subsystem: network
tags: [tcp, window-management, persist-timer, SWS, RFC-1122]

# Dependency graph
requires:
  - phase: 36-rtt-congestion
    provides: reno.zig congestion module, Tcb fields cwnd/ssthresh/srtt/rttvar

provides:
  - persist_timer and persist_backoff fields in Tcb (RFC 1122 S4.2.2.17)
  - SWS avoidance floor in currentRecvWindow() (RFC 1122 S4.2.3.3)
  - Dedicated persist timer block in processTimers() with 60s-capped exponential backoff
  - Removal of retransmit-timer-based zero-window probe from transmitPendingData()

affects: [38-socket-options, timers.zig, types.zig]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Persist timer mutual exclusion with retransmit timer via retrans_timer == 0 guard"
    - "SWS floor: suppress window advertisement below min(BUFFER_SIZE/2, MSS)"
    - "Persist probe: FLAG_ACK only (no FLAG_PSH), 1 byte from send_tail"

key-files:
  created: []
  modified:
    - src/net/transport/tcp/types.zig
    - src/net/transport/tcp/timers.zig
    - src/net/transport/tcp/tx/data.zig

key-decisions:
  - "Persist timer uses mutual exclusion with retransmit timer (retrans_timer == 0 guard) -- running both simultaneously causes duplicate probes"
  - "Persist probe sends FLAG_ACK only (no FLAG_PSH) -- RFC 1122 S4.2.2.17 does not require PSH; probe elicits window update, not data delivery"
  - "Probe byte read from send_tail (not send_head) -- send_tail tracks snd_una position in the circular buffer"
  - "SWS floor = min(BUFFER_SIZE/2, MSS) -- RFC 1122 S4.2.3.3; safe at SYN time since empty buffer space > floor"

patterns-established:
  - "Persist timer: arm at timer=1, increment each tick, fire when timer > probe_interval, reset to 1 after firing"
  - "Backoff: shift = min(persist_backoff, 6); probe_interval = min(rto_ms << shift, 60000)"
  - "Disarm persist timer when snd_wnd > 0 (window reopened by incoming ACK)"

requirements-completed: [WIN-01, WIN-02, WIN-04]

# Metrics
duration: 2min
completed: 2026-02-19
---

# Phase 37 Plan 01: SWS Avoidance and Persist Timer Summary

**RFC 1122-compliant persist timer with 60s-capped exponential backoff replacing retransmit-based zero-window probe, plus SWS avoidance floor suppressing window advertisements below min(BUFFER_SIZE/2, MSS)**

## Performance

- **Duration:** 2min
- **Started:** 2026-02-19T21:35:25Z
- **Completed:** 2026-02-19T21:37:43Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- Added `persist_timer:u64` and `persist_backoff:u8` fields to Tcb struct, initialized to 0 in Tcb.init()
- Replaced `currentRecvWindow()` with SWS avoidance floor: returns 0 when available space < min(BUFFER_SIZE/2, MSS), preventing silly-window syndrome (RFC 1122 S4.2.3.3)
- Added dedicated persist timer block in processTimers() with exponential backoff capped at 60s and mutual exclusion with retransmit timer -- persist only fires when retrans_timer == 0
- Removed old retransmit-timer-based zero-window probe from transmitPendingData() -- persist timer now handles this exclusively

## Task Commits

Each task was committed atomically:

1. **Task 1: Add SWS floor to currentRecvWindow() and persist timer fields to Tcb** - `a8bcffa` (feat)
2. **Task 2: Add persist timer to processTimers() and remove old zero-window probe** - `e9f21d9` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/net/transport/tcp/types.zig` - Added persist_timer/persist_backoff fields to Tcb; SWS avoidance floor in currentRecvWindow()
- `src/net/transport/tcp/timers.zig` - Added segment import; added persist timer block in processTimers() with 60s-capped exponential backoff
- `src/net/transport/tcp/tx/data.zig` - Removed old zero-window probe block; window-full case now returns early with comment pointing to persist timer

## Decisions Made

- Persist timer uses mutual exclusion with retransmit timer: the `retrans_timer == 0` guard prevents duplicate probes when data is in flight. When all in-flight data is ACKed and retrans_timer disarms, persist timer takes over.
- Persist probe sends FLAG_ACK only (no FLAG_PSH): RFC 1122 S4.2.2.17 does not require PSH on zero-window probes. PSH signals the receiver to deliver buffered data; a persist probe only elicits a window update.
- Probe byte read from `send_tail % BUFFER_SIZE` (not send_head or send_acked): send_tail tracks the circular buffer position of snd_una data, so send_buf[send_tail] is always the byte at snd_una.
- SWS floor applied at advertisement time in currentRecvWindow(): safe at SYN time because empty buffer gives space == BUFFER_SIZE, which always exceeds the floor.

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

Pre-existing `zig build test` failure in `tests/unit/slab_bench.zig:29` using `std.time.Timer` removed in Zig 0.16.x. This is unrelated to the TCP window changes -- the 15/15 unit tests that do compile all pass. Logged as deferred item; not caused by this plan.

## Next Phase Readiness

- WIN-01 (currentRecvWindow wiring): confirmed structurally satisfied -- all segment-building paths already call tcb.currentRecvWindow()
- WIN-02 (persist timer): complete with proper RFC 1122 S4.2.2.17 implementation
- WIN-04 (SWS avoidance): complete with RFC 1122 S4.2.3.3 floor in currentRecvWindow()
- Ready for Phase 37 Plan 02 (buffer management / rcv_buf_size wiring)

---
*Phase: 37-dynamic-window-mgmt-persist-timer*
*Completed: 2026-02-19*

## Self-Check: PASSED

Files verified present:
- src/net/transport/tcp/types.zig: FOUND (persist_timer, persist_backoff, sws_floor confirmed)
- src/net/transport/tcp/timers.zig: FOUND (persist_timer block confirmed)
- src/net/transport/tcp/tx/data.zig: FOUND (old probe removed, confirmed)

Commits verified:
- a8bcffa: FOUND (Task 1 -- types.zig)
- e9f21d9: FOUND (Task 2 -- timers.zig + data.zig)
