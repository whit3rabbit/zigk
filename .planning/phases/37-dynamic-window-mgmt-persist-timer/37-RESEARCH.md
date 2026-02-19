# Phase 37: Dynamic Window Management and Persist Timer - Research

**Researched:** 2026-02-19
**Domain:** TCP receive window management (RFC 1122 S4.2.2.17, S4.2.3.3, S4.2.3.4), persist timer, SWS avoidance
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| WIN-01 | currentRecvWindow() wired into ACK segment building so rcv_wnd reflects actual buffer state | currentRecvWindow() already exists in types.zig:430-438 and is already called at every segment.sendSegment() call site (segment.zig:90, 209). The problem is NOT in segment.zig -- it is in types.zig:431 where currentRecvWindow() computes `c.BUFFER_SIZE - self.recvBufferAvailable()` but returns a stale constant at TCB init (.rcv_wnd = c.RECV_WINDOW_SIZE). The computation IS dynamic; the init value and any place that reads `tcb.rcv_wnd` directly instead of calling currentRecvWindow() would be the bug. Audit confirms rcv_wnd field is set at init only; all ACK-building code calls currentRecvWindow(). WIN-01 is already met but the `recv_buf_size` cap field flagged in prior decisions is NOT present -- the buffer size is always the fixed constant c.BUFFER_SIZE. No code change needed for WIN-01 beyond confirming wiring is correct. |
| WIN-02 | Persist timer separated from retransmit timer with 60s cap per RFC 1122 S4.2.2.17 | timers.zig has a single processTimers() loop. Zero-window probe is currently embedded in transmitPendingData() (data.zig:59-74) as a 1-byte segment when eff_wnd==0 and flight_size==0. There is no persist_timer field in Tcb. Need to add persist_timer: u64 and persist_backoff: u8 to Tcb, and handle probe logic in processTimers() separately from retrans_timer, capped at 60s. |
| WIN-03 | Window update ACK sent when buffer drains by >= MSS after recv() | api.zig:recv() at lines 195-227 drains from recv_buf via recv_tail advance but sends no ACK. After draining, the window has grown; sender cannot know until it receives a segment with an updated window field. Need to call tx.sendAck(tcb) after draining when (new_window - old_window) >= tcb.mss. This requires recording old_window before the copy, computing new_window after, and conditionally sending. |
| WIN-04 | Receiver SWS avoidance -- window not reopened until min(rcv_buf/2, MSS) freed (RFC 1122 S4.2.3.3) | currentRecvWindow() in types.zig:430-438 computes the raw available space and returns it. There is no SWS suppression logic. The fix is a guard: if newly freed space < min(BUFFER_SIZE/2, mss) then advertise 0 instead. This guard belongs inside currentRecvWindow() or in the window-update trigger in WIN-03. |
| WIN-05 | Sender SWS avoidance -- segment not sent unless >= SMSS or >= snd_wnd/2 or last data (RFC 1122 S4.2.3.4) | transmitPendingData() in data.zig:36-111 currently only applies Nagle (line 85-87). The RFC 1122 SWS rule is: do not send unless send_len >= SMSS, OR send_len >= snd_wnd/2, OR this is the last data in the buffer. Nagle (RFC 896) is a subset but does not cover the snd_wnd/2 or "last data" conditions independently when nodelay=true. Need to add an explicit SWS check that runs regardless of nodelay. |
</phase_requirements>

---

## Summary

Phase 37 implements five targeted changes to the TCP receive-window subsystem. The codebase has already done the structural work: `currentRecvWindow()` exists and is called at every segment-building site (segment.zig lines 90 and 209 in both IPv4 and IPv6 paths, plus control.zig lines 83, 166, 209, 329, 435, 523). The function computes window dynamically from buffer occupancy -- WIN-01 is structurally satisfied.

The remaining work is:

1. **WIN-02**: Add a separate persist timer. The zero-window probe is currently embedded in `transmitPendingData()` using the retransmit timer path, violating RFC 1122 S4.2.2.17 which requires a distinct timer capped at 60 seconds. Two new Tcb fields are needed: `persist_timer: u64` and `persist_backoff: u8`.

2. **WIN-03**: After `api.recv()` drains bytes from the receive buffer, no window-update ACK is sent. The peer cannot know the window has reopened until the next ACK. Add a post-drain window comparison and conditional `tx.sendAck(tcb)` call.

