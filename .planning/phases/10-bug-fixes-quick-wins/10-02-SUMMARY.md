---
phase: 10-bug-fixes-quick-wins
plan: 02
subsystem: syscall/stubs
tags: [syscall, fd-management, networking, stub-verification, flag-handling]
dependency_graph:
  requires: []
  provides: [dup3-validation, accept4-validation, fd-flag-tests]
  affects: [fd-table, socket-layer]
tech_stack:
  added: [O_CLOEXEC-constant, FD_CLOEXEC-constant, SYS_ACCEPT4-export]
  patterns: [flag-validation, POSIX-compliance, integration-testing]
key_files:
  created: []
  modified:
    - src/kernel/sys/syscall/fs/fd.zig
    - src/kernel/sys/syscall/net/net.zig
    - src/user/test_runner/tests/syscall/fd_ops.zig
    - src/user/test_runner/tests/syscall/sockets.zig
    - src/user/test_runner/main.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/net.zig
    - src/user/lib/syscall/root.zig
    - src/uapi/syscalls/root.zig
decisions:
  - "sys_dup3 validates oldfd==newfd per POSIX (returns EINVAL, unlike dup2)"
  - "sys_accept4 applies O_NONBLOCK to FD flags (not just socket layer blocking field)"
  - "Added O_CLOEXEC/FD_CLOEXEC constants to userspace syscall library"
metrics:
  duration_minutes: 9
  completed_date: "2026-02-10"
  tasks_completed: 3
  files_modified: 9
  commits: 3
---

# Phase 10 Plan 02: FD/Network Stub Verification Summary

**One-liner:** Verified and fixed dup3/accept4 flag handling with POSIX compliance and integration tests

## Objective

Verify and fix FD/network stub syscalls (dup3, accept4) to ensure correct flag handling, POSIX compliance, and proper FD configuration.

## What Was Done

### Task 1: sys_dup3 Validation (STUB-01)
**Fixed sys_dup3 to comply with POSIX requirements:**
- Added oldfd == newfd check (returns EINVAL per POSIX, unlike dup2 which allows this)
- Added flag validation to reject unknown flags beyond O_CLOEXEC
- Verified O_CLOEXEC flag correctly sets fd.cloexec on duplicated FD

**Commit:** `a94aa45` - fix(10-02): sys_dup3 validates inputs per POSIX spec

**Files modified:**
- `src/kernel/sys/syscall/fs/fd.zig`: Added input validation (lines 502-506)

