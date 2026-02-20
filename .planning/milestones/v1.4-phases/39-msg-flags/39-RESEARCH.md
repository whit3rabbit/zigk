# Phase 39: MSG Flags - Research

**Researched:** 2026-02-19
**Domain:** POSIX socket message flags -- kernel recv buffer, non-blocking I/O, blocking recv accumulation
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| API-01 | MSG_PEEK returns data without consuming from receive buffer for both TCP and UDP | TCP: peek into `tcb.recv_buf` without advancing `recv_tail`. UDP: peek into `sock.rx_queue` without advancing `rx_tail`. New `peekPacketIp` and `tcpPeek` functions needed. |
| API-02 | MSG_DONTWAIT provides per-call non-blocking override independent of O_NONBLOCK (returns EAGAIN if no data) | `sys_recvfrom` currently ignores `flags`. Parse `MSG_DONTWAIT` bit and pass a `nonblocking` override down through `recvfromIp`/`tcpRecv`. No `sock.blocking` mutation required. |
| API-03 | MSG_WAITALL blocks until full requested length received, EOF, or error (with SO_RCVTIMEO and EINTR handling) | TCP: loop inside new `tcpRecvWaitall` accumulating into a growing offset until `len` satisfied or EOF/error. UDP: SOCK_DGRAM ignores MSG_WAITALL per POSIX. SO_RCVTIMEO already wired in UDP; needs wiring for TCP. |

</phase_requirements>

---

## Summary

Phase 39 adds three message-flag behaviors to `sys_recvfrom` (and by extension `sys_recvmsg`) that are currently missing. The kernel already has all the data-structure primitives needed; the work is entirely in the recv paths and flag dispatch, with no protocol-layer changes required.

The current `sys_recvfrom` ignores the `flags` argument entirely (`_ = flags;` at line 562 of `net.zig`). The `sys_recvmsg` in `msg.zig` also ignores flags (`_ = flags; // Flags ignored for MVP`). The three flags need to be parsed and routed to modified versions of the existing UDP and TCP receive functions.

**Primary recommendation:** Add flag parsing at the `sys_recvfrom`/`sys_recvmsg` syscall boundary, add `tcpPeek`/`tcpRecvWaitall` variants in `tcp/api.zig`, and add `peekPacketIp` in `udp_api.zig`. Keep all changes inside the recv path -- no changes to packet processing, TCB structure, or lock ordering.

---

## Standard Stack

### Core (already in codebase)
| Component | Location | Purpose | Notes |
|-----------|----------|---------|-------|
| TCP recv buffer | `src/net/transport/tcp/api.zig:195-244` | Circular buffer, `recv_tail` is consumer pointer | `recv_head`/`recv_tail`/`recv_buf` fields on `Tcb` |
| UDP rx queue | `src/net/transport/socket/types.zig:431-456` | Per-socket packet queue, `rx_tail` is consumer pointer | `dequeuePacketIp` consumes; need `peekPacketIp` that does not |
| SO_RCVTIMEO | `src/net/transport/socket/udp_api.zig:150-157` | `rcv_timeout_ms` field on `Socket`, checked via `clock.rdtsc`/`hasTimedOut` | Already wired in UDP path; not wired in TCP blocking path |
| Scheduler block/wake | `src/net/transport/socket/scheduler.zig` | `blockFn`, `wakeThread`, `currentThreadFn` | Same pattern used for UDP blocking |
| MSG_NOSIGNAL | `src/net/transport/socket/types.zig:74` | `pub const MSG_NOSIGNAL: u32 = 0x4000;` | Already defined; pattern for adding new constants |

### Flag Constants (need to add to `types.zig`)
| Flag | Linux Value | Meaning |
|------|-------------|---------|
| MSG_PEEK | 0x0002 | Return data without consuming |
| MSG_DONTWAIT | 0x0040 | Non-blocking for this call only |
| MSG_WAITALL | 0x0100 | Block until full length received |

`MSG_NOSIGNAL = 0x4000` is already defined. The three new flags need to be added alongside it in `src/net/transport/socket/types.zig` and re-exported in `root.zig`.

---

## Architecture Patterns

### Where recv dispatches today

