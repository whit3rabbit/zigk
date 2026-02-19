# Phase 38: Socket Options and Raw Socket Blocking - Research

**Researched:** 2026-02-19
**Domain:** TCP socket options (SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK), MSG_NOSIGNAL, raw socket blocking I/O
**Confidence:** HIGH (all findings verified directly from codebase)

## Summary

Phase 38 implements eight requirements across five implementation areas: buffer-size socket options, SO_REUSEPORT, TCP_CORK, MSG_NOSIGNAL, and raw socket blocking recv. Every requirement has a clear, localized implementation path already visible in the existing code. No new infrastructure is needed -- this phase is entirely additive work on top of existing structures.

The codebase already has the correct patterns for blocking I/O (`accept()` in `tcp_api.zig`), the signal delivery mechanism (`deliverSignalToThread()` in `signals.zig`), and the option plumbing skeleton (`setsockopt()`/`getsockopt()` in `socket/options.zig`). Phase 38 extends these patterns consistently.

The single area requiring the most care is SO_REUSEPORT: the bind-time conflict check in `lifecycle.zig:bindInternal()` needs a new multi-socket lookup structure or an inline table scan, and the accept dispatch needs round-robin or FIFO selection across co-bound listeners. All other requirements are straightforward field additions and option handler cases.

**Primary recommendation:** Implement the six simpler requirements (BUF-01 through BUF-03, BUF-05, API-04, API-05, API-06) in one plan and SO_REUSEPORT (BUF-04) in a second plan because SO_REUSEPORT requires a structural change to how listeners are indexed.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| BUF-01 | SO_RCVBUF accepted via setsockopt, value stored and applied as cap in currentRecvWindow() | Add `rcv_buf_size: u32` to `Socket`; add case in `socket/options.zig:setsockopt`; gate `currentRecvWindow()` in `tcp/types.zig` |
| BUF-02 | SO_SNDBUF accepted via setsockopt, value stored and applied as send buffer gate | Add `snd_buf_size: u32` to `Socket`; add case in `socket/options.zig:setsockopt`; check in `tcp.send()` or `transmitPendingData()` |
| BUF-03 | getsockopt returns doubled value for SO_RCVBUF/SO_SNDBUF per Linux ABI convention | Add cases in `socket/options.zig:getsockopt`; return `2 * stored_value` |
| BUF-04 | SO_REUSEPORT allows multiple sockets to bind same address:port pair (FIFO dispatch for accept) | Extend `canReuseAddress()` in `lifecycle.zig`; add FIFO dispatch among listeners; requires new field `so_reuseport: bool` on Socket |
| BUF-05 | Accept queue and RX queue sizes increased from fixed 8 to configurable higher values | Change `ACCEPT_QUEUE_SIZE` and `SOCKET_RX_QUEUE_SIZE` constants from 8 to larger values; arrays are statically allocated so no heap change required |
| API-04 | TCP_CORK holds data in send buffer until full MSS accumulated or cork cleared via setsockopt | Add `tcp_cork: bool` to `Socket` and `Tcb`; add option case in `setsockopt`; gate `transmitPendingData()` in `tx/data.zig` analogously to Nagle; flush on cork clear |
| API-05 | MSG_NOSIGNAL suppresses SIGPIPE delivery on write to broken connection | Parse `flags` in `sys_sendto`/`socketWrite`; when EPIPE/ConnectionReset and MSG_NOSIGNAL not set, call `deliverSignalToThread(current, SIGPIPE)` before returning EPIPE |
| API-06 | Raw socket blocking recv implemented via scheduler wake pattern (currently returns WouldBlock unconditionally) | Replace `return errors.SocketError.WouldBlock` at end of `recvfromRaw()` and `recvfromRaw6()` with the same block/wake pattern used in `accept()` |
</phase_requirements>

## Standard Stack

This is a pure Zig kernel project with no external dependencies. All relevant modules are internal.

