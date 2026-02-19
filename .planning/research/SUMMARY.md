# Project Research Summary

**Project:** zk Kernel -- TCP/UDP Network Stack Hardening (v1.4 Milestone)
**Domain:** Kernel TCP/IP stack: congestion control, window management, socket API completeness
**Researched:** 2026-02-19
**Confidence:** HIGH

## Executive Summary

The zk TCP stack is structurally sound -- it has a complete RFC 793 state machine, Jacobson/Karels RTT estimation, all the congestion control fields (cwnd, ssthresh, dup_ack_count, fast_recovery, recover), and a working Nagle implementation. This milestone is not a greenfield implementation; it is hardening and completing what already exists. The critical gaps are three: the slow-start cwnd increment uses the wrong formula (congestion avoidance arithmetic instead of RFC 5681 S3.1), the receive window is hardcoded to 8KB and never dynamically updated, and the MSG_* flags on recv/send are silently discarded at the syscall boundary (`_ = flags` at net.zig:547). These gaps cause real breakage for any userspace program using standard POSIX socket patterns.

The recommended approach is surgical: fix the congestion arithmetic, wire the existing `currentRecvWindow()` into ACK building, thread MSG flags through the call stack, and add a handful of missing socket options (SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK). No new libraries are needed. All algorithms are in-kernel Zig against RFC specifications. The primary complexity is architectural -- buffer sizing decisions cascade through TCB struct layout, window scale negotiation, and circular buffer arithmetic. These must be addressed in the right order or they interact badly.

The dominant risk is the buffer lifecycle: `Tcb` embeds fixed 8KB arrays inline, and `Tcb.reset()` uses a value-copy pattern that will silently leak if dynamic buffers are added. Additionally, Karn's Algorithm is not applied (RTT is measured on retransmitted segments), and the persist timer is missing (zero-window probing uses the RTO backoff, which can freeze connections for minutes). Both are RFC violations that must be fixed before congestion control is extended. The recommended build order addresses all of this: RTT fixes and congestion extraction first, window management second, socket options third, MSG flags fourth.

---

## Key Findings

### Recommended Stack

This milestone requires no new dependencies. The implementation is pure Zig against existing zk infrastructure. The relevant technology decisions are algorithmic.

**Core technologies/algorithms:**
- **RFC 5681 NewReno (not CUBIC/BBR):** QEMU loopback BDP is near zero; CUBIC adds W_max/t_last_decrease complexity with no measurable benefit. NewReno partial-ACK handling (RFC 6582) is already scaffolded via the `recover` field in TCB. One-line fix to the slow-start branch is the correct approach.
- **Option A buffer sizing (clamped fixed arrays):** Keep 8KB inline arrays; add a `rcv_buf_size` field that gates how much of that space is advertised in the window. Avoids heap allocation in the IRQ-context receive path. Dynamic allocation (Option B) deferred until a concrete workload demands buffers larger than 8KB.
- **`CongestionState` sub-struct isolation:** Extract `cwnd`, `ssthresh`, `dup_ack_count`, `fast_recovery`, `recover` into a new `congestion/reno.zig` module called via `congestion.onAck()`, `congestion.onTimeout()`, `congestion.onDupAck()`. Zero behavior change, but makes algorithm replacement surgical rather than a full RX path rewrite.
- **Zig 0.16.x nightly:** No new compatibility concerns for network code in this milestone. The `compilerFence` and `trimRight` removals (documented in CLAUDE.md) do not affect the TCP stack.

**Critical ABI values:** All Linux socket option and MSG flag constants verified against Linux 6.x stable UABI (MSG_PEEK=0x2, MSG_DONTWAIT=0x40, MSG_WAITALL=0x100, SO_SNDBUF=7, SO_RCVBUF=8, SO_REUSEPORT=15, TCP_CORK=3). These values have not changed since Linux 2.6.20 and are HIGH confidence.

### Expected Features

