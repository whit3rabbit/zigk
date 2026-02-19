# Technology Stack: TCP/UDP Network Stack Hardening

**Project:** zk kernel -- v1.4 networking milestone
**Domain:** Kernel TCP/IP stack: congestion control, window management, socket API completeness
**Researched:** 2026-02-19
**Confidence:** HIGH (RFC-grounded) / MEDIUM (sizing heuristics)

---

## Executive Summary

The existing zk TCP stack has structural scaffolding for congestion control (`cwnd`, `ssthresh`, `fast_recovery`, `dup_ack_count` in `Tcb`) and RTT estimation (Jacobson/Karels SRTT/RTTVAR), but the implementation is incomplete in three concrete ways:

1. **Congestion control is partially wired**: `cwnd` is advanced on ACK in `rx/established.zig` and collapsed on timeout in `timers.zig`, but the slow-start exit condition (`cwnd >= ssthresh`) incorrectly uses congestion avoidance arithmetic even during slow start (the AIMD increment `mss*mss/cwnd` instead of `+= min(acked, mss)`).
2. **Window management is static**: `RECV_WINDOW_SIZE = 8192` and `BUFFER_SIZE = 8192` are compile-time constants. `currentRecvWindow()` derives from buffer space but does not enforce the "silly window syndrome" (SWS) avoidance rules (RFC 813 / RFC 1122 S4.2.3.3). The send side does not implement SWS avoidance either (RFC 1122 S4.2.3.4).
3. **Socket options and message flags are stubs**: `SO_RCVBUF`, `SO_SNDBUF`, `SO_REUSEPORT` are not in `types.zig`; `MSG_PEEK`, `MSG_DONTWAIT`, `MSG_WAITALL` are ignored (see the `_ = flags` TODO comment in `raw_api.zig:128` and `raw_api.zig:283`); `TCP_CORK` is absent.

This milestone adds the algorithms and data-structure changes needed to fix these gaps. It does not require new libraries -- all algorithms are purely in-kernel Zig. What it does require is precise understanding of RFC 5681 (TCP Congestion Control), RFC 1122 (Host Requirements), and the Linux socket option ABI.

---

## Core Algorithm Additions

### 1. RFC 5681 Congestion Control -- Slow Start and Congestion Avoidance

**Status in codebase:** Structurally present, behaviorally incorrect.

The `cwnd` update in `rx/established.zig:62-68` has the slow-start and congestion-avoidance branches, but the slow-start branch uses the wrong increment. RFC 5681 S3.1 specifies:

- **Slow start**: `cwnd += min(N, SMSS)` where N = bytes newly acknowledged. One SMSS per RTT is the floor, but multiple segments ACKed in one ACK means multiple SMSS increments.
- **Congestion avoidance**: `cwnd += max(SMSS * SMSS / cwnd, 1)` per ACK (Reno AIMD).

Current code uses the congestion avoidance formula for both branches. Fix is a one-line condition change, but it must be precise.

**RFC 5681 algorithms to implement (all are additive changes to existing Tcb fields):**

```
Slow Start (cwnd < ssthresh):
  cwnd = cwnd + min(acked_bytes, SMSS)      // RFC 5681 S3.1, para 1

Congestion Avoidance (cwnd >= ssthresh):
  cwnd = cwnd + max(SMSS*SMSS/cwnd, 1)     // RFC 5681 S3.1, para 2

Fast Retransmit trigger (3 duplicate ACKs):
  ssthresh = max(FlightSize / 2, 2*SMSS)   // RFC 5681 S3.2, step 1
  cwnd     = ssthresh + 3*SMSS             // RFC 5681 S3.2, step 2
  retransmit oldest unACKed segment        // RFC 5681 S3.2, step 3

Fast Recovery inflation (each additional dup ACK):
  cwnd += SMSS                             // RFC 5681 S3.2, step 4

Fast Recovery exit (new ACK >= recover):
  cwnd = ssthresh                          // RFC 5681 S3.2, step 6
  exit fast recovery                       // RFC 6582 (NewReno) fixes partial ACK

Retransmission Timeout (RTO expiry):
  ssthresh = max(FlightSize / 2, 2*SMSS)   // RFC 5681 S3.1, para after bullet 5
  cwnd     = SMSS                          // RFC 5681 S3.1 (one segment)
  retransmit oldest unACKed segment
```

