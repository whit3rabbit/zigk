---
phase: 42-qemu-loopback-setup
verified: 2026-02-21T23:30:00Z
status: passed
score: 3/3 success criteria verified
gaps:
human_verification:
---

# Phase 42: QEMU Loopback Setup Verification Report

**Phase Goal:** The QEMU test environment has functional loopback networking on both x86_64 and aarch64, enabling guest-internal TCP/UDP connections
**Verified:** 2026-02-21T23:30:00Z
**Status:** passed
**Re-verification:** Yes -- re-verified after dbc1242 fixed checksum, TCP state machine, and loopback bugs

## Goal Achievement

### Observable Truths (from PLAN must_haves)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Loopback interface (lo0) is initialized with IP 127.0.0.1 at kernel boot on both x86_64 and aarch64 | VERIFIED | `net.loopback.init()` called in `init_hw.zig`, unconditionally before any RSDP/PCI checks. Loopback driver sets `ip_addr=0x7F000001`, `netmask=0xFF000000`, `is_up=true`, `link_up=true`. |
| 2 | TCP listen on 127.0.0.1 succeeds (no NetworkDown error) | VERIFIED | `net.init()` calls `transport.initSockets(iface, allocator)` which sets `global_iface`. NetworkDown only returned when `global_iface == null`. Runtime confirmed: `testListenOnSocket` PASS on both architectures. |
| 3 | TCP connect to 127.0.0.1 completes the 3-way handshake via loopback | VERIFIED | `testConnectToUnboundPort` returns ConnectionRefused (not NetworkDown/Skip). `makeTcpPair` succeeds for MSG_PEEK, MSG_DONTWAIT, MSG_WAITALL tests. Both x86_64 and aarch64 confirmed. |
| 4 | Data sent on a loopback TCP connection is received on the other end | VERIFIED | `testMsgPeekTcp`, `testMsgWaitallTcp` both PASS -- they write data from client and read it on accepted_fd. Both architectures confirmed. |
| 5 | UDP sendto/recvfrom on 127.0.0.1 exchanges datagrams | VERIFIED | `testSendtoRecvfromUdp`, `testMsgPeekUdp`, `testMsgWaitallIgnoredUdp` all PASS on both architectures. |
| 6 | TCP timer ticks (retransmission, keepalive) are driven by the scheduler tick | VERIFIED | `combinedTickCallback()` calls `net.tick()` unconditionally. `net.tick()` calls `arp.tick()`, `transport.tcp.tick()`. Registered in all 3 return paths of `initNetwork()`. |

**Score:** 6/6 truths fully verified

### Success Criteria (from ROADMAP.md)

| # | Success Criterion | Status | Evidence |
|---|------------------|--------|----------|
| SC1 | `zig build run -Darch=x86_64` launches QEMU with a virtual loopback adapter visible to the kernel | VERIFIED | `net.loopback.init()` called first in `initNetwork()`. Kernel logs "[NETSTACK] Loopback interface (lo0) initialized: 127.0.0.1". |
| SC2 | `zig build run -Darch=aarch64` launches QEMU with the same loopback configuration | VERIFIED | Same `initNetwork()` function runs on aarch64. Both architectures build and test clean. |
| SC3 | A test program can open a TCP socket, bind to 127.0.0.1, connect to itself, and exchange data without errors on both architectures | VERIFIED | x86_64: 416 PASS, 14 FAIL (all pre-existing). aarch64: 413 PASS, 16 FAIL (all pre-existing). Socket tests confirmed: sendto/recvfrom UDP, MSG_PEEK TCP/UDP, MSG_DONTWAIT, MSG_WAITALL TCP/UDP, connect to unbound port, listen, bind, getsockname, setsockopt, shutdown all PASS. |

**Score:** 3/3 success criteria verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `src/kernel/core/init_hw.zig` | Loopback interface initialization and full net stack init during kernel boot | VERIFIED | Contains `net.loopback.init()`, `net.init(...)`, `combinedTickCallback` with `net.tick()`. |
| `src/net/drivers/loopback.zig` | Loopback interface implementation | VERIFIED | Async queue-based design. `loopbackTransmit()` strips Ethernet and queues IP data. `drain()` processes from timer tick with MAX_DRAIN_PER_TICK=64 safety limit. |
| `src/net/root.zig` | net.init() and net.tick() entry points | VERIFIED | `init()` initializes socket/TCP subsystems. `tick()` drives ARP/TCP timers. mDNS init skipped (cannot run from ISR context). |

### Bugs Fixed During Verification (commit dbc1242)

The initial loopback wiring (7b71fda) was structurally correct but exposed multiple pre-existing bugs in the network stack that prevented runtime operation:

| Bug | Root Cause | Fix | Impact |
|-----|-----------|------|--------|
| IP checksum verification failure | `ipChecksum()` computes in big-endian, stored in native LE struct field, but `verifyIpChecksum()` reads as big-endian | Applied `@byteSwap()` to all 11 IP checksum stores | All IP packets rejected on loopback |
| TCP/UDP/ICMP checksum same issue | Same byte-order mismatch in all transport checksums | Applied `@byteSwap()` to all TCP, UDP, ICMP checksum stores | All transport packets rejected |
| UDP RX verification logic wrong | Compared struct field against computed value instead of standard recomputation check | Changed to `calc_checksum != 0xFFFF` | All UDP packets rejected |
| ACK storm on TCP connect | SYN_SENT handling ran after sequence acceptability check; rcv_nxt=0 fails acceptability for random ISN | Moved SYN_SENT handling before acceptability check | Infinite ACK loop |
| RST ignored in SYN_SENT | `processSynSent()` only checks for SYN flag | Added RST check before calling processSynSent | Connect to unbound port hangs |
| Double-free on connection refused | RST handler frees TCB but sock.tcb retains dangling pointer | Set sock.tcb=null in connect error paths | Kernel panic |
| MSG_WAITALL blocks forever | tcpRecvWaitall set sock.blocked_thread but not tcb.blocked_thread; TCP RX wakes tcb.blocked_thread | Set both blocked_thread fields | MSG_WAITALL test hangs |
| ARP request for 127.x.x.x | resolveUnlocked sent ARP for loopback addresses | Return zeros for 127.x.x.x | Connect hangs |
| Loopback re-entrant deadlock | Synchronous loopback re-enters TCP RX from TX path, both need state.lock | Made loopback async (queue + drain) | Deadlock on any TCP/UDP |
| Align(1) pointer casts | IPv6/NDP/ICMPv6/ARP/raw_api used @alignCast on potentially unaligned buffers | Changed to align(1) casts | Potential alignment faults |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| TST-01 | 42-01-PLAN.md | QEMU test environment has loopback networking configured for both x86_64 and aarch64 | Satisfied | x86_64: 416/430 tests pass including all socket tests. aarch64: 413/429 tests pass including all socket tests. All failures are pre-existing and unrelated to networking. |

### Anti-Patterns Found

None -- all phase 42 code is substantive and correct.

## Gaps Summary

No gaps. All success criteria verified. All observable truths confirmed at runtime.

---

*Verified: 2026-02-21T23:30:00Z*
*Verifier: Claude (gsd-verifier, re-verified after bug fixes)*
