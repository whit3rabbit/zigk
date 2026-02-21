---
phase: 40-network-code-fixes
verified: 2026-02-21T00:00:00Z
status: passed
score: 4/4 must-haves verified
re_verification: false
gaps: []
human_verification: []
---

# Phase 40: Network Code Fixes Verification Report

**Phase Goal:** All 4 network defects identified in the v1.4 audit are corrected in the codebase
**Verified:** 2026-02-21
**Status:** passed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|---------|
| 1 | tcb.blocked_thread is cleared to null before EINTR is returned in the MSG_PEEK blocking TCP recv path | VERIFIED | net.zig:624-628: after sched.block(), re-fetches TCB via getTcb() and sets tcb.blocked_thread = null before hasPendingSignal() check at line 629 |
| 2 | tcb.blocked_thread is cleared to null before EINTR is returned in the default TCP blocking recv path | VERIFIED | net.zig:671-675: same pattern -- after sched.block(), re-fetches TCB via getTcb() and sets tcb.blocked_thread = null before hasPendingSignal() check at line 676 |
| 3 | SO_RCVBUF and SO_SNDBUF set before connect() are reflected in the TCB after connect() | VERIFIED | tcp_api.zig: rcv_buf_size and snd_buf_size copied in all four connect paths (connect:218-219, connect6:334-335, connectAsync:852-853, connectAsync6:921-922) |
| 4 | TCP_CORK uncork flush holds tcb.mutex before calling transmitPendingData() | VERIFIED | options.zig:174-178: tcb_held = tcb.mutex.acquire(); defer tcb_held.release(); wraps transmitPendingData call inside the !new_cork branch |
| 5 | Raw socket recv returns WouldBlock immediately when MSG_DONTWAIT is set and no data is available | VERIFIED | raw_api.zig:129,170: is_nonblocking derived from MSG_DONTWAIT flag; line 170 checks is_nonblocking or !sock.blocking before entering blocking loop |
| 6 | Raw socket recv with MSG_PEEK returns data without consuming it from the receive queue | VERIFIED | raw_api.zig:130,148-151: is_peek derived from MSG_PEEK flag; selects peekPacketIp vs dequeuePacketIp; same pattern in recvfromRaw6 at 312,330-333 |