**Why NewReno (RFC 6582) over base Reno:** The current `recover` field in `Tcb` signals intent to implement RFC 6582 partial-ACK handling. Base Reno exits fast recovery on ANY new ACK, which causes cwnd oscillation on multi-segment loss. NewReno stays in recovery until `snd_una >= recover`. This is a 3-line change on top of the existing `fast_recovery` / `recover` logic.

**Why NOT CUBIC (RFC 8312) or BBR:** CUBIC replaces the AIMD cwnd growth function with a cubic function that requires a `t_last_decrease` timestamp and a `W_max` variable. It offers better performance on high-BDP links (>= 100ms RTT, >= 100 Mbit/s). zk runs inside QEMU TCG against a virtual e1000e on a local machine -- the effective BDP is < 1ms * 100 Mbit/s = 12.5 KB, which is already below a single cwnd. CUBIC/BBR provide zero benefit in this environment and add substantial complexity. Implement Reno/NewReno now; CUBIC is a future phase gate-kept on multi-NIC or real-hardware support.

**Data structure changes required:** None. All needed fields already exist in `Tcb`:
- `cwnd`, `ssthresh`, `snd_una`, `snd_nxt`, `mss`
- `fast_recovery`, `recover`, `dup_ack_count`, `last_ack`
- `srtt`, `rttvar`, `rto_ms`, `rtt_seq`, `rtt_start`

**Integration point:** `src/net/transport/tcp/rx/established.zig` (ACK processing), `src/net/transport/tcp/timers.zig` (RTO expiry).

---

### 2. Dynamic Window Management

**Status in codebase:** Static 8KB window. No SWS avoidance. No configurable buffer size.

**What needs to change:**

#### 2a. Receiver SWS Avoidance (RFC 1122 S4.2.3.3 / RFC 813)

When the application reads data slowly, the receive buffer fills. Without SWS avoidance, the receiver advertises tiny window updates (e.g., 1 byte) causing the sender to transmit tiny segments ("silly window syndrome"). The fix: do not advertise a new window opening unless it is at least min(half of receive buffer, 1 MSS).

```
Only update advertised window if:
  new_window > old_window + min(rcv_buf_size/2, mss)
```

This requires tracking the last advertised window value in `Tcb`. Add field: `last_rcv_wnd: u16`.

#### 2b. Sender SWS Avoidance (RFC 1122 S4.2.3.4 / Nagle interaction)

The current Nagle implementation in `tx/data.zig:85-87` checks `send_len < effective_mss` to coalesce small writes when data is in-flight. This is correct Nagle behavior (RFC 896). The sender SWS rule is slightly different: do not send a segment unless:
- it is at least SMSS bytes, OR
- it will consume at least half the remote's receive buffer, OR
- we can send everything buffered (no more data pending)

The existing Nagle check partially covers this. The SWS-specific addition is the "half remote buffer" condition:

```
can_send = (send_len >= SMSS) OR
           (send_len >= snd_wnd/2) OR
           (no_data_pending_after_send AND nodelay)
```

No new `Tcb` fields needed; `snd_wnd` already exists.

#### 2c. Configurable Buffer Sizes via SO_SNDBUF / SO_RCVBUF

The current `BUFFER_SIZE = 8192` is a compile-time constant. Per-socket configurable buffers require embedding the buffer size in `Socket` and `Tcb`:

```zig
// Add to Socket:
sndbuf_size: usize,  // Current send buffer limit (default 8192, max 256KB)
rcvbuf_size: usize,  // Current recv buffer limit (default 8192, max 256KB)

// Add to Tcb:
rcv_buf_size: usize, // Effective receive buffer limit (set from socket on connect/accept)
snd_buf_size: usize, // Effective send buffer limit
```

The buffer arrays in `Tcb` (`send_buf`, `recv_buf`) are fixed compile-time arrays. To support dynamic sizes, two options:

**Option A (recommended):** Keep fixed arrays, use a `usize` limit field that socket-layer setsockopt updates. The limit applies to how much data the send path accepts before blocking (not the physical array size). Simpler: no dynamic allocation in fast path.

**Option B:** Allocate buffers dynamically (heap.allocator). Requires `errdefer` cleanup in `allocateTcb()`, adds heap pressure in fast path.

