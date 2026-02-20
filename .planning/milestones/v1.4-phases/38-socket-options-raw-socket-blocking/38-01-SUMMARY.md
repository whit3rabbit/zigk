---
phase: 38-socket-options-raw-socket-blocking
plan: "01"
subsystem: network-stack
tags: [socket-options, tcp-cork, raw-sockets, sigpipe, buffer-management]
dependency_graph:
  requires: [phase-37-recv-window]
  provides: [SO_RCVBUF, SO_SNDBUF, TCP_CORK, MSG_NOSIGNAL, raw-socket-blocking-recv]
  affects: [currentRecvWindow, sendBufferSpace, transmitPendingData, recvfromRaw, sys_sendto, socketWrite]
tech_stack:
  added: [signals import in syscall_net_module]
  patterns: [blocking-loop-release-before-sleep, effective-buf-cap, sentinel-slot-preservation]
key_files:
  created: []
  modified:
    - src/net/transport/socket/types.zig
    - src/net/transport/socket/options.zig
    - src/net/transport/socket/root.zig
    - src/net/transport/socket.zig
    - src/net/transport/socket/raw_api.zig
    - src/net/transport/tcp/types.zig
    - src/net/transport/tcp/tx/data.zig
    - src/kernel/sys/syscall/net/net.zig
    - build.zig
decisions:
  - "sendBufferSpace() sentinel slot preserved (-1) when applying snd_buf_size cap to prevent head==tail ambiguity in circular buffer"
  - "sws_floor uses effective_buf (not c.BUFFER_SIZE) in currentRecvWindow() -- prevents zero-window stall when rcv_buf_size < BUFFER_SIZE/2"
  - "recvfromRaw blocking loop validates sock_type before loop via initial check, avoiding re-check under lock on every iteration"
  - "signals import added to syscall_net_module in build.zig for SIGPIPE delivery from sys_sendto and socketWrite"
  - "MSG_NOSIGNAL and new socket option constants exported through all three layers: types.zig -> root.zig -> socket.zig"
metrics:
  duration: "7 minutes"
  completed_date: "2026-02-20"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 9
---

# Phase 38 Plan 01: Socket Options and Raw Socket Blocking Summary

One-liner: SO_RCVBUF/SO_SNDBUF buffer size options with effective_buf cap in TCP window math, TCP_CORK gate in transmit path, blocking recv loop for raw sockets, and MSG_NOSIGNAL/SIGPIPE delivery in sys_sendto and socketWrite.

## Tasks Completed

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Buffer size fields, constants, queue sizes, option plumbing | f31b29d | types.zig, tcp/types.zig, options.zig |
| 2 | TCP_CORK gate, raw socket blocking recv, MSG_NOSIGNAL | 5a6d93a | tx/data.zig, raw_api.zig, net.zig, build.zig |

## Decisions Made

1. **sendBufferSpace() sentinel slot preserved**: When applying `snd_buf_size` cap, the `used + 1 >= limit` check preserves the one-slot sentinel that prevents head==tail ambiguity in the circular buffer. The physical `c.BUFFER_SIZE` modular arithmetic is unchanged; only the space report is capped.

2. **sws_floor uses effective_buf**: In `currentRecvWindow()`, the SWS avoidance floor is computed as `min(effective_buf/2, mss)` where `effective_buf` is capped by `rcv_buf_size`. If the floor used `c.BUFFER_SIZE/2` with a small cap (e.g., 1024 bytes), the floor (4096) would exceed the cap and always produce window=0 (Pitfall 2 from research).

3. **Raw socket blocking loop**: `recvfromRaw` and `recvfromRaw6` do a one-time sock_type validation before entering the loop, then loop with explicit lock management. Locks are released BEFORE calling `block_fn()` to prevent deadlock -- matching the accept() pattern in tcp_api.zig.

4. **signals import in build.zig**: The `syscall_net_module` (net.zig) required a `signals` import to call `deliverSignalToThread()` for SIGPIPE. Added `syscall_net_module.addImport("signals", syscall_signals_module)`.

5. **Constants exported through all three layers**: New constants (MSG_NOSIGNAL, SO_RCVBUF, SO_SNDBUF, TCP_CORK) added to `socket/types.zig`, re-exported from `socket/root.zig`, and then again from `socket.zig` (the top-level entrypoint used by net.zig).

## Implementation Details

### Task 1: Buffer Size Fields, Constants, Queue Sizes, Option Plumbing