**Score:** 6/6 supporting truths verified (mapping to 4/4 phase success criteria)

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/kernel/sys/syscall/net/net.zig` | Stale blocked_thread pointer fix in both recv paths | VERIFIED | tcb.blocked_thread = null present at lines 627 and 674, both after sched.block() and before hasPendingSignal() |
| `src/net/transport/socket/tcp_api.zig` | Buffer size propagation in all four connect paths | VERIFIED | rcv_buf_size and snd_buf_size assignments confirmed at lines 218-219, 334-335, 852-853, 921-922 |
| `src/net/transport/socket/options.zig` | TCP_CORK uncork flush with tcb.mutex acquisition | VERIFIED | Lines 176-177: tcb_held = tcb.mutex.acquire(); defer tcb_held.release(); immediately before transmitPendingData |
| `src/net/transport/socket/raw_api.zig` | MSG_DONTWAIT and MSG_PEEK flag handling for both raw recv functions | VERIFIED | Both recvfromRaw and recvfromRaw6 derive is_nonblocking and is_peek at function entry; no _ = flags stubs remain |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| net.zig MSG_PEEK blocking path | tcb.blocked_thread | cleared after sched.block(), before hasPendingSignal() | WIRED | Lines 625-628: re-fetch via getTcb(), null assignment, then line 629 hasPendingSignal() |
| net.zig default TCP blocking path | tcb.blocked_thread | cleared after sched.block(), before hasPendingSignal() | WIRED | Lines 672-675: re-fetch via getTcb(), null assignment, then line 676 hasPendingSignal() |
| tcp_api.zig connect() | tcb.rcv_buf_size / tcb.snd_buf_size | copy from sock in connect path | WIRED | Lines 218-219: tcb.rcv_buf_size = sock.rcv_buf_size; tcb.snd_buf_size = sock.snd_buf_size |
| tcp_api.zig connect6() | tcb.rcv_buf_size / tcb.snd_buf_size | copy from sock in connect path | WIRED | Lines 334-335: same pattern |
| tcp_api.zig connectAsync() | tcb.rcv_buf_size / tcb.snd_buf_size | copy from sock in connect path | WIRED | Lines 852-853: same pattern |
| tcp_api.zig connectAsync6() | tcb.rcv_buf_size / tcb.snd_buf_size | copy from sock in connect path | WIRED | Lines 921-922: same pattern |
| options.zig TCP_CORK uncork | transmitPendingData | tcb.mutex held during call | WIRED | Lines 176-178: mutex.acquire() -> defer release() -> transmitPendingData() all inside !new_cork branch |
| raw_api.zig recvfromRaw | MSG_DONTWAIT flag check | is_nonblocking derived at line 129, used at line 170 | WIRED | Non-blocking path returns WouldBlock at line 173 before blocking loop |
| raw_api.zig recvfromRaw | MSG_PEEK flag check | is_peek derived at line 130, selects peekPacketIp at line 148 | WIRED | peekPacketIp called instead of dequeuePacketIp when is_peek is true |
| raw_api.zig recvfromRaw6 | MSG_DONTWAIT flag check | is_nonblocking derived at line 311, used at line 353 | WIRED | Same pattern as recvfromRaw |
| raw_api.zig recvfromRaw6 | MSG_PEEK flag check | is_peek derived at line 312, selects peekPacketIp at line 330 | WIRED | Same pattern as recvfromRaw |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|---------|
| NET-01 | 40-01-PLAN.md | tcb.blocked_thread cleared before EINTR in MSG_PEEK and default TCP blocking recv paths | SATISFIED | net.zig:625-628 (MSG_PEEK path), net.zig:672-675 (default path) -- null assignment after sched.block() in both loops |
| NET-02 | 40-01-PLAN.md | SO_RCVBUF/SO_SNDBUF values set before connect() propagated to Tcb | SATISFIED | tcp_api.zig: rcv_buf_size and snd_buf_size assigned in all four connect functions (connect, connect6, connectAsync, connectAsync6) |
| NET-03 | 40-02-PLAN.md | TCP_CORK uncork flush acquires tcb.mutex before calling transmitPendingData() | SATISFIED | options.zig:176-178: mutex acquired and deferred for release; transmitPendingData wrapped inside |
| NET-04 | 40-02-PLAN.md | Raw sockets support MSG_DONTWAIT and MSG_PEEK flags in recv path | SATISFIED | raw_api.zig: both recvfromRaw and recvfromRaw6 handle is_nonblocking and is_peek; no _ = flags stubs remain |

**Orphaned requirements:** None. All four NET-01 through NET-04 requirements are claimed by plans and verified in code. REQUIREMENTS.md maps exactly these four IDs to Phase 40.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | - | - | - | - |

No TODO, FIXME, XXX, HACK, or placeholder comments found in any of the four modified files. No `_ = flags` stubs remain in raw_api.zig. No `return null` or empty handler implementations detected.

### Human Verification Required

None. All four defect fixes are structural code changes verifiable by static inspection. No visual rendering, real-time behavior, or external service interaction is involved.

### Gaps Summary

No gaps. All four defects are corrected and fully wired:

- NET-01: Both blocking recv paths (MSG_PEEK and default) clear tcb.blocked_thread after sched.block() using a safe re-fetch pattern (getTcb() rather than a stale pre-block pointer) and do so before the hasPendingSignal() check that can trigger EINTR.
- NET-02: All four connect paths (connect, connect6, connectAsync, connectAsync6) copy rcv_buf_size and snd_buf_size alongside the previously-copied tos and nodelay fields. The listen() path is correctly excluded.
- NET-03: The TCP_CORK uncork flush acquires tcb.mutex with defer release, wrapping the transmitPendingData() call, consistent with all other TCB mutation paths. The misleading comment that justified skipping the mutex has been replaced with a correct explanation of the lock ordering.
- NET-04: recvfromRaw and recvfromRaw6 both derive is_nonblocking and is_peek at function entry from the flags parameter. The is_nonblocking variable is used in place of the previous !sock.blocking-only check. The is_peek variable selects peekPacketIp vs dequeuePacketIp. The _ = flags stubs are gone from both functions.

All four commits (2e9292a, b9a933f, 6184cc3, 0466e2d) confirmed present in git history.

---

_Verified: 2026-02-21_
_Verifier: Claude (gsd-verifier)_