**Recommendation: Option A.** Max configurable limit = `BUFFER_SIZE` (8192 by default). Allow setsockopt to increase up to a hardcoded maximum (e.g., 262144). For values beyond `BUFFER_SIZE`, silently clamp to `BUFFER_SIZE` until Option B is implemented in a subsequent phase. This satisfies the ABI contract (setsockopt succeeds) without requiring allocator changes in this milestone.

Linux also doubles the requested value (see `net/core/sock.c:sk_setsockopt()`): `sk->sk_rcvbuf = max_t(int, val * 2, SOCK_MIN_RCVBUF)`. zk should do the same for ABI compatibility.

**Linux ABI values for buffer options:**

| Option | Level | Value | Type | Notes |
|--------|-------|-------|------|-------|
| `SO_SNDBUF` | `SOL_SOCKET` (1) | 7 | `int` | Linux doubles the value internally |
| `SO_RCVBUF` | `SOL_SOCKET` (1) | 8 | `int` | Linux doubles the value internally |
| `SO_SNDBUFFORCE` | `SOL_SOCKET` (1) | 32 | `int` | Bypass limit (CAP_NET_ADMIN only) |
| `SO_RCVBUFFORCE` | `SOL_SOCKET` (1) | 33 | `int` | Bypass limit (CAP_NET_ADMIN only) |

Source: `include/uapi/asm-generic/socket.h` in Linux kernel.

---

### 3. Message Flags: MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL

**Status in codebase:** Flags parameter exists in function signatures but is discarded (`_ = flags`).

**Linux ABI values:**

| Flag | Value (hex) | Value (dec) | Semantics |
|------|-------------|-------------|-----------|
| `MSG_OOB` | 0x1 | 1 | Out-of-band data (not implementing) |
| `MSG_PEEK` | 0x2 | 2 | Return data without consuming from buffer |
| `MSG_WAITALL` | 0x100 | 256 | Block until full request satisfied |
| `MSG_DONTWAIT` | 0x40 | 64 | Non-blocking, return EAGAIN if no data |
| `MSG_NOSIGNAL` | 0x4000 | 16384 | Do not send SIGPIPE on broken pipe |
| `MSG_TRUNC` | 0x20 | 32 | Return real length even if buffer shorter (UDP) |

Source: `include/uapi/linux/socket.h` in Linux kernel (HIGH confidence -- these values are part of the stable Linux UABI and have not changed since early 2.6.x).

**Implementation approach:**

#### MSG_PEEK
Peek reads from the receive buffer without advancing the tail pointer. In `Tcb`, `recv_tail` is the read position; a peek copies data starting at `recv_tail` but leaves `recv_tail` unchanged. This applies to TCP. For UDP, the `dequeuePacketIp` function must have a peek variant that does not remove the entry from `rx_queue`.

Requires adding a `peek` parameter to `tcp.recv()` and `socket.dequeuePacketIp()`. No new `Tcb` fields.

#### MSG_DONTWAIT
Overrides the socket's blocking mode for this call only. Implementation: at the top of `sys_recvfrom`, `sys_recv`, check `flags & MSG_DONTWAIT`; if set, treat as non-blocking for this call regardless of `sock.blocking`. No new fields needed. The flag must be passed down through `tcp.recv()` to `tcpRecv()`.

#### MSG_WAITALL
Block until the full requested length has been received. For TCP (stream socket): loop calling `tcp.recv()` accumulating data until `total_received == requested_len` or an error occurs. For UDP (datagram): MSG_WAITALL means "wait for at least one datagram"; a single datagram is always complete, so this flag degenerates to blocking recv for UDP.

Requires loop logic in the syscall layer (`sys_recv`/`sys_recvfrom`), not in the transport layer. The `EINTR` case must break the loop and return partial data if any was received (POSIX requirement).

---

### 4. SO_REUSEPORT

**Status in codebase:** `SO_REUSEADDR` exists; `SO_REUSEPORT` does not.

**Linux ABI value:** `SO_REUSEPORT = 15` at `SOL_SOCKET` level.

**Semantics (RFC 6056 / Linux `net/core/sock.c`):** Multiple sockets may bind to the same local address:port pair. Incoming connections/datagrams are distributed among the sockets. Linux uses a hash of the 4-tuple to select which socket receives each connection. For a single-process kernel like zk (no multi-process networking yet), the primary use case is:

