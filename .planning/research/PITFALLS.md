# Pitfalls Research: TCP/UDP Network Stack Hardening

**Domain:** Adding TCP congestion control, dynamic window management, and socket buffer resizing to an existing Zig microkernel network stack
**Researched:** 2026-02-19
**Confidence:** HIGH (grounded in the actual zk codebase; pitfalls verified against real code patterns)

---

## Context: What the Existing Code Looks Like

Before reading the pitfalls, understand these fixed points in the current design:

- `BUFFER_SIZE = 8192` is a comptime constant embedded in `[c.BUFFER_SIZE]u8` arrays directly **inside** the `Tcb` struct (types.zig:190,196). Replacing these with pointers requires `Tcb.init()` to be rewritten, every buffer access site to handle null, and the TCB size changes from ~22KB to a smaller header with heap allocations.
- `c.BUFFER_SIZE` appears in 18 source locations. It is not abstracted behind a function or field -- it is a literal type-level constant in array lengths.
- The global `state.lock` (IrqLock) wraps the entire TCP state machine. Per-TCB `mutex` (Spinlock) is nested inside. Lock order is strict: `state.lock` before `tcb.mutex`. Any new dynamic allocation must respect this order.
- `processTimers()` iterates all 256 TCBs every timer tick. Linear scan cost grows with TCB count -- adding per-connection timers for congestion control (persist timer, keepalive) increases this cost.
- `cwnd`, `ssthresh`, `srtt`, `rttvar` already exist in the TCB but are not enforced at all call sites. The congestion control logic in `rx/established.zig` is correct RFC 5681 but uses integer overflow for AIMD increment (line 65-67) that saturates to `maxInt(u32)` rather than clamping sensibly.
- `currentRecvWindow()` in types.zig computes the receive window from `c.BUFFER_SIZE` at runtime but the window scale is fixed at `calculateWindowScale(c.BUFFER_SIZE)` in options.zig:205, computed once at SYN time. If buffer size changes after handshake, the scale factor is wrong.

---

## Critical Pitfalls

### Pitfall 1: Replacing Fixed Buffer Arrays with Slices Breaks `Tcb.init()` and `Tcb.reset()`

**What goes wrong:**
`Tcb.init()` currently returns a `Self` by value containing `[8192]u8` arrays. If you change `send_buf` and `recv_buf` from arrays to slices (`[]u8`), the init function must allocate memory, which means it needs an allocator, which means every caller that does `tcb.* = Tcb.init()` breaks. Worse, `Tcb.reset()` calls `self.* = Self.init()` -- this would leak the old buffers every time a connection closes.

**Why it happens:**
The pattern `self.* = Self.init()` for reset is common in Zig and works correctly for value types. Adding heap-allocated fields converts a "copy to zero" into a "leak old + allocate new" operation unless the reset is explicitly rewritten.

**How to avoid:**
Do not change the reset pattern until buffer lifecycle is fully designed. Options:
1. Keep `send_buf`/`recv_buf` as fixed arrays but make them optional (`?[]u8`) with a fallback to stack-allocated 8KB when `setsockopt(SO_SNDBUF)` is not called. This keeps `Tcb.init()` trivial.
2. Write a `Tcb.deinit(allocator)` that frees buffers, and replace all `Tcb.reset()` calls with `tcb.deinit(allocator); tcb.* = Tcb.init();`.
3. Use a two-field approach: `send_buf_fixed: [BUFFER_SIZE]u8` as default, `send_buf_dyn: ?[]u8` as override. `sendBuf()` returns `if (send_buf_dyn) |d| d else &send_buf_fixed`. This avoids breaking existing code but increases struct size.

**Warning signs:**
- Any call to `freeTcb` that does not call `Tcb.deinit` first after adding dynamic buffers.
- `Tcb.reset()` still present and called without freeing slices.
- Tests passing on the happy path but leaking on connection reset/timeout.