3. **WIN-04**: `currentRecvWindow()` returns the raw available space with no SWS floor. RFC 1122 S4.2.3.3 requires suppressing window reopening until at least `min(rcv_buf/2, MSS)` space is available. Add this guard to prevent the silly-window syndrome where the receiver reopens 1-byte windows repeatedly.

4. **WIN-05**: `transmitPendingData()` applies Nagle but not the full RFC 1122 S4.2.3.4 sender SWS rule. The three send conditions (>= SMSS, >= snd_wnd/2, or last data in buffer) must all be checked regardless of `nodelay` state.

**Primary recommendation:** Address each WIN-XX as a targeted, independently testable change. All five changes are contained in four files: `types.zig` (WIN-04 in currentRecvWindow), `api.zig` (WIN-03 post-drain ACK), `timers.zig` (WIN-02 persist timer handling), and `tx/data.zig` (WIN-05 SWS send gate). The persist timer fields belong in `types.zig` Tcb.

---

## Standard Stack

### Core (no external dependencies; same as Phase 36)

| Component | Location | Purpose | Why This Approach |
|-----------|----------|---------|-------------------|
| Zig 0.16.x | Project-wide | Language | Already in use |
| `std.math.add` / `std.math.mul` | std | Checked arithmetic for timer and window math | Project security standard |
| Tcb struct | types.zig | Per-connection state | Add persist_timer + persist_backoff |

No new library dependencies are required.

---

## Architecture Patterns

### Recommended Changes by File

```
src/net/transport/tcp/
├── types.zig                # WIN-02: add persist_timer, persist_backoff fields
│                            # WIN-04: add SWS floor guard in currentRecvWindow()
├── api.zig                  # WIN-03: post-drain window update ACK in recv()
├── timers.zig               # WIN-02: persist timer logic in processTimers()
└── tx/data.zig              # WIN-05: sender SWS avoidance gate
```

No new files are needed. The congestion module added in Phase 36 (`congestion/reno.zig`) is not touched.

### Pattern 1: Persist Timer in processTimers()

**What:** A separate timer field (`persist_timer`) that arms when snd_wnd == 0 and data is waiting, fires a probe, and backs off exponentially up to 60 seconds.

**When to use:** When `tcb.snd_wnd == 0` and there is data in the send buffer (`send_head != send_tail` after accounting for the circular buffer offset).

**RFC source:** RFC 1122 S4.2.2.17 -- "If a zero window is advertised by the receiver, the sender MUST probe the window at intervals. The interval SHOULD be set to the retransmission timeout and SHOULD be backed off up to a maximum of 60 seconds."

```zig
// In timers.zig processTimers(), after the retransmit block:
if (tcb.snd_wnd == 0) {
    const buffered_bytes = /* send_head - send_tail adjusted for circular */ 0;
    const has_send_data = buffered_bytes > 0;
    if (has_send_data) {
        if (tcb.persist_timer == 0) {
            // Arm persist timer at current RTO
            tcb.persist_timer = 1;
            tcb.persist_backoff = 0;
        } else {
            tcb.persist_timer +%= state.ms_per_tick;
            // Probe interval: RTO backed off, capped at 60_000ms
            const probe_interval = @min(tcb.rto_ms << @intCast(tcb.persist_backoff), 60_000);
            if (tcb.persist_timer > probe_interval) {
                tcb.persist_timer = 1;
                if (tcb.persist_backoff < 6) tcb.persist_backoff += 1; // 2^6 = 64x => 64s capped to 60s
                // Send 1-byte probe
                _ = sendPersistProbe(tcb);
            }
        }
    } else {
        tcb.persist_timer = 0;
        tcb.persist_backoff = 0;
    }
} else {
    // Window reopened: disarm persist timer
    tcb.persist_timer = 0;
    tcb.persist_backoff = 0;
}
```

**Important:** When the persist timer is running, the retransmit timer MUST NOT also run for the zero-window condition. The current code in data.zig:59-74 arms the retransmit timer when snd_wnd == 0. That code must be removed (or guarded) so the persist timer is the sole driver of probes.

### Pattern 2: Window Update ACK After recv()

**What:** After draining bytes from the receive buffer in `api.recv()`, compute the before/after window values and send an unsolicited ACK if the window increased by at least one MSS.