```
sys_recvfrom (net.zig:554)
  -> flags currently ignored (_ = flags)
  -> socket.recvfromIp (udp_api.zig) for UDP
  -> [no direct path for TCP in sys_recvfrom -- TCP uses socketRead -> tcpRecv]

socketRead (net.zig:166)
  -> socket.tcpRecv (tcp_api.zig:450) for SOCK_STREAM
  -> socket.recvfrom (udp_api.zig:207) for UDP

tcpRecv (tcp_api.zig:450)
  -> tcp.recv (tcp/api.zig:195) -- does ONE non-blocking read of recv_buf
  -> returns WouldBlock if empty (caller handles blocking in syscall layer)
```

Note: The blocking loop for TCP is in `sys_accept` (net.zig:812-823) and the accept path. For `socketRead`, there is NO blocking loop -- `tcpRecv` returns `WouldBlock` and the socket read iface returns that error to the caller. The blocking behavior for TCP recv is currently missing (tests that rely on loopback likely pass because data arrives before the recv call in the loopback path).

### Pattern 1: MSG_DONTWAIT (simplest)

**What:** Override `sock.blocking` for this call only.

**Implementation:** In `sys_recvfrom`, parse `flags & MSG_DONTWAIT`. Pass a `force_nonblocking: bool` parameter down into `recvfromIp`/`tcpRecv`. Inside those functions, treat `force_nonblocking = true` as `sock.blocking = false` for this call only, without mutating `sock.blocking`.

**Alternatively (simpler):** Temporarily mutate `sock.blocking` to false before the call and restore it after. This is unsafe in a concurrent context. Do NOT do this.

**Correct approach:** Add a `flags: u32` parameter to the socket-layer recv functions, propagate it down, and inside the blocking path check `(flags & MSG_DONTWAIT) != 0` before blocking.

```zig
// In sys_recvfrom (net.zig), after parsing flags:
const recv_flags: u32 = @truncate(flags);
const received = socket.recvfromIp(ctx.socket_idx, kbuf, &src_ip, &src_port, recv_flags) catch |err| { ... };
```

```zig
// In udp_api.recvfromIp, blocking check:
const is_nonblocking = !sock.blocking or ((flags & MSG_DONTWAIT) != 0);
if (is_nonblocking) {
    // ... try once, return WouldBlock
}
// else blocking path
```

### Pattern 2: MSG_PEEK (moderate complexity)

**What:** Copy data out of the receive buffer without advancing the tail pointer.

**For TCP:** Add `tcpPeek(tcb, buf)` in `tcp/api.zig` that reads `recv_buf` from `recv_tail` without modifying `recv_tail`. This is a simple variant of `tcp.recv`. The loop body is the same but `recv_tail` is not written. Does NOT send a window update ACK (no data consumed).

**For UDP:** Add `peekPacketIp(sock, buf, src_addr, src_port)` in `udp_api.zig` that reads `rx_queue[rx_tail]` without calling `dequeuePacketIp`. The `rx_tail` and `rx_count` fields must not be modified.

**Lock requirement:** Must hold `sock.lock` during peek, same as dequeue.

**Edge case:** If buffer is empty, peek returns WouldBlock (same as recv). If `MSG_PEEK | MSG_DONTWAIT`, return EAGAIN immediately if empty (no blocking). If `MSG_PEEK` alone on a blocking socket, block until data arrives, then peek.

```zig
// TCP peek (tcp/api.zig) -- does not advance recv_tail
pub fn peek(tcb: *Tcb, buf: []u8) TcpError!usize {
    var state_held = state.lock.acquire();
    const tcb_held = tcb.mutex.acquire();
    state_held.release();
    defer tcb_held.release();

    if (tcb.closing) return TcpError.ConnectionReset;
    const available = tcb.recvBufferAvailable();
    if (available == 0) {
        return switch (tcb.state) {
            .CloseWait, .LastAck, .Closing, .TimeWait, .Closed => return 0,
            .Established, .FinWait1, .FinWait2 => TcpError.WouldBlock,
            else => TcpError.NotConnected,
        };
    }
    const copy_len = @min(buf.len, available);
    // Read without advancing recv_tail
    var tail = tcb.recv_tail;
    for (0..copy_len) |i| {
        buf[i] = tcb.recv_buf[tail];
        tail = (tail + 1) % c.BUFFER_SIZE;
    }
    // Do NOT update tcb.recv_tail
    // Do NOT send window update ACK (data not consumed)
    return copy_len;
}
```

