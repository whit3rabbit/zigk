# Architecture Research: TCP/UDP Network Stack Hardening

**Domain:** TCP congestion control, dynamic windows, socket API completeness, configurable buffers
**Researched:** 2026-02-19
**Confidence:** HIGH (based on direct source analysis of existing ~4200 LOC TCP implementation)

---

## Existing Architecture Inventory

This milestone adds features to an already-functional TCP stack. Understanding what exists is mandatory before deciding what to build.

### What Already Exists in TCB (types.zig)

The `Tcb` struct already has:

```
Congestion Control:
  cwnd: u32          -- Congestion window (bytes), initialized to DEFAULT_MSS * 2
  ssthresh: u32      -- Slow start threshold, initialized to 65535
  srtt: u32          -- Smoothed RTT (Jacobson/Karels, scaled by 8)
  rttvar: u32        -- RTT variance (scaled by 4)
  rtt_seq: u32       -- Sequence number being timed
  rtt_start: u64     -- Timestamp when rtt_seq was sent
  last_ack: u32      -- For dup ACK tracking
  dup_ack_count: u8  -- Duplicate ACK counter
  fast_recovery: bool -- In fast recovery (RFC 6582)
  recover: u32       -- Recovery point sequence number

Buffers (FIXED at compile time):
  send_buf: [BUFFER_SIZE]u8  -- 8192 bytes, embedded in struct
  recv_buf: [BUFFER_SIZE]u8  -- 8192 bytes, embedded in struct
  BUFFER_SIZE = 8192 (net/constants.zig)
  RECV_WINDOW_SIZE: u16 = 8192

Window:
  rcv_wnd: u16       -- Our advertised window
  snd_wnd: u32       -- Peer's window (scaled)
  wscale_ok: bool    -- Window scaling negotiated
  snd_wscale: u8     -- Peer's scale factor
  rcv_wscale: u8     -- Our scale factor

TCP Options already negotiated:
  SACK, timestamps, MSS, window scaling
```

### What Already Works in the TCP State Machine

From reading `rx/established.zig` and `tx/data.zig`:

- Slow start and congestion avoidance are **implemented** (the cwnd/ssthresh update logic in processEstablished)
- Fast retransmit/recovery (RFC 6582) is **implemented** (dup_ack_count, fast_recovery, recover fields)
- RTT estimation via Jacobson/Karels is **implemented** (updateRto in types.zig)
- SACK-aware retransmit selection is **implemented** (selectRetransmitSeq in tx/data.zig)
- Nagle's algorithm is **implemented** (nodelay field, check in transmitPendingData)
- Delayed ACK is **implemented** (ack_pending, ack_due, scheduleAck)
- Exponential backoff on timeout is **implemented** (timers.zig)
- Window update tracking (snd_wl1/snd_wl2) is **implemented** (processEstablished)

### What is Missing or Incomplete

Based on code analysis:

1. **Dynamic buffer sizing:** Buffers are fixed 8KB arrays embedded in the Tcb struct. Cannot resize without restructuring Tcb.
2. **SO_RCVBUF/SO_SNDBUF socket options:** Options struct in socket/options.zig does not handle these options (falls through to `InvalidArg`).
3. **MSG_* flags on send/recv:** `tcpSend` and `tcpRecv` in socket/tcp_api.zig take `[]u8` slices, no flags parameter. The syscall layer calls these without flag support.
4. **MSG_PEEK:** Cannot peek without consuming from the circular buffer.
5. **MSG_WAITALL:** No partial-read loop in tcpRecv.
6. **MSG_DONTWAIT:** No per-call non-blocking override distinct from socket-level O_NONBLOCK.
7. **sendmsg/recvmsg syscalls:** These are separate from send/recv; the scatter-gather iovec path is not connected to TCP.
8. **Configurable accept queue:** ACCEPT_QUEUE_SIZE is a compile-time constant (8), stored per-socket as `backlog: u16` but the backing array is fixed-size.
9. **sendSegment lacks TCP options in data segments:** `setDataOffsetFlags(5, flags)` hardcodes 5 words (no options). Timestamp option would require 12 bytes extra per segment.
10. **cwnd initial value:** Starting at `DEFAULT_MSS * 2` rather than the RFC 6928 recommended initial window of min(4*SMSS, max(2*SMSS, 4380)) for modern stacks.

