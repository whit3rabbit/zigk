---
phase: 36-rtt-estimation-and-congestion-module
plan: 02
subsystem: network
tags: [tcp, congestion-control, reno, rfc5681, rfc6298, karn]

# Dependency graph
requires:
  - 36-01 (congestion/reno.zig with onAck/onTimeout/onDupAck entry points)
provides:
  - established.zig wired to reno.onAck and reno.onDupAck (CC-04 complete)
  - timers.zig wired to reno.onTimeout for all timeout CC
  - Karn's Algorithm applied in retransmitFromSeq (CC-03 complete)
affects:
  - Phase 37 (window management can now build on correctly-wired CC state)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - reno module called from all CC call sites; no inline CC arithmetic remains outside congestion/
    - Correct ordering: partial ACK retransmit -> snd_una update -> reno.onAck (per RFC 6582 S3.2)
    - Karn's Algorithm: retransmitFromSeq clears rtt_seq as its first statement

key-files:
  created: []
  modified:
    - src/net/transport/tcp/rx/established.zig
    - src/net/transport/tcp/timers.zig
    - src/net/transport/tcp/tx/data.zig

key-decisions:
  - "Partial ACK retransmit placed BEFORE reno.onAck -- if onAck deflates cwnd first, retransmitLoss may see insufficient window and decline to send"
  - "snd_una updated BEFORE reno.onAck -- onAck reads snd_una to detect full ACK (seqGte(snd_una, recover) for fast recovery exit)"
  - "acked_bytes computed BEFORE snd_una update -- calculation uses old snd_una as base"
  - "rtt_seq cleared at top of retransmitFromSeq (not only in onTimeout) -- covers all three retransmit paths"

patterns-established:
  - "All cwnd mutations go through reno module; established.zig and timers.zig have zero inline CC arithmetic"
  - "Double-clear of rtt_seq in timeout path (onTimeout + retransmitFromSeq) is harmless -- clearing 0 to 0 is a no-op"

requirements-completed: [CC-01, CC-03, CC-04]

# Metrics
duration: 2min
completed: 2026-02-19
---

# Phase 36 Plan 02: Reno Wiring and Karn's Algorithm Summary

**Reno congestion module wired into all TCP call sites with correct ordering invariants, Karn's Algorithm applied in all retransmit paths, both architectures build clean**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-19T20:25:47Z
- **Completed:** 2026-02-19T20:27:48Z
- **Tasks:** 3 (2 code tasks + 1 build verification)
- **Files modified:** 3

## Accomplishments

- `rx/established.zig` now calls `reno.onAck` for all cwnd updates on new ACKs and `reno.onDupAck` for all duplicate ACK handling -- no inline CC arithmetic remains
- `timers.zig` now calls `reno.onTimeout` replacing the 3-line inline ssthresh/cwnd block -- no inline CC arithmetic remains
- `tx/data.zig` `retransmitFromSeq` clears `rtt_seq = 0` as its first statement (Karn's Algorithm, CC-03)
- Correct ordering in established.zig: RTT sample -> acked_bytes computed -> partial ACK retransmit -> snd_una update -> reno.onAck
- Both x86_64 and aarch64 build with zero errors

## Task Commits

Each task was committed atomically:

1. **Task 1: Wire reno into established.zig** - `33183d3` (feat)
2. **Task 2: Wire reno.onTimeout into timers.zig, apply Karn's in data.zig** - `98586f4` (feat)
3. **Task 3: Build verification** - no commit (verification-only task, no file changes)

## Files Created/Modified

- `src/net/transport/tcp/rx/established.zig` - Added reno import, replaced inline CC blocks with reno.onAck and reno.onDupAck calls with correct ordering
- `src/net/transport/tcp/timers.zig` - Added reno import, replaced 3-line inline ssthresh/cwnd block with reno.onTimeout(tcb)
- `src/net/transport/tcp/tx/data.zig` - Added tcb.rtt_seq = 0 as first statement in retransmitFromSeq for Karn's Algorithm

## Decisions Made

- Partial ACK retransmit placed BEFORE reno.onAck to prevent window starvation: if onAck deflates cwnd first, retransmitLoss may see insufficient window and decline
- snd_una updated BEFORE reno.onAck so that onAck can correctly detect full ACK exit from fast recovery via `seqGte(snd_una, recover)`
- acked_bytes computed BEFORE snd_una update since the formula `ack -% tcb.snd_una` requires the old snd_una as base
- rtt_seq cleared in retransmitFromSeq (not only in onTimeout) to cover all three retransmit paths: timeout, partial ACK, and 3-dup-ACK fast retransmit

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## Verification Results

- `zig build -Darch=x86_64`: exit 0 (PASS)
- `zig build -Darch=aarch64`: exit 0 (PASS)
- `reno.onAck` present in established.zig (line 65)
- `reno.onDupAck` present in established.zig (line 87)
- `reno.onTimeout` present in timers.zig (line 116)
- `tcb.rtt_seq = 0` present at top of retransmitFromSeq in data.zig (line 120)
- No inline CC arithmetic (`cwnd = std.math.add`, `ssthresh = @max(flight_size`) in established.zig or timers.zig

## User Setup Required

None -- no external service configuration required.

## Phase 36 Completion

All Phase 36 requirements are now complete:
- **CC-01**: Slow-start cwnd += min(acked, SMSS) preserved in reno.onAck (Plan 01)
- **CC-02**: Reno CC module created with all three entry points (Plan 01)
- **CC-03**: Karn's Algorithm -- rtt_seq cleared in all retransmit paths (Plan 01 onTimeout + Plan 02 retransmitFromSeq)
- **CC-04**: Wired into all existing call sites in established.zig and timers.zig (Plan 02)
- **CC-05**: MAX_CWND cap enforced via capCwnd() in every onAck/onDupAck path (Plan 01 + 02)

---
*Phase: 36-rtt-estimation-and-congestion-module*
*Completed: 2026-02-19*

## Self-Check: PASSED

- FOUND: src/net/transport/tcp/rx/established.zig
- FOUND: src/net/transport/tcp/timers.zig
- FOUND: src/net/transport/tcp/tx/data.zig
- FOUND: .planning/phases/36-rtt-estimation-and-congestion-module/36-02-SUMMARY.md
- FOUND commit: 33183d3 (Task 1)
- FOUND commit: 98586f4 (Task 2)
