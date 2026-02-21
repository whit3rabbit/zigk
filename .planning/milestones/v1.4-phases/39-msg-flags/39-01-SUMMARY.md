---
phase: 39-msg-flags
plan: 01
subsystem: network
tags: [tcp, udp, socket, recv, msg-flags, msg-peek, msg-dontwait]

# Dependency graph
requires:
  - phase: 38-socket-opts
    provides: socket options infrastructure (SO_RCVBUF, TCP_CORK, MSG_NOSIGNAL, blocking raw recv)
provides:
  - MSG_PEEK flag support for TCP and UDP recv paths
  - MSG_DONTWAIT flag support for per-call non-blocking behavior
  - MSG_WAITALL constant defined (for future plan 39-02)
  - peekPacketIp method on Socket for UDP peek without queue consumption
  - tcp.peek() function reading recv_buf without advancing recv_tail or ACK
  - tcpPeek() socket wrapper following tcpRecv pattern
  - flags parameter threaded through recvfromIp (UDP), sys_recvfrom, sys_recvmsg
  - MSG_NOSIGNAL flag honored in sys_sendmsg TCP path (SIGPIPE suppression)
  - recvfromFlags() and recvfrom6Flags() userspace wrappers with flags parameter
  - MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL constants in userspace lib/syscall/net.zig
affects:
  - phase 39-02 (MSG_WAITALL implementation uses MSG_WAITALL constant)
  - any userspace code using recv/recvfrom with flags

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Peek-without-consume: use local tail copy for iteration, do not write back to tcb.recv_tail"
    - "Flag override pattern: MSG_DONTWAIT ORed with sock.blocking for per-call non-blocking"
    - "Three-layer re-export: types.zig -> root.zig -> socket.zig for MSG_* constants"
    - "TCP blocking loop in sys_recvfrom mirrors pattern from sys_accept"

key-files:
  created: []
  modified:
    - src/net/transport/socket/types.zig
    - src/net/transport/socket/root.zig
    - src/net/transport/socket.zig
    - src/net/transport/tcp/api.zig
    - src/net/transport/tcp/root.zig
    - src/net/transport/tcp.zig
    - src/net/transport/socket/tcp_api.zig
    - src/net/transport/socket/udp_api.zig
    - src/kernel/sys/syscall/net/net.zig
    - src/kernel/sys/syscall/net/msg.zig
    - src/user/lib/syscall/net.zig

key-decisions:
  - "MSG_DONTWAIT overrides sock.blocking for current call only -- sock.blocking field is not mutated"
  - "TCP peek uses local_tail variable copy, iterates recv_buf without writing back tcb.recv_tail"
  - "sys_recvfrom dispatches TCP and UDP paths separately (TCP uses tcpRecv/tcpPeek, UDP uses recvfromIp with flags)"
  - "TCP blocking loop in sys_recvfrom sets both tcb.blocked_thread and sock.blocked_thread for wakeup"
  - "sys_sendmsg MSG_NOSIGNAL suppresses SIGPIPE in TCP ConnectionReset path; deliverSigpipe() added to msg.zig"
  - "signals import added to msg.zig (already in syscall_net_module deps in build.zig)"
  - "recvfrom (IPv4 wrapper in udp_api.zig) is independent and unchanged; only recvfromIp updated with flags"
  - "MSG_WAITALL constant defined (0x0100) to avoid future breakage; implementation deferred to plan 39-02"

patterns-established:
  - "Peek pattern: local tail copy + iterate without writing back for both TCP and UDP"
  - "Flag threading: flags: u32 parameter added to socket layer functions, threaded from syscall to implementation"
  - "Non-blocking override: is_nonblocking = !sock.blocking or ((flags & MSG_DONTWAIT) != 0)"

requirements-completed: [API-01, API-02]

# Metrics
duration: 6min
completed: 2026-02-19
---

# Phase 39 Plan 01: MSG_PEEK and MSG_DONTWAIT Flag Support Summary

**MSG_PEEK and MSG_DONTWAIT recv flags wired end-to-end for TCP and UDP with peek-without-consume semantics and per-call non-blocking override**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-19T00:30:10Z
- **Completed:** 2026-02-19T00:36:00Z
- **Tasks:** 2
- **Files modified:** 11

## Accomplishments

- Added MSG_PEEK (0x0002), MSG_DONTWAIT (0x0040), MSG_WAITALL (0x0100) constants at every layer (kernel types, socket re-exports, userspace lib)
- Implemented TCP peek: reads recv_buf using local tail copy without advancing tcb.recv_tail or sending window update ACK
- Implemented UDP peekPacketIp: reads rx_queue front entry without consuming (rx_tail, rx_count, entry.valid unchanged)
- Threaded flags parameter through recvfromIp (UDP), sys_recvfrom (kernel, TCP+UDP dispatch), sys_recvmsg (kernel), recvfromFlags/recvfrom6Flags (userspace)
- Added MSG_NOSIGNAL awareness to sys_sendmsg TCP path suppressing SIGPIPE when flag is set

## Task Commits

1. **Task 1: Flag constants, TCP peek, UDP peek, and flags plumbing through socket layer** - `1b59e03` (feat)
2. **Task 2: Wire flags in sys_recvfrom, sys_recvmsg, and userspace recvfromFlags wrapper** - `5801032` (feat)

## Files Created/Modified