---

## Component Boundaries and Integration Points

### System Overview

```
Userspace syscall path:
  sys_send(fd, buf, len, flags)
       |
  socket/tcp_api.tcpSend(sock_fd, data)       <-- NO flags today
       |
  tcp/api.send(tcb, data)
       |
  tx/data.transmitPendingData(tcb)            <-- cwnd/snd_wnd gate
       |
  tx/segment.sendSegment(tcb, flags, seq, ack, data)
       |
  iface.transmit(buf)

Receive path:
  e1000e IRQ -> rx/root.processPacket
                    |
              rx/established.processEstablished(tcb, pkt, hdr)
                    |
            [update cwnd on ACK, buffer data into recv_buf]
                    |
              socket/tcp_api.completePendingRecv OR
              tcb.recv_buf += data (wakes blocked thread)

Timer path:
  timer tick -> tcp/timers.processTimers()
                    |
              [retransmit, backoff, cwnd collapse on timeout]
```

### Component Responsibility Map

| Component | File | Current Responsibility | Change Needed? |
|-----------|------|----------------------|----------------|
| TCB struct | tcp/types.zig | Per-connection state + congestion fields | Add configurable buffer pointers |
| Constants | net/constants.zig | BUFFER_SIZE, RECV_WINDOW_SIZE, MAX_TCBS | Add configurable defaults |
| TX data | tcp/tx/data.zig | Segment selection, cwnd/snd_wnd gating, Nagle | Add congestion algorithm hooks |
| RX established | tcp/rx/established.zig | ACK processing, cwnd update, data delivery | Add MSG_PEEK support at buffer level |
| Timers | tcp/timers.zig | Retransmit, state GC, delayed ACK | Add keepalive timer |
| TCP API | tcp/api.zig | send/recv/connect/listen public interface | No change needed |
| Socket API | socket/tcp_api.zig | Syscall-to-TCP bridge, blocking logic | Add flags parameter to tcpSend/tcpRecv |
| Socket options | socket/options.zig | setsockopt/getsockopt dispatch | Add SO_RCVBUF, SO_SNDBUF, TCP_KEEPIDLE |
| Socket types | socket/types.zig | Socket struct definition | Add rcv_buf_size, snd_buf_size fields |
| Socket state | socket/state.zig | Socket table, port allocation | No change needed |

---

## Feature Integration Architecture

### Feature 1: Configurable Send/Receive Buffers

**The core problem:** `send_buf` and `recv_buf` are fixed-size arrays embedded directly in the Tcb struct. Changing them means:

Option A -- Heap-allocated buffers (recommended):
- Add `send_buf_ptr: ?[]u8` and `recv_buf_ptr: ?[]u8` to Tcb
- During TCB allocation, allocate from tcp_allocator at configured size
- Fall back to inline stack buffers if allocation fails
- `sendBufferSpace()` and `recvBufferAvailable()` already exist as methods -- update them to use dynamic size
- `currentRecvWindow()` must reflect actual buffer capacity, not BUFFER_SIZE constant

Option B -- Keep fixed buffers, change the constant:
- Change BUFFER_SIZE from 8192 to a larger value
- Simpler, but bloats every TCB regardless of actual need
- With 256 max TCBs, 64KB per TCB = 16MB just for buffers -- acceptable on this hardware

**Recommendation: Option B for send/recv buffers, but expose the constant as a tunable default.**

