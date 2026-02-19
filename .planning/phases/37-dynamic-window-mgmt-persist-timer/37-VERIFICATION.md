---
phase: 37-dynamic-window-mgmt-persist-timer
verified: 2026-02-19T22:15:00Z
status: passed
score: 5/5 must-haves verified
re_verification: false
gaps: []
human_verification:
  - test: "Zero-window stall recovery"
    expected: "A connection where the receiver advertises zero window should resume data transfer within 60 seconds without requiring any application action"
    why_human: "Requires live QEMU network session with a controlled receiver that can be told to stop reading; cannot verify timer firing and probe receipt programmatically"
  - test: "SWS avoidance does not suppress window at connection open"
    expected: "SYN-ACK and first data ACKs advertise the full receive window (8192), not 0, since the buffer is empty at connection time"
    why_human: "Requires packet capture to inspect actual window fields in wire frames; code inspection confirms the math is correct but live verification is stronger"
---

# Phase 37: Dynamic Window Management and Persist Timer Verification Report

**Phase Goal:** TCP receive windows accurately reflect available buffer space and zero-window connections do not stall indefinitely
**Verified:** 2026-02-19T22:15:00Z
**Status:** passed
**Re-verification:** No -- initial verification

---

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Every ACK sent by the receiver carries the result of currentRecvWindow() rather than a hardcoded constant | VERIFIED | segment.zig:90,209 and control.zig:83,166,329,435,523,611 all call `tcb.currentRecvWindow()`. sendFin routes through segment.sendSegment which sets window at lines 90 and 209. No hardcoded window values found in any outgoing segment path. |
| 2 | When the receive buffer drains by at least one MSS, the receiver sends a window update ACK to the peer | VERIFIED | api.zig:208-230 snapshots `old_used = tcb.recvBufferAvailable()` before drain, computes `freed = old_used - new_used`, sends `tx.sendAck(tcb)` when `freed >= c.DEFAULT_MSS` (1460 bytes). |
| 3 | A persist timer fires independently of the retransmit timer with probes capped at 60-second intervals; connections do not freeze during zero-window periods | VERIFIED | timers.zig:84-136 implements a dedicated persist timer block. Mutual exclusion guard at line 102: `tcb.retrans_timer == 0`. Backoff capped at line 112: `@min(@as(u64, tcb.rto_ms) << shift, 60_000)`. Fires in Established and CloseWait states only. |
| 4 | Receiver does not reopen the window for less than min(rcv_buf/2, MSS) freed space (RFC 1122 SWS avoidance) | VERIFIED | types.zig:436-450 `currentRecvWindow()` applies `sws_floor = @min(BUFFER_SIZE/2, mss)` = min(4096, 1460) = 1460 bytes. Returns 0 when free space < 1460. Returns scaled real space when >= 1460. Safe at SYN time: empty buffer gives space=8192 > 1460. |
| 5 | Sender does not transmit a segment unless it is at least SMSS bytes, at least half the peer's window, or the last data in the buffer (RFC 1122 SWS avoidance) | VERIFIED | data.zig:73-83 adds SWS gate after Nagle check (line 69). Guards: `is_full_segment` (>= effective_mss), `is_half_window` (>= snd_wnd/2), `is_last_data` (== buffered). Returns early if none pass. |

**Score:** 5/5 truths verified

---

### Required Artifacts

| Artifact | Provides | Exists | Substantive | Wired | Status |
|----------|----------|--------|-------------|-------|--------|
| `src/net/transport/tcp/types.zig` | persist_timer/persist_backoff fields in Tcb; SWS floor in currentRecvWindow() | YES | YES (lines 241-243, 319-320, 436-450) | YES (used in timers.zig, segment.zig, control.zig) | VERIFIED |
| `src/net/transport/tcp/timers.zig` | Persist timer logic in processTimers() | YES | YES (lines 84-136, full implementation with backoff, mutual exclusion, probe send) | YES (called from kernel timer tick, imports segment.zig) | VERIFIED |
| `src/net/transport/tcp/tx/data.zig` | Removed zero-window probe; added sender SWS gate | YES | YES (old probe absent; SWS gate at lines 73-83) | YES (called from api.send() and retransmit path) | VERIFIED |
| `src/net/transport/tcp/api.zig` | Post-drain window update ACK in recv() | YES | YES (lines 207-233 with old_used/new_used/freed logic and sendAck) | YES (entry point from socket layer syscalls) | VERIFIED |

---

### Key Link Verification