- `src/net/transport/socket/types.zig` - Added MSG_PEEK/MSG_DONTWAIT/MSG_WAITALL constants; added Socket.peekPacketIp() method
- `src/net/transport/socket/root.zig` - Re-exported MSG_* constants and tcpPeek
- `src/net/transport/socket.zig` - Re-exported MSG_* constants and tcpPeek for syscall layer
- `src/net/transport/tcp/api.zig` - Added tcp.peek() function with local tail copy semantics
- `src/net/transport/tcp/root.zig` - Exported peek from api.zig
- `src/net/transport/tcp.zig` - Re-exported peek for socket layer
- `src/net/transport/socket/tcp_api.zig` - Added tcpPeek() wrapper function
- `src/net/transport/socket/udp_api.zig` - Added flags: u32 parameter to recvfromIp; MSG_DONTWAIT and MSG_PEEK routing
- `src/kernel/sys/syscall/net/net.zig` - sys_recvfrom: parse recv_flags, dispatch TCP/UDP separately with MSG_PEEK/MSG_DONTWAIT handling
- `src/kernel/sys/syscall/net/msg.zig` - sys_sendmsg: parse send_flags, MSG_NOSIGNAL SIGPIPE suppression; sys_recvmsg: parse recv_flags, thread to TCP/UDP recv functions
- `src/user/lib/syscall/net.zig` - Added MSG_PEEK/MSG_DONTWAIT/MSG_WAITALL constants; added recvfromFlags() and recvfrom6Flags() wrappers

## Decisions Made

- MSG_DONTWAIT overrides `sock.blocking` for the current call only -- the socket's `blocking` field is not mutated, ensuring no side effects on subsequent calls without the flag.
- TCP peek implemented with a local tail variable that iterates recv_buf without writing tcb.recv_tail back. No window update ACK is sent because no data is consumed.
- sys_recvfrom now dispatches TCP and UDP paths separately rather than routing SOCK_STREAM through the UDP recvfromIp function (which only accesses the UDP rx_queue). The TCP blocking loop sets both tcb.blocked_thread and sock.blocked_thread for reliable wakeup.
- MSG_NOSIGNAL added to sys_sendmsg TCP path -- deliverSigpipe() helper added locally in msg.zig mirroring net.zig's existing helper. signals module is already in the syscall_net_module dependency graph (build.zig line 1647).
- MSG_WAITALL constant defined as 0x0100 to prevent future value collisions; implementation deferred to plan 39-02.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added tcp.peek/tcpPeek exports to tcp/root.zig, tcp.zig, socket.zig**
- **Found during:** Task 1 compilation
- **Issue:** The `tcp` module used by `tcp_api.zig` is `net.transport.tcp` (tcp.zig entrypoint), not `tcp/api.zig` directly. Similarly `socket` used by syscall layer is `net.transport.socket` (socket.zig). Neither re-exported `peek` or `tcpPeek`, causing compile errors.
- **Fix:** Added `pub const peek = api.peek;` to tcp/root.zig; `pub const peek = root.peek;` to tcp.zig; `pub const tcpPeek = root.tcpPeek;` to socket/root.zig and socket.zig.
- **Files modified:** src/net/transport/tcp/root.zig, src/net/transport/tcp.zig, src/net/transport/socket.zig
- **Committed in:** 1b59e03 (Task 1 commit)

**2. [Rule 3 - Blocking] Added MSG_PEEK/MSG_DONTWAIT/MSG_WAITALL exports to socket.zig**
- **Found during:** Task 2 compilation
- **Issue:** syscall net.zig uses `socket.MSG_PEEK` where `socket` is `net.transport.socket` (socket.zig). The constants were in types.zig and root.zig but not socket.zig.
- **Fix:** Added three MSG_* re-exports to socket.zig.
- **Files modified:** src/net/transport/socket.zig
- **Committed in:** 1b59e03 (Task 1 commit)

**3. [Rule 1 - Bug] sys_recvfrom previously routed SOCK_STREAM through UDP recvfromIp**
- **Found during:** Task 2 implementation review
- **Issue:** The original sys_recvfrom called `socket.recvfromIp` for all socket types. recvfromIp is a UDP function that accesses the rx_queue (UDP packet ring), not the TCP recv_buf. For connected TCP sockets this would always return WouldBlock since the rx_queue is empty.
- **Fix:** Added type-based dispatch in sys_recvfrom: SOCK_STREAM uses tcpRecv/tcpPeek with a blocking loop; UDP/raw uses recvfromIp with flags. The blocking loop mirrors the pattern in sys_accept.
- **Files modified:** src/kernel/sys/syscall/net/net.zig
- **Committed in:** 5801032 (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 Rule 3 blocking export gaps, 1 Rule 1 pre-existing bug in TCP/UDP dispatch)
**Impact on plan:** All fixes required for correctness. No scope creep. The TCP dispatch fix is a correctness bug fix that was latent but exposed by the refactoring.

## Issues Encountered

None beyond the deviations documented above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- MSG_PEEK and MSG_DONTWAIT are fully functional end-to-end for both TCP and UDP
- MSG_WAITALL constant is defined at 0x0100; implementation (accumulate until full or EOF) is plan 39-02
- recvfromFlags() and recvfrom6Flags() userspace wrappers ready for use by protocol libraries
- Both x86_64 and aarch64 compile cleanly with no regressions

---
*Phase: 39-msg-flags*
*Completed: 2026-02-19*