The Socket struct can carry `rcv_buf_size` and `snd_buf_size` fields (settable via SO_RCVBUF/SO_SNDBUF). When a new TCB is created for a socket, the socket's buffer size preference is passed to the TCB. The TCB still uses static arrays at BUFFER_SIZE bytes; the socket-level preference gates how much of that space is advertised in rcv_wnd.

This avoids heap allocation in the critical receive path while still giving userspace control over the effective window.

**Integration point:** `tcp/api.zig:listenIp()` and `connectIp()` -- pass desired buffer sizes from socket to TCB at construction. `types.Tcb:currentRecvWindow()` -- cap to min(actual_space, configured_rcv_buf).

**Data flow change:**
```
Before: rcv_wnd = min(BUFFER_SIZE - used, 65535)
After:  rcv_wnd = min(configured_rcv_buf - used, BUFFER_SIZE - used, 65535)
```

### Feature 2: MSG_* Flags on Send/Recv

**Integration approach:** Thread flags through the call stack without restructuring it.

The syscall dispatcher at `src/kernel/sys/syscall/fs/network.zig` (or equivalent) calls socket-layer functions. The socket TCP API functions need a `flags: u32` parameter added.

**Files to modify in order:**
1. `socket/tcp_api.zig`: Add `flags: u32` to `tcpSend()` and `tcpRecv()` signatures
2. `tcp/api.zig`: Add `flags: u32` to public `send()` and `recv()` -- pass through to implementation
3. Syscall layer (sys/syscall/fs/network.zig): Pass MSG flags from userspace to socket layer

**Flag behaviors:**

| Flag | Value | Send behavior | Recv behavior |
|------|-------|---------------|---------------|
| MSG_DONTWAIT | 0x40 | Return WouldBlock if send buffer full | Return WouldBlock if recv buffer empty |
| MSG_WAITALL | 0x100 | N/A | Loop until buf is full or connection closes |
| MSG_PEEK | 0x02 | N/A | Copy from recv_buf without advancing recv_tail |
| MSG_NOSIGNAL | 0x4000 | Suppress SIGPIPE on broken pipe | N/A |
| MSG_MORE | 0x8000 | Hint more data coming (suppress Nagle flush) | N/A |

**MSG_PEEK implementation detail:** The circular buffer in Tcb does not support peek natively. Add a `peekFromRecvBuf(tcb, buf)` function that reads from recv_tail without modifying it. This is a pure read -- no lock concern beyond the existing TCB mutex.

**MSG_WAITALL implementation detail:** Add a loop in `tcpRecv()` that re-blocks if `received < requested` and the connection is still open. Must handle partial delivery (connection closes mid-loop returns what was received, not error).

**MSG_DONTWAIT implementation detail:** Override the socket's `blocking` field for the duration of one call. Simplest approach: pass a local `effective_blocking = sock.blocking && !(flags & MSG_DONTWAIT)` into the blocking decision.

### Feature 3: Congestion Control Improvements

**What exists:** Slow start, AIMD congestion avoidance, and RFC 6582 fast recovery are all implemented in `rx/established.zig`. The code is correct per RFC 5681 but has two gaps:

1. **Initial window size:** RFC 6928 recommends IW = min(4*SMSS, max(2*SMSS, 4380)). Current code uses `DEFAULT_MSS * 2` (2920 bytes). Updating to RFC 6928 is a one-line change in `types.Tcb.init()`.

2. **Congestion window accounting in retransmit path:** When `timers.processTimers()` fires, it collapses cwnd to mss and calls `transmitPendingData`. This is correct. No change needed.

3. **Missing: ECN (Explicit Congestion Notification):** RFC 3168. Not in scope for this milestone unless explicitly requested.

**Integration point:** The cwnd update logic in `rx/established.zig:processEstablished()` lines 62-68. The congestion algorithm is tightly coupled to the ACK processing loop. To allow future algorithm swapping (Cubic, BBR), extract the cwnd update logic into a `congestion.zig` module with a function pointer or comptime-selectable algorithm.

