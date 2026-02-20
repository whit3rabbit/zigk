---
phase: 38-socket-options-raw-socket-blocking
plan: "02"
subsystem: network-stack
tags: [socket-options, tcp-reuseport, tcp-dispatch, load-balancing]
dependency_graph:
  requires:
    - phase: 38-01
      provides: SO_REUSEADDR infrastructure, socket option plumbing pattern
  provides: [SO_REUSEPORT bind allowance, FIFO listener dispatch via listen_accept_count]
  affects: [findListeningTcbIp, canReuseAddress, handleSynReceivedEstablished]
tech_stack:
  added: []
  patterns: [so_reuseport-first-check-in-canReuseAddress, listen_accept_count-FIFO-heuristic]
key_files:
  created: []
  modified:
    - src/net/transport/socket/types.zig
    - src/net/transport/socket/options.zig
    - src/net/transport/socket/lifecycle.zig
    - src/net/transport/socket/root.zig
    - src/net/transport/socket.zig
    - src/net/transport/tcp/types.zig
    - src/net/transport/tcp/state.zig
    - src/net/transport/tcp/rx/root.zig
key-decisions:
  - "SO_REUSEPORT check placed FIRST in canReuseAddress() as a blanket allow, bypassing all TCP-specific restrictions including the two-listeners block"
  - "listen_accept_count stored on Tcb (not Socket) to avoid cross-module import and lock ordering concerns between tcp_state.lock and socket/state.lock"
  - "listen_accept_count incremented by scanning listen_tcbs in handleSynReceivedEstablished() -- O(N) over listeners (typically 1-5), runs only on connection establishment not per-packet"
  - "findListeningTcbIp reads listen_accept_count without socket lock -- acceptable for load-balancing heuristic, slight staleness is fine"
  - "SO_REUSEPORT exported through all three layers: types.zig -> root.zig -> socket.zig matching the pattern established in Plan 01"

requirements-completed: [BUF-04]

duration: 2min
completed: 2026-02-20
---

# Phase 38 Plan 02: SO_REUSEPORT Summary

SO_REUSEPORT with FIFO connection dispatch: blanket allow in bind conflict check when both sockets have so_reuseport, with least-loaded listener selection via listen_accept_count on Tcb.

## Performance

- **Duration:** 2 minutes
- **Started:** 2026-02-20T00:27:13Z
- **Completed:** 2026-02-20T00:29:00Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments

- SO_REUSEPORT constant (value 15) and so_reuseport field added to Socket struct
- setsockopt/getsockopt handle SO_REUSEPORT in SOL_SOCKET branch
- canReuseAddress() updated: SO_REUSEPORT check is first and is a blanket allow, enabling two LISTEN sockets on the same port
- listen_accept_count field added to Tcb for FIFO dispatch (no cross-module coupling)
- findListeningTcbIp() rewritten to select listener with lowest listen_accept_count among matching listeners
- listen_accept_count incremented in handleSynReceivedEstablished() after queueAcceptConnection succeeds

## Task Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | SO_REUSEPORT field, option plumbing, and bind conflict logic | 90a5fb4 | types.zig, options.zig, lifecycle.zig, root.zig, socket.zig |
| 2 | FIFO listener dispatch in findListeningTcbIp | cdc30e2 | tcp/types.zig, tcp/state.zig, tcp/rx/root.zig |

## Files Created/Modified

- `src/net/transport/socket/types.zig` - Added SO_REUSEPORT constant (15) and so_reuseport: bool field on Socket
- `src/net/transport/socket/options.zig` - Added SO_REUSEPORT cases to setsockopt() and getsockopt()
- `src/net/transport/socket/lifecycle.zig` - canReuseAddress() rewritten with SO_REUSEPORT check first
- `src/net/transport/socket/root.zig` - Export SO_REUSEPORT via pub const
- `src/net/transport/socket.zig` - Re-export SO_REUSEPORT from root
- `src/net/transport/tcp/types.zig` - Added listen_accept_count: usize field to Tcb, initialized to 0
- `src/net/transport/tcp/state.zig` - findListeningTcbIp() rewritten for FIFO dispatch by listen_accept_count
- `src/net/transport/tcp/rx/root.zig` - Increment listen_accept_count in handleSynReceivedEstablished() after successful queueAcceptConnection

