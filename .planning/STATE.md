# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-11)

**Core value:** Every implemented syscall works correctly on both x86_64 and aarch64, tested via the integration test harness.
**Current focus:** Phase 25 complete (Seccomp), ready for Phase 26

## Current Position

Phase: 25 of 26 (Seccomp) -- COMPLETE
Plan: 1 of 1 complete
Status: Phase complete. 1 syscall (seccomp), classic BPF interpreter, dispatch hook, 10 tests (all passing on both x86_64 and aarch64).
Last activity: 2026-02-16 - Phase 25 complete with seccomp syscall filtering

Progress: [████████████████████████░░░░░░░░░░░░░░░░░░] 74% (55/75+ plans complete from v1.0+v1.1+v1.2)

## Performance Metrics

**Velocity:**
- Total plans completed: 53 (v1.0: 29, v1.1: 12, v1.2: 12)
- Average duration: ~8.0 min per plan
- Total execution time: ~7.0 hours over 8 days

**By Milestone:**

| Milestone | Phases | Plans | Duration |
|-----------|--------|-------|----------|
| v1.0 | 1-9 | 29 | 4 days |
| v1.1 | 10-14 | 12 | 2 days |
| v1.2 | 15-26 | 12 (in progress) | Started |

**Recent Trend:**
- Last plan (v1.2 Phase 25-01): 13 minutes, 1 syscall + BPF interpreter, 10 tests (all passing), dual-arch verified
- Phase 24-01: 8 minutes, 2 syscalls, 10 tests, dual-arch build
- Phase 23-01: 13 minutes, 5 syscalls, 10 tests (9 passed, 1 skipped), dual-arch verified + stack overflow fix
- Phase 22-01: 7 minutes, 3 syscalls, 10 tests (9 passed, 1 skipped), dual-arch build
- Phase 21-01: 7 minutes, 1 syscall, 5 tests, x86_64 verified
- Phase 20-01: 14.5 minutes, 4 syscalls, 10 tests, dual-arch
- Phase 19-01: 13 minutes, 2 syscalls, 10 tests, dual-arch
- Phase 18-01: 14 minutes, 3 syscalls, 10 tests, dual-arch
- Phase 17-02: 11 minutes, gap closure, 10 tests passing
- Trend: Fast execution, consistent 7-14 min per plan

## Accumulated Context

### Decisions

Recent decisions affecting current work (full log in PROJECT.md):

