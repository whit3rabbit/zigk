---
phase: 39-msg-flags
verified: 2026-02-20T01:00:00Z
status: passed
score: 3/3 success criteria verified
re_verification:
  previous_status: gaps_found
  previous_score: 2/3
  gaps_closed:
    - "recv() with MSG_WAITALL returns partial count or EINTR when a signal is pending during the blocking wait"
    - "recv() with MSG_PEEK on a blocking socket returns EINTR when a signal is pending during the blocking wait"
    - "recv() with MSG_WAITALL returns partial byte count (not EINTR) if any bytes were accumulated before the signal arrived"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "MSG_PEEK + MSG_DONTWAIT on empty UDP buffer returns EAGAIN"
    expected: "recvfromFlags(fd, buf, MSG_PEEK | MSG_DONTWAIT, null) returns error.WouldBlock immediately when no data is in the buffer"
    why_human: "All 5 MSG flag integration tests skip in QEMU test environment because loopback networking is not configured -- consistent with all other socket tests"
  - test: "MSG_WAITALL accumulates split TCP segments"
    expected: "If sender writes 4 bytes, yields, then writes 4 more bytes, server calling recvfromFlags(fd, buf[0..8], MSG_WAITALL, null) returns all 8 bytes in one call"
    why_human: "Current testMsgWaitallTcp only validates single-chunk delivery; split delivery requires timing control not available in current CI environment"
  - test: "SO_RCVTIMEO terminates MSG_WAITALL wait"
    expected: "After setsockopt(SO_RCVTIMEO, 100ms), MSG_WAITALL on a socket with no data returns EAGAIN within approximately 100ms"
    why_human: "Requires timing-sensitive verification in live QEMU environment with loopback configured"
---

# Phase 39: MSG Flags Verification Report

**Phase Goal:** Standard recv/send flags work correctly across TCP and UDP so protocol libraries that use MSG_PEEK, MSG_DONTWAIT, and MSG_WAITALL operate without modification
**Verified:** 2026-02-20T01:00:00Z
**Status:** passed
**Re-verification:** Yes -- after gap closure (plan 39-03, commit def5f6c)

## Goal Achievement

### Observable Truths (from ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | recv() with MSG_PEEK returns data from the receive buffer without consuming it; a subsequent recv() without MSG_PEEK returns the same data | VERIFIED | tcp/api.zig:214 uses local_tail copy; line 220 comment "Do NOT update tcb.recv_tail". peekPacketIp leaves rx_queue unmodified. sys_recvfrom MSG_PEEK branch dispatches to tcpPeek. No regression from plan 03. |
| 2 | recv() with MSG_DONTWAIT returns immediately with EAGAIN if no data is available, regardless of the socket's O_NONBLOCK state | VERIFIED | udp_api.zig:139 `is_nonblocking = !sock.blocking or ((flags & MSG_DONTWAIT) != 0)`. net.zig single non-blocking tcpRecv attempt for TCP MSG_DONTWAIT. sock.blocking field not mutated. No regression from plan 03. |
| 3 | recv() with MSG_WAITALL blocks until the full requested length is received, EOF is reached, or an error occurs; SO_RCVTIMEO and EINTR terminate the wait early | VERIFIED | tcpRecvWaitall accumulation loop and SO_RCVTIMEO check present. EINTR now implemented: scheduler.hasPendingSignal() at tcp_api.zig:557 returns partial count or WouldBlock. net.zig:646 converts WouldBlock-from-signal to EINTR. MSG_PEEK blocking loop: hasPendingSignal() at net.zig:625. Default blocking TCP recv loop: hasPendingSignal() at net.zig:668. |

**Score:** 3/3 truths verified

### Required Artifacts