- **Test compatibility**: Programs that set `SO_REUSEPORT` before `bind()` must not get `EADDRINUSE`.
- **Future multi-listener**: Enables multiple threads each calling `accept()` on different sockets bound to the same port.

**Implementation approach for this milestone:** Add `so_reuseport: bool` to `Socket`. In `state.zig` port validation (inside `bind()`), when the port is already in use, check if both sockets have `so_reuseport = true`. If yes, allow the bind. For the accept/receive dispatch, choose the listening socket that was bound first (simple FIFO). Full hash-based distribution is a future enhancement.

**Interaction with `SO_REUSEADDR`:** `SO_REUSEADDR` allows rebinding a port in TIME_WAIT. `SO_REUSEPORT` allows multiple simultaneous listeners. They are independent flags.

---

### 5. TCP_CORK

**Status in codebase:** Not present.

**Linux ABI value:** `TCP_CORK = 3` at `IPPROTO_TCP` level.

**Semantics (Linux `net/ipv4/tcp.c`):** When `TCP_CORK` is set, TCP will not transmit partial frames. Data accumulates in the send buffer until either: (a) a full MSS segment is ready, (b) `TCP_CORK` is cleared, or (c) the send buffer is closed. This is the kernel-level equivalent of `MSG_MORE`.

**Interaction with Nagle:** Nagle (RFC 896) already delays small sends when data is in-flight. `TCP_CORK` delays even when no data is in-flight -- it forces accumulation without the Nagle condition. On Linux, `TCP_CORK` and `TCP_NODELAY` are mutually exclusive: setting `TCP_NODELAY` clears `TCP_CORK`, and setting `TCP_CORK` does not override `TCP_NODELAY`.

**Implementation approach:** Add `tcp_cork: bool` to `Socket` and `cork: bool` to `Tcb`. In `tx/data.zig:transmitPendingData()`, add the cork check before the Nagle check:

```zig
// Cork: hold data until full MSS or cork is cleared
if (tcb.cork and send_len < effective_mss and buffered > send_len) {
    return true; // Defer transmission
}
```

Clearing cork (`setsockopt(fd, IPPROTO_TCP, TCP_CORK, &zero, 4)`) must call `transmitPendingData()` immediately to flush any held data.

---

### 6. Raw Socket Blocking Recv

**Status in codebase:** `raw_api.zig:161-167` returns `WouldBlock` unconditionally when no data is available in blocking mode ("TODO: implement blocking raw recv").

**Implementation:** Raw socket blocking recv needs the same blocked-thread pattern used by TCP and UDP accept/recv:
1. Set `sock.blocked_thread = current_thread`.
2. Call `block_fn()`.
3. On wake, retry dequeue.
4. Loop until data arrives or timeout.

This requires a wakeup path in the packet RX handler for raw sockets. When a raw ICMP/ICMPv6 packet is enqueued (`enqueuePacketIp`), `scheduler.wakeThread(sock.blocked_thread)` must be called. The `enqueuePacketIp` in `types.zig:393` already does this for UDP sockets -- raw sockets use the same `Socket` struct and the same queue, so the wake call is already present. The missing piece is the blocking loop in `recvfromRaw` / `recvfromRaw6`.

No new data structures required. The fix is ~20 lines in `raw_api.zig`.

---

## Socket Option Linux ABI Reference

Complete set of socket options for this milestone, with Linux constant values. These are from `include/uapi/asm-generic/socket.h` and `include/uapi/linux/tcp.h` (verified via Linux 6.x kernel source; HIGH confidence -- stable UABI since 2.6.x).

### SOL_SOCKET Options