```zig
// UDP peek -- does not advance rx_tail/rx_count
pub fn peekPacketIp(self: *Socket, buf: []u8, src_addr: ?*IpAddr, src_port: ?*u16) ?usize {
    if (self.rx_count == 0) return null;
    const entry = &self.rx_queue[self.rx_tail];
    if (!entry.valid) return null;
    const copy_len = @min(entry.len, buf.len);
    @memcpy(buf[0..copy_len], entry.data[0..copy_len]);
    if (src_addr) |addr| addr.* = entry.src_addr;
    if (src_port) |port| port.* = entry.src_port;
    // Do NOT modify rx_tail or rx_count
    return copy_len;
}
```

### Pattern 3: MSG_WAITALL (most complex)

**What:** Block until `len` bytes are accumulated, EOF, or error/timeout.

**Scope:** Only meaningful for TCP (byte stream). For UDP/SOCK_DGRAM, POSIX says MSG_WAITALL is ignored because UDP delivers discrete datagrams -- a single datagram is always complete.

**Implementation:** Add `tcpRecvWaitall(sock_fd, buf, timeout_ms)` that loops calling `tcp.recv` into `buf[offset..]` until `offset == buf.len`, EOF (recv returns 0), or error.

The SO_RCVTIMEO deadline must cover the TOTAL wait, not per-iteration. Capture `start_tsc` before the loop and check `hasTimedOut` at each iteration.

EINTR handling: When a signal is pending during the block, `sched.block()` returns. Check for pending signal using the same pattern as the poll/select syscalls (`hasPendingSignal`). If a signal is pending AND some bytes were already accumulated, return the partial count. If no bytes accumulated, return EINTR.

```zig
// Conceptual pseudocode for MSG_WAITALL TCP loop
pub fn tcpRecvWaitall(sock_fd: usize, buf: []u8, timeout_ms: u64) SocketError!usize {
    var offset: usize = 0;
    const start_tsc = clock.rdtsc();
    while (offset < buf.len) {
        // Check timeout
        if (timeout_ms > 0 and clock.hasTimedOut(start_tsc, timeout_ms * 1000)) {
            if (offset > 0) return offset; // partial data
            return SocketError.TimedOut;
        }
        const n = tcpRecv(sock_fd, buf[offset..]) catch |err| {
            if (err == SocketError.WouldBlock) {
                // block via scheduler
                // check EINTR
                if (hasPendingSignal()) {
                    if (offset > 0) return offset;
                    return error.EINTR; // -> EINTR to syscall layer
                }
                continue;
            }
            if (offset > 0) return offset;
            return err;
        };
        if (n == 0) break; // EOF
        offset += n;
    }
    return offset;
}
```

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Timeout tracking | Custom tick counter | `clock.rdtsc()` + `clock.hasTimedOut()` | Already used in `udp_api.recvfrom`; correct, TSC-based |
| Thread blocking | Custom spinwait | `scheduler.blockFn()` + `scheduler.wakeThread()` | Already wired in UDP blocking path; IRQ-safe pattern |
| Signal checking | Polling `pending_signals` directly | `poll_mod.hasPendingSignal()` from `net.zig` | Already exported and used in poll syscall |
| Lock management | Multiple nested locks | Existing `state.lock` + `tcb.mutex` Held pattern | Lock ordering documented: tcp_state.lock(5) before sock.lock(6) |

**Key insight:** All infrastructure exists. This phase is pure recv-path plumbing with no new data structures.

---

## Common Pitfalls

### Pitfall 1: Mutating sock.blocking for MSG_DONTWAIT
**What goes wrong:** If you set `sock.blocking = false` before the recv call and restore it after, a concurrent thread observing `sock.blocking` sees the wrong value. Races are possible.
**Why it happens:** Temptation to reuse existing non-blocking path by flipping the flag.
**How to avoid:** Pass `flags: u32` parameter through the call chain. Check `(flags & MSG_DONTWAIT) != 0` in addition to `!sock.blocking`.
**Warning signs:** Any code that writes to `sock.blocking` outside of `setsockopt`/`fcntl`.