### Core Files to Modify

| File | Purpose | Change Type |
|------|---------|-------------|
| `src/net/transport/socket/types.zig` | Socket struct, queue size constants | Add fields, increase constants |
| `src/net/transport/socket/options.zig` | setsockopt/getsockopt dispatch | Add new option cases |
| `src/net/transport/socket/lifecycle.zig` | bind() conflict check | SO_REUSEPORT logic |
| `src/net/transport/socket/raw_api.zig` | recvfromRaw / recvfromRaw6 | Blocking recv pattern |
| `src/net/transport/tcp/types.zig` | Tcb struct, currentRecvWindow() | Add cork field, rcv_buf_size cap |
| `src/net/transport/tcp/tx/data.zig` | transmitPendingData() | TCP_CORK gate |
| `src/kernel/sys/syscall/net/net.zig` | socketWrite(), sys_sendto() | MSG_NOSIGNAL flag parsing |
| `src/net/constants.zig` | Protocol constants | SO_RCVBUF, SO_SNDBUF, SO_REUSEPORT, TCP_CORK constant values |

### Constants That Need Adding to types.zig

Linux ABI values (verified from Linux source and standard headers):

| Constant | Value | Purpose |
|----------|-------|---------|
| `SO_SNDBUF` | 7 | Send buffer size option |
| `SO_RCVBUF` | 8 | Receive buffer size option |
| `SO_REUSEPORT` | 15 | Allow multiple binds to same address:port |
| `TCP_CORK` | 3 | Hold segments until full MSS |
| `MSG_NOSIGNAL` | 0x4000 | Suppress SIGPIPE |

## Architecture Patterns

### Pattern 1: BUF-01 and BUF-02 - Buffer Size Options

**What:** Store user-specified buffer sizes and apply them as caps.

**Socket struct additions** in `src/net/transport/socket/types.zig`:
```zig
// Inside Socket struct, under existing socket options:
rcv_buf_size: u32,  // 0 = use default (BUFFER_SIZE)
snd_buf_size: u32,  // 0 = use default (BUFFER_SIZE)
```

Initialize in `Socket.init()`:
```zig
.rcv_buf_size = 0,
.snd_buf_size = 0,
```

**setsockopt handler** addition in `src/net/transport/socket/options.zig`:
```zig
types.SO_RCVBUF => {
    if (optlen < 4) return errors.SocketError.InvalidArg;
    const val: *const i32 = @ptrCast(@alignCast(optval));
    if (val.* < 0) return errors.SocketError.InvalidArg;
    // Linux silently clamps to [256, rmem_max]; use BUFFER_SIZE as ceiling
    const requested: u32 = @intCast(@min(@as(u64, @intCast(val.*)), @as(u64, c.BUFFER_SIZE)));
    sock.rcv_buf_size = @max(256, requested);
    // Propagate to TCB if connected
    if (sock.tcb) |tcb| {
        tcb.rcv_buf_size = sock.rcv_buf_size;
    }
},
types.SO_SNDBUF => {
    if (optlen < 4) return errors.SocketError.InvalidArg;
    const val: *const i32 = @ptrCast(@alignCast(optval));
    if (val.* < 0) return errors.SocketError.InvalidArg;
    const requested: u32 = @intCast(@min(@as(u64, @intCast(val.*)), @as(u64, c.BUFFER_SIZE)));
    sock.snd_buf_size = @max(256, requested);
    if (sock.tcb) |tcb| {
        tcb.snd_buf_size = sock.snd_buf_size;
    }
},
```

### Pattern 2: BUF-03 - Doubled getsockopt Return

Linux doubles SO_RCVBUF and SO_SNDBUF in getsockopt to report the actual kernel allocation (which is doubled internally). This is the Linux ABI, not a bug.

