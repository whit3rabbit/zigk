---
phase: 36-rtt-estimation-and-congestion-module
plan: 01
subsystem: network
tags: [tcp, congestion-control, reno, rfc5681, rfc6928]

# Dependency graph
requires: []
provides:
  - congestion/reno.zig with onAck, onTimeout, onDupAck entry points (RFC 5681 + RFC 6582)
  - INITIAL_CWND=14600 constant (RFC 6928 IW10) in net/constants.zig
  - MAX_CWND=32768 constant (4*BUFFER_SIZE, CC-05) in net/constants.zig
  - Both constants re-exported in tcp/constants.zig
  - Tcb.init() sets cwnd=INITIAL_CWND (replaces conservative DEFAULT_MSS*2)
affects:
  - 36-02 (wires reno.zig into existing call sites; depends on these entry points)
  - Phase 37 (window management builds on congestion state in Tcb)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Congestion control as a separate module (congestion/reno.zig) with pure functions mutating *Tcb
    - std.math.add with maxInt(u32) catch for all cwnd arithmetic (integer safety)
    - capCwnd() private helper enforces MAX_CWND ceiling after every increase

key-files:
  created:
    - src/net/transport/tcp/congestion/reno.zig
  modified:
    - src/net/constants.zig
    - src/net/transport/tcp/constants.zig
    - src/net/transport/tcp/types.zig

key-decisions:
  - "Congestion module uses relative imports (../types.zig, ../constants.zig) matching existing tcp/ convention"
  - "capCwnd is private inline fn, not exported -- callers do not need to know about the cap"
  - "onTimeout resets cwnd to 1*SMSS not IW10 (RFC 5681 S3.5 -- conservative restart, not initial window)"
  - "MAX_CWND expressed as 4 * BUFFER_SIZE in source (32768) to stay in sync if BUFFER_SIZE ever changes"

patterns-established:
  - "Congestion control functions take *Tcb and mutate in-place; callers hold tcb.mutex"
  - "flight_size computed as snd_nxt -% snd_una (wrapping subtraction for correct seq arithmetic)"
  - "u64 intermediate for MSS^2/cwnd CA increase avoids 32-bit overflow without heap allocation"

requirements-completed: [CC-02, CC-04, CC-05]

# Metrics
duration: 2min
completed: 2026-02-19
---

# Phase 36 Plan 01: Reno Congestion Control Module Summary

**TCP Reno congestion control module (RFC 5681/6582) created with IW10 initialization and MAX_CWND cap, establishing the congestion/ module boundary for Plan 02 call-site wiring**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-19T20:21:58Z
- **Completed:** 2026-02-19T20:23:23Z
- **Tasks:** 2
- **Files modified:** 4 (1 created, 3 modified)

## Accomplishments

- New module `src/net/transport/tcp/congestion/reno.zig` with three RFC-conformant entry points
- `INITIAL_CWND=14600` (RFC 6928 IW10) and `MAX_CWND=32768` (CC-05) defined in shared constants
- `Tcb.init()` updated from conservative `DEFAULT_MSS*2=2920` to `INITIAL_CWND=14600` (5x higher initial window)
- All cwnd arithmetic uses `std.math.add` with `maxInt(u32)` catch for integer overflow safety per project standards

## Task Commits

Each task was committed atomically:

1. **Task 1: Create congestion/reno.zig module with onAck/onTimeout/onDupAck** - `911e8f2` (feat)
2. **Task 2: Add INITIAL_CWND/MAX_CWND constants and set IW10 in Tcb.init()** - `1f2a44a` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/net/transport/tcp/congestion/reno.zig` - Reno CC module: onAck (slow-start + CA + fast recovery), onTimeout (RTO + Karn), onDupAck (fast retransmit/recovery), capCwnd (MAX_CWND enforcer)
- `src/net/constants.zig` - Added INITIAL_CWND=14600 and MAX_CWND=4*BUFFER_SIZE after BUFFER_SIZE
- `src/net/transport/tcp/constants.zig` - Re-exported INITIAL_CWND and MAX_CWND from net/constants.zig
- `src/net/transport/tcp/types.zig` - Tcb.init() cwnd changed from DEFAULT_MSS*2 to c.INITIAL_CWND with updated comment

## Decisions Made

- `onTimeout` resets cwnd to `1*SMSS` (not IW10) per RFC 5681 S3.5 -- conservative restart after timeout is mandatory, IW10 applies only to new connections
- `capCwnd` is a private `inline fn` -- the cap is an implementation detail of the congestion module, not a contract for callers
- `MAX_CWND` expressed as `4 * BUFFER_SIZE` in source to track BUFFER_SIZE changes automatically
- `flight_size` uses `-% ` (wrapping subtraction) for correct sequence number arithmetic across 32-bit wraparound

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness

- Plan 02 can now import `congestion/reno.zig` and wire `onAck`, `onTimeout`, `onDupAck` into existing call sites in `rx/` and `timers.zig`
- `INITIAL_CWND` and `MAX_CWND` are available in `tcp/constants.zig` for any code that needs them
- Full compilation verification will happen in Plan 02 when the module is actually imported

---
*Phase: 36-rtt-estimation-and-congestion-module*
*Completed: 2026-02-19*
