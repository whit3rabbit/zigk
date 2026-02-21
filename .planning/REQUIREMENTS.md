# Requirements: ZK Kernel v1.5 Tech Debt Cleanup

**Defined:** 2026-02-20
**Core Value:** Every implemented syscall must work correctly on both x86_64 and aarch64 with matching behavior, tested via the existing integration test harness.

## v1.5 Requirements

### Network Code Fixes

- [ ] **NET-01**: tcb.blocked_thread is cleared before returning EINTR in MSG_PEEK blocking and default TCP blocking recv paths (net.zig:619-627, 662-670)
- [ ] **NET-02**: setsockopt SO_RCVBUF/SO_SNDBUF values set before connect() are propagated to Tcb.init()
- [ ] **NET-03**: TCP_CORK uncork flush acquires tcb.mutex before calling transmitPendingData()
- [ ] **NET-04**: Raw sockets support MSG_DONTWAIT and MSG_PEEK flags in recv path (raw_api.zig)

### Code Cleanup

- [ ] **CLN-01**: Dead field Tcb.send_acked is removed from types.zig
- [ ] **CLN-02**: slab_bench.zig compiles on Zig 0.16.x (std.time.Timer replacement)

### Documentation

- [ ] **DOC-01**: v1.4 REQUIREMENTS.md checkboxes updated to reflect satisfied requirements
- [ ] **DOC-02**: SUMMARY frontmatter requirements_completed field populated in all 9 v1.4 plan SUMMARYs
- [ ] **DOC-03**: ROADMAP.md phase 37/39 progress table formatting corrected

### Test Infrastructure

- [ ] **TST-01**: QEMU test environment has loopback networking configured for both x86_64 and aarch64
- [ ] **TST-02**: 8 network features verified under live loopback (zero-window recovery, SWS avoidance, raw socket blocking recv, SO_REUSEPORT distribution, SIGPIPE/MSG_NOSIGNAL, MSG_PEEK+DONTWAIT UDP, MSG_WAITALL multi-segment, SO_RCVTIMEO+MSG_WAITALL)
- [ ] **TST-03**: 5 MSG flag integration tests pass (unskipped) in QEMU test environment

## Future Requirements

None -- this is a cleanup milestone.

## Out of Scope

| Feature | Reason |
|---------|--------|
| New syscall implementations | v1.5 is strictly tech debt cleanup |
| QEMU TAP networking (host-to-guest) | Only loopback (guest-internal) needed for test verification |
| Performance benchmarking | Verification is functional correctness, not throughput |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| NET-01 | Phase 40 | Pending |
| NET-02 | Phase 40 | Pending |
| NET-03 | Phase 40 | Pending |
| NET-04 | Phase 40 | Pending |
| CLN-01 | Phase 41 | Pending |
| CLN-02 | Phase 41 | Pending |
| DOC-01 | Phase 41 | Pending |
| DOC-02 | Phase 41 | Pending |
| DOC-03 | Phase 41 | Pending |
| TST-01 | Phase 42 | Pending |
| TST-02 | Phase 43 | Pending |
| TST-03 | Phase 43 | Pending |

**Coverage:**
- v1.5 requirements: 12 total
- Mapped to phases: 12
- Unmapped: 0

---
*Requirements defined: 2026-02-20*
*Last updated: 2026-02-20 after roadmap creation (traceability complete)*
