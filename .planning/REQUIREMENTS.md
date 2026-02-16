# Requirements: ZK Kernel v1.3 Tech Debt Cleanup

**Defined:** 2026-02-16
**Core Value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.

## v1.3 Requirements

Requirements for v1.3 tech debt cleanup. Each maps to roadmap phases.

### Signal Infrastructure

- [ ] **SIG-01**: rt_sigsuspend correctly delivers pending signals without race condition
- [ ] **SIG-02**: Signals carry per-thread siginfo data (queue replaces bitmask-only tracking)
- [ ] **SIG-03**: signalfd wakes immediately on signal delivery (no polling timeout)

### Inotify Completion

- [ ] **INOT-01**: VFS operations (ftruncate, write, rename, unlink) fire inotify events
- [ ] **INOT-02**: Event queue overflow generates IN_Q_OVERFLOW notification
- [ ] **INOT-03**: Inotify supports increased capacity (more instances, watches, queued events)

### Seccomp Hardening

- [ ] **SECC-01**: SECCOMP_RET_KILL delivers SIGSYS to the offending thread
- [ ] **SECC-02**: SeccompData includes instruction_pointer of the trapped syscall

### POSIX Timer Improvements

- [ ] **PTMR-01**: Per-process timer limit increased beyond 8
- [ ] **PTMR-02**: Timer and clock_nanosleep resolution improved beyond 10ms tick granularity
- [ ] **PTMR-03**: POSIX timers support SIGEV_THREAD and SIGEV_THREAD_ID notification modes

### Resource Management

- [ ] **RSRC-01**: fchdir changes working directory via open file descriptor
- [ ] **RSRC-02**: Per-process resource limits persist across setrlimit/getrlimit calls

### Memory Management

- [ ] **MEM-01**: mremap correctly handles invalid address edge cases (testMremapInvalidAddr passes)

### Zero-Copy I/O

- [ ] **ZCIO-01**: VFS page cache enables true zero-copy data transfer
- [ ] **ZCIO-02**: splice, sendfile, tee, and copy_file_range use page cache (no kernel buffer copy)

## Future Requirements

None -- this milestone is debt cleanup, not new features.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Full seccomp BPF JIT | Interpreter sufficient, JIT is optimization work |
| SFS nested subdirectories | Fundamental architecture change, separate project |
| SFS file count increase (>64) | On-disk format change, separate project |
| ptrace support | Extremely complex, separate project |
| eBPF (extended BPF) | Classic BPF sufficient for seccomp |
| Container/namespace support | Requires kernel architecture changes |
| Multi-CPU scheduling | Single-CPU kernel, separate project |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| MEM-01 | Phase 27 | Pending |
| RSRC-01 | Phase 27 | Pending |
| RSRC-02 | Phase 27 | Pending |
| SECC-02 | Phase 27 | Pending |
| SIG-01 | Phase 28 | Pending |
| SIG-02 | Phase 29 | Pending |
| SIG-03 | Phase 30 | Pending |
| SECC-01 | Phase 30 | Pending |
| INOT-01 | Phase 31 | Pending |
| INOT-02 | Phase 31 | Pending |
| INOT-03 | Phase 31 | Pending |
| PTMR-01 | Phase 32 | Pending |
| PTMR-02 | Phase 33 | Pending |
| PTMR-03 | Phase 34 | Pending |
| ZCIO-01 | Phase 35 | Pending |
| ZCIO-02 | Phase 35 | Pending |

**Coverage:**
- v1.3 requirements: 16 total
- Mapped to phases: 16/16 (100%)
- Unmapped: 0

---
*Requirements defined: 2026-02-16*
*Last updated: 2026-02-16 after roadmap creation*
