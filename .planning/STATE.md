# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-19)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** v1.4 Network Stack Hardening -- Phase 37 in progress (Receive Window and Buffer Management)

## Current Position

Phase: 37 of 39 (Receive Window and Buffer Management -- in progress)
Plan: 2 of 2 in current phase (37-01 and 37-02 complete -- phase 37 done)
Status: Phase 37 complete
Last activity: 2026-02-19 -- 37-02 complete (sender SWS avoidance gate + window update ACK in recv)

Progress: [████████░░] 80% (2/2 plans in phase 37 done; 77/77 plans complete across phases 1-37)

## Performance Metrics

**Velocity:**
- Total plans completed: 77 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4-p36: 2, v1.4-p37: 2)
- Total phases: 37 complete, across 4 milestones
- Timeline: 14 days (2026-02-06 to 2026-02-19)

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 15 | 2 days |
| v1.2 | 15-26 | 14 | 5 days |
| v1.3 | 27-35 | 15 | 4 days |
| v1.4 (partial) | 36-37 | 4 | <1 day (in progress) |

**Phase 36 metrics:**
- 36-01: 2min -- Reno CC module created (congestion/reno.zig), IW10 constants, INITIAL_CWND in Tcb.init
- 36-02: 2min -- Reno wired into all call sites, Karn's Algorithm applied

**Phase 37 metrics:**
- 37-01: 2min -- SWS avoidance floor in currentRecvWindow() + RFC 1122 persist timer with 60s-capped exponential backoff
- 37-02: 1min -- Sender SWS avoidance gate in transmitPendingData() + window update ACK in recv()

## Accumulated Context

### Decisions

See PROJECT.md Key Decisions table for full history.

Recent v1.4 decisions:
- Option A buffer sizing (fixed 8KB arrays with rcv_buf_size cap field) -- avoids heap allocation in IRQ-context recv path and Tcb.reset() leak risk
- SO_REUSEPORT included in Phase 38 as simplified FIFO implementation -- bind table data structure change is minimal for FIFO dispatch
- Congestion module extraction (Phase 36) before window wiring (Phase 37) -- module boundary must exist before algorithm work; retrofitting later requires full re-audit
- onTimeout resets cwnd to 1*SMSS not IW10 (RFC 5681 S3.5 mandatory; IW10 is for new connections only)
- MAX_CWND expressed as 4*BUFFER_SIZE in source (not hardcoded 32768) -- tracks BUFFER_SIZE changes automatically
- capCwnd is private inline fn in reno.zig -- cap is CC module detail, not a caller contract
- Partial ACK retransmit placed BEFORE reno.onAck in established.zig -- if onAck deflates cwnd first, retransmitLoss may see insufficient window and decline
- rtt_seq cleared in retransmitFromSeq (not only onTimeout) -- covers all three retransmit paths (timeout, partial ACK, 3-dup-ACK)
- Persist timer uses retrans_timer == 0 mutual exclusion -- running both simultaneously causes duplicate zero-window probes
- Persist probe sends FLAG_ACK only (no FLAG_PSH) -- RFC 1122 S4.2.2.17; probe elicits window update, not data delivery signal
- SWS floor = min(BUFFER_SIZE/2, MSS) -- RFC 1122 S4.2.3.3; safe at SYN time since empty buffer space always exceeds floor
- Sender SWS gate placed after Nagle check -- Nagle gates on flight_size, SWS gates on segment size vs window; both are complementary suppressors
- Window update threshold uses c.DEFAULT_MSS (local receive MSS) not tcb.mss (peer send MSS) -- semantically correct for receive-side decision

### Pending Todos

None.

### Blockers/Concerns

- Phase 37 research flag: calculateWindowScale() call chain in options.zig:205 needs auditing to confirm how rcv_buf_size threads through rx/syn.zig. Plan-phase should include an audit pass before implementation estimate.
- Minor v1.3 tech debt: SIGEV_THREAD_ID does not call sched.unblock on blocked target (latent optimization, not correctness bug, not blocking v1.4)
- Pre-existing: `zig build test` fails in tests/unit/slab_bench.zig:29 (std.time.Timer removed in Zig 0.16.x) -- unrelated to TCP changes

## Session Continuity

Last session: 2026-02-19 (37-02 execution)
Stopped at: Completed 37-02-PLAN.md (sender SWS avoidance + window update ACK)
Resume file: None

**Next action:** Phase 37 complete. Ready for Phase 38.

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-19 after 37-02 execution*
