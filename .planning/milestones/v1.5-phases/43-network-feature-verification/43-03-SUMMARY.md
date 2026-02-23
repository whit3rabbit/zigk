---
phase: 43-network-feature-verification
plan: 03
subsystem: testing
tags: [raw-socket, icmp, checksum, loopback, blocking-recv]

# Dependency graph
requires:
  - phase: 43-network-feature-verification
    provides: "Phase 43-02: 4 verification gaps closed, all 8 Phase 43 tests passing on x86_64/aarch64"
provides:
  - "ICMP echo round-trip test via raw socket blocking recv (SC3 closed)"
  - "sendtoRaw IP and ICMP checksum byteSwap fix"
affects: [43-VERIFICATION, 44-v1.5-milestone-audit]

# Tech tracking
tech-stack:
  added: []
  patterns: ["All TX checksum stores require @byteSwap -- onesComplement() returns big-endian, struct fields are native-endian"]

key-files:
  created: []
  modified:
    - src/user/test_runner/tests/syscall/sockets.zig
    - src/net/transport/socket/raw_api.zig

key-decisions:
  - "sendtoRaw IP and ICMP checksums both required @byteSwap -- same bug family as Phase 42 fix; packet was silently dropped at IPv4 RX checksum verification"
  - "Blocking recv relies on LAPIC timer -> timerTick -> net.tick() -> loopback.drain() -> ICMP echo reply -> deliverToRawSockets4 -> wakeThread path"
  - "loopback.drain() processes both echo request and reply within a single drain call (MAX_DRAIN_PER_TICK=64), so one timer tick suffices"

patterns-established:
  - "Rule: All TX paths building IP headers must use @byteSwap(checksum.ipChecksum(...)) -- verified in sendtoRaw, handleEchoRequest, ipv4/transmit.zig"
  - "Rule: All TX paths building ICMP headers must use @byteSwap(checksum.icmpChecksum(...)) for the checksum field"

requirements-completed: [TST-02, TST-03]

# Metrics
duration: 45min
completed: 2026-02-22
---

# Phase 43 Plan 03: Raw Socket ICMP Echo Round-Trip Summary

**ICMP echo request/reply round-trip via SOCK_RAW blocking recv, with sendtoRaw checksum @byteSwap bug fix that caused silent packet drop at IPv4 RX**

## Performance

- **Duration:** ~45 min
- **Started:** 2026-02-22T00:00:00Z
- **Completed:** 2026-02-22T00:45:00Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments

- Rewrote `testRawSocketBlockingRecv` to send an ICMP echo request to 127.0.0.1 and receive the echo reply via blocking recv, verifying type=0 and matching identifier bytes
- Fixed `sendtoRaw` in `raw_api.zig`: both IP checksum and ICMP checksum were missing `@byteSwap`, causing the ICMP echo request to be silently dropped at the IPv4 RX layer
- SC3 verification gap fully closed: blocking recv returns actual ICMP echo reply data from the loopback network path
- All 8 Phase 43 tests pass on x86_64 (463/480) and aarch64 (460/480), zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Rewrite testRawSocketBlockingRecv + fix sendtoRaw checksums** - `93b9a13` (fix)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/user/test_runner/tests/syscall/sockets.zig` - Rewrote testRawSocketBlockingRecv with ICMP echo round-trip over loopback
- `src/net/transport/socket/raw_api.zig` - Fixed missing @byteSwap on IP and ICMP checksum stores in sendtoRaw

## Decisions Made

- **sendtoRaw checksum bug**: IP and ICMP checksums in `sendtoRaw` were stored without `@byteSwap`. The `onesComplement()` checksum function returns a big-endian value that must be byte-swapped before storing in a native-endian struct field (same bug family as the Phase 42 fix documented in MEMORY.md). Without the fix, the IPv4 RX path's `verifyIpChecksum` rejected the packet silently.
- **Blocking recv mechanism**: The blocking path in `recvfromIp` uses `sched.block()` -> `hal.cpu.enableAndHalt()` (STI; HLT), which halts until the next hardware LAPIC timer interrupt (100Hz = ~10ms). The timer fires `timerTick` -> `net.tick()` -> `loopback.drain()`, which processes the echo request and generates the echo reply in the same drain call. The reply is delivered to the raw socket via `deliverToRawSockets4`, which calls `wakeThread(sock.blocked_thread)`.
- **No SO_RCVTIMEO needed**: The LAPIC timer fires within ~10ms, well within the 90s test runner timeout. The fallback path (returning on WouldBlock/TimedOut) was kept for robustness but is not exercised in practice.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed sendtoRaw missing @byteSwap on IP and ICMP checksum stores**
- **Found during:** Task 1 (after first test run timed out at 90s)
- **Issue:** `sendtoRaw` in `raw_api.zig` stored IP checksum as `ip.checksum = checksum_mod.ipChecksum(...)` and ICMP checksum as `icmp_hdr.checksum = checksum_mod.icmpChecksum(...)`. Both missing `@byteSwap`. The IPv4 RX path's `verifyIpChecksum` check (ipv4/process.zig:51) rejected the malformed packet, so `handleEchoRequest` was never called, and the blocking recv hung indefinitely.
- **Fix:** Added `@byteSwap(...)` to both checksum stores in `sendtoRaw`, matching the pattern used in `handleEchoRequest` and `ipv4/transmit.zig`
- **Files modified:** `src/net/transport/socket/raw_api.zig`
- **Verification:** x86_64 test PASS: raw socket blocking recv; aarch64 test PASS: raw socket blocking recv
- **Committed in:** `93b9a13` (combined with task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** The byteSwap fix was required for the test to function. Without it, the echo request was silently dropped before ICMP processing. The fix is correct and consistent with the project-wide rule established in Phase 42.

## Issues Encountered

The first test run timed out at 90s because the blocking recv in `testRawSocketBlockingRecv` never returned. Investigation traced the hang: `schedule_sync()` fires `int $32` which goes through `irqHandler(IRQ 0)` -> `timerTick` -> `tick_cb` -> `net.tick()` -> `loopback.drain()`. However, `sched.block()` uses `hal.cpu.enableAndHalt()` (STI; HLT), not the software `int $32`. The loopback drain fires correctly on the hardware LAPIC timer. The actual root cause was `sendtoRaw` producing an invalid IP checksum (missing `@byteSwap`), which caused `processPacket` in `ipv4/process.zig` to reject the packet at step 4 (checksum verification) before any ICMP processing occurred.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 43 SC3 gap is now fully closed
- All 8 Phase 43 tests pass on both architectures
- Phase 43 is complete: all 3 plans (43-01, 43-02, 43-03) done
- Next: Phase 44 -- v1.5 Milestone Audit (if planned)

## Self-Check: PASSED

- `43-03-SUMMARY.md`: FOUND
- `src/net/transport/socket/raw_api.zig`: FOUND
- `src/user/test_runner/tests/syscall/sockets.zig`: FOUND
- Commit `93b9a13`: FOUND

---
*Phase: 43-network-feature-verification*
*Completed: 2026-02-22*