**Phase to address:** The buffer resizing phase. Requires an explicit design decision before any code changes. Do not proceed with buffer changes until `Tcb.deinit` exists.

---

### Pitfall 2: Window Scale Factor Locked at Connection Setup, Invalid After Buffer Resize

**What goes wrong:**
`rcv_wscale` is negotiated in the SYN/SYN-ACK handshake (options.zig:205) based on `c.BUFFER_SIZE`. It tells the peer "shift your receive window advertisement left by N bits." If you resize the buffer after the handshake, the scale factor is now wrong -- the peer continues sending window advertisements assuming the original scale, but the actual buffer is larger (or smaller).

**Why it happens:**
RFC 7323 requires window scale to be agreed once at connection setup. You cannot renegotiate. The scale factor encodes the ratio between actual buffer capacity and the 16-bit window field. Changing buffer size without changing scale breaks this ratio permanently for the lifetime of the connection.

**How to avoid:**
- For new connections, compute `rcv_wscale` from the configured socket buffer size, not from `c.BUFFER_SIZE`. This means reading `SO_RCVBUF` at `listen()`/`connect()` time.
- Never allow buffer resize after the handshake completes for the current connection. `setsockopt(SO_RCVBUF)` on an established connection should either be rejected with `EINVAL`, apply only to new connections, or -- if you want Linux behavior -- silently clamp and apply the new buffer size without changing the scale.
- If you grow the buffer without changing scale: advertised window will saturate at `65535 << rcv_wscale`. This is a correctness bug but not a crash. The connection works but cannot use the extra buffer space.
- If you shrink the buffer without changing scale: the peer may send data faster than the buffer can hold. `currentRecvWindow()` computes from actual free space, so the window advertisement will still be correct, but the scale computation in the TX path may produce a window value that overflows u16 when shifted.

**Warning signs:**
- `currentRecvWindow()` returning 0 when the buffer has space (integer cast overflow).
- Transfer throughput does not improve after increasing buffer size on an established connection.
- Peer sends data at rate higher than buffer capacity immediately after buffer shrink.

**Phase to address:** Window management phase. The `calculateWindowScale` call in options.zig must be made dependent on the per-socket configured buffer size before the handshake phase of that function.

---

### Pitfall 3: `send_acked` Pointer Becomes Invalid When Buffer Pointer Changes

**What goes wrong:**
`Tcb` has three pointers into the send buffer: `send_head`, `send_tail`, and `send_acked`. These are byte offsets into `send_buf` modulo `BUFFER_SIZE`. If you change the buffer size (either in place by reallocation, or by replacing the pointer), `send_head % new_size` and `send_tail % new_size` no longer point to the same data -- the circular buffer has been logically corrupted.

**Why it happens:**
A circular buffer with modulo arithmetic encodes position as an absolute offset that wraps at capacity. Changing capacity retroactively invalidates all existing position encodings. The offset `send_acked = 4100` means "byte 4100 % 8192 = 4100" in an 8KB buffer. In a 16KB buffer, the same offset still points to the same physical byte, but the logical interpretation (bytes from tail to head vs. bytes in flight) is now computed incorrectly.

**How to avoid:**
Buffer resize must be done atomically with a position recalculation. The correct procedure is:
```
1. Acquire tcb.mutex
2. Drain/copy existing buffered bytes: compute logical content as contiguous slice
3. Allocate new buffer
4. Copy content to start of new buffer
5. Reset send_head = content_length, send_tail = 0, send_acked = 0
6. Replace buffer pointer, update BUFFER_SIZE reference
7. Release mutex
```
This is complex under the existing lock hierarchy. Any shortcut (e.g., just replacing the pointer without recalculating offsets) will corrupt the buffer.

**Warning signs:**
- Data corruption (wrong bytes sent) after buffer resize with data in flight.
- Retransmission of wrong data after resize.
- `bufferedBytes()` in tx/data.zig returning values larger than the buffer.

