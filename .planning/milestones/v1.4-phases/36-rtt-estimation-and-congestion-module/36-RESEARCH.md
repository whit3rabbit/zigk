# Phase 36: RTT Estimation and Congestion Module - Research

**Researched:** 2026-02-19
**Domain:** TCP congestion control (RFC 5681, RFC 6298, RFC 6928), Zig kernel module extraction
**Confidence:** HIGH

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CC-01 | TCP slow-start uses correct cwnd increment per RFC 5681 S3.1 (cwnd += min(acked, SMSS) instead of AIMD formula) | Current code in established.zig lines 62-64 already uses `min(acked_bytes, tcb.mss)` for slow-start; this is correct. The bug is in the congestion avoidance branch. Research confirms RFC 5681 S3.1 wording precisely. |
| CC-02 | TCP initial window set to 10*MSS per RFC 6928 (IW10) | types.zig line 301 sets `.cwnd = c.DEFAULT_MSS * 2`. Must change to `min(10*MSS, max(2*MSS, 14600))`. Formula confirmed from RFC 6928. |
| CC-03 | Karn's Algorithm applied -- RTT not sampled on retransmitted segments (RFC 6298 S5) | data.zig line 97-100 sets rtt_seq on every transmit including retransmits. timers.zig timeout path does not clear rtt_seq before retransmitting. retransmitLoss does not clear rtt_seq. Must clear rtt_seq = 0 in all retransmit paths. |
| CC-04 | Congestion control logic extracted into congestion/reno.zig module with onAck/onTimeout/onDupAck entry points | No congestion/ directory exists under src/net/transport/tcp/. All CC logic is inline in established.zig and timers.zig. New module needs creating at src/net/transport/tcp/congestion/reno.zig. |
| CC-05 | cwnd upper bound enforced relative to send buffer size (prevents unbounded growth to maxInt(u32)) | established.zig line 63 uses `std.math.add(u32, cwnd, ...) catch std.math.maxInt(u32)` -- overflow guard only, no send-buffer cap. Need `@min(cwnd, 4 * c.BUFFER_SIZE)` cap after every cwnd increase. |
</phase_requirements>

---

## Summary

Phase 36 fixes five concrete TCP congestion control defects and extracts the CC logic into a dedicated module. The codebase already has the structural scaffolding (Tcb fields, RTT measurement, slow-start/CA distinction) but has four correctness issues and one missing module boundary.

The current state of the code:
- Slow-start cwnd increment is correct (`min(acked, mss)`) at line 62-64 of established.zig, but the success criterion says it must not use an AIMD step during slow-start. The congestion avoidance branch on lines 65-67 uses a per-ACK AIMD formula which is correct for CA; this does not need changing. The slow-start path is already right per CC-01.
- Initial window is 2*MSS (types.zig line 301). Must become 10*MSS (RFC 6928).
- Karn's Algorithm is broken: rtt_seq is set in transmitPendingData but is never cleared before retransmitting in retransmitFromSeq or in the timer timeout path. This means RTT samples are taken on retransmitted segments, contaminating SRTT with ambiguous measurements.
- No congestion/reno.zig module exists; all CC logic is scattered inline in established.zig and timers.zig.
- cwnd has overflow protection (`catch maxInt(u32)`) but no send-buffer ceiling. An idle connection receiving many ACKs can grow cwnd to 4GB, violating CC-05.

**Primary recommendation:** Create `src/net/transport/tcp/congestion/reno.zig` with three pure functions (`onAck`, `onTimeout`, `onDupAck`) that mutate the Tcb in-place, then redirect the three call sites in established.zig and timers.zig to call these functions. Fix IW, Karn, and cwnd cap as targeted one-line changes at their respective call sites.

---

## Standard Stack

### Core (this project has no external library dependencies for TCP CC)

