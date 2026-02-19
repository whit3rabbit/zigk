# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-19)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** v1.4 Network Stack Hardening -- Phase 36 COMPLETE, next: Phase 37 (Receive Window and Buffer Management)

## Current Position

Phase: 36 of 39 (RTT Estimation and Congestion Module -- COMPLETE)
Plan: 2 of 2 in current phase (36-02 complete)
Status: Phase 36 complete, ready for Phase 37
Last activity: 2026-02-19 -- 36-02 complete (reno wired into all call sites, Karn's Algorithm applied)

Progress: [██░░░░░░░░] 10% (2/2 plans in phase 36 done; 75/75 plans complete across phases 1-36)

## Performance Metrics

**Velocity:**
- Total plans completed: 75 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4-p36: 2)
- Total phases: 36 complete across 4 milestones + phase 36
- Timeline: 14 days (2026-02-06 to 2026-02-19)

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 15 | 2 days |
| v1.2 | 15-26 | 14 | 5 days |
| v1.3 | 27-35 | 15 | 4 days |
| v1.4 (partial) | 36 | 2 | <1 day |

**Phase 36 metrics:**
- 36-01: 2min -- Reno CC module created (congestion/reno.zig), IW10 constants, INITIAL_CWND in Tcb.init
- 36-02: 2min -- Reno wired into all call sites, Karn's Algorithm applied

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

### Pending Todos

None.

### Blockers/Concerns

- Phase 37 research flag: calculateWindowScale() call chain in options.zig:205 needs auditing to confirm how rcv_buf_size threads through rx/syn.zig. Plan-phase should include an audit pass before implementation estimate.
- Minor v1.3 tech debt: SIGEV_THREAD_ID does not call sched.unblock on blocked target (latent optimization, not correctness bug, not blocking v1.4)

## Session Continuity

Last session: 2026-02-19 (36-02 execution)
Stopped at: Completed 36-02-PLAN.md (reno wiring + Karn's Algorithm)
Resume file: None

**Next action:** /gsd:execute-phase 37 (Phase 37: Receive Window and Buffer Management)

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-19 after 36-02 execution*