**getsockopt handler** in `src/net/transport/socket/options.zig`:
```zig
types.SO_RCVBUF => {
    if (optlen.* < 4) return errors.SocketError.InvalidArg;
    const val: *i32 = @ptrCast(@alignCast(optval));
    const stored = if (sock.rcv_buf_size == 0) c.BUFFER_SIZE else sock.rcv_buf_size;
    val.* = @intCast(@min(@as(u64, stored) * 2, @as(u64, std.math.maxInt(i32))));
    optlen.* = 4;
},
types.SO_SNDBUF => {
    if (optlen.* < 4) return errors.SocketError.InvalidArg;
    const val: *i32 = @ptrCast(@alignCast(optval));
    const stored = if (sock.snd_buf_size == 0) c.BUFFER_SIZE else sock.snd_buf_size;
    val.* = @intCast(@min(@as(u64, stored) * 2, @as(u64, std.math.maxInt(i32))));
    optlen.* = 4;
},
```

### Pattern 3: BUF-01 Cap in currentRecvWindow()

The prior decision chose "Option A: fixed 8KB arrays with rcv_buf_size cap field." The `currentRecvWindow()` function in `src/net/transport/tcp/types.zig` currently uses `c.BUFFER_SIZE` as the total buffer size. The cap must gate the effective window advertisement, not the physical buffer. This avoids needing to resize the array.

Add `rcv_buf_size: u32` to `Tcb` (initialized to 0 meaning "use default"):
```zig
// In currentRecvWindow():
const effective_buf: usize = if (self.rcv_buf_size == 0)
    c.BUFFER_SIZE
else
    @min(@as(usize, self.rcv_buf_size), c.BUFFER_SIZE);

const space = effective_buf - @min(self.recvBufferAvailable(), effective_buf);
// ... rest unchanged
```

### Pattern 4: BUF-02 Send Buffer Gate

The send buffer gate applies in `sendBufferSpace()` or as a pre-check in `tcp.send()`. The cleanest approach: add `snd_buf_size: u32` to `Tcb` and apply it as a maximum in `tcp.send()` before writing into the circular buffer.

In `src/net/transport/tcp/root.zig` (or wherever `tcp.send()` is implemented), add:
```zig
const buf_limit = if (tcb.snd_buf_size == 0) c.BUFFER_SIZE else @min(@as(usize, tcb.snd_buf_size), c.BUFFER_SIZE);
const available = buf_limit - (tcb.sendBufferSpace() being used...);
```

The exact location needs checking against `tcp.send()` implementation (not yet read).

### Pattern 5: BUF-05 - Queue Size Increase

Current values in `src/net/transport/socket/types.zig`:
```zig
pub const SOCKET_RX_QUEUE_SIZE: usize = 8;
pub const ACCEPT_QUEUE_SIZE: usize = 8;
```

These are compile-time constants used as array sizes in the `Socket` struct. Increasing them increases the `Socket` struct size but requires no heap allocation. Recommended values based on Linux defaults:

- `SOCKET_RX_QUEUE_SIZE`: increase to 64 (8x, handles burst packets for raw sockets)
- `ACCEPT_QUEUE_SIZE`: increase to 128 (16x, handles high connection rate servers)

**Warning:** These arrays are embedded in `Socket` which is heap-allocated per socket. At 4096 max sockets, `ACCEPT_QUEUE_SIZE=128` uses `128 * 8 bytes = 1KB` extra per socket, so `4MB` total additional heap. Verify this is acceptable. If memory is tight, consider `ACCEPT_QUEUE_SIZE=32` instead.

### Pattern 6: API-04 - TCP_CORK

TCP_CORK (Linux extension) prevents `transmitPendingData()` from sending segments smaller than MSS. Unlike Nagle (which triggers on flight_size > 0), cork prevents transmission regardless of flight size -- it holds data until either a full MSS accumulates OR the cork is explicitly cleared.

Add to `Tcb` struct:
```zig
tcp_cork: bool,
```
Initialize to `false`.

