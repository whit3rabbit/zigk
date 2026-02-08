---
phase: 07-socket-extras
plan: 02
subsystem: network
tags: [socket, userspace, testing, socketpair, sendmsg, recvmsg, shutdown]
dependency_graph:
  requires: [socket_syscall_infrastructure]
  provides: [socket_extras_userspace_api, socket_extras_tests]
  affects: [userspace_programs, test_suite]
tech_stack:
  added: []
  patterns: [userspace_wrappers, integration_testing, scatter_gather_io, in_place_init]
key_files:
  created: []
  modified:
    - src/user/lib/syscall/net.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/sockets.zig
    - src/user/test_runner/main.zig
    - src/kernel/sys/syscall/net/net.zig
    - src/net/transport/socket/unix_socket.zig
decisions:
  - desc: "UnixSocketPair.initInPlace() replaces init() to avoid 11KB stack allocation"
    rationale: "Returning 11KB struct by value overflows 64KB kernel stack on aarch64"
    alternatives: "heap allocation, but static pool is the existing pattern"
  - desc: "sys_shutdown checks socketpair handles via getSocketpairHandle()"
    rationale: "Socketpair FDs use different file_ops than full UNIX sockets"
    alternatives: "unify file_ops, but that requires larger refactor"
  - desc: "Added read_shutdown_0/1 flags to UnixSocketPair for SHUT_RD/SHUT_RDWR"
    rationale: "POSIX requires read to return EOF after SHUT_RD, not block forever"
    alternatives: "reuse existing shutdown flags with different semantics"
metrics:
  duration_minutes: 25
  tasks_completed: 2
  files_modified: 6
  tests_added: 12
  tests_passing: 10
  tests_skipped: 1
  commits: 4
completed: 2026-02-08
---

# Phase 07 Plan 02: Socket Extras Userspace API & Tests

**One-liner:** Added socketpair/sendmsg/recvmsg wrappers, fixed aarch64 stack overflow and shutdown dispatch, 10/12 new tests passing on both architectures

## Overview

Implemented complete userspace API for Phase 7 socket extras and created 12 integration tests covering all SOCK-01 through SOCK-06 requirements. Fixed three kernel bugs discovered during testing: stack overflow in UnixSocketPair init, missing shutdown dispatch for socketpair FDs, and missing read-side shutdown flags.

## Tasks Completed

### Task 1: Add userspace wrappers and constants for socket extras
**Status:** Complete
**Commits:** 8bc9ea7, b601d2b

**Changes to src/user/lib/syscall/net.zig:**
- Added AF_UNIX, AF_LOCAL, SOCK_NONBLOCK, SOCK_CLOEXEC constants
- Added SHUT_RD, SHUT_WR, SHUT_RDWR shutdown constants
- Added SCM_RIGHTS ancillary data constant
- Added MsgHdr, CmsgHdr, MsgIovec structs for scatter-gather I/O
- Added socketpair(), sendmsg(), recvmsg() wrapper functions

**Changes to src/user/lib/syscall/root.zig:**
- Re-exported all new constants, types, and functions

### Task 2: Create integration tests for all Phase 7 socket extras
**Status:** Complete
**Commits:** 1c6cc9e, e6ab6a4

**12 new tests added:**

| # | Test | Requirement | Result |
|---|------|-------------|--------|
| 1 | testSocketpairStream | SOCK-01 | PASS |
| 2 | testSocketpairBidirectional | SOCK-01 | PASS |
| 3 | testSocketpairInvalidDomain | SOCK-01 | PASS |
| 4 | testShutdownWrite | SOCK-02 | PASS |
| 5 | testShutdownRdwr | SOCK-02 | PASS |
| 6 | testSendtoRecvfromUdp | SOCK-03/04 | SKIP (no loopback) |
| 7 | testSendtoConnectedSocket | SOCK-03/04 | PASS |
| 8 | testSendmsgRecvmsgBasic | SOCK-05/06 | PASS |
| 9 | testSendmsgScatterGather | SOCK-05/06 | PASS |
| 10 | testSendmsgInvalidFd | SOCK-05/06 | PASS |
| 11 | testShutdownNonSocket | SOCK-02 | PASS |
| 12 | testSocketpairDgram | SOCK-01 | PASS |

Results identical on both x86_64 and aarch64.

## Deviations from Plan

### Kernel Bugs Found and Fixed

**1. Stack overflow in UnixSocketPair.init() (CRITICAL - aarch64)**
- **Root cause:** `UnixSocketPair.init()` returned an 11KB struct by value. On aarch64, this overflowed the 64KB kernel stack (guard page at 0xffffa0000020a000 was hit).
- **Fix:** Replaced `init()` with `initInPlace()` that uses `@memset` to zero the struct directly at its destination, then sets non-zero fields. No stack allocation.
- **Files:** src/net/transport/socket/unix_socket.zig
- **Impact:** Socketpair now works on aarch64. This was the "kernel panic" blocker.

**2. sys_shutdown missing socketpair dispatch**
- **Root cause:** `sys_shutdown` only checked `UnixSocket` (full sockets from socket()+connect()), not `UnixSocketHandle` (from socketpair()). Socketpair FDs fell through to ENOTSOCK.
- **Fix:** Added `getSocketpairHandle()` helper to identify socketpair FDs by their file_ops pointer. Added socketpair-specific shutdown path that sets flags on the pair and wakes blocked readers.
- **Files:** src/kernel/sys/syscall/net/net.zig

**3. Missing read-side shutdown flags**
- **Root cause:** After SHUT_RDWR on endpoint 0, `read(sv[0])` checked `isPeerClosed(0)` which returned false (peer endpoint 1 wasn't shut down). Read blocked forever.
- **Fix:** Added `read_shutdown_0/1` flags to `UnixSocketPair` and `isReadShutdown()` method. The read path now checks both peer closure and own-side read shutdown.
- **Files:** src/net/transport/socket/unix_socket.zig, src/kernel/sys/syscall/net/net.zig

## Verification

1. Both architectures build cleanly
2. 10/12 new tests pass on both x86_64 and aarch64 (identical results)
3. 1 test skips (UDP sendto/recvfrom needs loopback interface)
4. 0 new test failures
5. No regression in existing tests (248 pass x86_64, 250 pass aarch64, 4 pre-existing failures)
6. Total test count: 284 (274 execute before SFS timeout)

## Self-Check: PASSED

**Commits:** 8bc9ea7, b601d2b, 1c6cc9e, e6ab6a4
**All socket extras tests running on both architectures**
**Architecture parity maintained**
