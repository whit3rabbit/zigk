# Roadmap: ZK Kernel

## Milestones

- ✅ **v1.0 POSIX Syscall Coverage** - Phases 1-9 (shipped 2026-02-09)
- ✅ **v1.1 Hardening & Debt Cleanup** - Phases 10-14 (shipped 2026-02-11)
- ✅ **v1.2 Systematic Syscall Coverage** - Phases 15-26 (shipped 2026-02-16)
- ✅ **v1.3 Tech Debt Cleanup** - Phases 27-35 (shipped 2026-02-19)
- 🚧 **v1.4 Network Stack Hardening** - Phases 36-39 (in progress)

## Phases

<details>
<summary>v1.0 POSIX Syscall Coverage (Phases 1-9) - SHIPPED 2026-02-09</summary>

- [x] Phase 1: Trivial Stubs (4/4 plans) - completed 2026-02-06
- [x] Phase 2: UID/GID Infrastructure (3/3 plans) - completed 2026-02-06
- [x] Phase 3: File Ownership (2/2 plans) - completed 2026-02-06
- [x] Phase 4: I/O Multiplexing Infrastructure (3/3 plans) - completed 2026-02-07
- [x] Phase 5: Event Notification FDs (3/3 plans) - completed 2026-02-07
- [x] Phase 6: Vectored & Positional I/O (3/3 plans) - completed 2026-02-08
- [x] Phase 7: Filesystem Extras (3/3 plans) - completed 2026-02-08
- [x] Phase 8: Socket Extras (3/3 plans) - completed 2026-02-08
- [x] Phase 9: Process Control & SysV IPC (5/5 plans) - completed 2026-02-09

</details>

<details>
<summary>v1.1 Hardening & Debt Cleanup (Phases 10-14) - SHIPPED 2026-02-11</summary>

- [x] Phase 10: Critical Kernel Bugs (3/3 plans) - completed 2026-02-09
- [x] Phase 11: SFS Deadlock Fix (1/1 plans) - completed 2026-02-09
- [x] Phase 12: SFS Hard Link Support (2/2 plans) - completed 2026-02-10
- [x] Phase 13: SFS Symlink & Timestamp Support (2/2 plans) - completed 2026-02-10
- [x] Phase 14: WaitQueue Blocking & Optimizations (7/7 plans) - completed 2026-02-11

</details>

<details>
<summary>v1.2 Systematic Syscall Coverage (Phases 15-26) - SHIPPED 2026-02-16</summary>

- [x] Phase 15: File Synchronization (1/1 plans) - completed 2026-02-12
- [x] Phase 16: Advanced File Operations (1/1 plans) - completed 2026-02-12
- [x] Phase 17: Zero-Copy I/O (2/2 plans) - completed 2026-02-13
- [x] Phase 18: Memory Management Extensions (1/1 plans) - completed 2026-02-13
- [x] Phase 19: Process Control Extensions (1/1 plans) - completed 2026-02-14
- [x] Phase 20: Signal Handling Extensions (1/1 plans) - completed 2026-02-14
- [x] Phase 21: I/O Multiplexing Extension (1/1 plans) - completed 2026-02-15
- [x] Phase 22: File Monitoring (1/1 plans) - completed 2026-02-15
- [x] Phase 23: POSIX Timers (1/1 plans) - completed 2026-02-15
- [x] Phase 24: Capabilities (1/1 plans) - completed 2026-02-16
- [x] Phase 25: Seccomp (1/1 plans) - completed 2026-02-16
- [x] Phase 26: Test Coverage Expansion (2/2 plans) - completed 2026-02-16

</details>

<details>
<summary>v1.3 Tech Debt Cleanup (Phases 27-35) - SHIPPED 2026-02-19</summary>

- [x] Phase 27: Quick Wins (2/2 plans) - completed 2026-02-16
- [x] Phase 28: rt_sigsuspend Race Fix (1/1 plans) - completed 2026-02-17
- [x] Phase 29: Siginfo Queue (2/2 plans) - completed 2026-02-17
- [x] Phase 30: Signal Wakeup Integration (1/1 plans) - completed 2026-02-18
- [x] Phase 31: Inotify Completion (1/1 plans) - completed 2026-02-18
- [x] Phase 32: Timer Capacity Expansion (1/1 plans) - completed 2026-02-18
- [x] Phase 33: Timer Resolution Improvement (3/3 plans) - completed 2026-02-18
- [x] Phase 34: Timer Notification Modes (2/2 plans) - completed 2026-02-19
- [x] Phase 35: VFS Page Cache and Zero-Copy (2/2 plans) - completed 2026-02-19

</details>

### v1.4 Network Stack Hardening (In Progress)

**Milestone Goal:** Harden the existing TCP/UDP networking stack with correct congestion control per RFC 5681/6298/6928, dynamic window management per RFC 1122, complete socket option support (SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK), MSG flag threading (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL), and raw socket blocking recv.

- [x] **Phase 36: RTT Estimation and Congestion Module** - Fix Karn's Algorithm in all retransmit paths, apply IW10, cap cwnd growth, extract congestion logic into congestion/reno.zig (completed 2026-02-19)
- [x] **Phase 37: Dynamic Window Management and Persist Timer** - Wire currentRecvWindow() into ACK building, add persist timer separate from retransmit, implement SWS avoidance on both sender and receiver (completed 2026-02-19)
- [x] **Phase 38: Socket Options and Raw Socket Blocking** - Implement SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK, MSG_NOSIGNAL, and raw socket blocking recv (completed 2026-02-20)
- [ ] **Phase 39: MSG Flags** - Thread flags parameter through the TCP/UDP call stack; implement MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL

## Phase Details