| Constant | Value | Already in zk | Notes |
|----------|-------|---------------|-------|
| `SO_DEBUG` | 1 | No | Not needed |
| `SO_REUSEADDR` | 2 | Yes | Already implemented |
| `SO_TYPE` | 3 | No | getsockopt only: returns SOCK_STREAM/SOCK_DGRAM |
| `SO_ERROR` | 4 | No | getsockopt only: returns and clears pending error |
| `SO_BROADCAST` | 6 | Yes | Already implemented |
| `SO_SNDBUF` | 7 | **No** | Add this milestone |
| `SO_RCVBUF` | 8 | **No** | Add this milestone |
| `SO_KEEPALIVE` | 9 | No | Future: TCP keepalives |
| `SO_REUSEPORT` | 15 | **No** | Add this milestone |
| `SO_PEERCRED` | 17 | Yes (UNIX) | Already implemented for AF_UNIX |
| `SO_RCVTIMEO` | 20 | Yes | Already implemented |
| `SO_SNDTIMEO` | 21 | Yes | Already implemented |
| `SO_SNDBUFFORCE` | 32 | No | Requires CAP_NET_ADMIN; stub with EPERM |
| `SO_RCVBUFFORCE` | 33 | No | Requires CAP_NET_ADMIN; stub with EPERM |

### IPPROTO_TCP Options

| Constant | Value | Already in zk | Notes |
|----------|-------|---------------|-------|
| `TCP_NODELAY` | 1 | Yes | Already implemented |
| `TCP_MAXSEG` | 2 | No | getsockopt: return tcb.mss |
| `TCP_CORK` | 3 | **No** | Add this milestone |
| `TCP_KEEPIDLE` | 4 | No | Future: keepalive idle time |
| `TCP_KEEPINTVL` | 5 | No | Future: keepalive interval |
| `TCP_KEEPCNT` | 6 | No | Future: keepalive count |
| `TCP_INFO` | 11 | No | Future: TCP_INFO struct (large, 232 bytes) |
| `TCP_CONGESTION` | 13 | No | String: "reno", "cubic". getsockopt returns "reno" |
| `TCP_USER_TIMEOUT` | 18 | No | Future: per-connection timeout override |

### Message Flags

| Constant | Value | Already in zk | Notes |
|----------|-------|---------------|-------|
| `MSG_OOB` | 0x1 | No | Urgent data; do not implement |
| `MSG_PEEK` | 0x2 | **No** | Add this milestone |
| `MSG_TRUNC` | 0x20 | No | Add: UDP only, indicates truncation |
| `MSG_DONTWAIT` | 0x40 | **No** | Add this milestone |
| `MSG_WAITALL` | 0x100 | **No** | Add this milestone |
| `MSG_NOSIGNAL` | 0x4000 | No | Add: suppress SIGPIPE (no-op if no signals to pipe) |

---

## Data Structures: What Changes

### Additions to `Tcb` (src/net/transport/tcp/types.zig)

```zig
// Receiver-side SWS avoidance (RFC 1122 S4.2.3.3)
last_adv_wnd: u16,   // Last window we advertised (for SWS avoidance threshold)

// Per-connection buffer limits (set from socket's SO_SNDBUF/SO_RCVBUF)
rcv_buf_size: usize, // Effective receive buffer limit
snd_buf_size: usize, // Effective send buffer limit

// TCP_CORK (hold data until MSS)
cork: bool,
```

### Additions to `Socket` (src/net/transport/socket/types.zig)

```zig
// Buffer size options (SO_SNDBUF, SO_RCVBUF)
so_sndbuf: u32,   // Requested send buffer size (default 8192)
so_rcvbuf: u32,   // Requested recv buffer size (default 8192)

// Port reuse option (SO_REUSEPORT)
so_reuseport: bool,

// TCP_CORK
tcp_cork: bool,
```

### Additions to Constants (src/net/constants.zig)

```zig
// Maximum configurable buffer size (for SO_SNDBUF/SO_RCVBUF clamping)
pub const MAX_SOCKET_BUF_SIZE: usize = 262144; // 256KB

// Minimum window advertisement threshold (SWS avoidance)
// Advertise only if new window >= this threshold
// RFC 1122: min(half rcvbuf, SMSS)
pub const MIN_WINDOW_ADVERTISEMENT: usize = 512; // fallback if mss not yet known

// Message flags
pub const MSG_PEEK: u32     = 0x0002;
pub const MSG_DONTWAIT: u32 = 0x0040;
pub const MSG_WAITALL: u32  = 0x0100;
pub const MSG_TRUNC: u32    = 0x0020;
pub const MSG_NOSIGNAL: u32 = 0x4000;

// Socket option additions
pub const SO_SNDBUF: i32    = 7;
pub const SO_RCVBUF: i32    = 8;
pub const SO_REUSEPORT: i32 = 15;
pub const TCP_CORK: i32     = 3;
pub const TCP_MAXSEG: i32   = 2;
pub const TCP_CONGESTION: i32 = 13;
```

