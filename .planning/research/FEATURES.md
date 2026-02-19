# Feature Research

**Domain:** TCP/UDP Network Stack Hardening -- Microkernel (zk)
**Researched:** 2026-02-19
**Confidence:** HIGH (code audit + RFC verification)

## Context: What Already Exists

The existing zk network stack has:
- TCP: full RFC 793 state machine, SYN/FIN handshake, retransmission with exponential backoff,
  delayed ACK (200ms), MSS negotiation, window scaling option (negotiated but rcv_wnd fixed at 8KB),
  SACK, timestamps, keepalive, Nagle, fast retransmit (3 dup-ACK), fast recovery (NewReno partial)
- Congestion fields already in TCB: `cwnd`, `ssthresh`, `srtt`, `rttvar`, RTT estimation
  (Jacobson/Karels), slow-start vs congestion-avoidance branching, fast recovery state machine
- UDP: IPv4/IPv6, checksum validation, multicast, security-sensitive port detection
- Socket API: socket, bind, listen, accept/accept4, connect, sendto, recvfrom, sendmsg/recvmsg,
  setsockopt, getsockopt, shutdown, socketpair, poll
- Socket options implemented: SO_REUSEADDR, SO_BROADCAST, SO_RCVTIMEO, SO_SNDTIMEO,
  TCP_NODELAY, IP_TOS, IP_TTL, multicast group ops, IP_RECVTOS
- `flags` parameter in sys_recvfrom is accepted but IGNORED (`_ = flags;` at line 547 of net.zig)
- Buffer sizes: fixed 8KB send and receive buffers per TCB (BUFFER_SIZE = 8192)
- ACCEPT_QUEUE_SIZE = 8, SOCKET_RX_QUEUE_SIZE = 8

The critical gap: the congestion fields exist and are partially wired (cwnd used to gate
transmitPendingData, ssthresh used in ACK processing) but the receive window (rcv_wnd) is
hardcoded as a fixed 8KB constant. It never grows. The `flags` parameter to recv is silently
discarded. SO_RCVBUF/SO_SNDBUF do not exist.

---

## Feature Landscape

### Table Stakes (Users Expect These)