**Must have (table stakes -- active breakage today):**
- **MSG_PEEK** -- protocol parsers (HTTP, TLS) peek headers before consuming; without it, any non-trivial protocol library breaks. Implementation: copy from recv_tail without advancing it. No new buffer structures required.
- **MSG_DONTWAIT** -- per-call non-blocking override distinct from O_NONBLOCK. Required by event loop patterns. Implementation: `effective_blocking = sock.blocking AND NOT(flags & MSG_DONTWAIT)` threaded through the call stack.
- **MSG_WAITALL** -- binary protocols that know exact message sizes; without it, short reads silently truncate. Implementation: accumulation loop in the syscall layer with SO_RCVTIMEO deadline and EINTR break.
- **Dynamic rcv_wnd wiring** -- `currentRecvWindow()` exists and computes the correct value from free buffer space, but ACK segments use the hardcoded `tcb.rcv_wnd` constant. Fixing this is a wiring change, not a new algorithm. Without it, throughput is capped at 8KB in-flight.
- **IW10 (RFC 6928)** -- one-line change: `.cwnd = c.DEFAULT_MSS * 10` instead of `* 2`. Current IW2 requires 5x more RTTs to fill the pipe on a typical 14KB HTTP response.
- **Karn's Algorithm (RFC 6298)** -- set `rtt_seq = 0` in all retransmit paths. Currently RTT is sampled on retransmitted segments, causing RTO inflation after any loss event. This is an RFC violation that corrupts all congestion control decisions post-loss.

**Should have (improve compliance and throughput):**
- **SO_RCVBUF / SO_SNDBUF (store-and-cap)** -- programs that set these options receive EINVAL today; some treat that as fatal. Store value, clamp to [1024, 262144], apply as cap in `currentRecvWindow()`. Linux doubles the stored value internally; implement the same for ABI compatibility.
- **TCP_CORK** -- batch writes into full-MSS segments; used by HTTP/1.1 sendfile patterns and scatter-gather protocols. Adds `cork: bool` to TCB; modifies `transmitPendingData` to hold data until MSS or cork cleared.
- **Persist timer separation** -- zero-window probing currently uses the RTO backoff timer, which backs off to 64s+ between probes. RFC 1122 requires a separate persist timer capped at 60s. Connections freeze without this.

**Defer (v2+):**
- **SO_REUSEPORT** -- requires a reuseport group data structure and 4-tuple hash at SYN time; no current workload demands multi-worker server architecture. Simplified FIFO version is implementable but the bind table data structure design is not fully resolved.
- **True dynamic buffer resize** -- converting TCB's fixed 8KB arrays to heap-allocated slices requires TCB struct refactor, `Tcb.deinit()`, and auditing 18 sites that reference `c.BUFFER_SIZE` as a type-level constant.
- **CUBIC / BBR / ECN** -- zero measurable benefit in QEMU loopback environment; add when real-hardware networking is supported.
- **MSG_OOB** -- RFC 6093 recommends against new implementations; no known application on zk uses urgent data.

### Architecture Approach

The existing TCP stack is organized cleanly: `rx/established.zig` owns ACK and data processing, `tx/data.zig` owns segment selection and Nagle, `timers.zig` owns retransmit and backoff, `socket/tcp_api.zig` bridges the syscall layer to the transport layer. All new features integrate into these existing files; only two new files are added (`congestion/root.zig`, `congestion/reno.zig`). The key architectural decision is that MSG flags must be threaded as a `flags: u32` parameter through the `tcpSend`/`tcpRecv` -> `tcp/api.send`/`recv` call chain -- these functions currently take no flags parameter. No changes to the state machine, lock structure, or TCP dispatch are needed.

