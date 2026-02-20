# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-19)

**Core value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.
**Current focus:** v1.4 Network Stack Hardening -- Phase 39 complete (MSG flags: MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL, EINTR gap closed)

## Current Position

Phase: 39 of 39 (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL flag support + EINTR gap closure)
Plan: 3 of 3 in current phase (39-01, 39-02, and 39-03 complete)
Status: Phase 39 complete -- all plans done
Last activity: 2026-02-20 -- 39-03 complete (hasPendingSignal callback + EINTR checks in MSG_PEEK, MSG_WAITALL, default TCP recv loops)

Progress: [██████████] 100% (3/3 plans in phase 39 done; 83/83 plans complete across phases 1-39)

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

**Phase 38 metrics:**
- 38-01: 7min -- SO_RCVBUF/SO_SNDBUF/TCP_CORK/MSG_NOSIGNAL + queue size increases + blocking raw recv
- 38-02: 2min -- SO_REUSEPORT blanket bind allow in canReuseAddress() + FIFO dispatch via listen_accept_count

**Phase 39 metrics:**
- 39-01: 6min -- MSG_PEEK/MSG_DONTWAIT/MSG_WAITALL constants + TCP/UDP peek support + flags threaded through recv stack + userspace recvfromFlags wrappers
- 39-02: ~30min -- tcpRecvWaitall accumulation loop + MSG_WAITALL dispatch + 5 integration tests + kernel stack 96KB->192KB fix
- 39-03: 2min -- hasPendingSignal callback in socket scheduler shim + EINTR checks in MSG_PEEK, MSG_WAITALL, and default TCP recv blocking loops

## Accumulated Context

### Decisions

See PROJECT.md Key Decisions table for full history.

Recent v1.4 decisions (Phase 39):
- MSG_DONTWAIT overrides sock.blocking per-call only (sock.blocking field not mutated)
- TCP peek uses local_tail copy to iterate recv_buf without writing back tcb.recv_tail; no window update ACK
- sys_recvfrom now dispatches TCP and UDP separately (pre-existing bug: SOCK_STREAM was routed through UDP recvfromIp which accesses UDP rx_queue, not TCP recv_buf)
- MSG_NOSIGNAL honored in sys_sendmsg TCP send path (SIGPIPE suppression)
- MSG_WAITALL implemented as tcpRecvWaitall accumulation loop with SO_RCVTIMEO total-wait timeout
- MSG_WAITALL ignored for SOCK_DGRAM per POSIX (datagrams are atomic, partial returns undefined)
- Flag priority: MSG_PEEK > MSG_DONTWAIT > MSG_WAITALL > default blocking (matches Linux behavior)
- Kernel stack increased 96KB->192KB (24->48 pages) to fix pre-existing double fault from comptime dispatch table expansion across phases 24-39
- signals import added to msg.zig (already in syscall_net_module build.zig deps)
- hasPendingSignal callback stored in scheduler.zig shim behind spinlock -- same pattern as existing wake/block/getCurrent callbacks
- tcpRecvWaitall returns WouldBlock on signal; syscall layer converts to EINTR -- keeps transport layer independent of syscall error vocabulary
- HLT fallback path in tcpRecvWaitall intentionally excludes signal check -- no signal delivery without scheduler; comment added

Previous v1.4 decisions:
- Option A buffer sizing (fixed 8KB arrays with rcv_buf_size cap field) -- avoids heap allocation in IRQ-context recv path and Tcb.reset() leak risk
- SO_REUSEPORT included in Phase 38 as simplified FIFO implementation -- bind table data structure change is minimal for FIFO dispatch
- sendBufferSpace() sentinel slot preserved when applying snd_buf_size cap (used+1>=limit) to prevent head==tail ambiguity
- sws_floor uses effective_buf (not c.BUFFER_SIZE) in currentRecvWindow() -- prevents zero-window stall when rcv_buf_size < BUFFER_SIZE/2
- signals import added to syscall_net_module in build.zig to enable SIGPIPE delivery from sys_sendto and socketWrite
- SO_REUSEPORT check is FIRST in canReuseAddress() as blanket allow, bypassing all TCP restrictions including two-listener block
- listen_accept_count on Tcb (not Socket) avoids circular import and lock ordering concern between tcp_state.lock (5) and socket/state.lock (6)
- listen_accept_count incremented by scanning listen_tcbs in handleSynReceivedEstablished() after queueAcceptConnection -- O(N) over listeners, negligible cost
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

Last session: 2026-02-20 (39-03 execution)
Stopped at: Completed 39-03-PLAN.md (hasPendingSignal callback + EINTR checks for MSG_PEEK, MSG_WAITALL, default TCP recv loops)
Resume file: None

**Next action:** Phase 39 complete. All plans across all phases complete (83/83). EINTR gap for MSG_WAITALL is fully closed.

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-20 after 39-03 execution*