### Task 2: sys_accept4 Validation (STUB-02)
**Fixed sys_accept4 to handle all flags correctly:**
- Added flag validation to reject invalid flags (only SOCK_CLOEXEC | SOCK_NONBLOCK allowed)
- Applied O_NONBLOCK to FD flags for network sockets (not just socket layer's blocking field)
- Verified SOCK_CLOEXEC passed correctly to installSocketFd (already working)

**Commit:** `4e49ce9` - fix(10-02): sys_accept4 validates flags and applies O_NONBLOCK to FD

**Files modified:**
- `src/kernel/sys/syscall/net/net.zig`: Added flag validation and O_NONBLOCK FD flag application (lines 819-827, 947-955)

### Task 3: Integration Tests
**Added 5 integration tests to verify stub behavior:**

**dup3 tests (3 tests):**
- `testDup3Cloexec`: Verifies O_CLOEXEC flag sets close-on-exec via fcntl(F_GETFD)
- `testDup3SameFdReturnsEinval`: Validates POSIX restriction (oldfd == newfd returns EINVAL)
- `testDup3InvalidFlags`: Validates flag rejection for unknown flags

**accept4 tests (2 tests):**
- `testAccept4InvalidFlags`: Validates rejection of invalid flags (returns EINVAL)
- `testAccept4ValidFlags`: Validates SOCK_CLOEXEC | SOCK_NONBLOCK are accepted (returns EAGAIN/WouldBlock, not EINVAL)

**Commit:** `badbf10` - test(10-02): add integration tests for dup3 and accept4

**Files modified:**
- `src/user/test_runner/tests/syscall/fd_ops.zig`: Added 3 dup3 tests
- `src/user/test_runner/tests/syscall/sockets.zig`: Added 2 accept4 tests
- `src/user/test_runner/main.zig`: Registered 5 new tests
- `src/user/lib/syscall/io.zig`: Added dup3() wrapper and O_CLOEXEC constant
- `src/user/lib/syscall/net.zig`: Added accept4() wrapper
- `src/user/lib/syscall/root.zig`: Exported dup3, accept4, O_CLOEXEC
- `src/uapi/syscalls/root.zig`: Exported SYS_ACCEPT4

## Deviations from Plan

### Auto-fixed Issues (Rule 2: Missing Critical Functionality)

**1. [Rule 2 - Security] Missing O_CLOEXEC constant in userspace**
- **Found during:** Task 3 (integration test compilation)
- **Issue:** O_CLOEXEC constant not defined in userspace syscall library, preventing tests from using the flag
- **Fix:** Added `pub const O_CLOEXEC: i32 = 0o2000000;` to `src/user/lib/syscall/io.zig` and exported from `root.zig`
- **Files modified:** `src/user/lib/syscall/io.zig`, `src/user/lib/syscall/root.zig`
- **Commit:** badbf10

**2. [Rule 2 - Missing API] Missing FD_CLOEXEC constant in tests**
- **Found during:** Task 3 (integration test compilation)
- **Issue:** FD_CLOEXEC constant needed for fcntl(F_GETFD) flag checking in dup3 test
- **Fix:** Added `const FD_CLOEXEC: i32 = 1;` to test file (matches kernel's FD_CLOEXEC value)
- **Files modified:** `src/user/test_runner/tests/syscall/fd_ops.zig`
- **Commit:** badbf10

**3. [Rule 2 - Missing API] Missing dup3/accept4 userspace wrappers**
- **Found during:** Task 3 (integration test compilation)
- **Issue:** Syscall wrappers for dup3 and accept4 not exposed in userspace library
- **Fix:** Added wrapper functions and exported from `root.zig`
- **Files modified:** `src/user/lib/syscall/io.zig`, `src/user/lib/syscall/net.zig`, `src/user/lib/syscall/root.zig`
- **Commit:** badbf10

**4. [Rule 2 - Missing API] Missing SYS_ACCEPT4 export**
- **Found during:** Task 3 (userspace library compilation)
- **Issue:** SYS_ACCEPT4 constant defined in linux.zig and linux_aarch64.zig but not exported from uapi/syscalls/root.zig
- **Fix:** Added `pub const SYS_ACCEPT4 = linux.SYS_ACCEPT4;` to `src/uapi/syscalls/root.zig`
- **Files modified:** `src/uapi/syscalls/root.zig`
- **Commit:** badbf10

## Verification

**Build verification:**
- [x] Kernel builds for x86_64 without errors
- [x] Kernel builds for aarch64 without errors
- [x] Test runner compiles successfully

**Integration test verification:**
- [x] 3 new dup3 tests added and registered
- [x] 2 new accept4 tests added and registered
- [x] Tests validate flag handling, POSIX compliance, and error conditions

**POSIX compliance:**
- [x] sys_dup3 returns EINVAL when oldfd == newfd (POSIX requirement)
- [x] sys_dup3 validates flags (rejects unknown flags)
- [x] sys_accept4 validates flags (rejects unknown flags)
- [x] sys_accept4 applies O_NONBLOCK to FD (not just socket layer)

## Self-Check: PASSED

**Created files:**
- [x] `.planning/phases/10-bug-fixes-quick-wins/10-02-SUMMARY.md` (this file)

**Modified files:**
- [x] `src/kernel/sys/syscall/fs/fd.zig` - sys_dup3 input validation
- [x] `src/kernel/sys/syscall/net/net.zig` - sys_accept4 flag validation and O_NONBLOCK handling
- [x] `src/user/test_runner/tests/syscall/fd_ops.zig` - 3 dup3 tests
- [x] `src/user/test_runner/tests/syscall/sockets.zig` - 2 accept4 tests
- [x] `src/user/test_runner/main.zig` - test registration
- [x] `src/user/lib/syscall/io.zig` - dup3 wrapper, O_CLOEXEC constant
- [x] `src/user/lib/syscall/net.zig` - accept4 wrapper
- [x] `src/user/lib/syscall/root.zig` - exports
- [x] `src/uapi/syscalls/root.zig` - SYS_ACCEPT4 export

**Commits:**
- [x] `a94aa45` - fix(10-02): sys_dup3 validates inputs per POSIX spec
- [x] `4e49ce9` - fix(10-02): sys_accept4 validates flags and applies O_NONBLOCK to FD
- [x] `badbf10` - test(10-02): add integration tests for dup3 and accept4

## Impact

**Stability:** High - Fixed POSIX compliance issues in sys_dup3, validated flag handling in sys_accept4

**Security:** Medium - Proper flag validation prevents invalid flag combinations from silently succeeding

**Testing:** 5 new integration tests added to FD ops and socket test suites

## Next Steps

Plan 10-02 complete. Ready for plan 10-03 (process syscall stubs verification).

## Notes

- All deviations were Rule 2 (missing critical functionality) - required for test compilation and API completeness
- No architectural changes were needed - all fixes were local to syscall implementations
- sys_dup3 now matches Linux behavior: oldfd==newfd returns EINVAL (unlike dup2 which allows it)
- sys_accept4 now correctly applies O_NONBLOCK to both socket layer and FD flags (matching sys_socket behavior)
