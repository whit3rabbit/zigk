---
phase: 29-siginfo-queue
plan: 02
subsystem: signal
tags: [signals, siginfo, sa-siginfo, rt-signals, posix, x86_64, aarch64, signal-frame]

dependency_graph:
  requires:
    - phase: 29-01
      provides: KernelSigInfo, SigInfoQueue, per-thread siginfo queue wired into all delivery paths
  provides:
    - SA_SIGINFO handler three-argument calling convention (signum, siginfo_t*, ucontext_t*)
    - SigInfoT extern struct (128-byte ABI-compatible user-visible siginfo_t)
    - SA_SIGINFO signal frame setup on both x86_64 (interrupt + syscall paths) and aarch64 (syscall path)
    - Integration tests: SA_SIGINFO pid delivery, rt_sigqueueinfo round-trip, standard coalescing, RT queuing
    - Fixed tryDequeueSignal RT signal bitmask clearing (only clear when queue empty)
    - Fixed x86_64 asm_helpers.S: removed rdi/rsi/rdx zeroing that destroyed SA_SIGINFO handler args
  affects:
    - src/kernel/proc/signal.zig
    - src/uapi/process/signal.zig
    - src/arch/x86_64/lib/asm_helpers.S
    - src/kernel/sys/syscall/process/signals.zig
    - src/user/test_runner/tests/syscall/signals.zig
    - src/user/test_runner/main.zig

tech_stack:
  added: [SigInfoT extern struct (uapi/process/signal.zig)]
  patterns:
    - "SA_SIGINFO stack layout on x86_64: [restorer][ucontext][siginfo_t] low-to-high; ret advances RSP to ucontext"
    - "SA_SIGINFO stack layout on aarch64: [ucontext][siginfo_t] with LR=restorer; SP at ucontext for sigreturn"
    - "Allocate siginfo BEFORE ucontext so siginfo is at higher address; ucontext is below it"
    - "RT signal bitmask: clear pending bit only when siginfo_queue has no more entries for that signal"
    - "x86_64 sysretq: do NOT zero rdi/rsi/rdx - they carry SA_SIGINFO handler arguments"

key_files:
  created: []
  modified:
    - src/uapi/process/signal.zig
    - src/kernel/proc/signal.zig
    - src/arch/x86_64/lib/asm_helpers.S
    - src/kernel/sys/syscall/process/signals.zig
    - src/user/test_runner/tests/syscall/signals.zig
    - src/user/test_runner/main.zig

key_decisions:
  - "x86_64 signal stack layout: siginfo allocated FIRST (highest address), then ucontext below, then restorer at bottom - ensures 'ret' in handler advances RSP to ucontext for rt_sigreturn"
  - "aarch64 signal stack layout: ucontext at bottom (SP points to it), siginfo above it, LR=restorer - consistent with aarch64 SyscallFrame conventions"
  - "Remove rdi/rsi/rdx zeroing from x86_64 sysretq path - these registers carry SA_SIGINFO handler args and are not kernel-sensitive after syscall return"
  - "RT signal tryDequeueSignal: bitmask bit cleared only when hasSignal() returns false after dequeue - enables multiple dequeues of same RT signal"
  - "SigInfoT _pad = [128-48]u8 (80 bytes), NOT [128-40]u8 - si_value_ptr is usize (8 bytes) ending at offset 48"

patterns_established:
  - "SA_SIGINFO frame setup: reserve siginfo space before ucontext space so stack layout is correct for sigreturn"
  - "SA_SIGINFO test pattern: callconv(.c) handler with (sig: i32, info_ptr: usize, _ucontext: usize) signature"
  - "RT signal queuing test: block signal, send twice via rt_sigqueueinfo, verify two rt_sigtimedwait successes"

requirements_completed: [SIG-02]

duration: "~60 minutes"
completed: "2026-02-17"
---

# Phase 29 Plan 02: SA_SIGINFO Handler Argument Passing Summary

**SA_SIGINFO three-argument calling convention wired into signal frame setup on both architectures, with SigInfoT ABI struct and four integration tests proving end-to-end metadata delivery.**

## Performance

- **Duration:** ~60 minutes
- **Started:** 2026-02-17T12:00:00Z
- **Completed:** 2026-02-17T13:09:48Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments

- SA_SIGINFO handlers now receive (signum, siginfo_t*, ucontext_t*) on both x86_64 and aarch64
- SigInfoT (128-byte ABI-compatible extern struct with comptime size assert) added to uapi
- Signal frame setup on both interrupt path and syscall-exit path populate siginfo_t from KernelSigInfo queue
- Fixed x86_64 assembly register zeroing that was silently destroying handler arguments after sysretq
- Fixed RT signal bitmask clearing bug that made second queued instance of same RT signal invisible
- 4 new integration tests pass on both architectures (SA_SIGINFO pid delivery, rt_sigqueueinfo round-trip, standard coalescing, RT queuing)
- All 17 existing signal tests continue to pass

## Task Commits

Each task was committed atomically:

1. **Task 1: SA_SIGINFO handler argument passing in signal frame setup** - `e3223dd` (feat)
2. **Task 2: Integration tests for siginfo metadata delivery** - `cdc532b` (feat)

## Files Created/Modified