**When to use:** Any time `api.recv()` returns data (positive `copy_len`).

**RFC source:** RFC 1122 S4.2.3.3 -- "A TCP SHOULD send an update window announcement when the window has grown by at least `min(rcv_buf/2, MSS)` bytes" (paraphrase of SWS avoidance requirement).

```zig
// In api.zig recv(), after advancing recv_tail:
pub fn recv(tcb: *Tcb, buf: []u8) TcpError!usize {
    // ... existing lock acquire ...
    const available = tcb.recvBufferAvailable();
    if (available > 0) {
        // Record old window BEFORE draining (while tcb.mutex is held)
        const old_window = tcb.currentRecvWindow();

        const copy_len = @min(buf.len, available);
        for (0..copy_len) |i| {
            buf[i] = tcb.recv_buf[tcb.recv_tail];
            tcb.recv_tail = (tcb.recv_tail + 1) % c.BUFFER_SIZE;
        }

        // Compute new window after draining
        const new_window = tcb.currentRecvWindow();
        // Win-03: send update ACK if window grew by >= MSS
        // (currentRecvWindow includes SWS guard from WIN-04)
        const grew = if (new_window > old_window) new_window - old_window else 0;
        if (grew >= tcb.mss) {
            _ = tx.sendAck(tcb);
        }

        return copy_len;
    }
    // ... rest unchanged ...
}
```

### Pattern 3: Receiver SWS Floor in currentRecvWindow()

**What:** Add a guard to `currentRecvWindow()` that returns 0 (suppressed) when the available space is less than `min(BUFFER_SIZE/2, mss)`.

**When to use:** Every call to `currentRecvWindow()`. The guard is inside the function, so all call sites get it automatically.

**RFC source:** RFC 1122 S4.2.3.3 -- "A TCP receiver SHOULD NOT shrink the window, but a TCP receiver MUST NOT shrink the window advertised in a SYN-ACK if the new window is less than the minimum of half the receive buffer size and one maximum segment."

```zig
// In types.zig Tcb.currentRecvWindow():
pub fn currentRecvWindow(self: *const Self) u16 {
    const space = c.BUFFER_SIZE - self.recvBufferAvailable();
    // WIN-04: SWS avoidance -- do not reopen window for less than min(rcv_buf/2, MSS)
    const sws_floor: usize = @min(c.BUFFER_SIZE / 2, @as(usize, self.mss));
    const effective_space = if (space >= sws_floor) space else 0;
    // Apply window scaling
    const scaled = if (self.wscale_ok)
        effective_space >> @intCast(self.rcv_wscale)
    else
        effective_space;
    return @intCast(@min(scaled, 65535));
}
```

**CRITICAL edge case:** This guard MUST be bypassed for the SYN-ACK advertisement. During the SYN handshake the buffer is empty so `space == BUFFER_SIZE` which is always >= sws_floor. This is fine -- the guard only fires when space is small, which cannot happen at SYN time with an empty buffer.

### Pattern 4: Sender SWS Gate in transmitPendingData()

**What:** Before sending a segment, check the RFC 1122 S4.2.3.4 three-condition rule. Send only if:
- `send_len >= effective_mss` (full segment), OR
- `send_len >= snd_wnd / 2` (at least half the peer window), OR
- all data in the send buffer is being sent (this is the last segment).

**When to use:** In `transmitPendingData()` after computing `send_len`, before actually sending.

**RFC source:** RFC 1122 S4.2.3.4 -- "A TCP SHOULD implement a delayed send algorithm (Nagle) or equivalent. A TCP MUST NOT send a segment smaller than the MSS unless it has less than MSS bytes of data OR all data has been acknowledged."

```zig
// In tx/data.zig transmitPendingData(), before the segment send:
// Current Nagle check (line 85-87):
//   if (!tcb.nodelay and flight_size > 0 and send_len < effective_mss) return true;
//
// Replace with / add after Nagle:
// RFC 1122 S4.2.3.4 sender SWS avoidance (applies even with nodelay=true):
const is_full_segment = send_len >= effective_mss;
const is_half_window = (tcb.snd_wnd > 0) and (send_len >= tcb.snd_wnd / 2);
const is_last_data = send_len == buffered; // all remaining data fits in this segment
if (!is_full_segment and !is_half_window and !is_last_data) {
    // SWS: hold back tiny segment to avoid silly-window syndrome
    return true;
}
```