### Phase 36: RTT Estimation and Congestion Module
**Goal**: TCP congestion control operates on a reliable RTT foundation with correct RFC-compliant algorithms
**Depends on**: Phase 35 (v1.3 complete)
**Requirements**: CC-01, CC-02, CC-03, CC-04, CC-05
**Success Criteria** (what must be TRUE):
  1. Slow-start increments cwnd by min(acked, SMSS) per ACK, not by a fixed AIMD step
  2. New connections open with cwnd = 10*MSS (IW10) instead of the previous IW2
  3. RTT is not sampled on retransmitted segments; rtt_seq is cleared in all retransmit paths
  4. Congestion logic lives in congestion/reno.zig with onAck/onTimeout/onDupAck entry points callable from the existing TCP paths
  5. cwnd cannot grow beyond 4x the send buffer size regardless of how many ACKs arrive on an idle connection
**Plans**: 2 plans
Plans:
- [x] 36-01-PLAN.md -- Create reno.zig module, IW10 constants, Tcb.init() update (complete 2026-02-19)
- [x] 36-02-PLAN.md -- Wire reno into established.zig/timers.zig, fix Karn's in data.zig (complete 2026-02-19)

### Phase 37: Dynamic Window Management and Persist Timer
**Goal**: TCP receive windows accurately reflect available buffer space and zero-window connections do not stall indefinitely
**Depends on**: Phase 36
**Requirements**: WIN-01, WIN-02, WIN-03, WIN-04, WIN-05
**Success Criteria** (what must be TRUE):
  1. Every ACK sent by the receiver carries the result of currentRecvWindow() rather than a hardcoded constant
  2. When the receive buffer drains by at least one MSS, the receiver sends a window update ACK to the peer
  3. A persist timer fires independently of the retransmit timer with probes capped at 60-second intervals; connections do not freeze during zero-window periods
  4. Receiver does not reopen the window for less than min(rcv_buf/2, MSS) freed space (RFC 1122 SWS avoidance)
  5. Sender does not transmit a segment unless it is at least SMSS bytes, at least half the peer's window, or the last data in the buffer (RFC 1122 SWS avoidance)
**Plans**: 2 plans
Plans:
- [x] 37-01-PLAN.md -- SWS floor in currentRecvWindow(), persist timer fields and logic, remove old zero-window probe (complete 2026-02-19)
- [ ] 37-02-PLAN.md -- Sender SWS avoidance gate, post-drain window update ACK in recv()

### Phase 38: Socket Options and Raw Socket Blocking
**Goal**: Standard socket buffer options take effect and are reflected in the protocol, and raw sockets can block for incoming packets
**Depends on**: Phase 37
**Requirements**: BUF-01, BUF-02, BUF-03, BUF-04, BUF-05, API-04, API-05, API-06
**Success Criteria** (what must be TRUE):
  1. setsockopt(SO_RCVBUF) and setsockopt(SO_SNDBUF) succeed and the set value gates currentRecvWindow() and the send buffer respectively
  2. getsockopt(SO_RCVBUF) and getsockopt(SO_SNDBUF) return double the stored value per Linux ABI convention
  3. Multiple sockets can bind to the same address:port pair when SO_REUSEPORT is set; incoming connections are distributed FIFO among them
  4. TCP_CORK holds data in the send buffer until a full MSS is accumulated or the cork is cleared via setsockopt; clearing the cork flushes immediately
  5. Raw socket recv blocks until a packet arrives rather than returning WouldBlock unconditionally
  6. MSG_NOSIGNAL suppresses SIGPIPE on write to a broken connection; the call returns EPIPE instead of delivering a signal
**Plans**: 2 plans
- [x] 38-01-PLAN.md -- Buffer options, TCP_CORK, raw blocking recv, MSG_NOSIGNAL (BUF-01/02/03/05, API-04/05/06)
- [x] 38-02-PLAN.md -- SO_REUSEPORT bind and FIFO listener dispatch (BUF-04)

### Phase 39: MSG Flags
**Goal**: Standard recv/send flags work correctly across TCP and UDP so protocol libraries that use MSG_PEEK, MSG_DONTWAIT, and MSG_WAITALL operate without modification
**Depends on**: Phase 38
**Requirements**: API-01, API-02, API-03
**Success Criteria** (what must be TRUE):
  1. recv() with MSG_PEEK returns data from the receive buffer without consuming it; a subsequent recv() without MSG_PEEK returns the same data
  2. recv() with MSG_DONTWAIT returns immediately with EAGAIN if no data is available, regardless of the socket's O_NONBLOCK state
  3. recv() with MSG_WAITALL blocks until the full requested length is received, EOF is reached, or an error occurs; SO_RCVTIMEO and EINTR terminate the wait early
**Plans**: 3 plans
Plans:
- [x] 39-01-PLAN.md -- MSG_PEEK and MSG_DONTWAIT flag constants, peek functions, flags plumbing (API-01, API-02)
- [x] 39-02-PLAN.md -- MSG_WAITALL accumulation loop, integration tests for all three flags (API-03)
- [ ] 39-03-PLAN.md -- Gap closure: EINTR signal checks in MSG_WAITALL and MSG_PEEK blocking loops (API-01, API-02, API-03)

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
| 36. RTT Estimation and Congestion Module | v1.4 | Complete    | 2026-02-19 | 2026-02-19 |
| 37. Dynamic Window Management and Persist Timer | 2/2 | Complete    | 2026-02-19 | - |
| 38. Socket Options and Raw Socket Blocking | v1.4 | Complete    | 2026-02-20 | 2026-02-20 |
| 39. MSG Flags | v1.4 | 2/3 | In progress | - |

---
*Roadmap created: 2026-02-06*
*Last updated: 2026-02-19 after Phase 39 plan 01 execution*