## Decisions Made

1. **SO_REUSEPORT check is FIRST in canReuseAddress()**: Placed before the SO_REUSEADDR check as a blanket allow. This means any two sockets with so_reuseport=true can share a port regardless of their TCP state (including both being in LISTEN). This is the correct POSIX behavior for SO_REUSEPORT.

2. **listen_accept_count on Tcb, not Socket**: Avoids the circular import and lock ordering concern between tcp_state.lock (level 5) and socket/state.lock (level 6). If we looked up accept_count via parent_socket in findListeningTcbIp, we would need to acquire socket_state under tcp_state.lock, violating the ordering. Storing it on Tcb avoids any cross-module lock.

3. **FIFO heuristic acceptable with stale reads**: The listen_accept_count is read in findListeningTcbIp without the socket lock -- the value may be slightly stale if another CPU is concurrently completing a connection. This is acceptable for a load-balancing heuristic; slight inaccuracy does not affect correctness.

4. **O(N) scan of listen_tcbs in handleSynReceivedEstablished**: The listen_tcbs list is typically 1-5 entries (one per SO_REUSEPORT group). The scan runs only when a connection moves from SYN_RECEIVED to ESTABLISHED, not per-packet. This is negligible overhead.

5. **SO_REUSEPORT exported through all three layers**: Following the pattern from Plan 01 (MSG_NOSIGNAL, SO_RCVBUF, etc.), the constant is exported from types.zig -> root.zig -> socket.zig.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] SO_REUSEPORT export chain (same pattern as Plan 01)**
- **Found during:** Task 1
- **Issue:** Plan 01 required fixing SO_RCVBUF/SO_SNDBUF/TCP_CORK/MSG_NOSIGNAL through the three-layer export chain. SO_REUSEPORT needed the same treatment for net.zig accessibility.
- **Fix:** Added SO_REUSEPORT to socket/root.zig and socket.zig exports alongside the Task 1 changes
- **Files modified:** src/net/transport/socket/root.zig, src/net/transport/socket.zig
- **Commit:** 90a5fb4

---

**Total deviations:** 1 auto-fixed (Rule 2 missing critical -- export chain)
**Impact on plan:** Required for SO_REUSEPORT to be accessible from syscall layer. No scope creep.

## Issues Encountered

None -- plan executed cleanly. Both architectures compiled without errors after each task.

## Verification Results

```
zig build -Darch=x86_64  -- PASS
zig build -Darch=aarch64 -- PASS

grep SO_REUSEPORT.*15 types.zig       -- FOUND: pub const SO_REUSEPORT: i32 = 15
grep so_reuseport types.zig           -- FOUND: field + init
grep so_reuseport lifecycle.zig       -- FOUND: blanket allow check first
grep listen_accept_count tcp/types.zig   -- FOUND: field + init
grep listen_accept_count tcp/state.zig   -- FOUND: FIFO selection in findListeningTcbIp
grep listen_accept_count tcp/rx/root.zig -- FOUND: increment after queueAcceptConnection
grep exact_accept tcp/state.zig       -- FOUND: FIFO comparison logic
```

## Next Phase Readiness

Phase 38 is now complete. Both plans executed:
- Plan 01: SO_RCVBUF/SO_SNDBUF/TCP_CORK/MSG_NOSIGNAL + queue size increases + blocking raw recv
- Plan 02: SO_REUSEPORT bind allow + FIFO dispatch via listen_accept_count

Ready to proceed to Phase 39.

---
*Phase: 38-socket-options-raw-socket-blocking*
*Completed: 2026-02-20*
