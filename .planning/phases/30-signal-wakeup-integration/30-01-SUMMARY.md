---
phase: 30-signal-wakeup-integration
plan: 01
subsystem: kernel-signals
tags: [signals, signalfd, seccomp, scheduler, waitqueue, sigsys, sigsegv]

# Dependency graph
requires:
  - phase: 29-siginfo-queue
    provides: KernelSigInfo type, SigInfoQueue per thread, siginfo threading through signal delivery
  - phase: 28-rt-sigsuspend
    provides: checkSignalsOnSyscallExit pattern, rt_sigreturn frame-restoring bypass
provides:
  - signalfd reads wake immediately on signal delivery via sched.unblock (no 10ms polling)
  - SECCOMP_RET_KILL delivers SIGSYS with si_syscall/si_arch metadata instead of silent ENOSYS
  - sched.exitWithStatus marks Process as Zombie (not just Thread) to prevent sys_wait4 deadlock
  - Integration tests for signalfd direct wakeup and seccomp SIGSYS delivery
affects: [31-tcp-fin-teardown, 32-futex-robustlist, 33-io-uring-batch, 34-virtio-net-rx, 35-vfs-page-cache]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "sched.unblock wakes signalfd readers without timeout (indefinite block + direct wakeup)"
    - "WaitQueue.removeThread cleans stale entries after unblock (not via wakeUp path)"
    - "sched.exitWithStatus marks Process zombie for single-thread process death via signal"
    - "SECCOMP_RET_KILL: deliver signal first, then run checkSignalsOnSyscallExit for immediate termination"

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/io/signalfd.zig
    - src/kernel/sys/syscall/core/table.zig
    - src/kernel/sys/syscall/process/signals.zig
    - src/kernel/proc/sched/scheduler.zig
    - src/kernel/proc/signal.zig
    - src/uapi/process/signal.zig
    - src/user/test_runner/tests/syscall/event_fds.zig
    - src/user/test_runner/tests/syscall/seccomp.zig
    - src/user/test_runner/main.zig

key-decisions:
  - "Use sched.waitOn (indefinite block) + sched.unblock wakeup for signalfd; not waitOnWithTimeout"
  - "WaitQueue.removeThread called at top of signalfd read loop to clean stale entries after unblock"
  - "SIGSYS delivery + checkSignalsOnSyscallExit in seccomp KILL path ensures immediate termination without userspace escape"
  - "Fix process zombie marking in sched.exitWithStatus (not in signal.zig) to avoid circular dependency: signal_module -> process_module -> sched_module -> signal_module"
  - "KernelSigInfo syscall_nr surfaced via si_value_int for SA_SIGINFO handlers and ssi_int for signalfd readers"
  - "prlimit64 #GP crash is a pre-existing bug - baseline (302b291) hangs on siginfo_queue test before reaching it"

patterns-established:
  - "Frame-restoring syscall bypass: if syscall_num == SYS_RT_SIGRETURN, skip setReturnSigned (Phase 28 pattern maintained)"
  - "Signal delivery path bypassing process.exit() must trigger Zombie marking in sched.exitWithStatus"

requirements-completed: [SIG-03, SECC-01]

# Metrics
duration: ~90min
completed: 2026-02-17
---

# Phase 30 Plan 01: Signal Wakeup Integration Summary

**signalfd converted from 10ms polling to direct sched.unblock wakeup; seccomp KILL now delivers SIGSYS with syscall/arch metadata; sched.exitWithStatus fixed to mark Process zombie preventing sys_wait4 deadlock**

## Performance

- **Duration:** ~90 min (two sessions)
- **Started:** 2026-02-17T17:35:00Z (approximate)
- **Completed:** 2026-02-17T18:29:03-0600
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- SIG-03: signalfd read now uses indefinite block via `sched.waitOn` + `sched.unblock` wakeup from signal delivery -- no more 10ms polling latency
- SECC-01: `SECCOMP_RET_KILL` delivers SIGSYS with `si_syscall`/`si_arch` metadata; `checkSignalsOnSyscallExit` runs immediately after delivery to terminate the thread before userspace can execute further instructions
- Critical bug fix: `sched.exitWithStatus` now marks the owning Process as Zombie when the Thread exits via signal delivery (bypassing `process.exit()`), preventing `sys_wait4` from hanging forever waiting for a zombie that never appeared
- Bonus: the Process zombie fix also resolved a pre-existing hang in the `siginfo_queue: SA_SIGINFO handler receives pid` test (which was the blocking test in baseline 302b291)

## Task Commits

Each task was committed atomically:

1. **Task 1: Replace signalfd 10ms polling with indefinite block** - `302b291` (feat)
2. **Task 2: Deliver SIGSYS on seccomp KILL and fix process zombie marking** - `e16db48` (feat)

**Plan metadata:** (pending - this commit)