**Recommended structure:**

```
src/net/transport/tcp/
  congestion/
    root.zig      -- algorithm selection (comptime or runtime)
    reno.zig      -- RFC 5681 New Reno (current behavior, extracted)
    cubic.zig     -- future: RFC 8312 CUBIC
```

This is preparation work. For this milestone, extract current logic into `congestion/reno.zig` and call it from `rx/established.zig`. The behavior does not change; the structure enables future work without rewriting the state machine.

**Integration points for extraction:**
- `rx/established.zig:processEstablished()`: Replace inline cwnd update with `congestion.onAck(tcb, acked_bytes)`
- `timers.zig:processTimers()`: Replace inline `tcb.ssthresh = ...; tcb.cwnd = tcb.mss` with `congestion.onTimeout(tcb)`
- `rx/established.zig`: Replace fast recovery entry with `congestion.onDupAck(tcb, dup_count)`

### Feature 4: Dynamic Window Management

**What exists:** `currentRecvWindow()` in `types.Tcb` correctly computes the advertised window based on buffer space. Window scaling negotiation exists. The window update tracking (snd_wl1/snd_wl2) is correct.

**What is missing:**

1. **Window auto-tuning:** Linux adjusts rcv_wnd based on observed bandwidth-delay product. This is optional for this milestone. The simpler approach is to just allow userspace to configure rcv_buf_size via SO_RCVBUF (Feature 1 above), which indirectly sets the maximum window.

2. **Zero window probing:** When the receive buffer fills and we advertise a zero window, the remote side stops sending. When buffer space opens, we must send a window update. Currently, the code sends an ACK after each data delivery, which implicitly updates the window. This is correct but may delay window opening. Add an explicit window update when a blocked reader drains a significant amount of buffer space (threshold: when space opens by >= MSS).

**Integration point for window update:** `tcp/api.zig:recv()` -- after copying data out of `recv_buf`, check if `currentRecvWindow()` has increased by >= MSS since the last ACK sent, and if so, call `tx.sendAck(tcb)` to advertise the new window.

**Data flow change:**
```
After recv() drains data from recv_buf:
  old_window = tcb.rcv_wnd (as advertised in last ACK)
  new_window = tcb.currentRecvWindow()
  if new_window - old_window >= tcb.mss:
      tx.sendAck(tcb)  -- window update
      tcb.rcv_wnd = new_window  -- track what we advertised
```

**Tracking last-advertised window:** Add `last_rcv_wnd: u16` to Tcb. Updated every time sendAck or sendSegment is called. Compare against currentRecvWindow() in recv() to decide if update is needed.

---

## New vs Modified Components

### Files Modified (not new)

| File | Change | Risk |
|------|--------|------|
| `net/constants.zig` | Increase BUFFER_SIZE default, add TCP_KEEPIDLE_DEFAULT | Low |
| `net/transport/tcp/types.zig` | Add `last_rcv_wnd`, `congestion_algo` enum, `configured_rcv_buf`/`snd_buf` | Medium (struct size change) |
| `net/transport/tcp/rx/established.zig` | Replace inline cwnd logic with congestion.onAck call; add window update after delivery | Medium |
| `net/transport/tcp/tx/data.zig` | No change needed for core logic | None |
| `net/transport/tcp/timers.zig` | Replace inline congestion logic with congestion.onTimeout; add keepalive timer logic | Low |
| `net/transport/socket/types.zig` | Add `rcv_buf_size: usize`, `snd_buf_size: usize` to Socket struct | Low |
| `net/transport/socket/options.zig` | Add SO_RCVBUF, SO_SNDBUF, TCP_KEEPIDLE, TCP_INFO cases | Low |
| `net/transport/socket/tcp_api.zig` | Add `flags: u32` to tcpSend/tcpRecv; implement MSG_PEEK, MSG_WAITALL, MSG_DONTWAIT, MSG_MORE | Medium |