---

## Implementation Priority Order

This order minimizes risk -- each item builds on the previous and can be tested independently.

| Priority | Feature | Risk | RFC | Integration Point |
|----------|---------|------|-----|-------------------|
| 1 | Fix RFC 5681 slow-start arithmetic | LOW | RFC 5681 S3.1 | `rx/established.zig` |
| 2 | MSG_DONTWAIT flag | LOW | POSIX | `socket/udp_api.zig`, `tcp_api.zig`, `raw_api.zig` |
| 3 | MSG_PEEK for TCP | LOW | POSIX | `tcp/api.zig`, `socket/tcp_api.zig` |
| 4 | MSG_PEEK for UDP | LOW | POSIX | `socket/types.zig` (dequeuePacketIp) |
| 5 | SO_SNDBUF / SO_RCVBUF (clamped) | LOW | Linux ABI | `socket/options.zig`, `socket/types.zig` |
| 6 | Raw socket blocking recv | LOW | POSIX | `socket/raw_api.zig` |
| 7 | SO_REUSEPORT | MEDIUM | RFC 6056 | `socket/state.zig` (bind), `socket/lifecycle.zig` |
| 8 | TCP_CORK | MEDIUM | Linux | `socket/options.zig`, `tcp/tx/data.zig` |
| 9 | Receiver SWS avoidance | MEDIUM | RFC 1122 | `tcp/types.zig` (currentRecvWindow) |
| 10 | Sender SWS avoidance | MEDIUM | RFC 1122 | `tcp/tx/data.zig` |
| 11 | MSG_WAITALL | MEDIUM | POSIX | syscall layer (`sys_recv`) |
| 12 | NewReno partial-ACK (RFC 6582) | MEDIUM | RFC 6582 | `rx/established.zig` |

---

## What NOT to Implement in This Milestone

| Feature | Why Defer | When to Add |
|---------|-----------|-------------|
| CUBIC (RFC 8312) | Zero benefit in QEMU local loopback environment; adds W_max, t_last_decrease fields | When real-hardware networking or remote QEMU is supported |
| BBR | Requires RTT-probing phase and bandwidth estimation; fundamentally different architecture from loss-based CC | Never (academic interest only for this kernel) |
| TCP_INFO (option 11) | 232-byte struct; complex to populate correctly | When network debugging tools need it |
| SO_SNDBUFFORCE / SO_RCVBUFFORCE | Requires capability check; low test coverage need | With full CAP_NET_ADMIN support |
| TCP_KEEPALIVE / TCP_KEEPIDLE / etc. | Timer infrastructure works, but keepalive has no test demand yet | Next networking milestone |
| MSG_OOB / urgent data | RFC 793 urgent pointer is rarely used and partially deprecated (RFC 6093) | Potentially never |
| Multipath TCP (MPTCP) | Requires scheduler-level subflow management | Future milestone |
| Dynamic buffer allocation (Option B above) | Adds allocator complexity to fast path; Option A clamping is sufficient | When buffers > 8KB are tested as a performance need |

---

## Interaction with Existing Lock Order

From CLAUDE.md, the lock order is:

```
3. FileDescriptor.lock
4. Scheduler/Runqueue Lock
5. tcp_state.lock  <-- global TCP state
7. Per-socket sock.lock
```

For the new features:

- **SO_REUSEPORT bind check**: Acquire `state.lock` (socket subsystem IrqLock), scan socket table. Do not hold `tcp_state.lock` simultaneously. This is already the pattern in `socket/state.zig:bind()`.
- **MSG_WAITALL loop**: In syscall context. Acquire `sock.lock` to check data, release before blocking. Same pattern as existing `tcp_api.zig:accept()`. Do NOT hold `tcp_state.lock` while sleeping.
- **TCP_CORK flush on setsockopt**: `setsockopt` already holds `sock.lock`. After clearing cork, call `transmitPendingData(tcb)` while holding the `tcb.mutex`. This is safe: `sock.lock` -> `tcb.mutex` is the existing order in `socket/options.zig`.

---

## Testing Strategy

