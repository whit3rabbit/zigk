---
phase: 42-qemu-loopback-setup
plan: 01
subsystem: network
tags: [loopback, tcp, udp, networking, socket, tick-callback, scheduler, checksum, byte-order]

# Dependency graph
requires:
  - phase: 40-network-code-fixes
    provides: Fixed TCP/UDP socket layer, MSG_DONTWAIT, MSG_PEEK, MSG_WAITALL, TCP_CORK
provides:
  - Loopback interface (lo0 at 127.0.0.1) initialized at kernel boot on both x86_64 and aarch64
  - Full network stack (socket subsystem, TCP, IPv4, ARP, packet pool) active at boot
  - net.tick() called from scheduler tick on both architectures via combinedTickCallback
  - TCP timer-driven operations (retransmission, keepalive) work via loopback
  - All network checksum TX paths produce correct byte-order checksums
  - TCP 3-way handshake completes over loopback (SYN_SENT state machine fixed)
  - UDP sendto/recvfrom works over loopback (RX verification fixed)
affects:
  - 43-socket-test-verification
  - Any phase relying on TCP/UDP loopback networking

# Tech tracking
tech-stack:
  added: []
  patterns:
    - combinedTickCallback pattern: single tick_callback slot shared by net.tick() and USB polling (aarch64)
    - loopback-first init: loopback and full stack initialized before PCI/NIC enumeration so loopback works regardless of hardware
    - async loopback: queue-based deferred processing prevents TX->RX re-entrant deadlocks

key-files:
  created: []
  modified:
    - src/kernel/core/init_hw.zig
    - src/net/drivers/loopback.zig
    - src/net/ipv4/ipv4/transmit.zig
    - src/net/ipv4/ipv4/process.zig
    - src/net/ipv4/arp/packet.zig
    - src/net/transport/tcp/tx/control.zig
    - src/net/transport/tcp/tx/segment.zig
    - src/net/transport/tcp/rx/root.zig
    - src/net/transport/udp.zig
    - src/net/transport/icmp.zig
    - src/net/transport/socket/tcp_api.zig
    - src/net/transport/socket/raw_api.zig
    - src/net/root.zig
    - src/net/ipv6/icmpv6/transmit.zig
    - src/net/ipv6/icmpv6/types.zig
    - src/net/ipv6/ipv6/transmit.zig
    - src/net/ipv6/ndp/transmit.zig
    - src/net/ipv6/ndp/types.zig

key-decisions:
  - "Initialize loopback and full net stack unconditionally in initNetwork() before PCI enumeration"
  - "Replace usbPollTickCallback with combinedTickCallback that runs net.tick() on both architectures plus USB poll on aarch64 only"
  - "Make loopback async (queue + drain) to prevent re-entrant deadlocks from TX->RX->TX calling state.lock recursively"
  - "Apply @byteSwap to all checksum stores because onesComplement() computes in big-endian but struct fields store in native endian"
  - "Handle SYN_SENT before sequence number acceptability check because rcv_nxt=0 in SYN_SENT rejects random ISN"
  - "Skip mDNS init -- mdns.tick() cannot run from ISR context (acquires socket locks)"

patterns-established:
  - "combinedTickCallback: single scheduler tick slot covers all periodic subsystems (net + USB)"
  - "Async loopback: queue IP packets in loopbackTransmit, process in drain() from timer tick with MAX_DRAIN_PER_TICK safety limit"
  - "Checksum byte-order: all TX checksum stores must use @byteSwap(checksum.*Checksum(...)) because extern struct fields are native-endian"
  - "TCP blocked_thread: set BOTH sock.blocked_thread AND tcb.blocked_thread when blocking on TCP recv"

requirements-completed: [TST-01]

# Metrics
duration: 4h
completed: 2026-02-21
---

# Phase 42 Plan 01: QEMU Loopback Setup Summary

**Loopback interface lo0 (127.0.0.1/8) initialized at kernel boot with full TCP/IP stack, async packet queue, and all checksum/state-machine bugs fixed. Tests pass on both x86_64 (416/430) and aarch64 (413/429).**

## Performance