**Phase to address:** Buffer resizing phase. Must be treated as an atomic operation with position renormalization. Flag this as requiring a specific test: send 4KB, resize to 16KB, send 4KB more, verify all 8KB received in order.

---

### Pitfall 4: `cwnd` Growing Without Bound Under Sustained ACKs (Missing Max Cap)

**What goes wrong:**
The congestion avoidance increment in rx/established.zig:65-67 is:
```zig
const inc = @max(1, (@as(u64, tcb.mss) * tcb.mss) / tcb.cwnd);
const inc_clamped: u32 = if (inc > std.math.maxInt(u32)) std.math.maxInt(u32) else @truncate(inc);
tcb.cwnd = std.math.add(u32, tcb.cwnd, inc_clamped) catch std.math.maxInt(u32);
```
This correctly uses `std.math.add` to saturate at `maxInt(u32)` (~4GB). However, there is no upper bound on `cwnd` relative to the actual send buffer size. Once `cwnd > BUFFER_SIZE`, it has no effect (the send buffer is the bottleneck). A `cwnd` of 4GB wastes comparison operations every retransmit and can trigger u32 overflow in `eff_wnd` calculations:
```zig
const eff_wnd = @min(@as(u32, tcb.snd_wnd), tcb.cwnd); // Both u32, safe
const flight_size = tcb.snd_nxt -% tcb.snd_una; // Wrapping subtraction
if (flight_size >= eff_wnd) { // Can be wrong if eff_wnd = maxInt(u32)
```
If `cwnd` reaches `maxInt(u32)` and `snd_wnd` is also large, `eff_wnd` stays sane. But if you introduce a 64-bit `cwnd` (e.g., for large buffers), the `@min` comparisons must be widened consistently.

**How to avoid:**
Cap `cwnd` at `max(send_buffer_size, snd_wnd * 2)` during AIMD. Linux caps at 1GB. A reasonable cap for zk is `min(BUFFER_SIZE * 4, snd_wnd * 4)` since there's no reason to have a `cwnd` larger than what can actually be buffered and sent.

**Warning signs:**
- `cwnd` growing to `maxInt(u32)` in long-lived idle connections with no data loss.
- Adding larger buffer sizes causes cwnd to overflow u32 when treated as byte count.

**Phase to address:** Congestion control hardening phase. Add `cwnd = @min(cwnd, MAX_CWND)` at the end of the AIMD update path.

---

### Pitfall 5: Partial ACK Deflation in Fast Recovery Sets `cwnd` Below `mss`

**What goes wrong:**
In rx/established.zig:47, partial ACK during fast recovery does:
```zig
tcb.cwnd = tcb.ssthresh + @as(u32, tcb.mss);
```
This is the Reno partial ACK deflation. However, `ssthresh` at fast recovery entry is set to `max(flight / 2, mss * 2)`. If there is only 1 MSS in flight when duplicate ACKs arrive, `ssthresh = mss * 2` and `cwnd = mss * 3` at recovery entry, then on partial ACK `cwnd = mss * 2 + mss = mss * 3`. This is actually correct. The bug manifests differently: if `ssthresh` was set to exactly `mss * 2` and then `ssthresh + mss` is `mss * 3`, the window never deflates below `mss * 2` even when `flight_size = 0`. This prevents proper stall detection.

The real risk: when implementing NewReno or CUBIC later, the partial ACK handling must be rewritten. The current Reno implementation is tightly coupled to the specific cwnd arithmetic. Adding a different algorithm means untangling these values without breaking the existing fast recovery state machine.

**How to avoid:**
Isolate congestion control state into a separate struct at the design phase:
```zig
pub const CongestionState = struct {
    cwnd: u32,
    ssthresh: u32,
    algorithm: enum { Reno, NewReno, CUBIC },
    // algorithm-specific state
    fast_recovery: bool,
    recover: u32,
    dup_ack_count: u8,
};
```
The `Tcb` holds a `CongestionState` and calls `cc.onAck()`, `cc.onLoss()`, `cc.onDupAck()`. This makes algorithm replacement surgical rather than a diff across the entire RX path.