These are features that userspace programs running on a POSIX-compatible kernel assume work
correctly. Programs that use them will silently misbehave or hard-fail without them.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| MSG_PEEK | Protocol framing code (HTTP parsers, TLS, custom protocols) uses peek to read a header without consuming it, then issues a full read. Without it, applications using libc or any non-trivial protocol library break. | LOW | Implementation: pass a copy of recv_tail to the copy loop; do not advance recv_tail after read. The TCB circular buffer already has the primitives (recv_head, recv_tail). No buffer allocation needed. Dependency: none. |
| MSG_DONTWAIT | Per-call non-blocking flag. Standard pattern for event loops: programs set O_NONBLOCK on the fd, or pass MSG_DONTWAIT per-call. Without it, any program using non-blocking I/O on a per-operation basis fails. Many userspace event loops use this instead of O_NONBLOCK. | LOW | Implementation: check this flag before the blocking path; if set, return EAGAIN immediately instead of sleeping. The blocking check is already in tcp_api.zig and udp_api.zig. Requires threading the flags value from sys_recvfrom into socket.recvfromIp. |
| MSG_WAITALL | Guarantees the full requested length is returned (blocks until buffer is full, or error/EOF). Used by protocols that know exact message lengths (binary protocols, TLS record layers). Without it, short reads silently truncate. | MEDIUM | Implementation: loop the recv call accumulating bytes until len satisfied or EAGAIN/EOF. Requires a retry loop in the kernel recv path. Interacts with timeout (SO_RCVTIMEO must still work). |
| Dynamic receive window (rcv_wnd reflects actual buffer state) | The existing rcv_wnd is hardcoded to 8192 at initialization and never changes. currentRecvWindow() already computes the correct value from buffer space but it is unclear if this value is actually being sent in ACKs. A fixed window prevents the peer from sending more than 8KB in flight, which caps throughput. Any peer doing window-based flow control (all standard TCP stacks) is throttled. | LOW | Implementation: ensure ACK segments use currentRecvWindow() return value rather than the tcb.rcv_wnd constant. The function already exists and does the right math. This is a wiring fix, not a new feature. |
| SO_RCVBUF / SO_SNDBUF | Programs that tune socket buffer sizes (databases, file transfer tools, high-throughput servers) call setsockopt(SO_RCVBUF) before connect/listen. The Linux default is to allow setting these. Without them, setsockopt returns EINVAL for these options, which some programs treat as fatal. | MEDIUM | Implementation: add SO_RCVBUF=8 and SO_SNDBUF=7 constants to socket types.zig, handle in options.zig setsockopt. The hard part is whether buffer size actually changes the backing array (requires dynamic allocation or a maximum cap). Easiest approach: accept the value and store it, but enforce a maximum (e.g., 256KB). Changing actual buffer size at runtime requires TCB buffer to be heap-allocated rather than fixed array. |
| TCP congestion window actually gates send (cwnd is wired) | cwnd exists in the TCB and transmitPendingData does compute eff_wnd = min(snd_wnd, cwnd). The slow-start / congestion-avoidance branching in established.zig processEstablished is present. However, initial cwnd = 2 * MSS (2920 bytes) is very conservative and the code does not implement IW10 (RFC 6928). The congestion control is structurally correct per the code audit but needs verification that cwnd updates happen on all ACK paths (particularly in timers.zig for RTO expiry). | LOW | Audit-only task: verify timers.zig halves cwnd and resets ssthresh on RTO expiry. The ACK path in established.zig appears correct. |

### Differentiators (Competitive Advantage)

Features that set the zk network stack apart from a bare-minimum TCP implementation. Not
strictly required for POSIX compliance but expected by higher-throughput workloads.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| TCP_CORK | Allows applications to batch writes into a single full-MSS segment. Used by HTTP/1.1 sendfile emulation, databases writing headers then body, any scatter-gather protocol pattern. The effect is: while CORK is set, hold data in the kernel send buffer and never send a segment smaller than MSS. When uncorked, flush immediately. | MEDIUM | Implementation: add `cork: bool` field to TCB (similar to existing `nodelay: bool`). Modify transmitPendingData to refuse to send if cork is true AND data < MSS AND no window pressure. Add TCP_CORK = 3 to socket options. Add IPPROTO_TCP setsockopt handler. Interaction: TCP_CORK takes priority over Nagle. TCP_CORK + TCP_NODELAY together should mean: cork wins (hold until uncorked), then when uncorked flush immediately without Nagle delay. |
| SO_REUSEPORT | Allows multiple listening sockets on the same port. Enables multi-worker server design where N threads each call accept() on the same port. The kernel distributes incoming connections by 4-tuple hash. Without it, the standard worker-pool architecture requires a single accept thread passing sockets via IPC. | HIGH | Implementation: requires changes to the listen TCB lookup in tcp.zig. When SO_REUSEPORT is set, a new listen() on an already-listening port must succeed (not EADDRINUSE) and must be added to a reuseport group. Incoming SYN packets must hash to one of the group members. Requires a reuseport group data structure in tcp/state.zig. This is non-trivial because the current architecture has one listen TCB per port. |
| Configurable buffer sizes (actually resize at runtime) | If SO_RCVBUF/SO_SNDBUF are implemented as store-only with a fixed cap, programs that need large buffers (bulk file transfer, high-bandwidth connections) cannot benefit. True dynamic sizing means the TCB send_buf and recv_buf should be heap-allocated slices rather than fixed arrays. | HIGH | Implementation: convert `send_buf: [c.BUFFER_SIZE]u8` and `recv_buf: [c.BUFFER_SIZE]u8` in Tcb struct from fixed arrays to `[]u8` heap-allocated slices. This touches every place these buffers are accessed. Risk: changes the TCB size significantly (from ~20KB to a pointer + length), affects alignment, and requires careful allocator management. The entire TCB pool would need rethinking since TCBs are currently value types. Recommend defer to v2 unless a concrete use case demands it. |
| TCP initial window IW10 (RFC 6928) | Modern Linux and BSD stacks default to 10 MSS initial window instead of 2. This matters for latency of short connections (most HTTP requests). The current IW2 means 5x more RTT to fill the pipe on a 14KB response. | LOW | Implementation: change `.cwnd = c.DEFAULT_MSS * 2` to `.cwnd = c.DEFAULT_MSS * 10` in Tcb.init(). One-line change. RFC 6928 says IW10 is the recommended default. No negative interactions with existing code. |