### Files Added (new)

| File | Purpose |
|------|---------|
| `net/transport/tcp/congestion/root.zig` | Algorithm selection, shared types |
| `net/transport/tcp/congestion/reno.zig` | RFC 5681 New Reno (extracted from established.zig) |

---

## Build Order (Dependency-Aware)

The features have the following dependency graph:

```
Feature 1 (Configurable Buffers)
  -- required by --> Feature 4 (Dynamic Windows) [rcv_buf_size controls max window]
  -- independent of --> Feature 2 (MSG flags)
  -- independent of --> Feature 3 (Congestion refactor)

Feature 2 (MSG flags)
  -- independent of --> Features 1, 3, 4
  -- required by --> any userspace program using sendmsg/recvmsg with flags

Feature 3 (Congestion extraction)
  -- independent of --> Features 1, 2, 4
  -- enables future --> CUBIC, BBR algorithms

Feature 4 (Dynamic Windows)
  -- requires --> Feature 1 (needs rcv_buf_size to compute effective window)
```

**Recommended build order:**

Phase 1: Congestion algorithm extraction (Feature 3)
- Extract reno.zig from established.zig with no behavior change
- This is refactoring only; cannot break existing behavior
- No dependency on other features
- Provides the clean structure that future phases build on

Phase 2: Configurable buffers + socket options (Feature 1)
- Add SO_RCVBUF/SO_SNDBUF to socket/options.zig
- Add `rcv_buf_size`/`snd_buf_size` to Socket struct
- Pass buffer size preference into TCB at connect/accept time
- Cap advertised window to configured size in currentRecvWindow()

Phase 3: Dynamic window updates (Feature 4)
- Add last_rcv_wnd tracking to Tcb
- Add window update trigger in tcp/api.recv() after buffer drain
- Validate: zero window probe followed by window open advertisement

Phase 4: MSG flags (Feature 2)
- Add flags parameter through tcp_api.tcpSend/tcpRecv -> tcp/api.send/recv
- Implement MSG_PEEK (peekFromRecvBuf helper)
- Implement MSG_WAITALL (loop in recv until buffer full)
- Implement MSG_DONTWAIT (per-call blocking override)
- Implement MSG_MORE (suppress Nagle flush hint on send)

---

## Structural Constraints

### TCB Struct Size Warning

The TCB struct currently embeds two 8192-byte buffers inline, making each TCB approximately 16.5KB. With 256 max TCBs, this is 4MB of kernel heap. If BUFFER_SIZE is increased (e.g., to 32KB for better throughput), each TCB becomes ~64.5KB and the pool costs 16MB. This is still acceptable on x86_64 but check AArch64 heap limits.

The kernel stack overflow risk documented in CLAUDE.md (dispatch table expansion = stack overflow) does not apply here since we are not adding new syscall modules. But large struct initialization in kernel code can still cause stack pressure -- use `@memset` initialization pattern documented for `UnixSocketPair`.

### Lock Order Compliance

The existing lock hierarchy places `tcp_state.lock` (global TCP state) above `sock.lock` (per-socket lock). All new code must respect this:

- Acquire `tcp_state.lock` first if touching TCB pool
- Acquire `sock.lock` second if touching socket RX queue
- Never acquire `tcp_state.lock` while holding `sock.lock`

The MSG_WAITALL blocking loop must release all locks before calling `block_fn()` and re-acquire after waking -- same pattern as the existing `accept()` blocking loop in `tcp_api.zig`.

### Zig 0.16.x Specific

The `std.mem.trimRight` removal noted in CLAUDE.md does not affect network code. The `std.atomic.compilerFence` removal is already worked around in existing code with `asm volatile ("" ::: "memory")`. No new compatibility concerns for the features in this milestone.

---

## Data Flow Diagrams

### Current Send Path (with new features marked)

