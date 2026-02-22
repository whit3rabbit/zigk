# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-20)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** Phase 42 -- QEMU Loopback Setup (complete with bug fixes); Phase 43 -- Socket Test Verification (goals already achieved by Phase 42 bug fixes)

## Current Position

Phase: 42 of 44 (QEMU Loopback Setup)
Plan: 1 of 1 in current phase
Status: Complete (verified, all success criteria passed)
Last activity: 2026-02-21 -- 42-01 complete with extensive bug fixes; loopback fully functional on both architectures

Progress: [████░░░░░░] ~35% (v1.5 milestone; 86/86+ plans complete overall)

## Performance Metrics

**Velocity:**
- Total plans completed: 82 (v1.0: 29, v1.1: 15, v1.2: 14, v1.3: 15, v1.4: 9)
- Total phases: 39 complete, across 5 milestones
- Timeline: 16 days (2026-02-06 to 2026-02-21)

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

Last session: 2026-02-21 (Phase 42 complete with bug fixes)
Stopped at: All Phase 42 work complete, verification passed
Resume file: None

**Next action:** Phase 43 (Socket Test Verification) -- note that Phase 42 bug fixes have already achieved most of Phase 43's goals (all socket tests pass). Consider whether Phase 43 needs separate execution or can be marked complete based on Phase 42 results.

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-21 after 42-01 completion and verification*