### Anti-Features (Commonly Requested, Often Problematic)

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| CUBIC or BBR congestion control | Modern Linux uses CUBIC by default; BBR is used by Google. Users assume a "real" stack uses these. | For a microkernel with 256 max TCBs and a flat LAN or loopback use case, the difference between NewReno and CUBIC is unmeasurable. CUBIC requires cubic polynomial calculation per ACK. BBR requires packet pacing, which needs per-packet timestamps and a shaper. Both add hundreds of lines of code and new failure modes for negligible benefit in the target deployment context (single-machine OS, QEMU networking). | Complete the RFC 5681 NewReno implementation correctly. That is the correct choice for this context. |
| MSG_OOB (out-of-band / urgent data) | Some old protocols (rsh, rlogin, some databases) use TCP urgent data. It is a POSIX-required flag. | TCP urgent data is widely considered a design mistake. RFC 6093 (2011) strongly recommends against new implementations. No modern application uses it. Implementing it correctly requires maintaining a separate urgent pointer in the TCB and special-casing the receive path. | Return EOPNOTSUPP. Document that OOB is not implemented. No known application running on zk needs it. |
| IP_PKTINFO / IP_RECVORIGDSTADDR | Allows servers to know which local address a packet arrived on (useful for transparent proxying, DNS servers with multiple IPs). | zk currently has a single network interface. Multi-homing is not supported. These options require attaching ancillary data (cmsg) to every recvmsg call, which complicates the receive path significantly. | Stub the setsockopt call to succeed silently. Applications that use these typically check the cmsg on recvmsg; if no cmsg is returned they fall back to other methods. |
| SO_LINGER with l_onoff=1 | Causes close() to block until all data is flushed or timeout expires. Some servers use this to guarantee data delivery before close. | In a single-address-space microkernel, a blocking close() is a scheduler-level problem. The thread calling close() must sleep while the TCP retransmit loop drains the send buffer. This interacts badly with the current TCB lifecycle (TCB is freed by the close path). Requires a new TCB state where the socket is closed but the TCB lingers until send_buf is empty. | Implement SO_LINGER as store-only (accept the setsockopt) but behave as l_onoff=0 (non-lingering close). Applications that rely on linger for correctness are rare and typically have other mechanisms. |

---

## Feature Dependencies

```
MSG_PEEK
    requires: recv_tail not advanced on peek (trivial, buffer already supports this)
    no upstream dependencies

MSG_DONTWAIT
    requires: flags parameter threaded from sys_recvfrom -> recvfromIp -> socket recv
    no upstream dependencies

MSG_WAITALL
    requires: MSG_DONTWAIT (needs EAGAIN detection to know when to retry)
    requires: SO_RCVTIMEO interaction (must respect timeout even in waitall loop)

Dynamic rcv_wnd
    requires: currentRecvWindow() to be called at ACK-send time (function exists)
    enhances: MSG_WAITALL (peer can send more, less stalling)
    enhances: SO_RCVBUF (if buffer is larger, window can advertise larger)

SO_RCVBUF / SO_SNDBUF (store-and-cap)
    requires: Dynamic rcv_wnd (otherwise storing the value has no effect on peer)
    no upstream dependencies for the store-only version

TCP_CORK
    requires: nodelay field pattern in TCB (already exists as model)
    conflicts with: TCP_NODELAY (precedence rule: cork wins while active)
    enhances: application-level scatter-gather (HTTP headers + body as single segment)

SO_REUSEPORT
    requires: listen TCB group data structure (new)
    requires: 4-tuple hash distribution at SYN receive time
    conflicts with: SO_REUSEADDR (different semantics; both can be set but mean different things)

IW10 (RFC 6928)
    requires: nothing (one constant change)
    enhances: short connection latency
```

