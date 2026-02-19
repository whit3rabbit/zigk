---
phase: 28-rt-sigsuspend-race-fix
plan: 01
subsystem: kernel
tags: [signals, rt_sigsuspend, signal-mask, syscall-dispatch]

requires:
  - phase: 27
    provides: "Base signal infrastructure and syscall dispatch"
provides:
  - "Race-free rt_sigsuspend with deferred mask restoration pattern"
  - "dispatch_syscall skips rax clobber for rt_sigreturn (frame-restoring syscall)"
  - "testRtSigsuspendBasic validates signal delivery during mask swap"
affects: [siginfo-queue, signal-wakeup]

tech-stack:
  added: []
  patterns: ["deferred mask restoration via saved_sigmask (Linux kernel pattern)", "frame-restoring syscalls skip setReturnSigned"]

key-files:
  created: []
  modified:
    - src/kernel/proc/thread.zig
    - src/kernel/proc/signal.zig
    - src/kernel/sys/syscall/process/signals.zig
    - src/kernel/sys/syscall/core/table.zig
    - src/user/test_runner/tests/syscall/signals.zig

key-decisions:
  - "dispatch_syscall must skip setReturnSigned for rt_sigreturn to avoid clobbering restored rax"
  - "Deferred mask restoration via saved_sigmask/has_saved_sigmask on Thread struct (same pattern as Linux)"
  - "setupSignalFrameForSyscall writes saved_sigmask into ucontext so rt_sigreturn restores original mask"

patterns-established:
  - "Frame-restoring syscalls: any syscall that restores the full frame from saved context (rt_sigreturn) must be excluded from setReturnSigned in dispatch_syscall"
  - "Deferred mask restoration: when a syscall temporarily changes the signal mask, save the original in saved_sigmask and let the signal delivery path handle restoration"

requirements-completed: [SIG-01]

duration: 25min
completed: 2026-02-16
---

# Phase 28: rt_sigsuspend Race Fix Summary

**Race-free rt_sigsuspend using deferred mask restoration, with dispatch_syscall fix to preserve restored frame state across rt_sigreturn**

## Performance

- **Duration:** 25 min
- **Started:** 2026-02-16
- **Completed:** 2026-02-16
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Fixed POSIX rt_sigsuspend race where pending signals were never delivered because the original mask was restored before checkSignalsOnSyscallExit ran
- Fixed dispatch_syscall clobbering restored rax after rt_sigreturn, which made rt_sigsuspend appear to succeed instead of returning EINTR
- Un-skipped testRtSigsuspendBasic with a real test that validates the complete signal delivery flow

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix rt_sigsuspend mask restoration race** - `b1da1fc` (fix)
2. **Task 2: Fix rt_sigreturn rax clobber and un-skip test** - `e669aa9` (fix/test)

## Files Created/Modified
- `src/kernel/proc/thread.zig` - Added saved_sigmask and has_saved_sigmask fields
- `src/kernel/proc/signal.zig` - checkSignalsOnSyscallExit defers mask restoration; setupSignalFrameForSyscall uses saved mask in ucontext
- `src/kernel/sys/syscall/process/signals.zig` - sys_rt_sigsuspend defers mask restoration instead of restoring before return
- `src/kernel/sys/syscall/core/table.zig` - Skip setReturnSigned for SYS_RT_SIGRETURN
- `src/user/test_runner/tests/syscall/signals.zig` - Real testRtSigsuspendBasic test

## Decisions Made
- dispatch_syscall must skip setReturnSigned for rt_sigreturn because rt_sigreturn restores the entire frame from ucontext (including rax). Writing the dummy return value (0) clobbers the restored rax, making the original syscall (rt_sigsuspend) appear to succeed instead of returning -EINTR.
- Used Linux's deferred mask restoration pattern: save original mask in Thread.saved_sigmask, keep temp mask active through signal delivery, restore via rt_sigreturn's ucontext or fallback defer in checkSignalsOnSyscallExit.

## Deviations from Plan

### Auto-fixed Issues

**1. [Critical Bug] dispatch_syscall clobbers rt_sigreturn's restored frame**
- **Found during:** Task 2 (test verification)
- **Issue:** Plan did not account for dispatch_syscall writing return value AFTER rt_sigreturn restores the frame. sys_rt_sigreturn returns 0 (dummy), dispatch_syscall writes 0 to rax, clobbering the restored -EINTR.
- **Fix:** Skip setReturnSigned when syscall_num == SYS_RT_SIGRETURN
- **Files modified:** src/kernel/sys/syscall/core/table.zig
- **Verification:** testRtSigsuspendBasic passes on both x86_64 and aarch64
- **Committed in:** e669aa9

---

**Total deviations:** 1 auto-fixed (critical bug in dispatch path)
**Impact on plan:** Essential fix -- without it, rt_sigsuspend never returns EINTR when a signal handler runs via rt_sigreturn.

## Issues Encountered
None beyond the dispatch_syscall deviation above.

## Next Phase Readiness
- Signal mask infrastructure now correctly supports deferred restoration
- Ready for Phase 29 (Siginfo Queue) which builds on signal delivery paths

---
*Phase: 28-rt-sigsuspend-race-fix*
*Completed: 2026-02-16*