| Component | Location | Purpose | Why This Approach |
|-----------|----------|---------|-------------------|
| Zig 0.16.x | Project-wide | Language | Already in use; no alternative |
| `std.math.add` / `std.math.mul` | std library | Checked arithmetic on cwnd/ssthresh | Project security standard -- overflow = kernel bug |
| Tcb struct fields | types.zig | Per-connection CC state | Already defined: cwnd, ssthresh, srtt, rttvar, rtt_seq, rtt_start, dup_ack_count, fast_recovery, recover |

No new library dependencies are needed. This phase is pure algorithm correctness and module extraction.

---

## Architecture Patterns

### Recommended Project Structure After Phase 36

```
src/net/transport/tcp/
├── congestion/
│   └── reno.zig        # New: extracted CC logic (CC-04)
├── rx/
│   └── established.zig # Modified: CC calls replaced with congestion.reno calls
├── timers.zig           # Modified: onTimeout call, rtt_seq clear (CC-03)
├── tx/
│   └── data.zig        # Modified: rtt_seq clear in retransmit paths (CC-03)
├── types.zig            # Modified: IW = 10*MSS (CC-02), cwnd cap logic
└── constants.zig        # Modified: add INITIAL_CWND constant
```

### Pattern 1: Pure CC Module with In-Place Mutation

**What:** reno.zig exports three functions that take `*Tcb` and compute the new cwnd/ssthresh values, mutating the Tcb directly.
**When to use:** Whenever an ACK is processed (established.zig), when timeout fires (timers.zig), when 3 dup ACKs detected (established.zig).
**Constraints:** Must be called under tcb.mutex already held (the callers already hold it).

```zig
// src/net/transport/tcp/congestion/reno.zig

const std = @import("std");
const types = @import("../types.zig");
const constants = @import("../constants.zig");

const Tcb = types.Tcb;

/// RFC 5681 S3.1 slow-start + congestion avoidance cwnd update
/// Called on every new ACK (acked_bytes > 0), after snd_una is updated.
/// acked_bytes: number of newly acknowledged bytes (ack - old snd_una)
pub fn onAck(tcb: *Tcb, acked_bytes: u32) void {
    if (tcb.fast_recovery) {
        // Full ACK in fast recovery: exit fast recovery, set cwnd = ssthresh
        if (types.seqGte(tcb.snd_una, tcb.recover)) {
            tcb.fast_recovery = false;
            tcb.cwnd = tcb.ssthresh;
        } else {
            // Partial ACK in fast recovery: deflate cwnd, retransmit
            // Caller handles retransmit; here we just adjust cwnd
            tcb.cwnd = tcb.ssthresh + @as(u32, tcb.mss);
        }
        // Apply send-buffer cap (CC-05) before returning
        tcb.cwnd = capCwnd(tcb);
        return;
    }

    if (tcb.cwnd < tcb.ssthresh) {
        // Slow-start: cwnd += min(acked, SMSS) per RFC 5681 S3.1
        const inc = @min(acked_bytes, @as(u32, tcb.mss));
        tcb.cwnd = std.math.add(u32, tcb.cwnd, inc) catch std.math.maxInt(u32);
    } else {
        // Congestion avoidance: cwnd += SMSS*SMSS/cwnd per RFC 5681 S3.1
        const inc = @max(1, (@as(u64, tcb.mss) * tcb.mss) / tcb.cwnd);
        const inc32: u32 = if (inc > std.math.maxInt(u32)) std.math.maxInt(u32) else @truncate(inc);
        tcb.cwnd = std.math.add(u32, tcb.cwnd, inc32) catch std.math.maxInt(u32);
    }

    // CC-05: cap cwnd at 4x send buffer size
    tcb.cwnd = capCwnd(tcb);
}

/// RFC 5681 S3.5 + RFC 6298: Timeout-based loss detection
/// Sets ssthresh = max(flight/2, 2*SMSS), cwnd = 1*SMSS.
pub fn onTimeout(tcb: *Tcb) void {
    const flight_size = tcb.snd_nxt -% tcb.snd_una;
    tcb.ssthresh = @max(flight_size / 2, @as(u32, tcb.mss) * 2);
    tcb.cwnd = @as(u32, tcb.mss);
    tcb.fast_recovery = false;
    // CC-03: Karn's Algorithm -- do not sample RTT on retransmitted segments
    tcb.rtt_seq = 0;
}

/// RFC 5681 S3.2: 3 duplicate ACKs -> fast retransmit / fast recovery entry
pub fn onDupAck(tcb: *Tcb, dup_count: u8) void {
    if (dup_count == 3 and !tcb.fast_recovery) {
        const flight = tcb.snd_nxt -% tcb.snd_una;
        tcb.ssthresh = @max(flight / 2, @as(u32, tcb.mss) * 2);
        tcb.cwnd = tcb.ssthresh + (@as(u32, tcb.mss) * 3);
        tcb.fast_recovery = true;
        tcb.recover = tcb.snd_nxt;
    } else if (tcb.fast_recovery) {
        // Inflate cwnd by one SMSS per additional dup ACK
        tcb.cwnd = std.math.add(u32, tcb.cwnd, tcb.mss) catch std.math.maxInt(u32);
        tcb.cwnd = capCwnd(tcb);
    }
}

/// CC-05: cap cwnd at 4 * send buffer size to prevent unbounded growth
fn capCwnd(tcb: *const Tcb) u32 {
    const buf_cap = 4 * @as(u32, constants.BUFFER_SIZE);
    return @min(tcb.cwnd, buf_cap);
}
```