**For RFC 5681 fix:**
- Existing test runner's TCP stress tests will indirectly cover this (sustained transfer).
- Add a targeted test: send 100KB over loopback, measure throughput at different simulated RTTs. cwnd should grow to fill the window within ~10 RTTs in slow start.

**For MSG_* flags:**
- Unit test MSG_PEEK: peek 5 bytes, then recv 10 bytes; second recv should return same 5 bytes.
- Unit test MSG_DONTWAIT: nonblocking recv on empty socket; must return EAGAIN/WouldBlock immediately, not block.
- Unit test MSG_WAITALL: recv with count=100 on a socket that delivers 10 bytes per packet; must accumulate 100 bytes before returning.

**For SO_SNDBUF/SO_RCVBUF:**
- Set SO_RCVBUF to 2048; fill with 8KB of data; verify backpressure (sender blocks or gets WouldBlock at 2048 bytes, not 8192).

**For SO_REUSEPORT:**
- Bind two sockets to same port with SO_REUSEPORT=1; both bind calls must succeed. Without SO_REUSEPORT, second bind returns EADDRINUSE.

**For TCP_CORK:**
- Set TCP_CORK, write 100 bytes (< MSS), verify no segment transmitted. Clear TCP_CORK, verify segment transmitted immediately.

---

## Alternatives Considered

| Feature | Our Choice | Alternative | Why Not Alternative |
|---------|-----------|-------------|---------------------|
| Congestion control | Reno/NewReno (RFC 5681/6582) | CUBIC (RFC 8312) | CUBIC is optimal for high-BDP paths; QEMU loopback has near-zero BDP; adds complexity without measurable benefit |
| Buffer management | Clamped fixed arrays (Option A) | Dynamic allocation (Option B) | Dynamic alloc in fast path adds allocator pressure and `errdefer` complexity; clamping satisfies ABI without risk |
| SO_REUSEPORT dispatch | FIFO (first socket wins) | Hash-based per-4-tuple | Hash dispatch requires iterating socket list per incoming connection; FIFO is O(1) and sufficient for single-process test use |
| MSG_WAITALL | Syscall-layer loop | Transport-layer loop | Transport layer should not know about syscall blocking semantics; keeping it in syscall layer respects existing separation |

---

## Sources

**HIGH confidence -- RFC specifications (authoritative):**
- RFC 5681 (Allman, Paxson, Blanton 2009) -- TCP Congestion Control. Supersedes RFC 2581. Defines slow start, congestion avoidance, fast retransmit, fast recovery algorithms verbatim.
- RFC 6582 (Henderson, Floyd, Gurtov, Nishida 2012) -- NewReno modification to TCP's fast recovery algorithm. Fixes partial ACK handling.
- RFC 1122 (Braden 1989, updated) -- Host Requirements for Internet Hosts (Communication Layers). Section 4.2.3 covers TCP SWS avoidance for both receiver and sender.
- RFC 813 (Clark 1982) -- Window and Acknowledgement Strategy in TCP. Original SWS avoidance paper.
- RFC 6093 (Gont, Yourtchenko 2011) -- On the Implementation of the TCP Urgent Mechanism. Argues against implementing MSG_OOB.

**HIGH confidence -- Linux kernel UABI (stable, version-checked):**
- `include/uapi/asm-generic/socket.h` -- SO_* constant values. These are the stable UABI constants unchanged since ~2.6.20. Values verified in Linux 6.x via kernel.org.
- `include/uapi/linux/tcp.h` -- TCP_* option constants. Verified in Linux 6.x.
- `include/uapi/linux/socket.h` -- MSG_* flag constants.
- `net/core/sock.c:sk_setsockopt()` -- Linux's SO_SNDBUF/SO_RCVBUF doubling behavior (verified pattern, MEDIUM confidence on exact formula -- Linux doubles the request).

**MEDIUM confidence -- codebase analysis (verified by reading source):**
- zk codebase at `/Users/whit3rabbit/Documents/GitHub/zigk/src/net/` -- all gap analysis above is grounded in direct inspection of `types.zig`, `rx/established.zig`, `timers.zig`, `options.zig`, `raw_api.zig`, and `constants.zig`. Findings are HIGH confidence because they are observable facts in the code, not inferences.

---

*Stack research for: zk TCP/UDP network stack hardening*
*Researched: 2026-02-19*