Gate in `transmitPendingData()` in `src/net/transport/tcp/tx/data.zig`, after the existing Nagle check:
```zig
// TCP_CORK: hold until full MSS or cork cleared (RFC 2616/Linux extension)
if (tcb.tcp_cork and send_len < effective_mss) {
    return true; // Hold back
}
```

When `setsockopt(TCP_CORK, 0)` is called (clearing the cork), flush by calling `transmitPendingData()` immediately. This can be done in the `setsockopt` handler in `socket/options.zig`:
```zig
types.TCP_CORK => {
    if (optlen < 4) return errors.SocketError.InvalidArg;
    const val: *const i32 = @ptrCast(@alignCast(optval));
    const new_cork = (val.* != 0);
    sock.tcp_cork = new_cork;
    if (sock.tcb) |tcb| {
        tcb.tcp_cork = new_cork;
        if (!new_cork) {
            // Cork cleared: flush pending data
            _ = @import("../tcp/tx/root.zig").transmitPendingData(tcb);
        }
    }
},
```

Note: `TCP_CORK` is at IPPROTO_TCP level, so add this case to the `IPPROTO_TCP` branch, alongside the existing `TCP_NODELAY` case.

### Pattern 7: API-05 - MSG_NOSIGNAL

Currently `flags` is ignored in `sys_sendto()` and `socketWrite()`. MSG_NOSIGNAL must suppress SIGPIPE delivery when a write to a broken TCP connection returns EPIPE.

The write path for connected TCP goes through `socketWrite()` -> `socket.tcpSend()` -> returns `SocketError.ConnectionReset` when the peer has closed. This currently maps to ECONNRESET (correct). EPIPE is returned by Linux when writing to a half-closed connection (shutdown_write on peer). The current code returns `ENOTCONN` or `ConnectionReset`.

Implementation requires:
1. Define `MSG_NOSIGNAL: u32 = 0x4000` in `types.zig` (or `uapi`).
2. Pass `flags` down into `socketWrite()` -- this requires changing the FileOps write signature or threading flags separately. The current `FileOps.write` signature is `fn(fd: *FileDescriptor, buf: []const u8) isize` with no flags parameter.
3. For `sys_sendto()` and `sys_send()`, flags are available already. Add:
   ```zig
   const no_sigpipe = (flags & types.MSG_NOSIGNAL) != 0;
   // After call that returns EPIPE/ECONNRESET:
   if (!no_sigpipe) {
       const signals = @import("process/signals");
       const sched = @import("sched");
       if (sched.getCurrentThread()) |t| {
           signals.deliverSignalToThread(t, uapi.signal.SIGPIPE);
       }
   }
   ```
4. For the `socketWrite()` file-ops path (used by `sys_write()`), MSG_NOSIGNAL cannot be passed because the file-ops write has no flags. Linux handles this by checking `O_NOSIGPIPE` on the file descriptor or the `MSG_NOSIGNAL` send flag. For `sys_write()`, Linux always sends SIGPIPE when writing to a closed peer. Only `send(MSG_NOSIGNAL)` suppresses it.

**Decision needed:** Does the project need SIGPIPE on `sys_write(socket_fd, ...)` when TCP is broken? If yes, the `socketWrite()` function needs to check if the connection is broken and deliver SIGPIPE. If not, SIGPIPE only applies to the send() syscall path (where flags are available).

The simplest correct approach for Phase 38: add SIGPIPE delivery in `socketWrite()` unconditionally (since `sys_write()` should deliver it), and add MSG_NOSIGNAL suppression only in `sys_sendto()`/`sys_send()`. The `socketWrite()` path currently returns ENOTCONN (not EPIPE), so SIGPIPE is not triggered. For correctness, `ConnectionReset` should map to EPIPE + SIGPIPE, then MSG_NOSIGNAL suppresses it.

### Pattern 8: API-06 - Raw Socket Blocking Recv

