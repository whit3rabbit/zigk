---
phase: 40-network-code-fixes
plan: 01
subsystem: network
tags: [tcp, sockets, blocking-io, buf-size, eintr, use-after-free]

# Dependency graph
requires: []
provides:
  - "tcb.blocked_thread cleared to null before EINTR return in MSG_PEEK blocking recv"
  - "tcb.blocked_thread cleared to null before EINTR return in default TCP blocking recv"
  - "SO_RCVBUF and SO_SNDBUF values propagated from socket to TCB in all four connect paths"
affects:
  - "42-loopback-networking"
  - "43-network-integration-tests"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Re-fetch TCB via socket.getTcb() after blocking to avoid stale pointer on retry"
    - "Propagate all socket buffer options (tos, nodelay, rcv_buf_size, snd_buf_size) to TCB in connect paths"

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/net/net.zig
    - src/net/transport/socket/tcp_api.zig

key-decisions:
  - "Use socket.getTcb(ctx.socket_idx) to re-fetch TCB after sched.block() -- the TCB may have been freed during sleep so no stale pointer may be held across block()"
  - "Propagation added to all four connect paths (connect, connect6, connectAsync, connectAsync6) -- the listen() path is excluded because accepted connections inherit buffer sizes from the listening TCB, not the socket directly"

patterns-established:
  - "After sched.block(), always clear both sock_for_type.blocked_thread and tcb.blocked_thread before hasPendingSignal() check"
  - "When copying socket options to a newly created TCB in connect paths, include rcv_buf_size and snd_buf_size alongside tos and nodelay"

requirements-completed:
  - NET-01
  - NET-02

# Metrics
duration: 2min
completed: 2026-02-20
---

# Phase 40 Plan 01: Network Code Fixes Summary

**Stale tcb.blocked_thread use-after-free fixed in both TCP blocking recv paths; SO_RCVBUF/SO_SNDBUF now propagated from socket to TCB across all four connect functions**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-20T00:12:48Z
- **Completed:** 2026-02-20T00:14:35Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Fixed stale `tcb.blocked_thread` pointer in MSG_PEEK blocking recv path -- was left set after wakeup, causing use-after-free on signal-interrupted retry
- Fixed stale `tcb.blocked_thread` pointer in default TCP blocking recv path -- same root cause, same fix
- Propagated `rcv_buf_size` and `snd_buf_size` from socket to newly created TCB in `connect()`, `connect6()`, `connectAsync()`, and `connectAsync6()` -- previously these values were discarded, making SO_RCVBUF/SO_SNDBUF no-ops when set before connect()

## Task Commits

Each task was committed atomically:

1. **Task 1: Clear tcb.blocked_thread before EINTR in both TCP recv paths** - `2e9292a` (fix)
2. **Task 2: Propagate SO_RCVBUF and SO_SNDBUF from socket to TCB in connect paths** - `b9a933f` (fix)

**Plan metadata:** (docs commit to follow)

## Files Created/Modified
- `src/kernel/sys/syscall/net/net.zig` - Added `tcb.blocked_thread = null` after `sched.block()` in both blocking recv loops, using re-fetched TCB pointer via `socket.getTcb()`
- `src/net/transport/socket/tcp_api.zig` - Added `tcb.rcv_buf_size = sock.rcv_buf_size` and `tcb.snd_buf_size = sock.snd_buf_size` in `connect()`, `connect6()`, `connectAsync()`, and `connectAsync6()`

## Decisions Made
- Re-fetch the TCB via `socket.getTcb(ctx.socket_idx)` after `sched.block()` returns rather than using a pre-block TCB pointer. The TCB may have been freed during the blocking sleep (if the socket was closed by another thread), making a pre-captured pointer a use-after-free hazard.
- The `listen()` path was not modified. Accepted connections inherit buffer sizes directly from the listening TCB via the TCP handshake path, not from the socket struct -- so no propagation step is needed there.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. Both builds (x86_64 and aarch64) passed on first attempt after each change.

## Next Phase Readiness
- Both TCP defects are corrected and verified to compile on x86_64 and aarch64
- Phase 41 (cleanup) and Phase 42 (loopback networking) can proceed independently
- Phase 43 (integration tests) depends on Phase 42 being complete before network-level verification can run

---
*Phase: 40-network-code-fixes*
*Completed: 2026-02-20*

## Self-Check: PASSED
- FOUND: src/kernel/sys/syscall/net/net.zig
- FOUND: src/net/transport/socket/tcp_api.zig
- FOUND: .planning/phases/40-network-code-fixes/40-01-SUMMARY.md
- FOUND: commit 2e9292a (Task 1)
- FOUND: commit b9a933f (Task 2)