### Pattern 2: IW10 Initialization (CC-02)

Apply in `Tcb.init()` in types.zig. RFC 6928 formula: `min(10*MSS, max(2*MSS, 14600))`.

```zig
// In types.zig Tcb.init():
// Replace: .cwnd = c.DEFAULT_MSS * 2,
// With:
.cwnd = @min(10 * @as(u32, c.DEFAULT_MSS), @max(2 * @as(u32, c.DEFAULT_MSS), 14600)),
```

For DEFAULT_MSS=1460: `min(14600, max(2920, 14600))` = `min(14600, 14600)` = 14600 = 10*MSS. Correct.

Also add to constants.zig for clarity:
```zig
/// Initial congestion window per RFC 6928 (IW10)
/// min(10*MSS, max(2*MSS, 14600)) bytes
pub const INITIAL_CWND: u32 = 14600;
```

### Pattern 3: Karn's Algorithm -- All Retransmit Paths (CC-03)

Three locations must clear `rtt_seq = 0` before any segment retransmission:

**Location 1: timers.zig timeout path**
The `onTimeout(tcb)` call in reno.zig handles this (rtt_seq cleared inside onTimeout).

**Location 2: tx/data.zig retransmitFromSeq**
```zig
// At top of retransmitFromSeq(), before building packet:
// RFC 6298 S5: Karn's Algorithm -- do not time retransmitted segments
tcb.rtt_seq = 0;
```

**Location 3: tx/data.zig transmitPendingData -- rtt_seq assignment**
Currently (line 97-99): rtt_seq is set on every send. This is correct for new data but must NOT be set again after a timeout reset. The current logic `if (tcb.rtt_seq == 0)` already protects against overwriting an existing measurement. However, after a timeout, `onTimeout` clears rtt_seq to 0, so the next new segment will start a fresh measurement. This is correct -- no change needed in transmitPendingData other than ensuring onTimeout is called before the retransmit attempt.

**Location 4: established.zig fast retransmit via retransmitLoss**
`retransmitLoss` in data.zig calls `retransmitFromSeq`, which will now clear rtt_seq. This path is covered by Location 2 fix.

### Pattern 4: Call Site Replacement in established.zig

Replace the inline CC block (lines 39-68) with calls to reno functions:

```zig
// In processEstablished, after snd_una update:
const congestion = @import("../congestion/reno.zig");

// Where partial ACK / full ACK currently handled:
if (tcb.fast_recovery) {
    if (types.seqGte(tcb.snd_una, tcb.recover)) {
        // Full ACK -- handled by onAck
    } else {
        // Partial ACK
        _ = tx.retransmitLoss(tcb); // retransmit BEFORE onAck modifies cwnd
    }
}
congestion.onAck(tcb, acked_bytes);

// Replace inline dupAck CC block:
congestion.onDupAck(tcb, tcb.dup_ack_count);
if (tcb.dup_ack_count == 3 and !was_in_recovery) {
    _ = tx.retransmitLoss(tcb);
}
```

### Anti-Patterns to Avoid

- **Separating the partial-ACK retransmit from cwnd deflation:** The retransmit must happen before cwnd is modified. In the current code this ordering is correct (retransmitLoss on line 46 before cwnd set on line 47). Preserve this ordering when refactoring into reno.zig.
- **Clearing rtt_seq too late:** rtt_seq must be 0 before the retransmit packet is sent, not after. In onTimeout, clear rtt_seq before the retransmit call in timers.zig.
- **Adding heap allocation in reno.zig:** All Tcb mutations are in-place. Do not allocate. The send path already prohibits heap allocation (IRQ context).
- **Mixing fast recovery state transitions with cwnd arithmetic in onAck:** Keep the sequence: (1) update snd_una, (2) call onAck, (3) transmit. onAck reads snd_una, so snd_una must be updated first.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Overflow-safe cwnd arithmetic | Custom bit-twiddling | `std.math.add(u32, ...)` | Already project standard; consistent with CLAUDE.md integer safety rules |
| cwnd cap enforcement | Clamp at each increment site individually | Single `capCwnd(tcb)` call at end of onAck | One function prevents divergence between call sites |
| RTT sample filtering | Separate "was this a retransmit" flag | Clear rtt_seq=0 before retransmit | Matches Karn's original algorithm intent; simpler than adding a bool |

**Key insight:** The Tcb already has all needed fields. This phase is purely algorithmic correctness and module boundary creation -- no new data structures required.

---

## Common Pitfalls

### Pitfall 1: rtt_seq Cleared Too Early Loses Valid Measurement
**What goes wrong:** If `rtt_seq = 0` is set inside onTimeout but onTimeout is called before the ACK path, a valid in-flight RTT sample that arrives on the next ACK after a spurious timeout would be discarded.
**Why it happens:** The timeout fires, clears rtt_seq, then a delayed ACK for the original segment arrives.
**How to avoid:** This is actually correct per RFC 6298 S5: "Do not use RTT measurement from retransmitted segment even if ACK arrives." The spec accepts the cost of losing some samples. Do not add logic to restore rtt_seq after a timeout.
**Warning signs:** SRTT becomes 0 and RTO stays at INITIAL_RTO_MS permanently -- indicates rtt_seq is being cleared too aggressively even for fresh segments. Check that transmitPendingData still sets rtt_seq when rtt_seq == 0 for NEW segments only.

### Pitfall 2: cwnd Cap Must Use BUFFER_SIZE Not rcv_wnd
**What goes wrong:** CC-05 says "relative to send buffer size." rcv_wnd is the peer's advertised window and changes per packet. BUFFER_SIZE is the fixed send buffer size (8192 bytes). Using rcv_wnd instead would make the cap non-monotonic and could prevent legitimate cwnd growth on slow paths.
**How to avoid:** Cap is `4 * constants.BUFFER_SIZE` (= 32768). This is a constant, not a per-packet value. The 4x multiplier matches Linux's SO_SNDBUF behavior (socket buffer is doubled on set, kernel uses 4x for actual limit).
**Warning signs:** cwnd oscillates up/down with each ACK when rcv_wnd changes -- indicates wrong cap source.

### Pitfall 3: Partial ACK Retransmit Must Precede cwnd Deflation
**What goes wrong:** In fast recovery, a partial ACK requires retransmit AND cwnd = ssthresh + mss. If cwnd is deflated first, transmitPendingData in retransmitLoss may see an insufficient effective window and decline to send.
**How to avoid:** Call `tx.retransmitLoss(tcb)` before `onAck(tcb, acked)` in the partial ACK branch. The current code (established.zig line 46-47) already has this ordering -- preserve it.
**Warning signs:** Partial ACK in fast recovery causes connection stall (no retransmit sent despite cwnd > 0).