| From | To | Via | Status | Evidence |
|------|----|-----|--------|---------|
| `timers.zig` | `types.zig` | `tcb.persist_timer` and `tcb.persist_backoff` fields | WIRED | timers.zig:102,105,107,108,110,111,113,115,134 reads/writes persist_timer and persist_backoff |
| `timers.zig` | `tx/segment.zig` | `segment.sendSegment()` for persist probe | WIRED | timers.zig:6 imports segment.zig; timers.zig:128 calls `segment.sendSegment(tcb, types.TcpHeader.FLAG_ACK, ...)` |
| `api.zig` | `tx/control.zig` | `tx.sendAck(tcb)` for window update | WIRED | api.zig:4 imports tx/root.zig; api.zig:229 calls `tx.sendAck(tcb)` inside recv() drain path |
| `api.zig` | `types.zig` | `tcb.recvBufferAvailable()` for unscaled space comparison | WIRED | api.zig:205,209,226 calls `tcb.recvBufferAvailable()` |
| `tx/segment.zig` | `types.zig` | `tcb.currentRecvWindow()` in every outgoing segment | WIRED | segment.zig:90,209 both call `tcb.currentRecvWindow()` |
| `tx/control.zig` | `types.zig` | `tcb.currentRecvWindow()` in all ACK/SYN/SYN-ACK paths | WIRED | control.zig:83,166,329,435,523,611 all call `tcb.currentRecvWindow()` |

---

### Requirements Coverage

Requirements claimed by plans: WIN-01, WIN-02, WIN-03, WIN-04, WIN-05. All five are defined in REQUIREMENTS.md lines 20-24 and mapped to Phase 37 in lines 88-92.

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| WIN-01 | 37-01 | currentRecvWindow() wired into ACK segment building so rcv_wnd reflects actual buffer state | SATISFIED | 8 call sites verified in segment.zig and control.zig. No hardcoded window constants in any outgoing segment path. |
| WIN-02 | 37-01 | Persist timer separated from retransmit timer with 60s cap per RFC 1122 S4.2.2.17 | SATISFIED | timers.zig:84-136. Mutual exclusion guard `retrans_timer == 0` at line 102. Cap `@min(..., 60_000)` at line 112. Backoff via shift 0-6. |
| WIN-03 | 37-02 | Window update ACK sent when buffer drains by >= MSS after recv() | SATISFIED | api.zig:208-230. Threshold is `c.DEFAULT_MSS` (1460). Uses unscaled `recvBufferAvailable()` comparison. |
| WIN-04 | 37-01 | Receiver SWS avoidance -- window not reopened until min(rcv_buf/2, MSS) freed (RFC 1122 S4.2.3.3) | SATISFIED | types.zig:438-443. Floor = min(8192/2, 1460) = 1460. Returns 0 when free < 1460. |
| WIN-05 | 37-02 | Sender SWS avoidance -- segment not sent unless >= SMSS or >= snd_wnd/2 or last data (RFC 1122 S4.2.3.4) | SATISFIED | data.zig:73-83. Three conditions checked. Returns early with comment if all fail. |

No orphaned requirements: all five WIN IDs are claimed by plans and verified in code.

---

### Anti-Patterns Found

No anti-patterns detected in modified files. Scanned:
- `src/net/transport/tcp/types.zig`
- `src/net/transport/tcp/timers.zig`
- `src/net/transport/tcp/tx/data.zig`
- `src/net/transport/tcp/api.zig`

No TODO/FIXME/PLACEHOLDER/stub returns found. All implementations are substantive.

**Note (pre-existing, not caused by Phase 37):** `tests/unit/slab_bench.zig:29` uses `std.time.Timer` removed in Zig 0.16.x. Both SUMMARYs document this. The 15/15 unit tests that do compile pass. This is a pre-existing issue unrelated to TCP window management.

---

### Build Verification

| Target | Result |
|--------|--------|
| `zig build -Darch=x86_64` | Compiles cleanly (no output, exit 0) |
| `zig build -Darch=aarch64` | Compiles cleanly (no output, exit 0) |

---

### Specific Truth-Level Checks

**Truth 1 (WIN-01): currentRecvWindow() wired everywhere**

All segment-building paths verified:
- `segment.zig:90` -- data segments (IPv4)
- `segment.zig:209` -- data segments (IPv6)
- `control.zig:83` -- sendSyn IPv4
- `control.zig:166` -- sendSynAck IPv4
- `control.zig:329` -- sendAckWithOptions IPv4
- `control.zig:435` -- sendSyn6 (IPv6)
- `control.zig:523` -- sendSynAckWithOptions6 (IPv6)
- `control.zig:611` -- sendAckWithOptions6 (IPv6)

