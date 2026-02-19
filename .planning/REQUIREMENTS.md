# Requirements: ZK Kernel Network Stack Hardening

**Defined:** 2026-02-19
**Core Value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.

## v1.4 Requirements

Requirements for the v1.4 milestone. Each maps to roadmap phases.

### TCP Congestion Control

- [ ] **CC-01**: TCP slow-start uses correct cwnd increment per RFC 5681 S3.1 (cwnd += min(acked, SMSS) instead of AIMD formula)
- [ ] **CC-02**: TCP initial window set to 10*MSS per RFC 6928 (IW10)
- [ ] **CC-03**: Karn's Algorithm applied -- RTT not sampled on retransmitted segments (RFC 6298 S5)
- [ ] **CC-04**: Congestion control logic extracted into congestion/reno.zig module with onAck/onTimeout/onDupAck entry points
- [ ] **CC-05**: cwnd upper bound enforced relative to send buffer size (prevents unbounded growth to maxInt(u32))

### TCP Window Management

- [ ] **WIN-01**: currentRecvWindow() wired into ACK segment building so rcv_wnd reflects actual buffer state
- [ ] **WIN-02**: Persist timer separated from retransmit timer with 60s cap per RFC 1122 S4.2.2.17
- [ ] **WIN-03**: Window update ACK sent when buffer drains by >= MSS after recv()
- [ ] **WIN-04**: Receiver SWS avoidance -- window not reopened until min(rcv_buf/2, MSS) freed (RFC 1122 S4.2.3.3)
- [ ] **WIN-05**: Sender SWS avoidance -- segment not sent unless >= SMSS or >= snd_wnd/2 or last data (RFC 1122 S4.2.3.4)

### Socket API

- [ ] **API-01**: MSG_PEEK returns data without consuming from receive buffer for both TCP and UDP
- [ ] **API-02**: MSG_DONTWAIT provides per-call non-blocking override independent of O_NONBLOCK (returns EAGAIN if no data)
- [ ] **API-03**: MSG_WAITALL blocks until full requested length received, EOF, or error (with SO_RCVTIMEO and EINTR handling)
- [ ] **API-04**: TCP_CORK holds data in send buffer until full MSS accumulated or cork cleared via setsockopt
- [ ] **API-05**: MSG_NOSIGNAL suppresses SIGPIPE delivery on write to broken connection
- [ ] **API-06**: Raw socket blocking recv implemented via scheduler wake pattern (currently returns WouldBlock unconditionally)

### Buffer & Queue Sizing

- [ ] **BUF-01**: SO_RCVBUF accepted via setsockopt, value stored and applied as cap in currentRecvWindow()
- [ ] **BUF-02**: SO_SNDBUF accepted via setsockopt, value stored and applied as send buffer gate
- [ ] **BUF-03**: getsockopt returns doubled value for SO_RCVBUF/SO_SNDBUF per Linux ABI convention
- [ ] **BUF-04**: SO_REUSEPORT allows multiple sockets to bind same address:port pair (FIFO dispatch for accept)
- [ ] **BUF-05**: Accept queue and RX queue sizes increased from fixed 8 to configurable higher values

## Future Requirements

Deferred to subsequent milestones. Tracked but not in current roadmap.

### Advanced Congestion Control

- **CC-F01**: CUBIC congestion control algorithm (RFC 8312) as alternative to NewReno
- **CC-F02**: BBR congestion control with bandwidth estimation and packet pacing
- **CC-F03**: ECN (Explicit Congestion Notification) support (RFC 3168)

### Dynamic Buffers

- **BUF-F01**: Heap-allocated TCB send/receive buffers replacing fixed 8KB arrays
- **BUF-F02**: Runtime buffer resizing on established connections via SO_RCVBUF/SO_SNDBUF
- **BUF-F03**: SO_SNDBUFFORCE/SO_RCVBUFFORCE with CAP_NET_ADMIN capability check

### Additional Socket Features

- **API-F01**: TCP_INFO getsockopt returning 232-byte connection statistics struct
- **API-F02**: TCP_KEEPIDLE/TCP_KEEPINTVL/TCP_KEEPCNT for per-connection keepalive tuning
- **API-F03**: SO_LINGER with blocking close until data flushed

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| MSG_OOB / TCP urgent data | RFC 6093 recommends against new implementations; no known application on zk uses it |
| CUBIC/BBR congestion control | Zero measurable benefit in QEMU loopback; add when real-hardware networking supported |
| True dynamic buffer resize | Requires TCB struct refactor and Tcb.deinit() across 18 BUFFER_SIZE reference sites |
| Multipath TCP (MPTCP) | Requires scheduler-level subflow management; separate project |
| IP_PKTINFO / IP_RECVORIGDSTADDR | Single network interface; multi-homing not supported |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| CC-01 | Phase 36 | Pending |
| CC-02 | Phase 36 | Pending |
| CC-03 | Phase 36 | Pending |
| CC-04 | Phase 36 | Pending |
| CC-05 | Phase 36 | Pending |
| WIN-01 | Phase 37 | Pending |
| WIN-02 | Phase 37 | Pending |
| WIN-03 | Phase 37 | Pending |
| WIN-04 | Phase 37 | Pending |
| WIN-05 | Phase 37 | Pending |
| API-01 | Phase 39 | Pending |
| API-02 | Phase 39 | Pending |
| API-03 | Phase 39 | Pending |
| API-04 | Phase 38 | Pending |
| API-05 | Phase 38 | Pending |
| API-06 | Phase 38 | Pending |
| BUF-01 | Phase 38 | Pending |
| BUF-02 | Phase 38 | Pending |
| BUF-03 | Phase 38 | Pending |
| BUF-04 | Phase 38 | Pending |
| BUF-05 | Phase 38 | Pending |

**Coverage:**
- v1.4 requirements: 21 total
- Mapped to phases: 21
- Unmapped: 0

---
*Requirements defined: 2026-02-19*
*Last updated: 2026-02-19 after roadmap creation (full traceability added)*