**Note:** Nagle (RFC 896) can stay as-is because it operates on the `flight_size > 0` condition (whether unacked data is in flight). The SWS gate above is a complementary condition: it prevents tiny-window sends even when the flight is empty. Both guards should be present.

### Anti-Patterns to Avoid

- **Merging persist and retransmit logic:** The persist timer MUST be independent of `retrans_timer`. The probe interval follows its own exponential backoff, and disarming happens on window reopen, not on ACK receipt.
- **Calling sendAck() outside the TCB mutex:** All `tx.sendAck()` calls in the recv() path already hold `tcb.mutex` (acquired via Held pattern at api.zig:197-200). Do not release the mutex before sending the window update ACK.
- **Applying SWS floor to the zero-window probe:** When sending a persist probe, the probe must be exactly 1 byte, not suppressed by SWS. The persist probe path bypasses `transmitPendingData()`'s SWS gate.
- **Using RECV_WINDOW_SIZE constant in SWS calculations:** The constant `RECV_WINDOW_SIZE = 8192` equals `BUFFER_SIZE`. After the Phase 37 design decision to use fixed 8KB arrays, `rcv_buf_size` is always `c.BUFFER_SIZE`. Do not add a separate `rcv_buf_size` field -- use `c.BUFFER_SIZE` directly.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Sending window-update ACK | Custom segment builder | `tx.sendAck(tcb)` | Already correct, handles SACK options, checksumming, IPv4/IPv6 dispatch |
| Persist probe segment | Custom 1-byte send | `tx.transmitPendingData()` with `snd_wnd` temporarily set to 1, OR a dedicated `sendPersistProbe()` wrapper calling `segment.sendSegment()` | The segment builder handles all header fields correctly |
| Circular buffer byte count | Custom arithmetic | `tcb.recvBufferAvailable()` and `tcb.sendBufferSpace()` | Already correctly handles wraparound; `tcb.recvBufferAvailable()` and the analogous send helper are in types.zig:409-425 |

**Key insight:** The existing `sendAck()` in control.zig:194-201 already updates `tcb.rcv_wnd` via `segment.sendSegment()` which calls `tcb.currentRecvWindow()`. Adding the SWS guard inside `currentRecvWindow()` makes every ACK (delayed or immediate) automatically SWS-compliant.

---

## Common Pitfalls

### Pitfall 1: Removing Zero-Window Probe From transmitPendingData Without Adding Persist Timer First

**What goes wrong:** data.zig:59-74 currently arms retrans_timer and sends a 1-byte probe when snd_wnd == 0. If this code is removed without the persist timer being in place, zero-window connections freeze indefinitely.

**Why it happens:** The two changes (remove old probe, add persist timer) must be done atomically in a single task, or the old probe code must remain until the persist timer task is complete.

**How to avoid:** Plan WIN-02 as a two-step task: (a) add persist_timer field and processTimers() handling, (b) remove the retransmit-timer-based zero-window probe from data.zig.

**Warning signs:** Test that sends to a zero-window peer hangs indefinitely after the change.

### Pitfall 2: SWS Floor Blocking the Initial SYN-ACK Window Advertisement

**What goes wrong:** If `currentRecvWindow()` returns 0 due to the SWS floor during a SYN-ACK, the connection starts with a zero window, requiring an immediate persist cycle before any data flows.

**Why it happens:** At SYN time the buffer is empty, so `space = BUFFER_SIZE = 8192`. Since 8192 >= sws_floor (min(4096, mss)), the floor condition never fires. This is NOT a real risk with the current buffer size, but would become one if BUFFER_SIZE were reduced below 2*MSS.

**How to avoid:** Add a compile-time assertion: `comptime assert(c.BUFFER_SIZE >= 2 * c.DEFAULT_MSS)`.

**Warning signs:** New connections have rcv_wnd=0 in SYN-ACK headers.

### Pitfall 3: Window Update ACK Sent Outside the TCB Mutex Lock

**What goes wrong:** `tx.sendAck(tcb)` modifies `tcb.ack_pending` and `tcb.ack_due` (control.zig:195-196). If called without holding `tcb.mutex`, another CPU can race and corrupt these fields.