`src/net/transport/socket/raw_api.zig:recvfromRaw()` and `recvfromRaw6()` both contain:
```zig
// Blocking mode - would need to sleep and wait
// For now, return would-block (TODO: implement blocking raw recv)
return errors.SocketError.WouldBlock;
```

The correct pattern is already implemented in `tcp_api.zig:accept()`:
1. Set `sock.blocked_thread = get_current()`.
2. Release the socket lock.
3. Call `block_fn()`.
4. On wake, re-acquire and re-check for data.

For raw sockets, the wake-up already happens: `state.zig:deliverToRawSockets4()` and `deliverToRawSockets6()` both call `scheduler.wakeThread(thread)` and clear `blocked_thread`. So the delivery side is complete.

The fix is purely in `recvfromRaw()` and `recvfromRaw6()`:
```zig
// Replace the final WouldBlock return with:
if (!sock.blocking) {
    return errors.SocketError.WouldBlock;
}

// Blocking mode: sleep and wait
if (scheduler.blockFn()) |block_fn| {
    const get_current = scheduler.currentThreadFn() orelse {
        return errors.SocketError.SystemError;
    };
    sock.blocked_thread = get_current();
    // CRITICAL: release socket lock BEFORE blocking to allow delivery side to acquire it
    held.release(); // held was acquired above at "const held = sock.lock.acquire();"
    state.releaseSocket(sock);
    block_fn();
    // Woke up - loop and retry
    // (Simplest: return WouldBlock and let caller retry, or implement proper loop)
    // Better: loop like accept() does
} else {
    return errors.SocketError.WouldBlock;
}
```

The cleanest implementation mirrors `accept()`: restructure as a `while (true)` loop that re-acquires, checks, and blocks if no data.

**Critical detail:** The lock must be released before calling `block_fn()`. The current code structure acquires `sock.lock` before trying to dequeue. The refactored blocking version must release both the per-socket lock and the socket reference (`state.releaseSocket(sock)`) before calling `block_fn()`, then re-acquire both on wake. This is the same pattern `accept()` uses.

### Pattern 9: BUF-04 - SO_REUSEPORT

This is the most structurally significant requirement. SO_REUSEPORT allows multiple sockets to bind to the same address:port. On accept(), the kernel distributes incoming connections across the bound sockets.

**Current state:** `canReuseAddress()` in `lifecycle.zig` only handles `SO_REUSEADDR`. There is no `so_reuseport` field on `Socket`.

**Implementation:**

1. Add `so_reuseport: bool` to `Socket` struct, initialized to `false`.
2. Add `SO_REUSEPORT` option handling to `setsockopt()`.
3. Modify `bindInternal()` to allow binding when both `new_sock.so_reuseport` and `existing.so_reuseport` are true for sockets bound to the same address:port.
4. For FIFO dispatch: when a SYN arrives and multiple listening sockets exist for the same port, the TCP RX path (`rx/listen.zig`) must iterate listeners and pick one using a round-robin or FIFO selector.

The bind-table lookup is currently via `state.findListeningTcbIp()` and `state.findListeningTcb()` which return the FIRST match. For SO_REUSEPORT with FIFO dispatch, a per-port sequence number (or queue index) is needed. The simplest implementation: maintain a global round-robin index per port, or scan all listening TCBs for the port and pick the one with the least accept_count.

**FIFO dispatch recommendation:** When a SYN is received in `rx/listen.zig`, find all listening TCBs/sockets on that port. Select the one whose associated socket has the lowest `accept_count`. This is O(n) over listeners per port, which is acceptable for the small N (typical SO_REUSEPORT use has 2-N_CPU listeners).

### Anti-Patterns to Avoid

