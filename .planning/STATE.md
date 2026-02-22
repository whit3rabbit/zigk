# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-20)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** Phase 43 -- Network Feature Verification (complete); Phase 44 -- v1.5 Milestone Audit

## Current Position

Phase: 43 of 44 (Network Feature Verification)
Plan: 2 of 2 in current phase
Status: Complete (verified, all 8 Phase 43 tests pass on both x86_64 and aarch64)
Last activity: 2026-02-22 -- 43-02 complete; 4 verification gaps closed; x86_64 463/480, aarch64 460/480

Progress: [████░░░░░░] ~40% (v1.5 milestone; 87/87+ plans complete overall)

## Performance Metrics

**Velocity:**
- Total plans completed: 83 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4: 9, v1.5: 1)
- Total phases: 40 complete, across 5 milestones
- Timeline: 17 days (2026-02-06 to 2026-02-22)

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 15 | 2 days |
| v1.2 | 15-26 | 14 | 5 days |
| v1.3 | 27-35 | 15 | 4 days |
| v1.4 | 36-39 | 9 | 2 days |
| v1.5 (in progress) | 40-44 | 5+ | ongoing |

## Accumulated Context

### Decisions

See PROJECT.md Key Decisions table for full history.

Recent decisions affecting v1.5:
- [Phase 43-02]: processTimers() must be in net.tick() -- was defined/exported but never called; no delayed ACK ever fired
- [Phase 43-02]: SIGPIPE test uses AF_UNIX socketpair -- TCP FIN_WAIT2 ignores data without RST; socketpair gives synchronous EPIPE
- [Phase 43-02]: MSG_WAITALL as implicit sleep -- no sleep_ms between writes; recv blocking allows timer to fire delayed ACK
- [Phase 43-01]: SO_RCVTIMEO test uses EOF (SHUT_WR) not TSC timeout -- QEMU TCG has uncalibrated TSC so timers never fire; EOF is reliable
- [Phase 43-01]: SOCK_NONBLOCK fix applied -- sys_socket now sets sock.blocking=false + O_NONBLOCK when SOCK_NONBLOCK requested
- [Phase 43-01]: Single-threaded test constraint: SWS avoidance and MSG_WAITALL tests send all bytes atomically to avoid concurrent send+recv deadlock
- [Phase 42]: Make loopback async (queue + drain) to prevent re-entrant deadlocks
- [Phase 42]: Apply @byteSwap to all checksum stores -- onesComplement() computes big-endian, struct fields are native-endian
- [Phase 42]: Handle SYN_SENT before sequence acceptability check -- rcv_nxt=0 rejects random ISN
- [Phase 42]: Set BOTH sock.blocked_thread AND tcb.blocked_thread when blocking TCP recv
- [Phase 42]: Skip mDNS init -- mdns.tick() acquires socket locks, incompatible with ISR context
- [Phase 42]: ARP resolveUnlocked returns zeros for 127.x.x.x -- no ARP needed for loopback
- [Phase 42-01]: Initialize loopback and full net stack before PCI enumeration
- [Phase 42-01]: combinedTickCallback replaces usbPollTickCallback; single slot covers net.tick() + USB poll
- [Phase 40-network-code-fixes]: TCP_CORK flush acquires tcb.mutex before transmitPendingData
- [Phase 40-01]: Re-fetch TCB via socket.getTcb() after sched.block() to avoid stale pointer

### Pending Todos

None.

### Blockers/Concerns

- RESOLVED (42): Checksum byte-order bug across entire network TX stack -- fixed with @byteSwap
- RESOLVED (42): TCP SYN_SENT ACK storm on loopback -- fixed by reordering state machine check
- RESOLVED (42): MSG_WAITALL blocks forever -- fixed by setting tcb.blocked_thread
- Test suite hangs at "sendfile large transfer" due to pre-existing SFS close deadlock (documented in MEMORY.md)

## Session Continuity

Last session: 2026-02-22 (Phase 43-02 complete)
Stopped at: Completed 43-02-PLAN.md
Resume file: None

**Next action:** Phase 44 -- v1.5 Milestone Audit (if it exists in .planning/phases/)

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-22 after 43-02 completion -- 4 verification gaps closed; processTimers wired into net.tick()*