### Dependency Notes

- **MSG_WAITALL requires MSG_DONTWAIT pattern:** To implement the waitall retry loop, the inner
  recv call must be able to return EAGAIN without sleeping, so the outer loop can accumulate bytes
  and retry. This means MSG_DONTWAIT semantics must exist internally even if not exposed.

- **Dynamic rcv_wnd and SO_RCVBUF are linked:** If SO_RCVBUF stores a size but rcv_wnd always
  advertises 8KB, SO_RCVBUF has no effect. The two features must ship together or the store-only
  SO_RCVBUF is misleading.

- **TCP_CORK conflicts with TCP_NODELAY:** When both are set, cork takes precedence (hold data).
  When cork is cleared, flush immediately (nodelay behavior). This is consistent with Linux.

---

## MVP Definition

The milestone adds these features to an already-working TCP stack. The goal is POSIX compliance
for userspace programs that use standard socket patterns.

### Launch With (milestone core)

These are the features that fix active breakage -- programs that call these APIs and get wrong
behavior today:

- [ ] MSG_PEEK -- required by any protocol parser that peeks at headers before consuming
- [ ] MSG_DONTWAIT -- required by non-blocking event loop patterns (per-call, not O_NONBLOCK)
- [ ] MSG_WAITALL -- required by binary protocol readers that expect exact-length reads
- [ ] Dynamic rcv_wnd wiring -- required for any connection to reach throughput above 8KB in flight
- [ ] IW10 (RFC 6928) -- one-line fix, dramatically improves short connection latency

### Add After Core Flags Work

These improve throughput and server architecture but do not cause hard failures without them:

- [ ] SO_RCVBUF / SO_SNDBUF (store-and-cap, not dynamic resize) -- needed when programs check
  for EINVAL on these options
- [ ] TCP_CORK -- needed for high-throughput HTTP-style server workloads

### Future Consideration (v2+)

These require significant architectural changes and are not needed for the current milestone:

- [ ] SO_REUSEPORT -- requires reuseport group data structure and SYN distribution changes; defer
  until multi-worker server workloads are a stated goal
- [ ] True dynamic buffer resize (heap-allocated TCB buffers) -- requires TCB struct refactor;
  defer until a concrete workload shows 8KB or 256KB cap is insufficient

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| MSG_PEEK | HIGH | LOW | P1 |
| MSG_DONTWAIT | HIGH | LOW | P1 |
| MSG_WAITALL | HIGH | MEDIUM | P1 |
| Dynamic rcv_wnd (wiring fix) | HIGH | LOW | P1 |
| IW10 initial window | MEDIUM | LOW | P1 |
| SO_RCVBUF / SO_SNDBUF (store-and-cap) | MEDIUM | LOW | P2 |
| TCP_CORK | MEDIUM | MEDIUM | P2 |
| SO_REUSEPORT | MEDIUM | HIGH | P3 |
| True dynamic buffer resize | LOW | HIGH | P3 |

**Priority key:**
- P1: Must have for milestone -- fixes active breakage
- P2: Should have -- improves compliance and throughput
- P3: Defer -- significant cost for narrow use case

---

## Implementation Notes Per Feature

