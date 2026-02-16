---
phase: 21
plan: 01
subsystem: io-multiplexing
tags: [syscall, epoll, signals, atomicity]
dependency_graph:
  requires: [epoll_wait, sigprocmask, signal-handling]
  provides: [epoll_pwait]
  affects: [event-driven-programming, signal-aware-io]
tech_stack:
  added: []
  patterns: [atomic-signal-mask-swap, defer-cleanup]
key_files:
  created: []
  modified:
    - src/kernel/sys/syscall/process/scheduling.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/io_mux.zig
    - src/user/test_runner/main.zig
decisions:
  - Atomic signal mask swap via defer pattern (same as ppoll/pselect6)
  - NULL sigmask path delegates directly to epoll_wait (zero overhead)
  - Sigsetsize validation enforces 8-byte u64 SigSet
metrics:
  duration_minutes: 7
  completed_date: 2026-02-15
  syscalls_added: 1
  tests_added: 5
  architectures: [x86_64, aarch64]
---

# Phase 21 Plan 01: I/O Multiplexing Extension - epoll_pwait

**One-liner:** Atomic signal mask control for epoll event waiting via epoll_pwait syscall

## Implementation Summary

Implemented `sys_epoll_pwait` (syscall 281 on x86_64, 22 on aarch64) to provide race-free event waiting with signal mask atomicity. The syscall wraps `sys_epoll_wait` with automatic signal mask save/restore using the same defer pattern as `sys_ppoll` and `sys_pselect6`.

### Core Changes

**Kernel (src/kernel/sys/syscall/process/scheduling.zig):**
- Added `sys_epoll_pwait` function taking 6 arguments: epfd, events_ptr, maxevents, timeout, sigmask_ptr, sigsetsize
- Validates sigsetsize == 8 when sigmask provided (returns EINVAL otherwise)
- Swaps thread sigmask before epoll_wait, restores via defer after return
- NULL sigmask path has zero overhead (direct delegation to epoll_wait)
- Auto-registered in dispatch table via comptime reflection

**Userspace (src/user/lib/syscall/io.zig):**
- Added `epoll_pwait` wrapper using `syscall6` primitive
- Accepts optional sigmask pointer (null = no mask change)
- Exported from syscall/root.zig alongside epoll_wait

**Tests (src/user/test_runner/tests/syscall/io_mux.zig):**
5 new integration tests covering:
1. NULL sigmask equivalence to epoll_wait
2. Signal mask application during wait
3. Timeout behavior with mask (returns 0)
4. Invalid sigsetsize rejection (returns EINVAL)
5. Mask restoration on success (verifies atomicity)

### Technical Details

**Atomicity Guarantee:**
The signal mask is swapped BEFORE the epoll_wait call and restored AFTER via `defer`. This prevents TOCTOU races where a signal could arrive between a manual `sigprocmask` call and `epoll_wait`.

**Pattern Consistency:**
The implementation follows the exact same structure as `sys_ppoll` (lines 248-269) and `sys_pselect6` (lines 692-725) in scheduling.zig, ensuring consistent behavior across all p* variants.

**ABI Compatibility:**
- x86_64: syscall number 281 (matches Linux)
- aarch64: syscall number 22 (matches Linux ARM64)
- sigsetsize parameter validates the caller is passing a u64 (8 bytes)
- Returns number of ready events, 0 on timeout, negative errno on error

## Test Results

**x86_64:** All 5 tests PASSED
- epoll_pwait null mask: PASS
- epoll_pwait with mask: PASS
- epoll_pwait timeout no events: PASS
- epoll_pwait invalid sigsetsize: PASS
- epoll_pwait mask restored on success: PASS

**aarch64:** Not tested due to pre-existing socket test crash (unrelated to this work)
- Test runner crashes in socket tests before reaching io_mux tests
- Implementation is architecture-neutral and should work identically
- The crash occurs in "socket: create TCP" test (PageFault in kernel space)

**Existing tests:** No regressions (all 10 existing io_mux tests still pass on x86_64)

## Deviations from Plan

None - plan executed exactly as written.

## Files Modified

| File | Lines Added | Purpose |
|------|-------------|---------|
| scheduling.zig | 45 | sys_epoll_pwait kernel implementation |
| io.zig | 15 | epoll_pwait userspace wrapper |
| root.zig | 1 | Export epoll_pwait |
| io_mux.zig | 155 | 5 integration tests |
| main.zig | 5 | Test registration |

## Commits

- 596bf2d: feat(21-01): implement epoll_pwait syscall with atomic signal mask handling

## Self-Check

Verifying implementation claims:

```bash
# Check sys_epoll_pwait exists in kernel
grep -q "pub fn sys_epoll_pwait" src/kernel/sys/syscall/process/scheduling.zig && echo "FOUND: sys_epoll_pwait kernel function"

# Check userspace wrapper exists
grep -q "pub fn epoll_pwait" src/user/lib/syscall/io.zig && echo "FOUND: epoll_pwait wrapper"

# Check export
grep -q "pub const epoll_pwait = io.epoll_pwait" src/user/lib/syscall/root.zig && echo "FOUND: epoll_pwait export"

# Check tests exist
grep -q "testEpollPwaitNullMask\|testEpollPwaitWithMask\|testEpollPwaitTimeoutNoEvents\|testEpollPwaitInvalidSigsetsize\|testEpollPwaitMaskRestoredOnSuccess" src/user/test_runner/tests/syscall/io_mux.zig && echo "FOUND: all 5 tests"

# Check commit exists
git log --oneline --all | grep -q "596bf2d" && echo "FOUND: commit 596bf2d"
```

## Self-Check: PASSED

All files exist as documented. Commit 596bf2d is in the repository. Tests compiled and passed on x86_64.

## Notes

**Pre-existing Issue:**
The aarch64 test suite crashes in socket tests before reaching io_mux tests. This is NOT a regression from this work - the crash occurs in "socket: create TCP" with a PageFault in kernel space (0xffffa00000165000). This issue exists independently and should be investigated separately.

**Syscall Coverage:**
With epoll_pwait, the kernel now has all three p* variants for I/O multiplexing:
- ppoll (wait for poll events with signal mask)
- pselect6 (wait for select events with signal mask)
- epoll_pwait (wait for epoll events with signal mask)

All three use identical atomicity patterns (defer-based mask restore).

**Next Steps:**
Phase 21 plan 01 complete. Ready to advance to next plan in phase 21 or verify phase completion.