- **v1.2 Phase 25-01**: Classic BPF interpreter for MVP (not eBPF) - simpler, sufficient for seccomp
- **v1.2 Phase 25-01**: 256 instruction limit across all filters (8 filter programs max) for resource constraints
- **v1.2 Phase 25-01**: SECCOMP_RET_KILL returns ENOSYS instead of SIGSYS delivery (MVP - signal queue integration deferred)
- **v1.2 Phase 25-01**: Seccomp check runs BEFORE syscall dispatch (intercepts all syscalls at table level)
- **v1.2 Phase 25-01**: Seccomp is irreversible (cannot be undone once enabled) - strong sandbox guarantee
- **v1.2 Phase 24-01**: UAPI types registered via uapi.capability rather than separate build module (avoids build.zig complexity)
- **v1.2 Phase 24-01**: Default CAP_FULL_SET (bits 0-40) for all processes since all run as root (uid=0)
- **v1.2 Phase 24-01**: Inheritable set starts empty (Linux convention, prevents capability leakage across execve)
- **v1.2 Phase 24-01**: No new dispatch table module -- functions added to existing process.zig to avoid stack growth
- **v1.2 Phase 23-01**: Inline POSIX timer expiration in processIntervalTimers (no cross-module call) for minimal overhead
- **v1.2 Phase 23-01**: SigEvent exactly 64 bytes with comptime assertion for Linux ABI compatibility
- **v1.2 Phase 23-01**: 8 timer slots per process (MAX_POSIX_TIMERS) balances functionality with resource constraints
- **v1.2 Phase 21-01**: epoll_pwait uses defer pattern for atomic signal mask swap (matches ppoll/pselect6)
- **v1.2 Phase 21-01**: NULL sigmask path has zero overhead (direct delegation to epoll_wait)
- **v1.2 Phase 20-01**: Bitmask-only signal tracking for MVP (no per-thread siginfo queue)
- **v1.2 Phase 20-01**: rt_sigtimedwait uses atomic CAS loop for race-safe signal dequeue
- **v1.2 Phase 20-01**: si_code restriction: userspace can only send negative codes (prevents kernel impersonation)
- **v1.2 Phase 20-01**: clock_nanosleep supports CLOCK_REALTIME and CLOCK_MONOTONIC only
- **v1.2 Phase 20-01**: sys_nanosleep delegates to clock_nanosleep_internal(CLOCK_MONOTONIC, 0)
- **v1.2 Phase 19-01**: clone3 uses CloneArgs struct for forward-compatible ABI instead of register-packed arguments
- **v1.2 Phase 19-01**: waitid returns 0 on success (not child PID like wait4) per Linux semantics
- **v1.2 Phase 19-01**: clone3 fork path honors CLONE_PARENT_SETTID flag even when delegating to sys_fork
- **v1.2 Phase 19-01**: SigInfo struct is exactly 128 bytes matching Linux ABI with compile-time assertion
- **v1.2 Phase 18-01**: MemfdState uses PMM-backed pages with kernel virtual access via physToVirt for mmap support
- **v1.2 Phase 18-01**: mremap supports shrink, in-place growth, and MREMAP_MAYMOVE relocation with page-by-page data copy
- **v1.2 Phase 18-01**: msync is validation-only (no buffer cache in zk, data already on disk)
- **v1.2 Phase 17-02**: sys_tee loop removal - peekPipeBuffer doesn't advance read_pos, single peek+write prevents data duplication
- **v1.2 Phase 17-02**: Test reordering pattern - non-SFS tests first maximizes coverage despite SFS close deadlock
- **v1.2 Phase 17**: Zero-copy I/O uses 64KB kernel buffer copies (same as sendfile) - No page cache means true zero-copy deferred
- **v1.2 Phase 17**: Pipe helper functions keep pipe internals encapsulated - isPipe/getPipeHandle/read/write/peekPipeBuffer
- **v1.2 Phase 16**: fallocate mode=0 uses fstat+truncate to extend files; SFS truncateFd now supports extension
- **v1.2 Phase 16**: RENAME_EXCHANGE swaps directory entry names atomically under alloc_lock
- **v1.2**: File sync syscalls as validation-only operations - No buffer cache means data already on disk
- **v1.1**: WaitQueue replaces blocked_readers atomics - Cleaner lifecycle management
- **v1.1**: sendfile 64KB buffer instead of zero-copy - 16x improvement, deferred true zero-copy to v2
- **v1.0**: Dual-arch testing mandatory - Every syscall tested on both x86_64 and aarch64
- [Phase 22]: inotify MVP uses EAGAIN for empty reads instead of blocking - epoll integration primary use case
- [Phase 22]: VFS hooks use numeric event constants to avoid circular module dependencies

### Pending Todos

None yet.

### Blockers/Concerns

**Active:**
- signalfd uses 10ms polling timeout instead of direct signal delivery wakeup (acceptable for v1.2)
- aarch64 test suite no longer crashes in socket tests (stack overflow fixed in Phase 23)
- aarch64 test suite timeout in later tests (pre-existing, does not block functionality)
- sendfile uses 64KB buffer copy, not true zero-copy (requires VFS page cache, deferred to v2)
- sendfile large transfer test causes test runner timeout on both architectures (pre-existing)

**None blocking v1.2 work.**

## Session Continuity

Last session: 2026-02-16
Stopped at: Phase 25 complete (Seccomp). Ready for Phase 26.
Resume file: None

---
*State initialized: 2026-02-06*
*Last updated: 2026-02-16 after Phase 25 completion*