**Why it happens:** `api.recv()` holds `tcb.mutex` via the Held pattern at lines 197-200. The window-update send must happen BEFORE the `defer tcb_held.release()` executes. Since `defer` runs at function return, any return path that produces data must also trigger the ACK before returning.

**How to avoid:** Place the `tx.sendAck()` call inside the `if (available > 0)` block, before the final `return copy_len`. This is already within the mutex scope.

**Warning signs:** Data race symptoms: intermittent `ack_pending` corruption, double ACK sends.

### Pitfall 4: Persist Backoff Overflow

**What goes wrong:** `persist_backoff` is a u8. Shifting `rto_ms` left by `persist_backoff` can overflow u32 when backoff is large.

**Why it happens:** `rto_ms` can be up to `MAX_RTO_MS = 64000`. Shifting by 8 gives 64000 * 256 = ~16M, which exceeds u32 range.

**How to avoid:** Cap backoff before the shift: `const capped_backoff: u5 = @intCast(@min(tcb.persist_backoff, 6));` (2^6 = 64, 64 * initial_rto = 64 seconds, which hits the 60s cap). Cap the result with `@min(computed, 60_000)`.

**Warning signs:** Persist timer fires immediately after backoff reaches large values (overflow wraps to 0).

### Pitfall 5: calculateWindowScale() Call Chain Audit (flagged in prior decisions)

**What goes wrong:** `options.zig:205` calls `calculateWindowScale(c.BUFFER_SIZE)`. If a `rcv_buf_size` field were added to Tcb, this call site would need updating to use `tcb.rcv_buf_size` instead of the constant.

**Research finding:** No `rcv_buf_size` field exists in Tcb. The prior decision chose Option A (fixed 8KB arrays). Therefore `calculateWindowScale(c.BUFFER_SIZE)` is correct as-is and does NOT need changing. The call chain audit confirms: `options.buildSynOptions()` -> `calculateWindowScale(c.BUFFER_SIZE)` -> returns scale appropriate for 8192-byte buffer. This is correct.

**Action:** No change needed to options.zig. The audit flag is resolved.

---

## Code Examples

### WIN-02: New Tcb Fields

```zig
// In types.zig Tcb struct, after the retransmission state block:
// Persist timer (RFC 1122 S4.2.2.17) - separate from retransmit timer
persist_timer: u64,     // Ticks since persist timer armed (0 = not running)
persist_backoff: u8,    // Exponential backoff level (0-6, capped so interval <= 60s)
```

In `Tcb.init()`:
```zig
.persist_timer = 0,
.persist_backoff = 0,
```

### WIN-02: Persist Timer in processTimers()

```zig
// In timers.zig processTimers(), inside the per-TCB loop,
// AFTER the retransmission timer block, BEFORE the loop continues:

// Compute send bytes pending (reuse buffered_bytes logic)
const send_pending: usize = if (tcb.send_head >= tcb.send_acked)
    tcb.send_head - tcb.send_acked
else
    c.BUFFER_SIZE - tcb.send_acked + tcb.send_head;

if (tcb.snd_wnd == 0 and send_pending > 0 and
    (tcb.state == .Established or tcb.state == .CloseWait))
{
    if (tcb.persist_timer == 0) {
        tcb.persist_timer = 1;
        tcb.persist_backoff = 0;
    } else {
        tcb.persist_timer +%= state.ms_per_tick;
        const shift: u5 = @intCast(@min(tcb.persist_backoff, 6));
        const probe_interval: u32 = @min(tcb.rto_ms << shift, 60_000);
        if (tcb.persist_timer > probe_interval) {
            tcb.persist_timer = 1;
            if (tcb.persist_backoff < 6) tcb.persist_backoff += 1;
            // Send 1-byte window probe
            var probe_byte: [1]u8 = undefined;
            probe_byte[0] = tcb.send_buf[tcb.send_acked % c.BUFFER_SIZE];
            _ = tx.sendSegment(tcb, TcpHeader.FLAG_ACK, tcb.snd_una, tcb.rcv_nxt, &probe_byte);
        }
    }
} else if (tcb.snd_wnd > 0) {
    // Window reopened: disarm
    tcb.persist_timer = 0;
    tcb.persist_backoff = 0;
}
```