- **Do not resize the fixed-size send/receive arrays in `Tcb`**: The prior decision explicitly chose fixed 8KB arrays with `rcv_buf_size` as a cap. Do not change `[c.BUFFER_SIZE]u8` array sizes in Tcb.
- **Do not hold the socket lock while calling block_fn()**: Every blocking pattern in the codebase (accept, connect) releases all locks before calling `block_fn()`.
- **Do not call `transmitPendingData()` from within the setsockopt spinlock**: The function transmits packets which may acquire other locks. Release the socket lock first, then flush.
- **Do not add rcv_buf_size/snd_buf_size to `Tcb` as heap allocations**: Keep as `u32` fields on the struct (value 0 = use default).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Signal delivery | Custom SIGPIPE mechanism | `signals.deliverSignalToThread()` from `src/kernel/sys/syscall/process/signals.zig` |
| Thread blocking | Custom wait queue | `scheduler.blockFn()` + `scheduler.wakeThread()` pattern from `socket/scheduler.zig` |
| Option dispatch | New option dispatch layer | Extend existing `setsockopt()`/`getsockopt()` in `socket/options.zig` |
| Port conflict checking | New data structure | Extend `canReuseAddress()` in `lifecycle.zig` |

## Common Pitfalls

### Pitfall 1: Lock Held Across block_fn()
**What goes wrong:** If `sock.lock` is held when `block_fn()` is called, the delivering thread (from network interrupt context) will deadlock trying to acquire `sock.lock` to enqueue the packet and wake the thread.
**How to avoid:** Follow the pattern in `tcp_api.zig:accept()` exactly: release both `held` (the per-socket lock) and call `state.releaseSocket(sock)` before `block_fn()`. Re-acquire both on wake.
**Warning signs:** Kernel hangs after sending a packet to a raw socket.

### Pitfall 2: rcv_buf_size Cap Bypassed on currentRecvWindow
**What goes wrong:** The SWS avoidance floor `sws_floor = min(BUFFER_SIZE/2, MSS)` uses the physical buffer size. If `rcv_buf_size < BUFFER_SIZE/2`, the effective floor exceeds the cap and the window is always advertised as 0.
**How to avoid:** Use `effective_buf` (the capped value) for the SWS floor calculation too: `sws_floor = min(effective_buf/2, MSS)`.
**Warning signs:** getsockopt(SO_RCVBUF) shows a value, but TCP connections stall with zero window.

### Pitfall 3: TCP_CORK Flush Requires TCB Lock
**What goes wrong:** Calling `transmitPendingData(tcb)` from `setsockopt()` while holding `sock.lock` but not `tcb.mutex` leads to races with the RX path.
**How to avoid:** Acquire `tcb.mutex` before calling `transmitPendingData()`, or release `sock.lock` first. Check the lock ordering rule in CLAUDE.md: `socket/state.lock` > `per-socket sock.lock` > `per-TCB tcb.mutex`. Since `transmitPendingData` internally does not acquire the TCB mutex (caller is expected to hold it), acquire `tcb.mutex` under `sock.lock` -- but only if this doesn't invert lock order.
**Warning signs:** Data corruption or missing segments after cork clear.