#### Plan 39-01 Artifacts (previously verified -- regression check only)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/net/transport/socket/types.zig` | MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL constants; peekPacketIp method | VERIFIED | Constants at lines 75-77: MSG_PEEK=0x0002, MSG_DONTWAIT=0x0040, MSG_WAITALL=0x0100. |
| `src/net/transport/tcp/api.zig` | TCP peek function reads recv_buf without advancing recv_tail | VERIFIED | peek() at line 196; local_tail pattern at lines 214-220. |
| `src/net/transport/socket/tcp_api.zig` | tcpPeek wrapper; tcpRecvWaitall with accumulation loop | VERIFIED | tcpPeek at line 455; tcpRecvWaitall at line 509. |
| `src/net/transport/socket/udp_api.zig` | recvfromIp with flags parameter for MSG_PEEK and MSG_DONTWAIT | VERIFIED | flags: u32 parameter at line 121; MSG_DONTWAIT override at line 139. |
| `src/kernel/sys/syscall/net/net.zig` | sys_recvfrom flag parsing and dispatch to peek/dontwait/waitall paths | VERIFIED | recv_flags parsed; MSG_PEEK branch at line 598; MSG_DONTWAIT at 634; MSG_WAITALL at 640. |
| `src/user/lib/syscall/net.zig` | Userspace recvfromFlags wrapper accepting flags parameter | VERIFIED | recvfromFlags present; MSG_* constants at lines 30-32. |