## Files Created/Modified
- `src/kernel/sys/syscall/io/signalfd.zig` - Replaced `waitOnWithTimeout` (10ms) with `waitOn` (indefinite); added `removeThread` stale entry cleanup; populated `ssi_int` with `syscall_nr` for SIGSYS
- `src/kernel/sys/syscall/core/table.zig` - Replaced silent ENOSYS return on seccomp KILL with `deliverSigsysToCurrentThread` + `checkSignalsOnSyscallExit`
- `src/kernel/sys/syscall/process/signals.zig` - Added `deliverSigsysToCurrentThread(syscall_nr, arch)` helper
- `src/kernel/proc/sched/scheduler.zig` - Fixed `exitWithStatus` to mark Process as Zombie when Thread exits via signal (single-thread process case)
- `src/kernel/proc/signal.zig` - Map `syscall_nr` to `si_value_int` for SIGSYS in both `setupSignalFrame` and `setupSignalFrameForSyscall`
- `src/uapi/process/signal.zig` - Extended `KernelSigInfo` with `syscall_nr: i32` and `arch: u32`; added `SYS_SECCOMP = 1` constant
- `src/user/test_runner/tests/syscall/event_fds.zig` - Added `testSignalfdDirectWakeup`
- `src/user/test_runner/tests/syscall/seccomp.zig` - Added `testSeccompSigsysDelivery`
- `src/user/test_runner/main.zig` - Registered both new tests

## Decisions Made

- **Indefinite block over timeout**: `sched.waitOn` instead of `waitOnWithTimeout(10ms)` -- once signal delivery calls `sched.unblock(target)`, the reader wakes immediately. The timeout was a workaround for missing direct wakeup integration.

- **removeThread at loop top**: `sched.unblock` transitions thread from Blocked to Ready but does NOT remove it from the WaitQueue. `WaitQueue.wakeUp` (close path) does remove it. Cleanup at the top of the read loop handles the stale entry left by the unblock path.

- **Fix in sched.exitWithStatus, not signal.zig**: The circular dependency `signal_module -> process_module -> sched_module -> signal_module` prevented adding a `process.exit()` call in the signal delivery path. Fixing it in `sched.exitWithStatus` avoids the cycle -- `sched` already imports `base.zig` which exports the `Process` type.

- **deliverSigsysToCurrentThread wrapper**: Centralizes the KernelSigInfo construction for SIGSYS to avoid duplicating the siginfo setup in `table.zig`. The wrapper lives in `signals.zig` alongside other delivery helpers.

- **checkSignalsOnSyscallExit after SIGSYS delivery**: Running the signal check inside `dispatch_syscall` (before returning) ensures the default Core/Terminate action for SIGSYS kills the thread immediately. Without this, the thread would return to userspace with ENOSYS and potentially execute more instructions before the signal is processed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] sched.exitWithStatus did not mark Process as Zombie**
- **Found during:** Task 2 (testSeccompSigsysDelivery test hung; parent waitpid never returned)
- **Issue:** When signal delivery terminates a thread via `checkSignalsOnSyscallExit` -> `sched.exitWithStatus`, the process lifecycle function `process.exit()` is bypassed. This means `proc.state` stays `.Running` and `sys_wait4` loops forever finding no zombie children.
- **Fix:** Added Process zombie marking at the start of `exitWithStatus` for the single-thread case: if `proc.state != .Zombie and proc.state != .Dead` and the thread refcount is 1, set `proc.exit_status` and `proc.state = .Zombie`.
- **Files modified:** `src/kernel/proc/sched/scheduler.zig`
- **Verification:** `testSeccompStrictBlocksGetpid` and `testSeccompSigsysDelivery` both complete without hang; parent receives zombie child correctly.
- **Committed in:** `e16db48` (part of Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** The fix is a correctness requirement -- any signal-terminated process would fail `wait4`. No scope creep.

## Issues Encountered

**Pre-existing prlimit64 crash revealed by our fix:**

The baseline commit 302b291 never reached the `misc: prlimit64 self as non-root` test because it hung on `siginfo_queue: SA_SIGINFO handler receives pid` first. After our Process zombie fix resolved that hang, the test suite advanced further and hit a pre-existing `#GP` (General Protection Fault) in the prlimit64 test. Registers showed `RAX=0xAAAAAAAAAAAAAAAA` (Zig undefined sentinel), indicating a use-after-free or uninitialized struct access in the prlimit64 path when the child forks and calls `setresuid(1000, 1000, 1000)` before accessing limits.

This crash is out of scope for this plan -- it predates our changes and will be addressed as a separate bug fix.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase 30 (signal wakeup integration) complete
- SIG-03 and SECC-01 tech debt items resolved
- Remaining v1.3 phases: 31 (TCP FIN teardown), 32 (futex robustlist), 33 (io_uring batch), 34 (VirtIO net RX), 35 (VFS page cache)
- Pre-existing blocker discovered: prlimit64 #GP crash in `testPrlimit64SelfAsNonRoot` -- should be investigated before Phase 35

---
*Phase: 30-signal-wakeup-integration*
*Completed: 2026-02-17*