### Pitfall 2: Sending window update ACK after MSG_PEEK
**What goes wrong:** WIN-03 logic in `tcp/api.recv` sends a window update ACK when freed space >= MSS. If `peek` calls `sendAck`, the peer advances its send window based on space the application hasn't actually consumed yet. This is harmless but misleading.
**Why it happens:** Copy-paste of recv body into peek.
**How to avoid:** The peek implementation must NOT call `tx.sendAck`. The window does not change because `recv_tail` does not move.

### Pitfall 3: MSG_WAITALL on UDP
**What goes wrong:** Blocking until `len` bytes arrive on a UDP socket. Each datagram is independent; you cannot accumulate across datagrams.
**Why it happens:** Treating UDP like a byte stream.
**How to avoid:** In `sys_recvfrom`, if `sock.sock_type == SOCK_DGRAM`, ignore `MSG_WAITALL` and do a normal recv. POSIX allows this. Document it.

### Pitfall 4: EINTR vs partial WAITALL return
**What goes wrong:** Returning EINTR when some bytes were already accumulated. Linux returns the partial count, not EINTR, if any data was received before the signal.
**Why it happens:** Checking for signal before checking `offset > 0`.
**How to avoid:** In the WAITALL loop, if signal is pending AND `offset > 0`, return `offset`. Only return EINTR if `offset == 0`.
**Warning signs:** Test that does `recv(MSG_WAITALL)` in a signal handler loop and expects partial count.

### Pitfall 5: MSG_PEEK not blocking on empty buffer
**What goes wrong:** On a blocking socket with MSG_PEEK and empty buffer, returning EAGAIN instead of blocking until data arrives.
**Why it happens:** Short-circuit that treats peek like a non-blocking op.
**How to avoid:** MSG_PEEK only prevents consuming; it does not prevent blocking. Block until data is available, then peek.

### Pitfall 6: Stack growth from tcpRecvWaitall accumulation loop
**What goes wrong:** The WAITALL loop allocates `kbuf` on the heap in `sys_recvfrom`, but the kernel-side buffer is already allocated. There is no stack issue with the loop itself.
**Why it happens:** Not a real issue for this phase; the heap-allocated `kbuf` in `sys_recvfrom` is sufficient.
**Note:** `sys_recvfrom` already heap-allocates `kbuf` (line 574). MSG_WAITALL loops over `tcpRecv` filling different offsets of the same buffer. No additional allocation needed.

### Pitfall 7: TCP blocking recv currently missing
**What goes wrong:** `socketRead` (called by `read()` on a socket fd) calls `tcpRecv` which returns `WouldBlock` if the buffer is empty -- and `socketRead` propagates `WouldBlock` as `EAGAIN` without blocking. This means TCP recv is currently non-blocking by default when called via `read()`.
**Why it matters:** Phase 39 adds MSG_WAITALL which requires the blocking recv path to exist. The blocking TCP recv loop needs to be added as part of implementing MSG_WAITALL.
**How to avoid:** The syscall-layer blocking loop (currently only in accept) must be added to `sys_recvfrom` and `socketRead` for SOCK_STREAM sockets. MSG_WAITALL depends on this loop already working.

---

## Code Examples

### Existing: flag parse point in sys_recvfrom
```zig
// src/kernel/sys/syscall/net/net.zig:562
pub fn sys_recvfrom(
    fd: usize, buf_ptr: usize, len: usize, flags: usize,
    src_addr_ptr: usize, addrlen_ptr: usize,
) SyscallError!usize {
    _ = flags;  // <-- THIS IS THE ENTRY POINT FOR PHASE 39
```

### Existing: UDP blocking path (template for TCP)
```zig
// src/net/transport/socket/udp_api.zig:147-178
if (scheduler.blockFn()) |block_fn| {
    const get_current = scheduler.currentThreadFn() orelse return errors.SocketError.SystemError;
    const timeout_us: u64 = if (sock.rcv_timeout_ms > 0)
        std.math.mul(u64, sock.rcv_timeout_ms, 1000) catch std.math.maxInt(u64)
    else 0;
    const start_tsc = clock.rdtsc();
    while (true) {
        if (timeout_us > 0 and clock.hasTimedOut(start_tsc, timeout_us)) {
            return errors.SocketError.TimedOut;
        }
        const irq_state = platform.cpu.disableInterruptsSaveFlags();
        {
            const held = sock.lock.acquire();
            sock.blocked_thread = get_current();
            if (sock.dequeuePacketIp(buf, &ip_addr, &port)) |len| {
                sock.blocked_thread = null;
                held.release();
                platform.cpu.restoreInterrupts(irq_state);
                // ...
                return len;
            }
            held.release();
        }
        block_fn();
        sock.blocked_thread = null;
        platform.cpu.restoreInterrupts(irq_state);
    }
}
```