### MSG_PEEK (P1, LOW complexity)

Current state: `flags` is accepted by sys_recvfrom but `_ = flags;` discards it entirely.

What to do:
1. Define `MSG_PEEK: u32 = 0x0002` in socket/types.zig (Linux constant).
2. Pass flags from sys_recvfrom into the socket recvfromIp call signature.
3. In the TCP recv path (tcp_api.zig), if MSG_PEEK is set, copy bytes from recv_buf starting at
   recv_tail but do NOT advance recv_tail after the copy. This is a read-only operation on the
   circular buffer.
4. For UDP, the rx_queue entry must not be dequeued; copy from rx_queue[rx_tail] without
   advancing rx_tail.

Edge case: MSG_PEEK with a buffer smaller than available data should return as much as fits
(same as a normal read), not peek at more than requested.

### MSG_DONTWAIT (P1, LOW complexity)

Current state: The blocking check in tcp_api.zig checks `sock.blocking`. The per-call flag would
override this for one call.

What to do:
1. Define `MSG_DONTWAIT: u32 = 0x0040` in socket/types.zig (Linux constant).
2. Pass effective_blocking = sock.blocking AND NOT(flags & MSG_DONTWAIT) into the recv path.
3. If effective_blocking is false and no data is available, return EAGAIN immediately.
4. Same for UDP: if MSG_DONTWAIT and rx_count == 0, return EAGAIN.

Note: MSG_DONTWAIT does not set O_NONBLOCK on the file descriptor permanently. It only affects
the single call. Subsequent calls without MSG_DONTWAIT block normally.

### MSG_WAITALL (P1, MEDIUM complexity)

Current state: The recv path returns whatever is available (partial reads are possible).

What to do:
1. Define `MSG_WAITALL: u32 = 0x0100` in socket/types.zig (Linux constant).
2. In the TCP recv path: if MSG_WAITALL is set and received < requested, accumulate into kbuf
   and loop. On each iteration, check SO_RCVTIMEO deadline. Break on EOF (FIN received) or
   connection error.
3. POSIX allows MSG_WAITALL to return less than requested on signal or disconnect. Implement
   the loop in the syscall layer (sys_recvfrom) rather than deep in the socket layer, so signal
   checking (pending_signals) can be done between iterations.
4. For UDP, MSG_WAITALL applies to a single datagram: block until one datagram arrives, return
   the whole datagram (truncated if buf is too small). Do not aggregate multiple datagrams.

### Dynamic rcv_wnd Wiring (P1, LOW complexity)

Current state: `tcb.rcv_wnd` is initialized to `c.RECV_WINDOW_SIZE` (8192) and is written into
ACK segment headers. `currentRecvWindow()` computes the correct scaled value from free buffer
space but may not be the value actually sent.

What to do:
1. Audit tx/control.zig and tx/segment.zig to confirm which value goes into the TCP window field
   of outgoing segments.
2. Replace any use of `tcb.rcv_wnd` in ACK building with `tcb.currentRecvWindow()`.
3. The `rcv_wnd` field in the TCB can remain as the cached last-advertised value (useful for
   detecting window update necessity), but the value sent in the wire header should always be
   computed from actual buffer state.

Risk: none. currentRecvWindow() already handles window scaling correctly.

### IW10 (P1, LOW complexity)

Change in types.zig Tcb.init():
```
// Before
.cwnd = c.DEFAULT_MSS * 2,

// After (RFC 6928)
.cwnd = c.DEFAULT_MSS * 10,
```

Also update the comment above it. No other changes needed.

### SO_RCVBUF / SO_SNDBUF (P2, LOW complexity for store-and-cap)

Current state: setsockopt returns EINVAL for these option numbers.