- **Duration:** ~4 hours (initial wiring 45min + bug fixing ~3h)
- **Started:** 2026-02-21T19:47:00Z
- **Completed:** 2026-02-21T23:30:00Z
- **Tasks:** 3 (original plan) + 10 bug fixes
- **Files modified:** 22

## Accomplishments

### Initial Wiring (commit 7b71fda)
- Replaced `net.transport.initSyscallOnly()` with `net.loopback.init()` + `net.init()` in `initNetwork()`
- Added `combinedTickCallback()` for `net.tick()` on both architectures
- Registered callback in all return paths of `initNetwork()`

### Bug Fixes (commit dbc1242)
Enabling loopback exposed 10 pre-existing bugs in the network stack:

1. **Checksum byte-order** -- All TX checksum stores (IP, TCP, UDP, ICMP) used native-endian but verification reads big-endian. Applied `@byteSwap()` to all stores across 6 files.
2. **UDP RX verification** -- Used field comparison instead of standard `calc_checksum != 0xFFFF` recomputation check.
3. **TCP SYN_SENT state machine** -- Sequence acceptability check ran before SYN_SENT handler; `rcv_nxt=0` rejected SYN-ACK's random ISN, causing ACK storm.
4. **RST in SYN_SENT** -- `processSynSent()` ignores RST packets; added RST check before calling it.
5. **Double-free on connection refused** -- RST handler freed TCB but `sock.tcb` retained dangling pointer.
6. **MSG_WAITALL blocked forever** -- Only set `sock.blocked_thread`, not `tcb.blocked_thread`. TCP RX wakes `tcb.blocked_thread`.
7. **ARP for 127.x.x.x** -- `resolveUnlocked` sent ARP requests for loopback addresses nobody answers.
8. **Loopback re-entrant deadlock** -- Made loopback async with queue-based deferred processing.
9. **mDNS in ISR context** -- Skipped mDNS init (acquires socket locks, incompatible with ISR).
10. **Align(1) pointer casts** -- Fixed potentially unaligned casts in IPv6/NDP/ICMPv6/ARP paths.

## Task Commits

1. **Loopback wiring** -- `7b71fda` (feat)
2. **Bug fixes** -- `dbc1242` (fix)
3. **Plan metadata** -- `eb08349` (docs)

## Files Created/Modified

22 files total. Key changes:
- `src/net/drivers/loopback.zig` -- Async queue-based design with drain limit
- `src/net/transport/tcp/rx/root.zig` -- SYN_SENT early handling before acceptability check
- `src/net/transport/tcp/tx/control.zig` -- Checksum byte-order fixes (8 stores)
- `src/net/transport/socket/tcp_api.zig` -- Double-free fix, MSG_WAITALL tcb.blocked_thread fix
- `src/net/transport/udp.zig` -- Checksum stores + RX verification fix
- `src/net/ipv4/ipv4/transmit.zig` -- IP checksum byte-order fix
- `src/net/ipv4/arp/packet.zig` -- Loopback ARP short-circuit

## Test Results

**x86_64:** 416 PASS, 14 FAIL, 9 SKIP (all failures pre-existing)
**aarch64:** 413 PASS, 16 FAIL, 10 SKIP (all failures pre-existing)

All socket/network tests pass on both architectures:
- `sendto/recvfrom udp` -- UDP loopback
- `connect to unbound port` -- TCP RST handling
- `MSG_PEEK TCP/UDP` -- peek-without-consume
- `MSG_WAITALL TCP` -- accumulation
- `MSG_DONTWAIT` -- non-blocking returns EAGAIN
- `listen on socket` -- bind/listen on 127.0.0.1
- `shutdown write/rdwr` -- TCP teardown

## Deviations from Plan

The plan covered loopback initialization wiring only. The extensive bug fixing was unplanned but necessary -- the bugs were pre-existing in the network stack but never triggered because no TX path produced packets that re-entered the same kernel's RX path.

## Next Phase Readiness
- Loopback networking fully functional on both architectures
- Phase 43 (socket test verification) goals are already achieved -- all socket tests pass
- No known blockers

---
*Phase: 42-qemu-loopback-setup*
*Completed: 2026-02-21*