**Major components and their changes:**
1. **`tcp/types.zig` (TCB struct)** -- add `last_adv_wnd: u16` for window update tracking, `rcv_buf_size`/`snd_buf_size: usize` for buffer caps, `cork: bool` for TCP_CORK, `last_rcv_wnd: u16` for SWS avoidance
2. **`tcp/congestion/` (new module)** -- extract cwnd update logic from `rx/established.zig` into `reno.zig` with `onAck()`, `onTimeout()`, `onDupAck()` entry points; `root.zig` provides algorithm selection
3. **`socket/tcp_api.zig`** -- add `flags: u32` to `tcpSend`/`tcpRecv`; implement MSG_PEEK (peekFromRecvBuf helper), MSG_WAITALL (accumulation loop), MSG_DONTWAIT (per-call blocking override)
4. **`socket/options.zig`** -- add handlers for SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK, TCP_MAXSEG, TCP_CONGESTION
5. **`tcp/timers.zig`** -- add persist timer separate from retrans timer; add `rtt_seq = 0` in retransmit paths (Karn's Algorithm)

**Lock order compliance:** All blocking loops (MSG_WAITALL, persist timer probes) must follow the existing `accept()` pattern: release `tcp_state.lock` and `sock.lock` before calling `block_fn()`, re-acquire after waking. Never allocate memory under `state.lock` (IrqLock, interrupts disabled). The existing lock ordering (`tcp_state.lock` -> `sock.lock` -> `tcb.mutex`) must not be violated by any new code path.

### Critical Pitfalls

1. **`Tcb.reset()` buffer lifecycle leak** -- `Tcb.reset()` does `self.* = Self.init()`, which is correct for value types. If dynamic buffers are added, this silently leaks the old allocation. Prevention: do not change buffer types until `Tcb.deinit(allocator)` exists and all `freeTcb` calls are audited to call it first. The safe path for this milestone is Option A (fixed arrays with a size-cap field), which avoids this pitfall entirely.

2. **Window scale locked at handshake, invalid after buffer resize** -- `rcv_wscale` is negotiated in SYN/SYN-ACK based on `c.BUFFER_SIZE` (comptime constant) in `options.zig:205`. If buffer size changes post-handshake, the scale factor is wrong. Prevention: compute `rcv_wscale` from the socket's configured `rcv_buf_size` at `listen()`/`connect()` time. `SO_RCVBUF` applies only to new connections -- reject or silently ignore changes on established sockets.

3. **Karn's Algorithm missing in all retransmit paths** -- `rtt_seq` is not cleared in `retransmitFromSeq()`, timer expiry, or fast retransmit. RTT samples from retransmitted segments overestimate RTT, inflating RTO post-loss. Prevention: add `tcb.rtt_seq = 0; tcb.rtt_start = 0` in three places: `retransmitFromSeq()` in tx/data.zig, RTO timer expiry in timers.zig, and fast retransmit entry in rx/established.zig.

4. **Persist timer missing -- zero-window deadlock** -- when `snd_wnd = 0`, the RTO exponential backoff applies to zero-window probes. After a few retries, probe interval reaches minutes. RFC 1122 requires persist probes capped at 60s, independent of the retransmission timer. Prevention: separate the persist timer state from `retrans_timer`; do not increment `retrans_count` for persist probes; cap persist interval at `min(rto_ms, 60000)`.

5. **`cwnd` saturates at maxInt(u32) without a meaningful cap** -- the AIMD path uses `std.math.add(...) catch maxInt(u32)`. With no cap relative to buffer size, `cwnd` can grow to 4GB in long-lived idle connections. Prevention: add `cwnd = @min(cwnd, send_buf_size * 4)` at the end of the AIMD update path. Linux caps at 1GB; any similar bound is sufficient.

---

## Implications for Roadmap

Based on combined research, this milestone maps naturally to four phases with a strict dependency order. Each phase can be tested independently.

### Phase 1: RTT Estimation Correctness + Congestion Module Extraction

**Rationale:** Karn's Algorithm is missing in all retransmit paths, making RTT measurements unreliable post-loss. This corrupts every subsequent congestion decision. Fix this first so the foundation is correct before touching anything else. Simultaneously extract congestion logic into `congestion/reno.zig` -- pure refactoring with zero behavior change, but it gates all future algorithm work cleanly.

**Delivers:** Correct RTT estimation under packet loss; `congestion/` module with `onAck()`, `onTimeout()`, `onDupAck()` entry points; cwnd upper bound relative to buffer size; IW10 one-line fix applied.

**Addresses:** Karn's Algorithm (RFC 6298 compliance), IW10 (RFC 6928, one-line change), cwnd unbounded growth cap, congestion avoidance arithmetic fix (slow-start branch)

**Avoids:** PITFALLS Pitfall 6 (Karn's violation), Pitfall 4 (cwnd unbounded growth), Pitfall 5 (partial-ACK coupling between Reno state machine and future algorithms)

**Research flag:** Standard RFC 6298 and 5681 patterns. No additional research needed.

---

### Phase 2: Dynamic Window Management + Persist Timer

**Rationale:** Window management and persist timer are tightly coupled -- zero-window detection, persist probing, and window update advertisements all interact. This phase wires `currentRecvWindow()` into ACK building and adds `last_adv_wnd` tracking. Must come after Phase 1 (congestion module exists for clean integration) but before Phase 3 (SO_RCVBUF with no window wiring is meaningless).

**Delivers:** Dynamic `rcv_wnd` advertised in every ACK; window update ACK sent when buffer drains by >= MSS; persist timer separate from retrans timer with 60s cap; receiver SWS avoidance (RFC 1122 S4.2.3.3); sender SWS avoidance (RFC 1122 S4.2.3.4)

**Addresses:** Dynamic rcv_wnd wiring (P1 -- active breakage), persist timer (prevents zero-window deadlock), SWS avoidance (RFC 1122 correctness)

**Avoids:** PITFALLS Pitfall 2 (window scale locked at handshake -- compute rcv_wscale from socket buffer at connect/listen time), Pitfall 10 (zero-window deadlock from RTO backoff)

**Research flag:** The `calculateWindowScale()` call chain in `options.zig:205` during SYN processing needs auditing to confirm how `rcv_buf_size` threads through `rx/syn.zig` to this call. If the call chain spans more than 3 files, recommend `/gsd:research-phase` before implementation.

---

### Phase 3: Socket Options (SO_RCVBUF, SO_SNDBUF, TCP_CORK) + Raw Socket Blocking

**Rationale:** Buffer size options must come after Phase 2 because SO_RCVBUF with no window wiring is a no-op. TCP_CORK belongs in the same phase as other TCP-level options. Raw socket blocking recv (~20 lines) fits here because it uses the same blocked-thread wake pattern and has no other dependencies.

**Delivers:** SO_RCVBUF/SO_SNDBUF accepted, stored, and applied as cap in `currentRecvWindow()`; rcv_buf_size applied at connect/listen time; TCP_CORK accumulation with flush-on-clear; raw socket blocking recv via scheduler wake; `send_tail` rogue-ACK assertion added

**Addresses:** SO_RCVBUF/SO_SNDBUF (P2 -- programs get EINVAL today), TCP_CORK (P2 -- scatter-gather protocol support), raw socket recv blocking (P2 -- currently returns WouldBlock unconditionally)

**Avoids:** PITFALLS Pitfall 1 (Tcb.reset() buffer leak -- Option A avoids dynamic allocation entirely), Pitfall 3 (send_tail corruption on resize -- not triggered by Option A), Pitfall 7 (allocation under IrqLock -- Option A allocates nothing in hot path), Pitfall 8 (rogue ACK without upper-bound check -- add assertion in rx/established.zig:70-72)

**Research flag:** Standard Linux ABI patterns. No additional research needed. Note: SO_REUSEPORT is intentionally deferred to v2+ because the bind-table data structure change is unresolved.

---

### Phase 4: MSG Flags (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL)

**Rationale:** MSG flags are independent of the buffer and window work but benefit from having stable blocking infrastructure (Phases 1-3). MSG_WAITALL requires MSG_DONTWAIT semantics internally -- the accumulation loop uses non-blocking inner calls to avoid holding tcp_state.lock while sleeping. Raw socket blocking was handled in Phase 3; this phase focuses on the flag infrastructure across TCP and UDP.

**Delivers:** MSG_PEEK for TCP and UDP (no-advance read); MSG_DONTWAIT per-call non-blocking override; MSG_WAITALL accumulation loop with SO_RCVTIMEO deadline and EINTR handling; MSG_NOSIGNAL stub; `flags: u32` parameter threaded through `tcpSend`/`tcpRecv` -> `tcp/api.send`/`recv` call chain

**Addresses:** MSG_PEEK (P1), MSG_DONTWAIT (P1), MSG_WAITALL (P1) -- all cause active breakage today

**Avoids:** Lock-release-before-block in MSG_WAITALL loop (same pattern as existing `accept()` in tcp_api.zig -- do not hold tcp_state.lock while sleeping)

**Research flag:** Well-documented POSIX patterns. No additional research needed. Implementation order within this phase: MSG_DONTWAIT first (simplest, unblocks internal use), then MSG_PEEK, then MSG_WAITALL (depends on DONTWAIT semantics).

---

### Phase Ordering Rationale

- **RTT before congestion extension:** Incorrect RTT measurements corrupt all congestion decisions. Fixing Karn's Algorithm before touching cwnd/ssthresh ensures the foundation is reliable.
- **Window before buffer options:** SO_RCVBUF with no window wiring is a lie to userspace -- the socket accepts the option but the peer never sees a larger window. The ordering makes each phase deliver real observable behavior change.
- **Buffer options before MSG flags:** Not a strict dependency, but SO_RCVBUF + MSG_WAITALL interacting correctly requires the window infrastructure to be in place. Testing MSG_WAITALL against a static 8KB window makes the test misleading.
- **Congestion module extraction in Phase 1 (not later):** The module boundary must exist before any new algorithm is added. Retrofitting the boundary after Phases 2-4 would require re-auditing all the new code for correct lock patterns.

### Research Flags

Phases needing deeper research during planning:
- **Phase 2 (Window Management):** The `calculateWindowScale()` call chain in `options.zig:205` needs auditing to confirm where `rcv_buf_size` threads through `rx/syn.zig`. The interaction is non-obvious from the research files. Recommend `/gsd:research-phase` if the call chain spans more than 3 files.

Phases with standard patterns (skip research):
- **Phase 1 (RTT + Congestion Extraction):** RFC 6298 Karn's Algorithm is a 3-line addition. Congestion module extraction is refactoring with no behavior change.
- **Phase 3 (Socket Options):** Linux ABI constants are verified. Option A buffer sizing is conservative and avoids dynamic allocation entirely.
- **Phase 4 (MSG Flags):** POSIX recv flag semantics are well-documented. Implementation pattern (thread flags through call stack) is straightforward with clear prior art in the existing blocking recv paths.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All algorithm choices are RFC-grounded (5681, 6582, 6298, 1122, 6928). No third-party libraries. ABI constants verified against Linux 6.x stable UABI. |
| Features | HIGH | Feature gaps confirmed by direct code audit: `_ = flags` at net.zig:547, `BUFFER_SIZE = 8192` hardcoded in 18 locations, `rtt_seq` not cleared in retransmit paths. All gaps are observable facts, not inferences. |
| Architecture | HIGH | Based on direct source analysis of ~4200 LOC TCP implementation. Component boundaries, lock patterns, and call chains verified against actual source files. |
| Pitfalls | HIGH | Pitfalls grounded in actual code patterns: Tcb.reset() value-copy pattern, comptime BUFFER_SIZE embedded in struct array types, rtt_seq not cleared in timers.zig. Not hypothetical risks. |

**Overall confidence:** HIGH

### Gaps to Address

- **`calculateWindowScale()` call chain:** The function is called in `options.zig:205` during SYN processing. It is unclear without further audit exactly how `rcv_buf_size` threads from the socket struct through `rx/syn.zig` to this call. This is the murkiest integration point in Phase 2. Plan for an audit pass before estimating Phase 2 implementation work.

- **SO_REUSEPORT bind table data structure:** The current socket state table supports one listener per port. FIFO SO_REUSEPORT requires a structural change to the bind table that is not fully specified by the research. Needs a design decision before implementation. Deferred to v2+ for this reason.

- **aarch64 window scale shift:** The `@intCast` for `snd_wscale` in `established.zig:123` is noted as a potential truncation risk on aarch64. The existing `@min(tcb.snd_wscale, 14)` clamp should prevent overflow, but this needs explicit verification when window scale negotiation is exercised in the test suite.

- **`processTimers()` wake_list stack growth:** Currently `[MAX_TCBS]?*anyopaque = undefined` on the stack (2KB at 256 TCBs). Not a blocking concern for this milestone. Must be addressed before any future increase to `MAX_TCBS` (see PITFALLS.md Pitfall 9).

---

## Sources

### Primary (HIGH confidence -- RFC specifications)
- RFC 5681 (Allman, Paxson, Blanton 2009) -- TCP Congestion Control: slow start, AIMD, fast retransmit/recovery algorithms
- RFC 6582 (Henderson et al. 2012) -- NewReno: partial ACK handling in fast recovery
- RFC 6298 (Paxson et al. 2011) -- Computing TCP's Retransmission Timer: Karn's Algorithm
- RFC 1122 (Braden 1989) -- Host Requirements: persist timer (S4.2.2.17), SWS avoidance (S4.2.3.3, S4.2.3.4)
- RFC 813 (Clark 1982) -- Window and Acknowledgement Strategy: original SWS avoidance paper
- RFC 6928 (Chu et al. 2013) -- Increasing TCP's Initial Window: IW10 recommendation
- RFC 7323 (Borman et al. 2014) -- TCP Extensions for High Performance: window scale, timestamps
- RFC 6056 (Larsen, Gont 2011) -- Port Randomization: referenced for SO_REUSEPORT semantics
- RFC 6093 (Gont, Yourtchenko 2011) -- TCP Urgent Mechanism: recommendation against MSG_OOB

### Primary (HIGH confidence -- Linux stable UABI)
- `include/uapi/asm-generic/socket.h` -- SO_* constant values (verified Linux 6.x, stable since 2.6.20)
- `include/uapi/linux/tcp.h` -- TCP_* option constants (verified Linux 6.x)
- `include/uapi/linux/socket.h` -- MSG_* flag constants (verified Linux 6.x)
- `net/core/sock.c:sk_setsockopt()` -- SO_SNDBUF/SO_RCVBUF internal doubling behavior

### Secondary (HIGH confidence -- direct code audit)
- `src/net/transport/tcp/` (~4200 LOC): types.zig, rx/established.zig, tx/data.zig, timers.zig, api.zig
- `src/net/transport/socket/tcp_api.zig`, `options.zig`, `types.zig`, `state.zig`
- `src/net/constants.zig` -- BUFFER_SIZE=8192, 18 reference sites confirmed
- `src/kernel/sys/syscall/net/net.zig:547` -- `_ = flags` discard confirmed
- `src/net/transport/socket/raw_api.zig:161-167` -- unconditional WouldBlock confirmed

### Secondary (MEDIUM confidence)
- Linux tcp(7) manual page -- TCP_CORK/TCP_NODELAY interaction
- Linux socket(7) manual page -- SO_RCVBUF/SO_SNDBUF behavior description
- Linux recv(2) manual page -- MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL semantics
- https://baus.net/on-tcp_cork/ -- TCP_CORK behavior analysis
- https://lwn.net/Articles/542629/ -- SO_REUSEPORT design and use cases

---

*Research completed: 2026-02-19*
*Ready for roadmap: yes*