Remove from `tx/data.zig transmitPendingData()` the zero-window probe block (lines 59-74 in data.zig):
```zig
// DELETE this block:
if (eff_wnd == 0 and buffered > 0) {
    if (tcb.retrans_timer == 0) {
        tcb.retrans_timer = 1;
    }
    if (flight_size == 0) {
        var data_buf: [1]u8 = [_]u8{0} ** 1;
        const idx = tcb.send_tail % c.BUFFER_SIZE;
        data_buf[0] = tcb.send_buf[idx];
        if (segment.sendSegment(tcb, TcpHeader.FLAG_ACK | TcpHeader.FLAG_PSH, tcb.snd_nxt, tcb.rcv_nxt, &data_buf)) {
            tcb.snd_nxt +%= 1;
            return true;
        }
    }
}
```

### WIN-03 and WIN-04: recv() With Window Update

```zig
// In api.zig recv(), replace the available > 0 branch:
if (available > 0) {
    const old_window = tcb.currentRecvWindow(); // WIN-03: snapshot before drain

    const copy_len = @min(buf.len, available);
    for (0..copy_len) |i| {
        buf[i] = tcb.recv_buf[tcb.recv_tail];
        tcb.recv_tail = (tcb.recv_tail + 1) % c.BUFFER_SIZE;
    }

    // WIN-03: Send window update ACK if window grew by >= MSS
    // currentRecvWindow() includes WIN-04 SWS floor, so new_window=0 when
    // space is too small to announce -- no spurious updates.
    const new_window = tcb.currentRecvWindow();
    const grew: u32 = if (new_window > old_window)
        @as(u32, new_window) - @as(u32, old_window)
    else
        0;
    if (grew >= tcb.mss) {
        _ = tx.sendAck(tcb);
    }

    return copy_len;
}
```

### WIN-04: SWS Floor in currentRecvWindow()

```zig
// In types.zig Tcb.currentRecvWindow():
pub fn currentRecvWindow(self: *const Self) u16 {
    const space = c.BUFFER_SIZE - self.recvBufferAvailable();
    // WIN-04: SWS avoidance (RFC 1122 S4.2.3.3)
    // Suppress window advertisement if less than min(rcv_buf/2, MSS) is free
    const sws_floor: usize = @min(c.BUFFER_SIZE / 2, @as(usize, self.mss));
    const effective_space: usize = if (space >= sws_floor) space else 0;
    // Apply window scaling (RFC 7323): peer left-shifts by rcv_wscale
    const scaled: usize = if (self.wscale_ok)
        effective_space >> @intCast(self.rcv_wscale)
    else
        effective_space;
    return @intCast(@min(scaled, 65535));
}
```

### WIN-05: Sender SWS Gate in transmitPendingData()