#### Plan 39-02 and 39-03 Artifacts (gap closure targets -- full 3-level verification)

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/net/transport/socket/scheduler.zig` | HasPendingSignalFn type; has_pending_signal_fn storage; 4-arg setSchedulerFunctions; hasPendingSignal() accessor | VERIFIED | HasPendingSignalFn at line 13; has_pending_signal_fn at line 21; setSchedulerFunctions accepts hasPending at line 25; hasPendingSignal() accessor at lines 61-66 with safe false-default when no callback registered. |
| `src/net/transport/socket/tcp_api.zig` | Signal check in tcpRecvWaitall blocking sub-loop after block_fn() | VERIFIED | scheduler.hasPendingSignal() at line 557; returns offset (partial) or WouldBlock on signal; HLT fallback comment at lines 591-592 documents why no check is needed there. |
| `src/kernel/sys/syscall/net/net.zig` | hasPendingSignalImpl callback; 4th arg to setSchedulerFunctions; EINTR in MSG_PEEK loop; EINTR in MSG_WAITALL handler; EINTR in default TCP recv loop | VERIFIED | hasPendingSignalImpl at lines 51-53; 4-arg call at line 61; MSG_PEEK EINTR at lines 625-627; MSG_WAITALL EINTR at line 646; default recv EINTR at lines 668-670. |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `net.zig init()` | `scheduler.zig` | setSchedulerFunctions with 4th hasPendingSignalImpl arg | WIRED | Line 61: sole call site in the codebase; hasPendingSignalImpl registered as 4th callback |
| `tcp_api.zig tcpRecvWaitall` | `scheduler.hasPendingSignal()` | After block_fn() returns, before timeout check | WIRED | Line 557: `if (scheduler.hasPendingSignal())` in the WouldBlock catch arm of the scheduler-path while loop |
| `net.zig MSG_PEEK loop` | `hasPendingSignal()` | After sched.block(), before continue | WIRED | Lines 625-627: `if (hasPendingSignal()) { return error.EINTR; }` |
| `net.zig MSG_WAITALL handler` | `hasPendingSignal()` | In tcpRecvWaitall catch block | WIRED | Line 646: `if (hasPendingSignal()) return error.EINTR;` converts WouldBlock-from-signal to EINTR |
| `net.zig default TCP recv loop` | `hasPendingSignal()` | After sched.block(), before continue | WIRED | Lines 668-670: `if (hasPendingSignal()) { return error.EINTR; }` |
| `sys_recvfrom` | `udp_api.recvfromIp` | flags parameter threaded (recv_flags) | WIRED | net.zig calls recvfromIp with recv_flags; udp_api.zig:139 applies MSG_DONTWAIT override |
| `tcp.peek` | TCB recv_buf | Reads without modifying recv_tail | WIRED | api.zig:214 local_tail; line 220 explicit "Do NOT update tcb.recv_tail" comment |
| Integration tests | `syscall.recvfromFlags` | Tests call recvfromFlags with MSG_* constants | WIRED | main.zig:358-362 registers 5 tests; sockets.zig implements using recvfromFlags |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| API-01 | 39-01-PLAN.md | MSG_PEEK returns data without consuming from receive buffer for both TCP and UDP | SATISFIED | tcp.peek local_tail pattern; peekPacketIp leaves rx_queue unmodified; sys_recvfrom MSG_PEEK dispatch verified |
| API-02 | 39-01-PLAN.md | MSG_DONTWAIT provides per-call non-blocking override independent of O_NONBLOCK (returns EAGAIN if no data) | SATISFIED | udp_api.zig:139 is_nonblocking override; net.zig single non-blocking attempt for TCP; sock.blocking not mutated |
| API-03 | 39-02-PLAN.md + 39-03-PLAN.md | MSG_WAITALL blocks until full requested length received, EOF, or error (with SO_RCVTIMEO and EINTR handling) | SATISFIED | Accumulation loop, EOF break, SO_RCVTIMEO check, and EINTR check (via hasPendingSignal) all present and wired |

Note: REQUIREMENTS.md tracker still shows "Pending" for API-01, API-02, API-03. This is a documentation artifact -- the tracker was not updated after phase completion. The code fully satisfies all three requirements.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| none | -- | -- | -- | -- |

No TODOs, no placeholder returns, no stub handlers in any modified file. The docstring at tcp_api.zig:499-504 previously documented behavior that was aspirational; the implementation now matches the docstring exactly.

### Build Verification

Both architectures compile without errors or warnings:
- `zig build -Darch=x86_64`: clean
- `zig build -Darch=aarch64`: clean

### Human Verification Required

#### 1. MSG_PEEK + MSG_DONTWAIT on empty buffer returns EAGAIN

**Test:** Create a UDP receiver socket, do NOT send any data, then call `recvfromFlags(fd, buf, MSG_PEEK | MSG_DONTWAIT, null)`
**Expected:** Returns `error.WouldBlock` immediately (no blocking)
**Why human:** All 5 MSG flag integration tests skip in the current QEMU test environment because loopback networking is not configured. Human verification requires a QEMU run with E1000 NIC or loopback enabled.

#### 2. MSG_WAITALL with multi-segment TCP delivery

**Test:** TCP pair; sender writes 4 bytes, yields, writes 4 more bytes; server calls `recvfromFlags(fd, buf[0..8], MSG_WAITALL, null)`
**Expected:** Returns 8 after accumulating both segments across two tcpRecv calls in the loop
**Why human:** Current testMsgWaitallTcp only tests single-chunk delivery; split delivery requires timing control not available in automated CI.

#### 3. SO_RCVTIMEO termination of MSG_WAITALL

**Test:** `setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, 100ms)`, then call `recvfromFlags(fd, buf, MSG_WAITALL, null)` on a socket with no data
**Expected:** Returns `error.EAGAIN` within approximately 100ms
**Why human:** Requires timing-sensitive verification in live QEMU environment.

### Gap Closure Summary

The single gap from the initial verification -- EINTR not terminating MSG_WAITALL or blocking MSG_PEEK waits -- is fully closed.

Plan 39-03 (commit def5f6c) made three coordinated changes:

1. `scheduler.zig`: Added `HasPendingSignalFn` callback type, `has_pending_signal_fn` storage, extended `setSchedulerFunctions` to a 4th parameter, and added `hasPendingSignal()` public accessor with a safe false-default when no callback is registered. This keeps the transport layer decoupled from the kernel scheduler module.

2. `tcp_api.zig`: Added `scheduler.hasPendingSignal()` check at line 557, immediately after `block_fn()` returns in the tcpRecvWaitall blocking sub-loop. Returns partial byte count if offset > 0, or `SocketError.WouldBlock` if no bytes received yet. The HLT fallback path is correctly excluded from signal checks with a documented rationale (no signal delivery infrastructure without the scheduler).

3. `net.zig`: Registered `hasPendingSignalImpl()` as the 4th callback in `init()`. Added `hasPendingSignal()` checks in three locations: the MSG_PEEK blocking loop (returns EINTR), the MSG_WAITALL error handler (converts WouldBlock-from-signal to EINTR), and the default blocking TCP recv loop (returns EINTR). The conversion at the syscall boundary keeps `SocketError.WouldBlock` as the transport-layer signal and `error.EINTR` as the syscall-layer signal, maintaining layer separation.

All automated checks pass. Three human verification items remain -- all require QEMU loopback networking, which is a consistent limitation across all socket integration tests in this codebase.

---

_Verified: 2026-02-20T01:00:00Z_
_Verifier: Claude (gsd-verifier)_
