# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-20)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** Phase 40 -- Network Code Fixes

## Current Position

Phase: 40 of 43 (Network Code Fixes)
Plan: 2 of TBD in current phase
Status: In progress
Last activity: 2026-02-21 -- 40-02 complete (TCP_CORK mutex fix + raw socket MSG_DONTWAIT/MSG_PEEK)

Progress: [██░░░░░░░░] ~20% (v1.5 milestone; 84/84+ plans complete overall)

## Performance Metrics

**Velocity:**
- Total plans completed: 82 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4: 9)
- Total phases: 39 complete, across 5 milestones
- Timeline: 16 days (2026-02-06 to 2026-02-20)

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 15 | 2 days |
| v1.2 | 15-26 | 14 | 5 days |
| v1.3 | 27-35 | 15 | 4 days |
| v1.4 | 36-39 | 9 | 2 days |
| v1.5 (in progress) | 40-43 | 4+ | ongoing |

## Accumulated Context

### Decisions

See PROJECT.md Key Decisions table for full history.

Recent decisions affecting v1.5:
- [Phase 40 prereq]: hasPendingSignal callback approach means blocked_thread must be cleared on EINTR -- the stale pointer is a real use-after-free risk on retry
- [Phase 42]: QEMU loopback only (guest-internal); no TAP/host-to-guest networking needed for verification
- [Phase 40-network-code-fixes]: TCP_CORK flush acquires tcb.mutex before transmitPendingData -- lock order: sock.lock (L6) -> tcb.mutex (L7)
- [Phase 40-network-code-fixes]: MSG_DONTWAIT in raw socket recv uses OR semantics with sock.blocking for WouldBlock decision
- [Phase 40-01]: Re-fetch TCB via socket.getTcb() after sched.block() to avoid stale pointer use-after-free on EINTR retry
- [Phase 40-01]: Propagate rcv_buf_size and snd_buf_size to TCB in all four connect paths; listen() path excluded as accepted connections inherit from listening TCB

### Pending Todos

None.

### Blockers/Concerns

- Pre-existing: `zig build test` fails in tests/unit/slab_bench.zig:29 (std.time.Timer removed in Zig 0.16.x) -- addressed by CLN-02 in Phase 41
- Phase 43 depends on Phase 42 (loopback setup) AND Phase 40 (code fixes) being complete before verification can run

## Session Continuity

Last session: 2026-02-21 (Phase 40 plan 02 execution)
Stopped at: Completed 40-02-PLAN.md
Resume file: None

**Next action:** Continue Phase 40 remaining plans

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-21 after 40-02 completion*