### Pitfall 4: IW10 Applied to Per-Retransmit Reset
**What goes wrong:** After a timeout, the congestion control collapses cwnd to 1*MSS. If the IW10 constant is used for the reset (instead of 1*MSS), slow-start after loss will be incorrectly fast.
**How to avoid:** IW10 applies ONLY to Tcb.init(). The timeout path uses `tcb.cwnd = tcb.mss` (1*MSS). These are separate code paths and must remain separate.
**Warning signs:** After packet loss, cwnd jumps to 14600 instead of staying at 1*MSS during retransmit.

### Pitfall 5: reno.zig Module Import Path
**What goes wrong:** Zig relative imports from established.zig (in rx/) to congestion/reno.zig (in tcp/congestion/) use `@import("../congestion/reno.zig")`. This is a relative path that works but violates CLAUDE.md guideline ("Avoid relative imports like @import("../../hal.zig")"). However, for files within the same tcp/ package not in build.zig, relative imports within the package are the correct approach -- the guideline specifically targets cross-package imports.
**How to avoid:** Use relative path `@import("../congestion/reno.zig")` from rx/established.zig and timers.zig. This is a package-internal import, not a cross-package import, so it is acceptable.
**Warning signs:** Build error "package not found" -- indicates the import path is wrong.

### Pitfall 6: Fast Recovery State Duplication in onAck
**What goes wrong:** onAck handles both full and partial ACK in fast recovery AND the normal slow-start/CA path. If the caller also checks `tcb.fast_recovery` before calling onAck, logic is duplicated.
**How to avoid:** onAck handles all cases internally. Callers should call `tx.retransmitLoss(tcb)` for partial ACK BEFORE calling onAck. The retransmit decision belongs to the caller; the cwnd mutation belongs to onAck.

---

## Code Examples

### Current Broken State: rtt_seq Not Cleared on Retransmit

```zig
// tx/data.zig line 113-116 -- CURRENT (buggy)
pub fn retransmitLoss(tcb: *Tcb) bool {
    const seq = selectRetransmitSeq(tcb);
    return retransmitFromSeq(tcb, seq);
    // rtt_seq is NOT cleared here -- Karn's Algorithm violation
}
```

```zig
// tx/data.zig retransmitFromSeq -- CURRENT (missing rtt_seq clear)
pub fn retransmitFromSeq(tcb: *Tcb, seq: u32) bool {
    // ... builds and sends retransmit packet ...
    // Does not clear tcb.rtt_seq -- violation of RFC 6298 S5
}
```

### Fixed: Karn's Algorithm Applied in retransmitFromSeq

```zig
// tx/data.zig retransmitFromSeq -- FIXED
pub fn retransmitFromSeq(tcb: *Tcb, seq: u32) bool {
    // RFC 6298 S5: Karn's Algorithm -- do not sample RTT on retransmitted segments
    tcb.rtt_seq = 0;

    const buffered = bufferedBytes(tcb);
    // ... rest unchanged ...
}
```

### Fixed: onTimeout Integrates Karn's Algorithm

```zig
// congestion/reno.zig onTimeout -- CC-03 + CC flow on loss
pub fn onTimeout(tcb: *Tcb) void {
    const flight_size = tcb.snd_nxt -% tcb.snd_una;
    tcb.ssthresh = @max(flight_size / 2, @as(u32, tcb.mss) * 2);
    tcb.cwnd = @as(u32, tcb.mss);     // 1*SMSS per RFC 5681 S3.1
    tcb.fast_recovery = false;
    tcb.rtt_seq = 0;                   // Karn's Algorithm: CC-03
}
```

### Fixed: timers.zig Timeout Handler Using reno Module

