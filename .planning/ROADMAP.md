# Roadmap: ZK Kernel

## Milestones

- v1.0 **POSIX Syscall Coverage** -- Phases 1-9 (shipped 2026-02-09)
- v1.1 **Hardening & Debt Cleanup** -- Phases 10-14 (shipped 2026-02-11)
- v1.2 **Systematic Syscall Coverage** -- Phases 15-26 (shipped 2026-02-16)
- v1.3 **Tech Debt Cleanup** -- Phases 27-35 (shipped 2026-02-19)
- v1.4 **Network Stack Hardening** -- Phases 36-39 (shipped 2026-02-20)
- v1.5 **Tech Debt Cleanup** -- Phases 40-44 (in progress)

## Phases

<details>
<summary>v1.0 POSIX Syscall Coverage (Phases 1-9) -- SHIPPED 2026-02-09</summary>

- [x] Phase 1: Trivial Stubs (4/4 plans) -- completed 2026-02-06
- [x] Phase 2: UID/GID Infrastructure (3/3 plans) -- completed 2026-02-06
- [x] Phase 3: File Ownership (2/2 plans) -- completed 2026-02-06
- [x] Phase 4: I/O Multiplexing Infrastructure (3/3 plans) -- completed 2026-02-07
- [x] Phase 5: Event Notification FDs (3/3 plans) -- completed 2026-02-07
- [x] Phase 6: Vectored & Positional I/O (3/3 plans) -- completed 2026-02-08
- [x] Phase 7: Filesystem Extras (3/3 plans) -- completed 2026-02-08
- [x] Phase 8: Socket Extras (3/3 plans) -- completed 2026-02-08
- [x] Phase 9: Process Control & SysV IPC (5/5 plans) -- completed 2026-02-09

</details>

<details>
<summary>v1.1 Hardening & Debt Cleanup (Phases 10-14) -- SHIPPED 2026-02-11</summary>

- [x] Phase 10: Critical Kernel Bugs (3/3 plans) -- completed 2026-02-09
- [x] Phase 11: SFS Deadlock Fix (1/1 plans) -- completed 2026-02-09
- [x] Phase 12: SFS Hard Link Support (2/2 plans) -- completed 2026-02-10
- [x] Phase 13: SFS Symlink & Timestamp Support (2/2 plans) -- completed 2026-02-10
- [x] Phase 14: WaitQueue Blocking & Optimizations (7/7 plans) -- completed 2026-02-11

</details>

<details>
<summary>v1.2 Systematic Syscall Coverage (Phases 15-26) -- SHIPPED 2026-02-16</summary>

- [x] Phase 15: File Synchronization (1/1 plans) -- completed 2026-02-12
- [x] Phase 16: Advanced File Operations (1/1 plans) -- completed 2026-02-12
- [x] Phase 17: Zero-Copy I/O (2/2 plans) -- completed 2026-02-13
- [x] Phase 18: Memory Management Extensions (1/1 plans) -- completed 2026-02-13
- [x] Phase 19: Process Control Extensions (1/1 plans) -- completed 2026-02-14
- [x] Phase 20: Signal Handling Extensions (1/1 plans) -- completed 2026-02-14
- [x] Phase 21: I/O Multiplexing Extension (1/1 plans) -- completed 2026-02-15
- [x] Phase 22: File Monitoring (1/1 plans) -- completed 2026-02-15
- [x] Phase 23: POSIX Timers (1/1 plans) -- completed 2026-02-15
- [x] Phase 24: Capabilities (1/1 plans) -- completed 2026-02-16
- [x] Phase 25: Seccomp (1/1 plans) -- completed 2026-02-16
- [x] Phase 26: Test Coverage Expansion (2/2 plans) -- completed 2026-02-16

</details>

<details>
<summary>v1.3 Tech Debt Cleanup (Phases 27-35) -- SHIPPED 2026-02-19</summary>