**Warning signs:**
- Fast recovery state machine behaving differently after adding a second algorithm.
- `cwnd` and `ssthresh` being modified from two code paths simultaneously (one in established.zig, one in the new algorithm).

**Phase to address:** Congestion control phase. The struct isolation should be done first, before implementing any new algorithm.

---

### Pitfall 6: RTT Measurement With Retransmitted Segments (Karn's Algorithm Not Applied)

**What goes wrong:**
The current RTT measurement in rx/established.zig:51-58 updates the RTO when `ack >= rtt_seq`. This is correct for new transmissions. However, `rtt_seq` is set in tx/data.zig:97-100 as the sequence number of the front of the next segment. If that segment is retransmitted (timer expiry or fast retransmit) and then ACKed, the RTT sample is the time from the *original* send, not the retransmit. This overestimates RTT after loss events.

RFC 6298 (Karn's Algorithm): do not use RTT samples from retransmitted segments. Reset `rtt_seq = 0` whenever a segment is retransmitted.

Currently, `retransmitFromSeq()` in tx/data.zig and `retransmitLoss()` do not clear `rtt_seq`. The timer expiry path in timers.zig:118-130 also does not clear `rtt_seq`.

**How to avoid:**
Add `tcb.rtt_seq = 0` and `tcb.rtt_start = 0` in:
1. `retransmitFromSeq()` in tx/data.zig
2. The RTO timer expiry branch in timers.zig (before the retransmit call)
3. Fast retransmit in rx/established.zig before calling `retransmitLoss()`

**Warning signs:**
- RTO inflating abnormally after a single loss event.
- `srtt` growing without bound after a period of congestion.
- The connection recovering from loss but then transmitting very slowly for minutes.

**Phase to address:** RTT estimation hardening. This is a correctness fix that should be applied before congestion control is extended, because incorrect RTT makes all congestion control decisions wrong.

---

### Pitfall 7: Dynamic Buffer Allocation Fails Under `state.lock` (IrqLock = Interrupts Disabled)

**What goes wrong:**
`state.lock` is an `IrqLock` that disables interrupts while held. The heap allocator (`tcp_allocator`) is accessed while holding this lock in `allocateTcb()`. If you add `SO_RCVBUF`/`SO_SNDBUF` resizing that calls `heap.allocator().alloc()` while holding `state.lock`, and the allocator internally tries to acquire another lock (e.g., `pmm.lock`), you will deadlock or violate the lock ordering documented in CLAUDE.md (lock order: `tcp_state.lock` at position 5, `pmm.lock` at position 10 -- so pmm can be acquired under tcp_state.lock in the ordering).

The actual risk is different: with interrupts disabled, any allocation that requires a page fault or sleeps (even briefly) is illegal. The heap allocator in this kernel does not sleep, but `pmm.allocZeroedPages` must not be called from interrupt context with interrupts disabled. Check `heap.allocator()` implementation carefully before allocating under IrqLock.

**How to avoid:**
- Pre-allocate buffers at socket creation time (`socket()` syscall), not at first send/recv or at `setsockopt`.
- If resizing is done on-demand, release `state.lock` before allocating, then re-acquire and validate the TCB still exists before installing the new buffer.
- Use the pattern from `freeTcb()`: collect work items to do after lock release, then do them outside the lock.

**Warning signs:**
- Deadlock in `setsockopt(SO_RCVBUF)` with another thread holding `pmm.lock`.
- Interrupt latency spike when buffer allocation happens during a connection-heavy workload.
- `alloc` called from timer interrupt context (processTimers holds state.lock).

**Phase to address:** Buffer resizing phase. Design the allocation site before writing any code. Never allocate under IrqLock unless the allocator is provably interrupt-safe.

---

### Pitfall 8: `send_tail` Advanced by ACK Without Checking `send_acked` (In-Flight Data Clobbered)

**What goes wrong:**
In rx/established.zig:70-72:
```zig
const real_acked = ack -% tcb.snd_una;
tcb.snd_una = ack;
tcb.send_tail = (tcb.send_tail + real_acked) % c.BUFFER_SIZE;
```
This advances `send_tail` by the ACKed byte count. `send_tail` is the read pointer for bytes to send/retransmit. `send_acked` is tracked separately (api.zig:185 shows it used for write position). The `send_tail` advancement assumes the circular buffer arithmetic is correct -- specifically that `real_acked` cannot exceed the actual buffered content.

If `real_acked` wraps (i.e., `ack -% snd_una` produces a value larger than the buffered data due to a rogue ACK or a bug), `send_tail` jumps past `send_head`, making the buffer appear empty when it is not, and subsequent sends will overwrite unacknowledged data.

With dynamic buffer sizes, if the buffer has been resized between the original send and the ACK, `real_acked` may be valid but the modulo with the old `BUFFER_SIZE` is wrong.

**How to avoid:**
Add an assertion (or runtime check in debug builds):
```zig
const buffered = bufferedBytes(tcb); // from tx/data.zig
if (real_acked > buffered) {
    // Rogue ACK or state corruption -- reset connection
    tcb.state = .Closed;
    return .Continue;
}
tcb.send_tail = (tcb.send_tail + real_acked) % effective_buf_size;
```
For dynamic buffers, `effective_buf_size` must come from the TCB's current buffer size field, not from the comptime constant `c.BUFFER_SIZE`.

**Warning signs:**
- Data received by peer out of order or duplicated after an ACK.
- `bufferedBytes()` returning values larger than buffer capacity.
- SACK blocks referencing sequence ranges that were already ACKed.

**Phase to address:** Buffer resizing phase. This check must be added when `c.BUFFER_SIZE` is replaced with a runtime value.

---

### Pitfall 9: `processTimers()` Stack Allocation Scales With `MAX_TCBS`

**What goes wrong:**
`processTimers()` in timers.zig:15 allocates:
```zig
var wake_list: [c.MAX_TCBS]?*anyopaque = undefined;
```
`MAX_TCBS = 256`, so this is `256 * 8 = 2048` bytes on the stack. The function already holds `state.lock` (IrqLock, interrupts disabled), so the stack frame is allocated in a restricted context. If you increase `MAX_TCBS` to support more connections (a natural consequence of dynamic buffers reducing per-connection overhead), this stack allocation grows linearly.

At 1024 TCBs: 8KB just for `wake_list`. The kernel stack is 96KB (24 pages), but the dispatch stack depth is already deep at timer interrupt entry. The "comptime dispatch table expansion = stack overflow" pattern from MEMORY.md is the precedent here.

**How to avoid:**
Change `wake_list` to a fixed small array (e.g., 32 entries) and process in batches, or use a static global wake buffer protected by its own lock (safe because `processTimers` is always called from a single timer context in this single-CPU kernel).

```zig
// Static buffer - safe for single-CPU kernel
var wake_list: [64]?*anyopaque = undefined; // Fixed size
var wake_count: usize = 0;
// If wake_count >= 64: release lock, wake batch, re-acquire, continue
```

**Warning signs:**
- Double fault or kernel stack guard hit after increasing `MAX_TCBS`.
- Stack corruption manifesting as wrong TCB state after a timer tick with many simultaneous timeouts.

**Phase to address:** Any phase that increases `MAX_TCBS`. If dynamic buffers reduce per-connection overhead enough to warrant more connections, address the wake_list size first.

---

### Pitfall 10: Persist Timer Logic Missing -- Zero-Window Deadlock

**What goes wrong:**
When `snd_wnd = 0` (peer's receive buffer is full), `transmitPendingData` returns early (tx/data.zig:58-76) and sets `retrans_timer = 1`. The RTO timer fires and retransmits a zero-window probe. However, the retransmit path in timers.zig:120-130 handles the `.Established` case by either using SACK retransmit or resetting `snd_nxt = snd_una` and calling `transmitPendingData`. If `snd_wnd` is still 0 when `transmitPendingData` is called, it hits the `eff_wnd == 0` branch and sends a 1-byte probe (lines 63-72). This is correct.

The bug is that the RTO exponential backoff applies to the persist probe -- the same timer backs off to 64 seconds. RFC 1122 requires a persist timer that probes at 5-60 second intervals (not the full RTO backoff schedule). Using RTO backoff for zero-window probing means after a few probe failures, the probe interval is minutes, effectively freezing the connection.

**How to avoid:**
Separate the persist timer from the retransmission timer. When `snd_wnd = 0`:
- Do not start the retrans timer in the normal sense.
- Start a persist timer that fires every `min(rto_ms, PERSIST_MAX_MS)` seconds.
- Do not apply exponential backoff to the persist interval (or apply a much gentler cap, e.g., 60s max).
- Reset persist timer when a non-zero window update arrives.

**Warning signs:**
- Connection "frozen" for minutes when peer's buffer temporarily fills.
- `retrans_count` incrementing on zero-window probes, eventually triggering MAX_RETRIES reset.
- Connection reset by kernel after peer's buffer opens up but before the next probe fires.

**Phase to address:** Window management phase. Persist timer is tightly coupled to zero-window logic.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Keep `c.BUFFER_SIZE` as comptime in buffer arithmetic | No code changes needed | Cannot support per-socket buffer sizes; window scale is wrong for non-default buffers | Only until buffer resizing phase |
| Use `cwnd = mss` on loss without per-algorithm state | Simple code, correct for Reno | Cannot add CUBIC without rewriting the RX path | Never -- struct isolation has no downside |
| Track RTT on retransmitted segments (Karn's violation) | One less conditional | RTT inflates post-loss, causing conservative RTO, hurting throughput | Never -- this is an RFC violation |
| Single `retrans_timer` for both retransmit and persist | Fewer timer fields | Zero-window deadlock under backoff | Never -- separate timers have independent purposes |
| `maxInt(u32)` saturation for cwnd | No overflow | cwnd becomes meaningless at >4GB; comparison semantics change | Acceptable only if BUFFER_SIZE cap is also applied |

---

## Integration Gotchas

| Integration Point | Common Mistake | Correct Approach |
|-------------------|----------------|------------------|
| `SO_SNDBUF`/`SO_RCVBUF` setsockopt | Apply new size immediately to established connection | Apply to new buffer allocation; do not resize in place; note that Linux doubles the value internally |
| `currentRecvWindow()` with new buffer size | Forget to update `rcv_wscale` in the TCB | `rcv_wscale` must match the configured buffer at SYN time; expose a `tcb.effectiveBufferSize()` used by both window computation and modulo arithmetic |
| `calculateWindowScale()` in options.zig:205 | Pass `c.BUFFER_SIZE` (comptime) | Pass `tcb.recv_buf_size` (runtime from socket option) |
| Congestion control in the ACK path | Modify `cwnd` before `send_tail` advancement | The order in established.zig is significant; cwnd update must see the new `snd_una` value |
| Adding CUBIC `K` and `W_max` fields to `Tcb` | Add directly to TCB struct | Put in `CongestionState` sub-struct; TCB at ~22KB is already large; adding 64 bytes per connection for unused fields is waste |
| `options.zig:205` window scale calculation | Called from SYN processing before socket buffer size is known | Pass socket's configured `rcv_buf_size` through the call chain from `rx/syn.zig` |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Linear TCB scan in `processTimers` | Timer tick takes proportionally longer with more connections | Indexed timer wheel (even a simple 8-bucket wheel by next-expiry-second) | At ~128 active connections with frequent short RTOs |
| Per-byte copy loop in `send()`/`recv()` (api.zig:183-186,210-213) | CPU-bound send throughput, not I/O bound | `@memcpy` with wrapped-buffer handling for the two-segment circular buffer case | Any bulk transfer >1MB with small MSS |
| `for (0..send_len)` copy in `transmitPendingData` (tx/data.zig:91-94) | Same as above but in TX path | Split into two `@memcpy` calls: `buf[tail..min(tail+len, cap)]` then `buf[0..remainder]` | Measurable at 100MB+ throughput |
| `isTcbValid()` linear scan on every `connect()` poll (tcp_api.zig:229) | O(n) per wakeup check while blocked on connect | Generation counter check (already in TCB) is sufficient for UAF safety; can skip `isTcbValid()` when generation matches | At 100+ concurrent connecting sockets |
| `OooBlock` with `[MAX_TCP_PAYLOAD]u8` inline (types.zig:123) | Each OOO block is 1466 bytes; 4 blocks = 5864 bytes per TCB in the struct | Allocate OOO blocks from a pool; or reduce to 2 blocks with coalescing | With dynamic buffers where OOO depth increases |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Accepting peer's window scale without validation | Peer advertises scale=14; computed `snd_wnd = raw_window << 14` overflows u32 | Clamp: `scale = @min(snd_wscale, c.TCP_MAX_WSCALE)` -- already done in established.zig:123 but verify in SYN-ACK processing path |
| Advertising window larger than actual buffer | Peer sends data faster than buffer can absorb; data silently dropped | `currentRecvWindow()` must compute from actual free space, not from nominal buffer size |
| `real_acked` without upper-bound check | Rogue ACK advances `send_tail` past valid data, enabling write-after-send | Add: `if (real_acked > bufferedBytes(tcb)) return error; // reset connection` |
| Zero-initializing large dynamic buffers at allocation | `pmm.allocZeroedPages` is safe; `heap.allocator().alloc()` with `[_]u8{0}` is a zeroing loop that holds `state.lock` | Allocate with `alloc(u8, size)` outside the lock, then `@memset` outside the lock |
| Window shrinking: advertising smaller window than already in flight | Peer may have sent more data than the shrunken buffer can hold | Never advertise a window smaller than `rcv_nxt + outstanding_data - recv_buf_start`; the RFC calls this "SWS avoidance" |

---

## "Looks Done But Isn't" Checklist

- [ ] **Congestion control:** `cwnd` is updated but there is no upper bound relative to buffer size -- verify `cwnd = @min(cwnd, send_buf_size * N)` is applied.
- [ ] **RTT measurement:** `rtt_seq = 0` is set in all retransmit paths (both timer expiry and fast retransmit) -- verify in timers.zig and rx/established.zig.
- [ ] **Buffer resize:** `Tcb.reset()` frees old dynamic buffer before zeroing -- verify `deinit()` is called, not just `self.* = init()`.
- [ ] **Window scale:** `rcv_wscale` is computed from the runtime buffer size, not from `c.BUFFER_SIZE` -- verify in options.zig:205.
- [ ] **Persist timer:** Zero-window detection does not apply exponential backoff beyond 60s -- verify `retrans_count` is not incremented for zero-window probes.
- [ ] **`send_tail` arithmetic:** The modulo uses the TCB's current effective buffer size, not the comptime constant -- verify in rx/established.zig:72.
- [ ] **`processTimers` wake_list:** Stack size of `[MAX_TCBS]?*anyopaque` is bounded -- verify when increasing `MAX_TCBS`.
- [ ] **`SO_SNDBUF` doubling:** Linux silently doubles `SO_SNDBUF` values (for bookkeeping overhead). If you implement `getsockopt(SO_SNDBUF)`, it should return double what `setsockopt` received. Userspace applications depend on this.
- [ ] **Both architectures:** `snd_wscale` shift (`<< scale`) and window scale option parsing behave identically on x86_64 and aarch64 -- the existing `@min(tcb.snd_wscale, 14)` cast in established.zig:123 is `@intCast` which must not truncate on aarch64.

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Broken `Tcb.reset()` leaks buffers | MEDIUM | Add `deinit(allocator)` to Tcb; audit all `freeTcb` calls to ensure deinit precedes them |
| Wrong `send_tail` after buffer resize | HIGH | Connection must be torn down and re-established; no in-place fix; add the buffer_size field validation check first |
| `cwnd` saturated at maxInt(u32) | LOW | Add cap: `cwnd = @min(cwnd, MAX_CWND)` at end of AIMD path; existing connections recover at next loss event |
| RTT inflated by retransmit samples | LOW | Add `rtt_seq = 0` in retransmit paths; existing connections self-correct within a few RTT measurements |
| Zero-window deadlock from RTO backoff | HIGH | Requires persist timer separation; no in-place workaround |
| `processTimers` stack overflow from large `MAX_TCBS` | HIGH | Reduce `wake_list` to fixed size before increasing `MAX_TCBS`; a double fault is the diagnostic |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| `Tcb.init()`/`reset()` buffer lifecycle | Buffer resizing design (before coding) | Test: create connection, resize buffer, close -- verify no heap leak via allocator accounting |
| Window scale locked at handshake | Window management phase | Test: configure `SO_RCVBUF = 65536`, connect, verify `rcv_wscale = 1` negotiated |
| `send_tail` corruption on resize | Buffer resizing phase | Test: 4KB in-flight, resize to 16KB, verify all data received correctly |
| `cwnd` unbounded growth | Congestion control hardening | Test: long idle connection, verify `cwnd <= MAX_CWND` after 10 minutes |
| Partial ACK deflation coupling | Congestion control phase (struct isolation first) | Test: add NewReno without changing existing Reno test results |
| Karn's Algorithm missing | RTT estimation fix (before congestion control) | Test: introduce packet loss, verify RTO does not grow beyond 3x base after recovery |
| Allocation under IrqLock | Buffer resizing phase design | Code review: no `alloc()` call between `lock.acquire()` and `lock.release()` in any path that could hold IrqLock |
| `send_tail` without upper-bound check | Buffer resizing phase | Test: send crafted rogue ACK (sequence above snd_nxt), verify connection resets gracefully |
| `processTimers` wake_list stack | Any phase increasing `MAX_TCBS` | Test: 256 simultaneous connections timing out, verify no double fault |
| Persist timer missing | Window management phase | Test: fill peer buffer, pause peer reading for 30s, verify connection still alive after peer resumes |

---

## Sources

- zk codebase, verified 2026-02-19: `src/net/transport/tcp/` (types.zig, state.zig, constants.zig, rx/established.zig, tx/data.zig, timers.zig, api.zig), `src/net/transport/socket/tcp_api.zig`, `src/net/core/pool.zig`
- RFC 793: Transmission Control Protocol (state machine, sequence arithmetic)
- RFC 6298: Computing TCP's Retransmission Timer (Karn's Algorithm, section 5)
- RFC 7323: TCP Extensions for High Performance (window scale, timestamp semantics)
- RFC 5681: TCP Congestion Control (slow start, congestion avoidance, fast retransmit/recovery)
- RFC 1122: Requirements for Internet Hosts (persist timer, section 4.2.2.17)
- MEMORY.md (zk project): "Comptime Dispatch Table Expansion = Stack Overflow" pattern
- CLAUDE.md (zk project): Lock ordering table, security standards, stack size history

---

*Pitfalls research for: TCP/UDP network stack hardening milestone (zk microkernel)*
*Researched: 2026-02-19*