`sendFin()` routes through `segment.sendSegment()` which sets window at segment.zig:90/209. All paths covered.

**Truth 2 (WIN-03): Window update ACK on recv() drain**

api.zig recv() (lines 207-233):
1. Snapshots `old_used = tcb.recvBufferAvailable()` BEFORE drain
2. Drains up to `copy_len` bytes
3. Recomputes `new_used = tcb.recvBufferAvailable()` AFTER drain
4. Computes `freed = old_used - new_used` with underflow guard
5. Sends `tx.sendAck(tcb)` when `freed >= c.DEFAULT_MSS` (1460)

Uses unscaled byte comparison (recvBufferAvailable) as specified. Uses `c.DEFAULT_MSS` (local receive MSS), not `tcb.mss` (peer send MSS).

**Truth 3 (WIN-02): Persist timer independent of retransmit timer**

timers.zig persist block (lines 84-136):
- Arms when: `snd_wnd == 0 AND send_pending > 0 AND retrans_timer == 0 AND (Established OR CloseWait)`
- Mutual exclusion: `retrans_timer == 0` guard is part of the arm condition
- Disarms when: `snd_wnd > 0` (window reopened by incoming ACK)
- Backoff: `shift = min(persist_backoff, 6)`, `probe_interval = min(rto_ms << shift, 60_000)`
- Probe: 1 byte from `send_buf[send_tail % BUFFER_SIZE]`, `FLAG_ACK` only (no `FLAG_PSH`)
- Timer counter: incremented with `+%=` (wrapping add) using `state.ms_per_tick`

**Truth 4 (WIN-04): Receiver SWS avoidance floor**

types.zig currentRecvWindow() (lines 436-450):
- `space = BUFFER_SIZE - recvBufferAvailable()` = free bytes in receive buffer
- `sws_floor = min(BUFFER_SIZE/2, mss)` = min(4096, 1460) = 1460 with default constants
- `effective_space = if (space >= sws_floor) space else 0`
- Apply window scaling if negotiated, clamp to u16

Corner case: At SYN time, buffer is empty so `recvBufferAvailable() = 0`, `space = 8192 > 1460` -- window is advertised correctly in SYN-ACK.

**Truth 5 (WIN-05): Sender SWS avoidance gate**

data.zig transmitPendingData() (lines 73-83):
- Placed AFTER Nagle check (line 69) and BEFORE `send_len == 0` guard (line 85)
- Ordering confirmed: Nagle at line 69, SWS gate at line 77 -- Nagle line number is lower
- `is_full_segment`: `send_len >= effective_mss`
- `is_half_window`: `send_len >= snd_wnd / 2` (uses peer's advertised window, not cwnd)
- `is_last_data`: `send_len == buffered`
- Returns `true` (hold, caller can retry) if none of the three conditions pass

---

### Human Verification Required

#### 1. Zero-Window Stall Recovery

**Test:** Set up a TCP connection between two QEMU instances. Have the receiver stop calling recv() until the send buffer fills and a zero-window is advertised. Verify that the sender's persist timer fires probes visible in a packet capture, and that when the receiver resumes reading, normal data flow resumes without a connection reset.

**Expected:** Persist probes visible at ~RTO intervals with exponential backoff; first probe within 1-2 seconds, subsequent probes at 2s, 4s, 8s, up to 60s cap. Data flow resumes immediately when receiver opens window.

**Why human:** Requires live network session in QEMU with controlled receive-side pacing. Cannot verify timer tick behavior or actual probe packet transmission from static code inspection alone.

#### 2. SWS Avoidance Does Not Suppress Window at Connection Open

**Test:** Capture SYN-ACK and first post-handshake ACK packets for a new TCP connection and inspect the window field. It should reflect the full receive buffer size (8192, or 8192 >> rcv_wscale if scaling is negotiated), not 0.

**Expected:** Window field in SYN-ACK is non-zero (full buffer available at connection open).

**Why human:** Code inspection confirms the SWS floor math is correct (empty buffer gives space=8192 > sws_floor=1460), but a wire-level packet capture provides stronger assurance that no regression was introduced.

---

### Gaps Summary

No gaps found. All five WIN requirements are implemented, substantive, and wired. Both architectures compile cleanly. The four commits (a8bcffa, e9f21d9, cac3554, 3897d88) are verified present in git history.

Two human verification items are flagged for behavioral testing that cannot be confirmed from static code inspection, but all automated checks pass.

---

_Verified: 2026-02-19T22:15:00Z_
_Verifier: Claude (gsd-verifier)_
