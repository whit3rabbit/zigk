---
phase: 19-process-control-extensions
plan: 01
subsystem: process-control
tags: [clone3, waitid, syscall, process-creation, posix, modern-linux]

# Dependency graph
requires:
  - phase: 18-memory-management-extensions
    provides: Process management foundation with fork/wait4
provides:
  - Modern clone3 syscall with struct-based arguments
  - Modern waitid syscall with siginfo_t output and flexible id types
  - Userspace wrappers for clone3 and waitid
  - 10 integration tests for both syscalls on dual architectures
affects: [process-management, libc-compatibility, posix-spawn]

# Tech tracking
tech-stack:
  added: [clone3, waitid, CloneArgs struct, SigInfo struct, P_PID/P_ALL/P_PGID id types]
  patterns: [struct-based syscall args, siginfo_t output format, modern Linux process API]

key-files:
  created: []
  modified:
    - src/uapi/syscalls/linux.zig
    - src/uapi/syscalls/root.zig
    - src/kernel/sys/syscall/core/execution.zig
    - src/kernel/sys/syscall/process/process.zig
    - src/user/lib/syscall/process.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/process.zig
    - src/user/test_runner/main.zig

key-decisions:
  - "clone3 uses CloneArgs struct for forward-compatible ABI instead of register-packed arguments"
  - "waitid returns 0 on success (not child PID like wait4) per Linux semantics"
  - "clone3 fork path honors CLONE_PARENT_SETTID flag even when delegating to sys_fork"
  - "SigInfo struct is exactly 128 bytes matching Linux ABI with compile-time assertion"

patterns-established:
  - "Struct-based syscall argument passing for modern syscalls"
  - "siginfo_t output format with si_signo, si_code, si_pid, si_status fields"
  - "P_PID/P_ALL/P_PGID id type patterns for flexible child selection"

# Metrics
duration: 13min
completed: 2026-02-14
---

# Phase 19 Plan 01: Process Control Extensions Summary

**Modern clone3 and waitid syscalls with struct-based args, siginfo_t output, and 10 dual-arch integration tests**

## Performance

- **Duration:** 13 min
- **Started:** 2026-02-14T02:27:09Z
- **Completed:** 2026-02-14T02:40:22Z
- **Tasks:** 2
- **Files modified:** 8

## Accomplishments
- Implemented clone3 syscall with CloneArgs struct-based interface replacing register-packed clone
- Implemented waitid syscall with siginfo_t output and P_PID/P_ALL/P_PGID id type support
- Added userspace wrappers with complete type definitions (CloneArgs, SigInfo, CLD_* codes)
- Created 10 integration tests covering basic fork, invalid args, parent tid, P_PID, P_ALL, P_PGID, WNOHANG, ECHILD, invalid options, and round-trip scenarios
- All tests passing on both x86_64 and aarch64 architectures

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement clone3 and waitid kernel syscalls** - `12e9a9d` (feat)
2. **Task 2: Add userspace wrappers and integration tests** - `6cf7563` (feat)

## Files Created/Modified
- `src/uapi/syscalls/linux.zig` - Added SYS_WAITID constant (247)
- `src/uapi/syscalls/root.zig` - Re-exported SYS_WAITID
- `src/kernel/sys/syscall/core/execution.zig` - Implemented sys_clone3 with CloneArgs handling, CLONE_THREAD path, fork fallback with flag support
- `src/kernel/sys/syscall/process/process.zig` - Implemented sys_waitid with P_PID/P_ALL/P_PGID matching, WEXITED/WNOWAIT options, siginfo_t output
- `src/user/lib/syscall/process.zig` - Added clone3(), waitid() wrappers, CloneArgs/SigInfo types, P_*/WEXITED/CLD_* constants
- `src/user/lib/syscall/root.zig` - Exported 20+ new symbols for clone3/waitid API
- `src/user/test_runner/tests/syscall/process.zig` - Added 10 integration tests for clone3 and waitid
- `src/user/test_runner/main.zig` - Registered proc_ext test suite

## Decisions Made
- **CloneArgs struct-based API:** clone3 uses a struct instead of register-packed arguments for cleaner ABI and forward compatibility with future Linux extensions
- **waitid returns 0:** Follows Linux semantics where waitid returns 0 on success (unlike wait4 which returns child PID)
- **Fork path flag handling:** clone3 honors CLONE_PARENT_SETTID flag even when delegating to sys_fork for non-threaded process creation
- **SigInfo 128-byte layout:** Enforced with compile-time assertion to match exact Linux ABI for cross-compatibility

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed clone3 fork path to honor CLONE_PARENT_SETTID flag**
- **Found during:** Task 2 (testClone3WithParentTid failing on x86_64)
- **Issue:** When clone3 delegated to sys_fork for non-threaded process creation, it ignored the CLONE_PARENT_SETTID flag and args.parent_tid pointer, causing the test to fail because the parent TID was never written to user memory
- **Fix:** Added parent_tid handling after sys_fork call in both fork fallback paths, writing child PID to parent's memory when flag or pointer is set
- **Files modified:** src/kernel/sys/syscall/core/execution.zig
- **Verification:** testClone3WithParentTid now passes on both architectures
- **Committed in:** 6cf7563 (Task 2 commit)

**2. [Rule 1 - Bug] Fixed waitid no-children test to reap existing children first**
- **Found during:** Task 2 (testWaitidNoChildren failing on x86_64)
- **Issue:** Test assumed it had no children, but the previous test's child process (from WNOHANG test which sleeps 200ms) was still alive or a zombie, causing waitid to not return ECHILD
- **Fix:** Added loop at test start to reap all existing children with WNOHANG before testing ECHILD error code
- **Files modified:** src/user/test_runner/tests/syscall/process.zig
- **Verification:** testWaitidNoChildren now passes reliably on both architectures
- **Committed in:** 6cf7563 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both auto-fixes necessary for test correctness. No scope creep.

## Issues Encountered
None - both tasks executed smoothly after auto-fixing test bugs

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- clone3 and waitid syscalls fully functional on both architectures
- Modern process creation API ready for libc and posix_spawn implementations
- Test coverage demonstrates correct interaction with existing fork/wait4 infrastructure
- Ready to proceed with additional process control syscalls in future phases

## Test Results

**x86_64:** All 10 proc_ext tests PASS
**aarch64:** All 10 proc_ext tests PASS

Test coverage:
- clone3 basic fork (exit_signal=SIGCHLD)
- clone3 invalid size (EINVAL)
- clone3 with parent tid (CLONE_PARENT_SETTID)
- waitid P_PID (wait for specific child)
- waitid P_ALL (wait for any child)
- waitid P_PGID (wait for process group)
- waitid WNOHANG (non-blocking)
- waitid no children (ECHILD)
- waitid invalid options (EINVAL)
- clone3 + waitid roundtrip

---
*Phase: 19-process-control-extensions*
*Completed: 2026-02-14*