- [x] Phase 27: Quick Wins (2/2 plans) -- completed 2026-02-16
- [x] Phase 28: rt_sigsuspend Race Fix (1/1 plans) -- completed 2026-02-17
- [x] Phase 29: Siginfo Queue (2/2 plans) -- completed 2026-02-17
- [x] Phase 30: Signal Wakeup Integration (1/1 plans) -- completed 2026-02-18
- [x] Phase 31: Inotify Completion (1/1 plans) -- completed 2026-02-18
- [x] Phase 32: Timer Capacity Expansion (1/1 plans) -- completed 2026-02-18
- [x] Phase 33: Timer Resolution Improvement (3/3 plans) -- completed 2026-02-18
- [x] Phase 34: Timer Notification Modes (2/2 plans) -- completed 2026-02-19
- [x] Phase 35: VFS Page Cache and Zero-Copy (2/2 plans) -- completed 2026-02-19

</details>

<details>
<summary>v1.4 Network Stack Hardening (Phases 36-39) -- SHIPPED 2026-02-20</summary>

- [x] Phase 36: RTT Estimation and Congestion Module (2/2 plans) -- completed 2026-02-19
- [x] Phase 37: Dynamic Window Management and Persist Timer (2/2 plans) -- completed 2026-02-19
- [x] Phase 38: Socket Options and Raw Socket Blocking (2/2 plans) -- completed 2026-02-20
- [x] Phase 39: MSG Flags (3/3 plans) -- completed 2026-02-20

</details>

### v1.5 Tech Debt Cleanup (In Progress)

**Milestone Goal:** Resolve all 18 v1.4 tech debt items -- fix 6 code defects, clean up 3 documentation gaps, configure QEMU loopback networking, and verify 8 network features live.

- [x] **Phase 40: Network Code Fixes** - Fix 4 TCP/raw socket defects from v1.4 audit (completed 2026-02-21)
- [x] **Phase 41: Code Cleanup and Documentation** - Remove dead code, fix Zig compat, update 3 archived milestone docs (completed 2026-02-21)
- [x] **Phase 42: QEMU Loopback Setup** - Configure loopback networking in QEMU test environment for both architectures (completed 2026-02-21)
- [x] **Phase 43: Network Feature Verification** - Verify 8 network features under live loopback; unskip 5 MSG flag tests (completed 2026-02-22)
- [x] **Phase 44: Audit Gap Closure** - Fix ROADMAP/REQUIREMENTS formatting, update satisfied checkboxes, resolve raw_api dead code (completed 2026-02-21)

## Phase Details

### Phase 40: Network Code Fixes
**Goal**: All 4 network defects identified in the v1.4 audit are corrected in the codebase
**Depends on**: Nothing (independent code fixes)
**Requirements**: NET-01, NET-02, NET-03, NET-04
**Success Criteria** (what must be TRUE):
  1. tcb.blocked_thread is cleared to null before EINTR is returned in both MSG_PEEK blocking and default TCP blocking recv paths, preventing stale pointer dereference on retry
  2. A socket with SO_RCVBUF or SO_SNDBUF set before connect() passes those buffer sizes into Tcb.init() so the configured sizes take effect on the connection
  3. TCP_CORK uncork flush holds tcb.mutex before calling transmitPendingData(), matching the locking pattern used in all other TCB mutation paths
  4. Raw socket recv path checks MSG_DONTWAIT and MSG_PEEK flags and behaves identically to TCP recv (non-blocking return and peek-without-consume respectively)
**Plans:** 2/2 plans complete
Plans:
- [x] 40-01-PLAN.md -- Fix stale blocked_thread pointer on EINTR and buffer size propagation on connect
- [x] 40-02-PLAN.md -- Fix TCP_CORK uncork locking and raw socket MSG_DONTWAIT/MSG_PEEK flags

### Phase 41: Code Cleanup and Documentation
**Goal**: Dead code is removed, the Zig 0.16.x compat issue is fixed, and all 3 v1.4 documentation gaps are closed
**Depends on**: Nothing (independent of Phase 40)
**Requirements**: CLN-01, CLN-02, DOC-01, DOC-02, DOC-03
**Success Criteria** (what must be TRUE):
  1. Tcb.send_acked field no longer exists in types.zig; all references compile cleanly
  2. `zig build test` completes without error (slab_bench.zig no longer uses the removed std.time.Timer API)
  3. v1.4 REQUIREMENTS.md has all previously-satisfied requirement checkboxes marked as checked
  4. All 9 v1.4 plan SUMMARY files have the requirements_completed frontmatter field populated with a non-empty value
  5. ROADMAP.md phase 37 and phase 39 progress table rows have correct formatting matching all other rows