### Existing: MSG_NOSIGNAL flag (pattern to follow for new flags)
```zig
// src/net/transport/socket/types.zig:74
pub const MSG_NOSIGNAL: u32 = 0x4000;
// src/net/transport/socket/root.zig:46
pub const MSG_NOSIGNAL = types.MSG_NOSIGNAL;
```

### Existing: TCP recv buffer read (template for peek)
```zig
// src/net/transport/tcp/api.zig:210-233
const copy_len = @min(buf.len, available);
for (0..copy_len) |i| {
    buf[i] = tcb.recv_buf[tcb.recv_tail];
    tcb.recv_tail = (tcb.recv_tail + 1) % c.BUFFER_SIZE;
}
// For peek: remove the recv_tail update line
```

### Existing: UDP dequeue (template for peek)
```zig
// src/net/transport/socket/types.zig:431-456 (dequeuePacketIp)
const entry = &self.rx_queue[self.rx_tail];
const copy_len = @min(entry.len, buf.len);
@memcpy(buf[0..copy_len], entry.data[0..copy_len]);
// ...
entry.valid = false;          // For peek: REMOVE these two lines
self.rx_tail = ...;           // For peek: REMOVE
self.rx_count -= 1;           // For peek: REMOVE
return copy_len;
```

---

## Current State Audit (what exists, what is missing)

### What exists
- `MSG_NOSIGNAL = 0x4000` defined in `types.zig` and re-exported
- `sock.blocking` field controls blocking mode on `Socket`
- `sock.rcv_timeout_ms` field with `SO_RCVTIMEO` plumbed in UDP path
- TCP circular recv buffer (`recv_buf`, `recv_head`, `recv_tail`) in `Tcb`
- UDP packet queue (`rx_queue`, `rx_head`, `rx_tail`, `rx_count`) in `Socket`
- `dequeuePacketIp` in `types.zig` (consumes packet)
- `tcpRecv` / `tcp.recv` (consumes TCP data)
- UDP blocking loop with TSC timeout in `udp_api.recvfromIp`
- `clock.rdtsc()` and `clock.hasTimedOut()` available
- `poll_mod.hasPendingSignal()` exported from `net.zig`
- `wakeThread` called in `enqueuePacketIp` to unblock a waiting thread

### What is missing
- `MSG_PEEK = 0x0002`, `MSG_DONTWAIT = 0x0040`, `MSG_WAITALL = 0x0100` constants
- Flag parsing in `sys_recvfrom` (currently `_ = flags`)
- Flag parsing in `sys_recvmsg` (currently `_ = flags`)
- `peekPacketIp` method on `Socket` (or standalone fn)
- `tcp.peek` function (non-consuming TCP recv)
- `tcpPeek` wrapper in `tcp_api.zig`
- Blocking recv loop for TCP in `sys_recvfrom` (currently only accept has this)
- `tcpRecvWaitall` (accumulation loop with timeout/signal handling)
- SO_RCVTIMEO wired into TCP blocking recv path

---

## Implementation Scope

Phase 39 fits naturally into two plans:

**39-01: MSG_PEEK and MSG_DONTWAIT**
- Add flag constants to `types.zig` and re-export
- Parse flags in `sys_recvfrom` (and `sys_recvmsg` for completeness)
- Add `peekPacketIp` to `Socket` in `types.zig`
- Add `tcp.peek` to `tcp/api.zig`
- Add `tcpPeek` to `tcp_api.zig`
- Wire MSG_DONTWAIT through recv call chain
- Wire MSG_PEEK to call peek instead of recv/dequeue
- Tests: UDP peek (recv twice, verify same data), TCP peek (loopback), MSG_DONTWAIT returns EAGAIN on empty

**39-02: MSG_WAITALL**
- Add TCP blocking recv loop (prerequisite for WAITALL)
- Add `tcpRecvWaitall` with SO_RCVTIMEO and EINTR handling
- Wire MSG_WAITALL in `sys_recvfrom` for SOCK_STREAM
- Ignore MSG_WAITALL for SOCK_DGRAM (document)
- Tests: TCP WAITALL accumulates across multiple send/recv cycles, timeout terminates early, EINTR/signal returns partial