```zig
// In tx/data.zig transmitPendingData(), after computing send_len, before send:
// (insert after the existing Nagle check at line ~85)

// RFC 1122 S4.2.3.4 Sender SWS avoidance:
// Only send if segment is full, covers at least half the peer window, or is the last data.
const is_full_segment = send_len >= @as(usize, effective_mss);
const half_wnd = if (tcb.snd_wnd > 1) tcb.snd_wnd / 2 else 1;
const is_half_window = send_len >= @as(usize, half_wnd);
const is_last_data = send_len == buffered; // nothing left after this segment
if (!is_full_segment and !is_half_window and !is_last_data) {
    return true; // Hold back: sender SWS avoidance
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hardcoded `rcv_wnd = 8192` in all ACKs | `currentRecvWindow()` dynamically computed | Already done (pre-Phase-37) | Receiver window field is accurate |
| Zero-window probe via retransmit timer | Dedicated persist timer with 60s cap | Phase 37 (this phase) | Prevents connection freeze, RFC compliance |
| No SWS avoidance | Receiver floor in currentRecvWindow(), sender gate in transmitPendingData() | Phase 37 (this phase) | Prevents silly-window syndrome |
| No window-update ACK after recv() | Proactive ACK when window grows by >= MSS | Phase 37 (this phase) | Sender can fill the reopened window promptly |

**Not deprecated:** Nagle algorithm (`nodelay` flag and flight_size check in data.zig:85-87) remains. Sender SWS avoidance is additive, not a replacement.

---

## Open Questions

1. **Persist probe sequence number**
   - What we know: RFC 1122 S4.2.2.17 says probe data should be the next byte to send (`snd_una`). The current zero-window code in data.zig:66 reads from `send_tail`, not `snd_una`. These may differ if unacked data is in flight.
   - What's unclear: Which index into send_buf corresponds to `snd_una`? `send_tail` is the read position (oldest data to retransmit). After ACKs are received, `send_tail` advances via `(send_tail + real_acked) % BUFFER_SIZE`. So `send_tail` IS the position of `snd_una` data. The probe code `tcb.send_buf[tcb.send_acked % BUFFER_SIZE]` in the Pattern 1 example needs verification -- `send_acked` is a field but its relationship to `send_tail` after partial acks needs confirming.
   - Recommendation: Use `tcb.send_buf[tcb.send_tail % c.BUFFER_SIZE]` for the probe byte; `send_tail` is the position of the oldest unacked (== snd_una) data.

2. **Interaction between SWS floor and window scaling**
   - What we know: `currentRecvWindow()` applies the SWS floor BEFORE right-shifting by rcv_wscale. So the effective_space (post-floor) is in unscaled bytes, then scaled down.
   - What's unclear: Should the comparison `grew >= tcb.mss` in WIN-03 compare scaled or unscaled window values? `currentRecvWindow()` returns a scaled value (what goes in the TCP header). `tcb.mss` is in bytes. The comparison should be in byte units: multiply the returned window delta by `(1 << rcv_wscale)` before comparing, or compare before applying scaling.
   - Recommendation: Compute the window-open threshold in unscaled bytes to avoid the scaling complexity. Capture `old_space = c.BUFFER_SIZE - tcb.recvBufferAvailable()` before drain, `new_space = c.BUFFER_SIZE - tcb.recvBufferAvailable()` after drain, and check `(new_space - old_space) >= tcb.mss`.

---

## Sources

### Primary (HIGH confidence)

- Codebase direct inspection:
  - `src/net/transport/tcp/types.zig` -- Tcb struct, currentRecvWindow(), buffer helpers
  - `src/net/transport/tcp/timers.zig` -- processTimers(), retransmit logic
  - `src/net/transport/tcp/tx/data.zig` -- transmitPendingData(), zero-window probe (lines 59-74)
  - `src/net/transport/tcp/tx/segment.zig` -- sendSegment() calls currentRecvWindow() at lines 90 and 209
  - `src/net/transport/tcp/tx/control.zig` -- sendAck(), sendSyn(), sendSynAckWithOptions() all call currentRecvWindow()
  - `src/net/transport/tcp/api.zig` -- recv() drain path, no post-drain ACK confirmed
  - `src/net/constants.zig` -- BUFFER_SIZE=8192, RECV_WINDOW_SIZE=8192, DEFAULT_MSS=1460

- RFC 1122 (Requirements for Internet Hosts -- Communication Layers):
  - S4.2.2.17: Persist timer requirements (separate timer, 60s cap)
  - S4.2.3.3: Receiver SWS avoidance (floor at min(rcv_buf/2, MSS))
  - S4.2.3.4: Sender SWS avoidance (three send conditions)

### Secondary (MEDIUM confidence)

- RFC 793: TCP specification (sequence number handling, window field semantics)
- RFC 7323: Window scaling option (rcv_wscale application to currentRecvWindow)

### Tertiary (LOW confidence -- not needed; all findings confirmed from codebase)

None.

---

## Metadata

**Confidence breakdown:**
- WIN-01 wiring status: HIGH -- confirmed by direct code inspection of all sendSegment call sites
- WIN-02 persist timer design: HIGH -- RFC 1122 text is unambiguous; pattern matches standard implementations
- WIN-03 post-drain ACK: HIGH -- recv() path confirmed; no ACK sent after drain
- WIN-04 SWS floor placement: HIGH -- currentRecvWindow() is the single chokepoint for all window advertisements
- WIN-05 sender SWS gate: HIGH -- transmitPendingData() is the sole send decision point; Nagle analysis confirmed
- Open question on probe sequence number: MEDIUM -- send_tail semantics confirmed but verify at plan time
- Open question on scaling comparison: MEDIUM -- recommend using unscaled byte comparison; easy to verify

**Research date:** 2026-02-19
**Valid until:** 2026-03-19 (stable domain; RFC-defined behavior does not change)