**Plans:** 2/2 plans complete
Plans:
- [x] 41-01-PLAN.md -- Remove dead Tcb.send_acked field and fix slab_bench Timer API for Zig 0.16.x
- [x] 41-02-PLAN.md -- Update v1.4 REQUIREMENTS.md checkboxes, SUMMARY frontmatter, and ROADMAP formatting

### Phase 42: QEMU Loopback Setup
**Goal**: The QEMU test environment has functional loopback networking on both x86_64 and aarch64, enabling guest-internal TCP/UDP connections
**Depends on**: Phase 40
**Requirements**: TST-01
**Success Criteria** (what must be TRUE):
  1. `zig build run -Darch=x86_64` with loopback networking launches QEMU with a virtual loopback adapter visible to the kernel
  2. `zig build run -Darch=aarch64` with loopback networking launches QEMU with the same loopback configuration
  3. A test program can open a TCP socket, bind to 127.0.0.1, connect to itself, and exchange data without errors on both architectures
**Plans:** 1/1 plans complete
Plans:
- [x] 42-01-PLAN.md -- Initialize loopback interface and full network stack at kernel boot

### Phase 43: Network Feature Verification
**Goal**: All 8 network features from the v1.4 audit are confirmed working under live loopback; the 5 MSG flag tests run and pass
**Depends on**: Phase 42, Phase 40
**Requirements**: TST-02, TST-03
**Success Criteria** (what must be TRUE):
  1. Zero-window recovery test completes: sender blocked on zero-window receive window, then unblocked when receiver opens window, with no hang or panic
  2. SWS avoidance test confirms small writes are coalesced until the window or Nagle threshold is satisfied
  3. Raw socket blocking recv returns data when a packet arrives (no busy-spin, no hang)
  4. SO_REUSEPORT test confirms connections are distributed across multiple listening sockets bound to the same port
  5. SIGPIPE is delivered on write to a closed socket; MSG_NOSIGNAL suppresses it and returns EPIPE instead
  6. MSG_PEEK on UDP does not consume the datagram; MSG_DONTWAIT on an empty socket returns EAGAIN immediately
  7. MSG_WAITALL on TCP accumulates across multiple segments until the full requested byte count is delivered
  8. SO_RCVTIMEO combined with MSG_WAITALL times out and returns a partial count when the deadline expires before full data arrives
  9. All 5 MSG flag integration tests in the test runner execute and report pass (not skipped) on both x86_64 and aarch64
**Plans:** 3 plans (2 complete, 1 pending)
Plans:
- [x] 43-01-PLAN.md -- Add userspace wrappers, write 8 network verification tests, run on both architectures
- [x] 43-02-PLAN.md -- Gap closure: strengthen SIGPIPE assertion, SWS multi-write, MSG_WAITALL multi-segment, raw socket traffic
- [ ] 43-03-PLAN.md -- Gap closure: raw socket ICMP echo round-trip over loopback (SC3 blocking recv with data)

### Phase 44: Audit Gap Closure
**Goal**: All audit-identified documentation gaps, tech debt, and dead code are resolved so the milestone can close cleanly
**Depends on**: Phase 41 (builds on partial DOC-03 work)
**Requirements**: DOC-03
**Gap Closure**: Closes gaps from v1.5 audit
**Success Criteria** (what must be TRUE):
  1. ROADMAP.md Phase 41 progress row has correct v1.5 milestone column, Plans Complete shows 2/2, and Plan 41-01 checkbox is checked
  2. REQUIREMENTS.md traceability table shows `[x] Satisfied` for all 9 completed requirements (NET-01 through NET-04, CLN-01, CLN-02, DOC-01, DOC-02, DOC-03)
  3. raw_api.recvfromRaw and recvfromRaw6 are either wired into sys_recvfrom SOCK_RAW dispatch path or removed as dead code