```
sys_send(fd, buf, len, flags)
    |
    v
tcpSend(sock_fd, data, flags)    <-- [NEW: add flags param]
    |
    +-- MSG_DONTWAIT? Override sock.blocking for this call
    +-- MSG_MORE? Set tcb.cork hint before sending
    |
    v
tcp.send(tcb, data, flags)       <-- [NEW: add flags param]
    |
    v
Copy data into tcb.send_buf (gated by snd_buf_size)  <-- [NEW: size gate]
    |
    v
transmitPendingData(tcb)
    |
    +-- effective_window = min(snd_wnd, cwnd)
    +-- Nagle check (unless MSG_MORE bypasses)
    |
    v
sendSegment(tcb, flags, seq, ack, data)
    |
    v
iface.transmit(buf)
```

### Current Receive Path (with new features marked)

```
e1000e IRQ -> processEstablished(tcb, pkt, hdr)
    |
    v
ACK processing:
    congestion.onAck(tcb, acked_bytes)   <-- [NEW: extracted call]
    window update tracking
    |
    v
Data delivery to recv_buf
    |
    v
After delivery: check if window opened by >= MSS
    if yes: tx.sendAck(tcb)              <-- [NEW: window update]
    |
    v
Wake blocked reader (tcb.blocked_thread)

------ (later, reader wakes) ------

tcpRecv(sock_fd, buf, flags)             <-- [NEW: add flags param]
    |
    +-- MSG_PEEK? Call peekFromRecvBuf(), skip advance of recv_tail
    +-- MSG_WAITALL? Loop until buf full or EOF
    +-- MSG_DONTWAIT? Set effective_blocking=false
    |
    v
tcp.recv(tcb, buf) -- copy from recv_buf, advance recv_tail
    |
    v
After drain: check window update trigger  <-- [NEW]
```

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Dynamic Buffer Allocation in RX IRQ Context

The IRQ handler (`processEstablished`) runs with the TCP global lock held and IRQs disabled. Calling `heap.allocator().alloc()` in this path will deadlock if the PMM lock is currently held by another CPU.

Do not attempt to resize buffers during packet processing. All buffer sizing decisions must happen at socket creation time or via setsockopt before the connection is established.

### Anti-Pattern 2: Holding tcp_state.lock During MSG_WAITALL Loop

The MSG_WAITALL blocking loop must not hold `tcp_state.lock` while sleeping. The pattern from the accept() implementation is correct: release all locks, register blocked_thread, call block_fn(), then re-acquire locks and re-check state.

### Anti-Pattern 3: Modifying Congestion State Outside TCB Mutex

The `cwnd`, `ssthresh`, `dup_ack_count`, `fast_recovery`, and `recover` fields in Tcb are protected by `tcb.mutex`. Any new congestion functions must be called with `tcb.mutex` held. The current code acquires the mutex in processEstablished before touching these fields.

### Anti-Pattern 4: Hardcoding Buffer Size in New Code

No new file should reference `constants.BUFFER_SIZE` for window calculation. Use `tcb.configured_rcv_buf` (or the equivalent new field) so that setsockopt changes take effect. Constants.BUFFER_SIZE remains the maximum allocation size -- the configured value is the effective window cap.

---

## Sources

- Direct source analysis: `src/net/transport/tcp/` (~4200 LOC)
- RFC 5681: TCP Congestion Control (New Reno behavior, confirmed matches existing implementation)
- RFC 6928: Increasing TCP's Initial Window (IW recommendation)
- RFC 6582: New Reno Modification to TCP's Fast Recovery Algorithm (confirmed implemented)
- RFC 793: TCP state machine (base reference, implemented in rx/ and tx/)
- RFC 7323: TCP Extensions for High Performance (window scaling, timestamps -- already negotiated)

---

*Architecture research for: TCP/UDP network stack hardening milestone*
*Researched: 2026-02-19*
