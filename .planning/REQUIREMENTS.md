# Requirements: ZK Kernel

**Defined:** 2026-02-09
**Core Value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.

## v1.1 Requirements

Requirements for hardening and debt cleanup. Each maps to roadmap phases.

### Bug Fixes

- [ ] **BUGFIX-01**: sys_setregid enforces POSIX permission checks (unprivileged process cannot set arbitrary gids)
- [ ] **BUGFIX-02**: SFS implements fchown via FileOps.chown
- [ ] **BUGFIX-03**: copyStringFromUser accepts stack-allocated user buffers without EFAULT

### SFS Filesystem

- [ ] **SFS-01**: SFS close operation does not deadlock after 50+ file operations
- [ ] **SFS-02**: SFS supports hard link creation (link/linkat)
- [ ] **SFS-03**: SFS supports symbolic link creation and resolution (symlink/symlinkat/readlink)
- [ ] **SFS-04**: SFS supports file timestamp modification (utimensat/futimesat)

### Wait Queues

- [ ] **WAIT-01**: timerfd blocking reads sleep on a wait queue instead of yield-looping
- [ ] **WAIT-02**: signalfd blocking reads sleep on a wait queue instead of yield-looping
- [ ] **WAIT-03**: semop blocks on a wait queue when semaphore value is insufficient
- [ ] **WAIT-04**: msgsnd blocks on a wait queue when message queue is full
- [ ] **WAIT-05**: msgrcv blocks on a wait queue when no matching message is available

### IPC Completeness

- [ ] **IPC-01**: SEM_UNDO flag tracks per-process semaphore adjustments and applies on exit
- [ ] **IPC-02**: semop with IPC_NOWAIT returns EAGAIN immediately (non-blocking path preserved)

### I/O Improvements

- [ ] **IO-01**: sendfile uses zero-copy path (direct page mapping) instead of 4KB buffer copy
- [ ] **IO-02**: utimensat handles AT_SYMLINK_NOFOLLOW flag correctly

### Test Infrastructure

- [ ] **TEST-01**: 4 event FD tests pass (fix userspace pointer casting/alignment issues)
- [ ] **TEST-02**: All tests previously skipped due to SFS deadlock now run to completion
- [ ] **TEST-03**: SFS link/symlink/timestamp tests unskipped and passing

### Stub Verification

- [ ] **STUB-01**: dup3 with O_CLOEXEC works correctly
- [ ] **STUB-02**: accept4 with flags works correctly
- [ ] **STUB-03**: getrlimit returns meaningful resource limits
- [ ] **STUB-04**: setrlimit accepts and stores resource limits
- [ ] **STUB-05**: sigaltstack configures alternate signal stack
- [ ] **STUB-06**: statfs returns filesystem statistics
- [ ] **STUB-07**: fstatfs returns filesystem statistics for open fd
- [ ] **STUB-08**: getresuid and getresgid return saved uid/gid values

### Documentation

- [ ] **DOC-01**: Phase 6 has a completed VERIFICATION.md

## Future Requirements

None -- this is a cleanup milestone.

## Out of Scope

| Feature | Reason |
|---------|--------|
| SFS nested subdirectory support | Fundamental SFS architecture change, separate project |
| SFS file count limit increase (64 max) | Requires on-disk format change |
| Multi-CPU affinity enforcement | Single-CPU kernel, separate multi-core project |
| VFS redesign (mount/umount rework) | Separate architecture milestone |
| Full io_uring expansion | Separate feature milestone |
| ptrace implementation | Separate debugger project |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| BUGFIX-01 | TBD | Pending |
| BUGFIX-02 | TBD | Pending |
| BUGFIX-03 | TBD | Pending |
| SFS-01 | TBD | Pending |
| SFS-02 | TBD | Pending |
| SFS-03 | TBD | Pending |
| SFS-04 | TBD | Pending |
| WAIT-01 | TBD | Pending |
| WAIT-02 | TBD | Pending |
| WAIT-03 | TBD | Pending |
| WAIT-04 | TBD | Pending |
| WAIT-05 | TBD | Pending |
| IPC-01 | TBD | Pending |
| IPC-02 | TBD | Pending |
| IO-01 | TBD | Pending |
| IO-02 | TBD | Pending |
| TEST-01 | TBD | Pending |
| TEST-02 | TBD | Pending |
| TEST-03 | TBD | Pending |
| STUB-01 | TBD | Pending |
| STUB-02 | TBD | Pending |
| STUB-03 | TBD | Pending |
| STUB-04 | TBD | Pending |
| STUB-05 | TBD | Pending |
| STUB-06 | TBD | Pending |
| STUB-07 | TBD | Pending |
| STUB-08 | TBD | Pending |
| DOC-01 | TBD | Pending |

**Coverage:**
- v1.1 requirements: 28 total
- Mapped to phases: 0
- Unmapped: 28

---
*Requirements defined: 2026-02-09*
*Last updated: 2026-02-09 after initial definition*