---

## Open Questions

1. **TCP blocking recv is currently missing**
   - What we know: `socketRead` calls `tcpRecv`, which returns `WouldBlock` with no blocking loop. The blocking recv loop needs to be added as part of this phase.
   - What's unclear: Whether existing socket tests pass because loopback delivers data before recv (timing). A proper WAITALL implementation requires the blocking loop regardless.
   - Recommendation: Add the TCP blocking recv loop in 39-01 before implementing WAITALL in 39-02.

2. **Signal check availability**
   - What we know: `poll_mod.hasPendingSignal()` is exported from `net.zig`. It requires `sched` import.
   - What's unclear: Whether EINTR is in the `SyscallError` set or needs to be added.
   - Recommendation: Check the `SyscallError` type definition in `uapi/errno` before 39-02.

3. **sys_recvmsg flags for MSG_PEEK**
   - What we know: `sys_recvmsg` also ignores flags. POSIX requires MSG_PEEK to work with recvmsg.
   - What's unclear: Whether the test suite exercises recvmsg with MSG_PEEK.
   - Recommendation: Apply flag parsing to both `sys_recvfrom` and `sys_recvmsg` in 39-01 for completeness. The plumbing is identical.

---

## Files to Modify

| File | Change |
|------|--------|
| `src/net/transport/socket/types.zig` | Add `MSG_PEEK`, `MSG_DONTWAIT`, `MSG_WAITALL` constants; add `peekPacketIp` method on `Socket` |
| `src/net/transport/socket/root.zig` | Re-export new flag constants |
| `src/net/transport/tcp/api.zig` | Add `peek(tcb, buf)` function |
| `src/net/transport/socket/tcp_api.zig` | Add `tcpPeek(sock_fd, buf)` and `tcpRecvWaitall(sock_fd, buf, timeout_ms)` |
| `src/net/transport/socket/udp_api.zig` | Pass `flags` through `recvfromIp`; check MSG_DONTWAIT; call `peekPacketIp` when MSG_PEEK |
| `src/kernel/sys/syscall/net/net.zig` | Parse `flags` in `sys_recvfrom`; add TCP blocking loop; route flags to socket layer |
| `src/kernel/sys/syscall/net/msg.zig` | Parse `flags` in `sys_recvmsg`; route MSG_PEEK/MSG_DONTWAIT |
| `src/user/test_runner/tests/syscall/sockets.zig` | Add tests for MSG_PEEK (TCP + UDP), MSG_DONTWAIT EAGAIN, MSG_WAITALL accumulation |
| `src/user/lib/syscall/net.zig` | Add `MSG_PEEK`, `MSG_DONTWAIT`, `MSG_WAITALL` constants; update `recvfrom` wrapper to accept flags |

---

## Sources

### Primary (HIGH confidence)
- Direct codebase reading: `src/net/transport/tcp/api.zig`, `src/net/transport/socket/udp_api.zig`, `src/net/transport/socket/types.zig`, `src/net/transport/socket/tcp_api.zig`, `src/kernel/sys/syscall/net/net.zig`, `src/kernel/sys/syscall/net/msg.zig` -- all read directly
- `src/net/transport/tcp/types.zig` -- Tcb struct, buffer fields confirmed
- `src/net/transport/socket/options.zig` -- SO_RCVTIMEO plumbing confirmed
- `.planning/REQUIREMENTS.md` -- API-01/02/03 requirements text confirmed
- `.planning/STATE.md` -- Phase 38 complete, decisions documented

### Secondary (MEDIUM confidence)
- POSIX recv(2) semantics for MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL -- applied from knowledge base, verified against codebase structure
- Linux flag values (0x0002, 0x0040, 0x0100) -- standard Linux kernel values, consistent with MSG_NOSIGNAL = 0x4000 already in types.zig

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all code read directly from codebase
- Architecture: HIGH -- recv paths traced end-to-end, entry/exit points identified
- Pitfalls: HIGH -- identified from code analysis (blocking TCP recv missing, peek-without-ACK requirement)
- Open questions: LOW confidence on EINTR set membership -- needs one-line verification

**Research date:** 2026-02-19
**Valid until:** Stable (no fast-moving dependencies; all kernel-internal changes)