### Pitfall 4: SO_REUSEPORT Listener Selection Race
**What goes wrong:** Multiple CPUs receive SYN packets for the same port simultaneously. Without atomics on the round-robin index, two SYNs go to the same listener.
**How to avoid:** Use `@atomicRmw` to increment and wrap the per-port dispatch index. Or use accept_count comparison (inherently safe because it's read under `state.lock`).
**Warning signs:** Uneven connection distribution or two SYNs routed to same socket.

### Pitfall 5: getsockopt Doubled Value Overflow
**What goes wrong:** If `rcv_buf_size` is near `maxInt(u32)`, doubling it overflows.
**How to avoid:** Use `@min(@as(u64, stored) * 2, std.math.maxInt(i32))` with intermediate u64 arithmetic.
**Warning signs:** getsockopt returns negative value.

### Pitfall 6: MSG_NOSIGNAL Only Applies to send() Not write()
**What goes wrong:** Treating `sys_write()` on a socket FD the same as `send(MSG_NOSIGNAL)`.
**Correct behavior:** `sys_write()` has no flags, so it ALWAYS delivers SIGPIPE on broken pipe (same as send without MSG_NOSIGNAL). Only `send(fd, ..., MSG_NOSIGNAL)` suppresses SIGPIPE. The `socketWrite()` file-op should deliver SIGPIPE. The flags-aware path only suppresses it.
**Warning signs:** `sys_write()` fails to deliver SIGPIPE, or `send(MSG_NOSIGNAL)` still delivers SIGPIPE.

## Code Examples

### Verified Blocking Pattern (from tcp_api.zig:accept())
```zig
// Source: src/net/transport/socket/tcp_api.zig:94-135
while (true) {
    const sock = state.acquireSocket(sock_fd) orelse return errors.SocketError.BadFd;
    {
        const held = sock.lock.acquire();
        if (/* data available */) {
            // consume data
            held.release();
            state.releaseSocket(sock);
            break;
        }
        if (!sock.blocking) {
            held.release();
            state.releaseSocket(sock);
            return errors.SocketError.WouldBlock;
        }
        if (scheduler.blockFn()) |block_fn| {
            const get_current = scheduler.currentThreadFn() orelse { ... };
            sock.blocked_thread = get_current();
            held.release();
            state.releaseSocket(sock); // MUST release before blocking
            block_fn();
            continue; // re-acquire and re-check
        }
    }
}
```

### Verified Wake Pattern (from state.zig:deliverToRawSockets4())
```zig
// Source: src/net/transport/socket/state.zig:418-422
// Wake blocked thread if any
if (sock.blocked_thread) |thread| {
    types.scheduler.wakeThread(thread);
    sock.blocked_thread = null;
}
```

### Verified Signal Delivery Pattern (from signals.zig)
```zig
// Source: src/kernel/sys/syscall/process/signals.zig:657-659
// Usage from any kernel context:
const sched = @import("sched");
const signals = @import("process/signals");  // path varies by caller location
if (sched.getCurrentThread()) |t| {
    signals.deliverSignalToThread(t, @intCast(uapi.signal.SIGPIPE));
}
```

### Verified Option Pattern (from socket/options.zig existing SO_REUSEADDR)
```zig
// Source: src/net/transport/socket/options.zig:43-48
types.SO_REUSEADDR => {
    if (optlen < 4) return errors.SocketError.InvalidArg;
    const val: *const i32 = @ptrCast(@alignCast(optval));
    sock.so_reuseaddr = (val.* != 0);
},
```

## State of the Art

| Area | Current State | Phase 38 Target |
|------|---------------|-----------------|
| SO_RCVBUF/SO_SNDBUF | Not handled (returns InvalidArg) | Stored, reflected in currentRecvWindow() and send gate |
| SO_REUSEPORT | Not implemented | FIFO dispatch for multiple listeners on same port |
| TCP_CORK | Not implemented | Holds segments until MSS full or cork cleared |
| MSG_NOSIGNAL | Flags parameter silently ignored | Suppresses SIGPIPE on broken connection write |
| Raw socket blocking | Always returns WouldBlock | Sleeps and wakes on packet arrival |
| Accept queue size | Fixed 8 entries | Configurable, increased to 128 |
| RX queue size | Fixed 8 entries | Configurable, increased to 64 |
| getsockopt SO_RCVBUF/SO_SNDBUF | Not handled | Returns 2x stored value per Linux ABI |

## Open Questions

1. **SIGPIPE from sys_write() path**
   - What we know: `socketWrite()` has no `flags` parameter; `sys_write()` has no socket-specific flags.
   - What's unclear: Should `socketWrite()` deliver SIGPIPE when it returns ECONNRESET/ENOTCONN? Linux does deliver SIGPIPE from write() on a broken socket if the application has not set SA_RESETHAND or ignored SIGPIPE.
   - Recommendation: Implement SIGPIPE delivery in `socketWrite()` when TCP connection is broken and SND half is shut down. Then MSG_NOSIGNAL only applies to `sys_sendto()`/`sys_send()`. This is the POSIX-correct behavior.

2. **TCP_CORK flush lock ordering**
   - What we know: `setsockopt` holds `sock.lock`, and `transmitPendingData()` works on `tcb.mutex`.
   - What's unclear: Whether `transmitPendingData()` is safe to call from `setsockopt()` without the TCB mutex (since TCB is not locked in setsockopt).
   - Recommendation: In the cork-clear handler, save a pointer to `tcb`, release `sock.lock`, acquire `tcb.mutex`, then call `transmitPendingData()`.

3. **SO_REUSEPORT dispatch index storage**
   - What we know: There is no per-port state structure in the current socket subsystem for dispatch ordering.
   - What's unclear: Where to store the FIFO dispatch index for SO_REUSEPORT (on the port, or computed dynamically by accept_count).
   - Recommendation: Use dynamic selection based on minimum `accept_count` across co-bound listeners. This avoids needing a new data structure and is self-balancing.

4. **rcv_buf_size propagation to TCB on listen()**
   - What we know: `listen()` in `tcp_api.zig` copies `tos` and `nodelay` from socket to listening TCB, but new fields are not automatically copied.
   - What's unclear: Whether `rcv_buf_size`/`snd_buf_size` set before `listen()` should be inherited by accepted connections.
   - Recommendation: Copy `rcv_buf_size`/`snd_buf_size` from listening socket to accepted child socket in `queueAcceptConnection()`/`accept()`.

## Sources

### Primary (HIGH confidence)
- `src/net/transport/socket/options.zig` - Existing setsockopt/getsockopt structure verified by direct read
- `src/net/transport/socket/types.zig` - Socket struct fields and queue constants verified by direct read
- `src/net/transport/socket/tcp_api.zig` - Blocking pattern (accept) verified by direct read
- `src/net/transport/socket/raw_api.zig` - TODO blocking path verified by direct read
- `src/net/transport/socket/state.zig` - Wake pattern in deliverToRawSockets4/6 verified by direct read
- `src/net/transport/tcp/types.zig` - Tcb struct and currentRecvWindow() verified by direct read
- `src/net/transport/tcp/tx/data.zig` - transmitPendingData() with Nagle/SWS gates verified by direct read
- `src/kernel/sys/syscall/process/signals.zig` - deliverSignalToThread() API verified by direct read
- `src/kernel/sys/syscall/net/net.zig` - socketWrite() and sys_sendto() flags ignored verified by direct read
- `src/net/constants.zig` - BUFFER_SIZE=8192, ACCEPT_QUEUE_SIZE=8, SOCKET_RX_QUEUE_SIZE=8 verified

### Secondary (MEDIUM confidence)
- Linux ABI constant values (SO_SNDBUF=7, SO_RCVBUF=8, SO_REUSEPORT=15, TCP_CORK=3, MSG_NOSIGNAL=0x4000) - standard Linux x86_64 ABI, consistent across kernel headers

## Metadata

**Confidence breakdown:**
- BUF-01, BUF-02, BUF-03: HIGH -- setsockopt/getsockopt patterns are identical to existing SO_REUSEADDR
- BUF-04 (SO_REUSEPORT): MEDIUM -- requires structural change to listen dispatch, no precedent in codebase
- BUF-05: HIGH -- simple constant change
- API-04 (TCP_CORK): HIGH -- gate in transmitPendingData identical to Nagle pattern
- API-05 (MSG_NOSIGNAL): HIGH -- deliverSignalToThread() call + flags check
- API-06 (raw blocking): HIGH -- pattern is identical to accept() and wake-up side is already wired

**Research date:** 2026-02-19
**Valid until:** 2026-04-01 (codebase-derived, stable until net stack changes)