**Plans:** 1/1 plans complete
Plans:
- [x] 44-01-PLAN.md -- Fix ROADMAP/REQUIREMENTS tracking and remove recvfromRaw dead code

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Trivial Stubs | v1.0 | 4/4 | Complete | 2026-02-06 |
| 2. UID/GID Infrastructure | v1.0 | 3/3 | Complete | 2026-02-06 |
| 3. File Ownership | v1.0 | 2/2 | Complete | 2026-02-06 |
| 4. I/O Multiplexing Infrastructure | v1.0 | 3/3 | Complete | 2026-02-07 |
| 5. Event Notification FDs | v1.0 | 3/3 | Complete | 2026-02-07 |
| 6. Vectored & Positional I/O | v1.0 | 3/3 | Complete | 2026-02-08 |
| 7. Filesystem Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 8. Socket Extras | v1.0 | 3/3 | Complete | 2026-02-08 |
| 9. Process Control & SysV IPC | v1.0 | 5/5 | Complete | 2026-02-09 |
| 10. Critical Kernel Bugs | v1.1 | 3/3 | Complete | 2026-02-09 |
| 11. SFS Deadlock Fix | v1.1 | 1/1 | Complete | 2026-02-09 |
| 12. SFS Hard Link Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 13. SFS Symlink & Timestamp Support | v1.1 | 2/2 | Complete | 2026-02-10 |
| 14. WaitQueue Blocking & Optimizations | v1.1 | 7/7 | Complete | 2026-02-11 |
| 15. File Synchronization | v1.2 | 1/1 | Complete | 2026-02-12 |
| 16. Advanced File Operations | v1.2 | 1/1 | Complete | 2026-02-12 |
| 17. Zero-Copy I/O | v1.2 | 2/2 | Complete | 2026-02-13 |
| 18. Memory Management Extensions | v1.2 | 1/1 | Complete | 2026-02-13 |
| 19. Process Control Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 20. Signal Handling Extensions | v1.2 | 1/1 | Complete | 2026-02-14 |
| 21. I/O Multiplexing Extension | v1.2 | 1/1 | Complete | 2026-02-15 |
| 22. File Monitoring | v1.2 | 1/1 | Complete | 2026-02-15 |
| 23. POSIX Timers | v1.2 | 1/1 | Complete | 2026-02-15 |
| 24. Capabilities | v1.2 | 1/1 | Complete | 2026-02-16 |
| 25. Seccomp | v1.2 | 1/1 | Complete | 2026-02-16 |
| 26. Test Coverage Expansion | v1.2 | 2/2 | Complete | 2026-02-16 |
| 27. Quick Wins | v1.3 | 2/2 | Complete | 2026-02-16 |
| 28. rt_sigsuspend Race Fix | v1.3 | 1/1 | Complete | 2026-02-17 |
| 29. Siginfo Queue | v1.3 | 2/2 | Complete | 2026-02-17 |
| 30. Signal Wakeup Integration | v1.3 | 1/1 | Complete | 2026-02-18 |
| 31. Inotify Completion | v1.3 | 1/1 | Complete | 2026-02-18 |
| 32. Timer Capacity Expansion | v1.3 | 1/1 | Complete | 2026-02-18 |
| 33. Timer Resolution Improvement | v1.3 | 3/3 | Complete | 2026-02-18 |
| 34. Timer Notification Modes | v1.3 | 2/2 | Complete | 2026-02-19 |
| 35. VFS Page Cache and Zero-Copy | v1.3 | 2/2 | Complete | 2026-02-19 |
| 36. RTT Estimation and Congestion Module | v1.4 | 2/2 | Complete | 2026-02-19 |
| 37. Dynamic Window Management and Persist Timer | v1.4 | 2/2 | Complete | 2026-02-19 |
| 38. Socket Options and Raw Socket Blocking | v1.4 | 2/2 | Complete | 2026-02-20 |
| 39. MSG Flags | v1.4 | 3/3 | Complete | 2026-02-20 |
| 40. Network Code Fixes | v1.5 | 2/2 | Complete | 2026-02-21 |
| 41. Code Cleanup and Documentation | v1.5 | 2/2 | Complete | 2026-02-21 |
| 42. QEMU Loopback Setup | v1.5 | 1/1 | Complete | 2026-02-21 |
| 43. Network Feature Verification | 2/2 | Complete   | 2026-02-22 | 2026-02-22 |
| 44. Audit Gap Closure | v1.5 | Complete    | 2026-02-21 | 2026-02-21 |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-22 after Phase 43 network feature verification completion*