**`src/net/transport/socket/types.zig`:**
- Added `TCP_CORK: i32 = 3`, `SO_SNDBUF: i32 = 7`, `SO_RCVBUF: i32 = 8`, `MSG_NOSIGNAL: u32 = 0x4000`
- Increased `SOCKET_RX_QUEUE_SIZE` from 8 to 64
- Increased `ACCEPT_QUEUE_SIZE` from 8 to 128
- Added `tcp_cork: bool`, `rcv_buf_size: u32`, `snd_buf_size: u32` fields to `Socket` struct
- Initialized all new fields to zero/false in `Socket.init()`

**`src/net/transport/tcp/types.zig`:**
- Added `rcv_buf_size: u32`, `snd_buf_size: u32`, `tcp_cork: bool` fields to `Tcb` struct
- Initialized all new fields in `Tcb.init()`
- Added `sendBufferLimit()` helper method
- Modified `sendBufferSpace()` to use `sendBufferLimit()` with sentinel preservation
- Modified `currentRecvWindow()` to compute `effective_buf` from `rcv_buf_size` and use it for both space calculation and sws_floor

**`src/net/transport/socket/options.zig`:**
- Added `std` and `tcp_constants` imports
- Added `SO_RCVBUF` and `SO_SNDBUF` cases to `setsockopt()` (clamp to BUFFER_SIZE, min 256, propagate to TCB)
- Added `TCP_CORK` case to `setsockopt()` (propagate to TCB, flush via `transmitPendingData()` on uncork)
- Added `SO_RCVBUF` and `SO_SNDBUF` cases to `getsockopt()` (return 2x stored value per Linux ABI)
- Added `TCP_CORK` case to `getsockopt()`

### Task 2: TCP_CORK Gate, Raw Socket Blocking Recv, MSG_NOSIGNAL

**`src/net/transport/tcp/tx/data.zig`:**
- Added TCP_CORK gate after Nagle check in `transmitPendingData()`: holds sub-MSS segments unconditionally until full MSS or cork cleared

**`src/net/transport/socket/raw_api.zig`:**
- Rewrote `recvfromRaw()` to use blocking loop pattern: one-time type validation, then loop with explicit lock acquire/release, sleep via `block_fn()` after releasing all locks
- Rewrote `recvfromRaw6()` identically for IPv6
- Removed TODO comments -- blocking is now implemented

**`src/kernel/sys/syscall/net/net.zig`:**
- Added `signals_mod` import
- Changed `_ = flags;` in `sys_sendto()` to `const send_flags: u32 = @truncate(flags);`
- Wrapped IPv4 and IPv6 `sendto()` calls with SIGPIPE delivery on `ConnectionReset` unless `MSG_NOSIGNAL` set
- Updated `socketWrite()` to deliver SIGPIPE unconditionally on `ConnectionReset` per POSIX (write() has no flags)
- Added `shouldDeliverSigpipe()` and `deliverSigpipe()` helper functions

**`build.zig`:**
- Added `syscall_net_module.addImport("signals", syscall_signals_module)` so net.zig can deliver SIGPIPE

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] MSG_NOSIGNAL export chain required fixing three files**
- **Found during:** Task 2
- **Issue:** `socket.MSG_NOSIGNAL` in net.zig was unresolved because the constant was defined in `socket/types.zig` but only exported through `socket/root.zig` -- not through the top-level `socket.zig` entrypoint used by net.zig
- **Fix:** Added exports of MSG_NOSIGNAL, SO_RCVBUF, SO_SNDBUF, TCP_CORK to both `socket/root.zig` and `socket.zig`
- **Files modified:** `src/net/transport/socket/root.zig`, `src/net/transport/socket.zig`
- **Commit:** 5a6d93a

## Verification Results

```
zig build -Darch=x86_64  -- PASS
zig build -Darch=aarch64 -- PASS

grep SO_RCVBUF types.zig          -- FOUND: pub const SO_RCVBUF: i32 = 8
grep ACCEPT_QUEUE_SIZE.*128 types.zig -- FOUND: pub const ACCEPT_QUEUE_SIZE: usize = 128
grep effective_buf tcp/types.zig  -- FOUND: 3 matches in currentRecvWindow()
grep tcp_cork tx/data.zig         -- FOUND: line 77
grep block_fn raw_api.zig         -- FOUND: lines 171, 172, 181, 348, 349, 358
grep MSG_NOSIGNAL net.zig         -- FOUND: lines 2062, 2065
```

## Self-Check: PASSED

All modified files exist on disk. Both commits (f31b29d, 5a6d93a) verified in git log. Both architectures compile cleanly.