- `src/uapi/process/signal.zig` - Added SigInfoT extern struct (128 bytes, comptime-verified)
- `src/kernel/proc/signal.zig` - SA_SIGINFO siginfo_t allocation and arg passing in both setupSignalFrame (interrupt path) and setupSignalFrameForSyscall (syscall exit path)
- `src/arch/x86_64/lib/asm_helpers.S` - Removed rdi/rsi/rdx zeroing before sysretq (was destroying SA_SIGINFO handler arguments)
- `src/kernel/sys/syscall/process/signals.zig` - Fixed tryDequeueSignal: RT signals only clear bitmask bit when siginfo_queue has no more entries for that signal
- `src/user/test_runner/tests/syscall/signals.zig` - 4 new integration tests (Tests 18-21) with SA_SIGINFO callconv(.c) handler
- `src/user/test_runner/main.zig` - Registered 4 new siginfo_queue tests

## Decisions Made

- x86_64 stack layout: siginfo allocated FIRST (reserved at higher address), ucontext below it, restorer at bottom. When the SA_SIGINFO handler executes `ret`, RSP advances past restorer to ucontext_addr, which is exactly where sys_rt_sigreturn reads from.
- aarch64 stack layout: ucontext at SP (sigreturn reads from SP), siginfo above it, LR = restorer address. Consistent with existing aarch64 frame conventions.
- x86_64 sysretq path: removed zeroing of rdi, rsi, rdx. These registers carry SA_SIGINFO handler arguments (signum, siginfo_ptr, ucontext_ptr). Kept zeroing of r8, r9, r10 which are not used for handler arguments.
- RT signal bitmask in tryDequeueSignal: for signals >= 32, use hasSignal() check after dequeue to determine whether to clear the pending bitmask bit. This enables correct dequeuing of multiple instances of the same RT signal.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Inverted SA_SIGINFO stack layout -- siginfo below ucontext (wrong)**
- **Found during:** Task 1 (SA_SIGINFO handler argument passing)
- **Issue:** Initial implementation pushed siginfo BELOW ucontext. When handler executed `ret`, RSP advanced to siginfo_t instead of ucontext, causing sys_rt_sigreturn to read garbage RIP (printed "Invalid RIP 0")
- **Fix:** Reversed allocation order -- allocate siginfo space FIRST (at higher SP), then ucontext below it, then restorer at bottom. Stack: [restorer][ucontext][siginfo_t] from low to high.
- **Files modified:** src/kernel/proc/signal.zig
- **Verification:** rt_sigreturn correctly restores context, handler returns cleanly
- **Committed in:** e3223dd (Task 1 commit)

**2. [Rule 1 - Bug] x86_64 sysretq zeroed rdi/rsi/rdx -- destroyed SA_SIGINFO handler args**
- **Found during:** Task 1 (debugging why testSiginfoPidUid saw info_ptr=0)
- **Issue:** `asm_helpers.S` zeroed rdi, rsi, rdx before sysretq as a security measure. For SA_SIGINFO signal delivery, these registers carry signum (rdi), siginfo_ptr (rsi), and ucontext_ptr (rdx). The zeroing destroyed them, making handler always see null pointers.
- **Fix:** Removed `xor %esi, %esi; xor %edi, %edi; xor %edx, %edx` from sysretq path. Kept zeroing of r8, r9, r10.
- **Files modified:** src/arch/x86_64/lib/asm_helpers.S
- **Verification:** Handler receives non-zero info_ptr, reads correct si_pid
- **Committed in:** cdc532b (Task 2 commit)

**3. [Rule 1 - Bug] tryDequeueSignal cleared RT signal bitmask on first dequeue**
- **Found during:** Task 2 (testSiginfoRtSignalQueuing -- second rt_sigtimedwait returned WouldBlock)
- **Issue:** `tryDequeueSignal` always cleared the pending bitmask bit regardless of signal type. For RT signals with two queued instances, first dequeue cleared the bit, making second instance invisible to the pending check.
- **Fix:** Added `is_rt_signal` check: for RT signals (signo >= 32), only clear bitmask if `!thread.siginfo_queue.hasSignal(signo)`. Standard signals always clear on first dequeue (coalescing behavior preserved).
- **Files modified:** src/kernel/sys/syscall/process/signals.zig
- **Verification:** testSiginfoRtSignalQueuing PASS -- two SIGRTMIN instances dequeued successfully
- **Committed in:** cdc532b (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (all Rule 1 - bugs)
**Impact on plan:** All fixes necessary for correctness. Bug 1 and 2 prevented the core SA_SIGINFO feature from working at all. Bug 3 prevented RT signal queuing tests from passing. No scope creep.

## Issues Encountered

- None beyond the 3 bugs documented above as deviations.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SIG-02 requirement fully met: siginfo metadata flows from sender through kernel queue to SA_SIGINFO handler
- Phase 29 (siginfo-queue) complete: both plans executed, all tests pass on x86_64 and aarch64
- Pre-existing failures (uid/gid: lchown non-existent, socket: accept4, fd_ops: dup3, resource: setrlimit, misc: prlimit64) are unrelated to signal changes

---
*Phase: 29-siginfo-queue*
*Completed: 2026-02-17*

## Self-Check: PASSED

Files verified:
- FOUND: src/uapi/process/signal.zig
- FOUND: src/kernel/proc/signal.zig
- FOUND: src/arch/x86_64/lib/asm_helpers.S
- FOUND: src/kernel/sys/syscall/process/signals.zig
- FOUND: src/user/test_runner/tests/syscall/signals.zig
- FOUND: src/user/test_runner/main.zig
- FOUND: .planning/phases/29-siginfo-queue/29-02-SUMMARY.md

Commits verified:
- FOUND: e3223dd (feat(29-02): implement SA_SIGINFO handler argument passing in signal frame setup)
- FOUND: cdc532b (feat(29-02): add siginfo integration tests and fix RT signal queuing)