What to do:
1. Add `SO_RCVBUF: i32 = 8` and `SO_SNDBUF: i32 = 7` to socket/types.zig.
2. Add `rcv_buf_size: u32` and `snd_buf_size: u32` fields to Socket struct with defaults of 8192.
3. Handle in options.zig setsockopt: read the i32 value, clamp to [1024, 262144], store in socket.
4. On TCP connect/accept, copy rcv_buf_size to tcb.rcv_wnd initialization.
5. getsockopt should return the stored value (Linux returns 2x the requested value to account for
   overhead; implement the same doubling for compatibility).

Do NOT change the actual buffer array size. The backing array stays at 8KB. This satisfies programs
that check for EINVAL but does not provide larger actual buffers. Document this limitation.

### TCP_CORK (P2, MEDIUM complexity)

Current state: No cork support. Nagle is the only send-coalescing mechanism.

What to do:
1. Add `TCP_CORK: i32 = 3` to socket/types.zig.
2. Add `cork: bool` field to TCB struct (default false).
3. In options.zig, handle IPPROTO_TCP / TCP_CORK: copy to tcb.cork.
4. In transmitPendingData (tx/data.zig), add check:
   if tcb.cork and send_len < effective_mss and flight_size > 0, return true (hold).
5. When cork is cleared (setsockopt TCP_CORK 0), call transmitPendingData immediately to flush.
6. Precedence: cork takes priority over Nagle. When cork is cleared, if nodelay is true,
   transmit immediately without any Nagle delay.

---

## Competitor Feature Analysis (Reference Stacks)

| Feature | Linux 6.x | lwIP 2.2 | Our Approach |
|---------|-----------|----------|--------------|
| MSG_PEEK | Full support | Partial (TCP only) | Implement for TCP + UDP |
| MSG_DONTWAIT | Full support | Via SO_NONBLOCK only | Implement per-call flag |
| MSG_WAITALL | Full support | Not supported | Implement for TCP |
| Dynamic rcv_wnd | Auto-tuning | Fixed | Wire existing currentRecvWindow() |
| SO_RCVBUF | Dynamic, doubles value | Fixed buffers | Store-and-cap |
| TCP_CORK | Full support | Not supported | Implement basic version |
| SO_REUSEPORT | Full support | Not supported | Defer |
| IW10 | Default since 3.0 | Configurable | Change constant |

---

## Sources

- RFC 5681: TCP Congestion Control (cwnd/ssthresh update rules) -- https://datatracker.ietf.org/doc/html/rfc5681
- RFC 6928: Increasing TCP's Initial Window -- https://datatracker.ietf.org/doc/html/rfc6928
- RFC 7323: TCP Extensions for High Performance (window scaling, timestamps)
- Linux recv(2) manual page (MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL semantics) -- https://man7.org/linux/man-pages/man2/recv.2.html
- Linux socket(7) manual page (SO_RCVBUF, SO_SNDBUF behavior) -- https://man7.org/linux/man-pages/man7/socket.7.html
- Linux tcp(7) manual page (TCP_CORK, TCP_NODELAY interaction) -- https://man7.org/linux/man-pages/man7/tcp.7.html
- TCP_CORK behavior analysis -- https://baus.net/on-tcp_cork/
- SO_REUSEPORT LWN article -- https://lwn.net/Articles/542629/
- Code audit: src/net/transport/tcp/types.zig (Tcb struct, cwnd/ssthresh fields confirmed present)
- Code audit: src/net/transport/tcp/tx/data.zig (transmitPendingData, Nagle check confirmed)
- Code audit: src/net/transport/tcp/rx/established.zig (ACK processing, cwnd update confirmed)
- Code audit: src/kernel/sys/syscall/net/net.zig (sys_recvfrom flags discarded at line 547)
- Code audit: src/net/transport/socket/options.zig (existing setsockopt handlers)
- Code audit: src/net/constants.zig (BUFFER_SIZE=8192, RECV_WINDOW_SIZE=8192)

---
*Feature research for: TCP/UDP Network Stack Hardening -- zk Microkernel*
*Researched: 2026-02-19*