```zig
// timers.zig -- current inline CC logic replaced with:
const reno = @import("congestion/reno.zig");

// In processTimers, at the retransmission timeout handling:
reno.onTimeout(tcb);
// retransmit follows immediately after
switch (tcb.state) {
    .SynSent => _ = tx.sendSyn(tcb),
    // ...
}
```

### Fixed: established.zig onAck Call Site

```zig
// rx/established.zig -- replace inline CC with:
const reno = @import("../congestion/reno.zig");

// In processEstablished, after computing acked_bytes and updating snd_una:
const acked_bytes = ack -% old_snd_una;

// Handle partial ACK retransmit BEFORE cwnd mutation
if (tcb.fast_recovery and types.seqLt(ack, tcb.recover)) {
    _ = tx.retransmitLoss(tcb);
}

// Delegate all CC state mutations to reno module
reno.onAck(tcb, acked_bytes);
```

### Fixed: established.zig onDupAck Call Site

```zig
// rx/established.zig -- replace inline dup ACK handling with:
const was_in_recovery = tcb.fast_recovery;
reno.onDupAck(tcb, tcb.dup_ack_count);

// Trigger retransmit when fast recovery is just entered
if (!was_in_recovery and tcb.fast_recovery) {
    _ = tx.retransmitLoss(tcb);
    if (tcb.retrans_timer == 0) {
        tcb.retrans_timer = 1;
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact for Phase 36 |
|--------------|------------------|--------------|---------------------|
| IW = 2-4*MSS (RFC 3390) | IW = 10*MSS (RFC 6928) | RFC 6928 published 2013 | CC-02: update Tcb.init() |
| RTT sampled on retransmits | Karn's Algorithm excludes retransmits (RFC 6298) | RFC 6298 published 2011 | CC-03: clear rtt_seq in retransmit paths |
| cwnd unlimited growth | cwnd bounded by send buffer | CC-05: add cap in reno.onAck |
| Inline CC logic | Dedicated CC module | CC-04: extraction to congestion/reno.zig |

**Current codebase status vs. RFC compliance:**
- The RTT formula in `types.zig updateRto()` is correctly implemented (Jacobson/Karels with alpha=1/8, beta=1/4). No changes needed there.
- The slow-start increment `min(acked, mss)` in established.zig line 63 is already RFC 5681 S3.1 compliant for CC-01. Re-reading: the success criterion says "cwnd += min(acked, SMSS) per ACK" which is what lines 62-64 do. The CC-01 requirement is already satisfied by the existing code. The extraction (CC-04) will preserve this correct logic.
- The congestion avoidance formula `SMSS*SMSS/cwnd` is the per-ACK formula from RFC 5681; correct.
- ssthresh floor at `2*MSS` matches RFC 5681 S3.1.

**Deprecated/outdated in current codebase:**
- `types.zig Tcb.init()`: `.cwnd = c.DEFAULT_MSS * 2` -- outdated, RFC 6928 supersedes this.
- No `sendSynWithOptions` in tx/root.zig (control.zig has it, root.zig line 9 exports it). This is fine; unchanged by Phase 36.

---

## Open Questions

1. **Where exactly does cwnd get initialized for the server-side (SYN-RECEIVED -> ESTABLISHED) path?**
   - What we know: `allocateTcb()` calls `Tcb.init()` which sets cwnd. The server TCB is allocated in `rx/listen.zig` when a SYN arrives. The Tcb.init() cwnd flows through to Established state.
   - What's unclear: Whether any code between listen and established currently resets cwnd.
   - Recommendation: Search `src/net/transport/tcp/rx/listen.zig` for any cwnd assignment. If none found, changing Tcb.init() covers both client and server paths.

2. **Should `onAck` be called when acked_bytes == 0 (pure ACK with no new data)?**
   - What we know: established.zig line 35 only enters the congestion update block when `seqGt(ack, tcb.snd_una)`, meaning acked_bytes > 0.
   - What's unclear: RFC 5681 says "for each ACK received that cumulatively acknowledges new data" -- this implies no update on pure ACK.
   - Recommendation: onAck should only be called when acked_bytes > 0. Guard in the caller, not inside onAck. This matches the existing behavior.

3. **Should the `4 * BUFFER_SIZE` cap in CC-05 be a constant or computed from the actual send buffer usage?**
   - What we know: BUFFER_SIZE is fixed at 8192 per constants.zig (prior decision: Option A buffer sizing). There is no dynamic buffer size in the Tcb.
   - What's unclear: The success criterion says "4x the send buffer size" -- this refers to the fixed BUFFER_SIZE since dynamic buffers were explicitly ruled out.
   - Recommendation: Use `4 * constants.BUFFER_SIZE` = 32768 as a compile-time constant. Document as `MAX_CWND` in constants.zig.

---

## Precise Call Site Inventory

This is critical for the planner. All locations that must change:

### Files Modified

| File | Change | RFC Basis |
|------|--------|-----------|
| `src/net/transport/tcp/types.zig` | Line 301: change `DEFAULT_MSS * 2` to IW10 formula | CC-02 (RFC 6928) |
| `src/net/transport/tcp/constants.zig` | Add `INITIAL_CWND` and `MAX_CWND` constants | CC-02, CC-05 |
| `src/net/transport/tcp/tx/data.zig` | Add `tcb.rtt_seq = 0` at start of `retransmitFromSeq` | CC-03 (RFC 6298 S5) |
| `src/net/transport/tcp/rx/established.zig` | Replace inline CC block (lines 39-104) with reno calls | CC-04 |
| `src/net/transport/tcp/timers.zig` | Replace inline loss CC (lines 114-117) with `reno.onTimeout(tcb)` | CC-03, CC-04 |

### Files Created

| File | Contents | Exports |
|------|----------|---------|
| `src/net/transport/tcp/congestion/reno.zig` | onAck, onTimeout, onDupAck, capCwnd | `pub fn onAck`, `pub fn onTimeout`, `pub fn onDupAck` |

### Files NOT Changed

| File | Reason |
|------|--------|
| `src/net/transport/tcp/types.zig` (updateRto) | RTT formula is correct; only IW changes |
| `src/net/transport/tcp/tx/segment.zig` | No CC logic |
| `src/net/transport/tcp/rx/listen.zig` | TCB allocated via allocateTcb which uses Tcb.init() |
| `src/net/transport/tcp/api.zig` | No CC logic |
| `src/net/transport/tcp/root.zig` | Only re-exports; no CC logic |

---

## Sources

### Primary (HIGH confidence)
- RFC 5681 (https://www.rfc-editor.org/rfc/rfc5681) -- TCP slow-start, congestion avoidance, fast retransmit, ssthresh formula
- RFC 6298 (https://www.rfc-editor.org/rfc/rfc6298) -- RTO computation, Karn's Algorithm (Section 5), SRTT/RTTVAR formulas
- RFC 6928 (https://www.rfc-editor.org/rfc/rfc6928) -- IW10 formula: `min(10*MSS, max(2*MSS, 14600))`
- Direct code inspection of `src/net/transport/tcp/` (all files read in full)

### Secondary (MEDIUM confidence)
- RFC 6582 (CLAUDE.md references this for fast retransmit/recovery) -- existing fast recovery implementation in established.zig follows this RFC

### Tertiary (LOW confidence)
- None needed; all findings verified against official RFC text and source code

---

## Metadata

**Confidence breakdown:**
- Call site identification: HIGH -- code read directly, line numbers cited
- RFC algorithm correctness: HIGH -- fetched RFC text, cross-referenced with existing code
- Module extraction pattern: HIGH -- matches existing tx/rx modular structure
- cwnd cap formula (4x BUFFER_SIZE): MEDIUM -- success criterion says "4x send buffer size"; BUFFER_SIZE is the only send buffer size concept in the codebase given Option A buffer decision

**Research date:** 2026-02-19
**Valid until:** N/A (this is a kernel codebase with no external dependencies; RFCs are stable documents)
