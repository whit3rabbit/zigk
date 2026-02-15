---
phase: 20-signal-handling-extensions
plan: 01
subsystem: signal-handling
tags: [signal, rt_sigtimedwait, rt_sigqueueinfo, clock_nanosleep, POSIX, dual-arch]
dependency_graph:
  requires:
    - phase-19-process-control-extensions (clone3, waitid, SigInfo struct)
    - existing signal infrastructure (rt_sigaction, rt_sigprocmask, pending_signals)
    - scheduler (yield, sleepForTicks, getTickCount)
  provides:
    - rt_sigtimedwait (synchronous signal waiting with timeout)
    - rt_sigqueueinfo (send signal with data to process)
    - rt_tgsigqueueinfo (send signal with data to thread)
    - clock_nanosleep (clock-aware sleep with TIMER_ABSTIME)
    - SI_* signal info code constants
    - TIMER_ABSTIME flag for absolute time sleep
  affects:
    - sys_nanosleep (now delegates to clock_nanosleep_internal)
    - signal pending/blocked bitmask operations (atomic CAS loop)
tech_stack:
  added:
    - "@cmpxchgWeak for atomic signal dequeue"
    - "atomic CAS loop pattern for pending_signals check-and-clear"
    - "clock_nanosleep_internal shared by nanosleep and clock_nanosleep"
  patterns:
    - "Bitmask-only signal tracking (MVP, no per-signal queue)"
    - "si_code restriction enforcement (negative codes only from userspace)"
    - "TIMER_ABSTIME absolute deadline comparison"
key_files:
  created:
    - .planning/phases/20-signal-handling-extensions/20-01-SUMMARY.md
  modified:
    - src/uapi/syscalls/linux.zig (SYS_RT_TGSIGQUEUEINFO = 297)
    - src/uapi/syscalls/linux_aarch64.zig (SYS_RT_TGSIGQUEUEINFO = 240)
    - src/uapi/syscalls/root.zig (SYS_RT_TGSIGQUEUEINFO export)
    - src/uapi/process/signal.zig (SI_* codes, TIMER_ABSTIME)
    - src/kernel/sys/syscall/process/signals.zig (3 new syscalls)
    - src/kernel/sys/syscall/process/scheduling.zig (clock_nanosleep, refactored nanosleep)
    - src/user/lib/syscall/signal.zig (4 wrappers, SigInfo, Timespec)
    - src/user/lib/syscall/root.zig (exports)
    - src/user/test_runner/tests/syscall/signals.zig (10 tests)
    - src/user/test_runner/main.zig (test registration)
decisions:
  - "Bitmask-only signal tracking for MVP (no per-thread siginfo queue)"
  - "rt_sigtimedwait uses atomic CAS loop for race-safe signal dequeue"
  - "si_code restriction: userspace can only send negative codes (prevents kernel impersonation)"
  - "clock_nanosleep supports CLOCK_REALTIME and CLOCK_MONOTONIC only"
  - "TIMER_ABSTIME uses absolute deadline comparison, not delta computation"
  - "sys_nanosleep delegates to clock_nanosleep_internal(CLOCK_MONOTONIC, 0)"
metrics:
  duration_minutes: 14.5
  tasks: 2
  commits: 2
  files_modified: 10
  syscalls_added: 4
  tests_added: 10
  tests_passed: 10
  architectures: [x86_64, aarch64]
---

# Phase 20 Plan 01: Signal Handling Extensions Summary

**One-liner:** rt_sigtimedwait, rt_sigqueueinfo, rt_tgsigqueueinfo, and clock_nanosleep with atomic CAS signal dequeue and shared nanosleep implementation.

## What Was Built

Implemented four new POSIX signal and time syscalls with full dual-architecture support:

1. **rt_sigtimedwait (128):** Synchronously wait for queued signals
   - Atomic CAS loop on pending_signals for race-safe check-and-clear
   - Supports zero timeout (immediate EAGAIN), finite timeout, and infinite wait
   - MVP: bitmask-only tracking (siginfo_t has si_signo only, no sender info)

2. **rt_sigqueueinfo (129):** Send signal with data to process
   - Enforces si_code < 0 restriction (prevents kernel signal impersonation)
   - Reuses checkSignalPermission for UID-based permission check
   - MVP: signal delivered but siginfo_t data not preserved

3. **rt_tgsigqueueinfo (297/240):** Send signal with data to specific thread
   - Targets tid within tgid thread group
   - Verifies thread belongs to specified thread group

4. **clock_nanosleep (230):** Clock-aware sleep with absolute time support
   - Supports CLOCK_REALTIME and CLOCK_MONOTONIC
   - TIMER_ABSTIME flag for absolute deadline sleep
   - Refactored sys_nanosleep to delegate to shared clock_nanosleep_internal

## Key Implementation Details

### Atomic Signal Dequeue Pattern

rt_sigtimedwait uses a CAS loop to atomically check and clear pending signals:

```zig
fn tryDequeueSignal(thread: *sched.Thread, wait_set: uapi.signal.SigSet) ?usize {
    const pending = @atomicLoad(u64, &thread.pending_signals, .acquire);
    const matching = pending & wait_set;
    if (matching == 0) return null;
    
    const bit_pos = @ctz(matching);
    const sig_bit: u64 = @as(u64, 1) << @intCast(bit_pos);
    
    var current = pending;
    while (true) {
        const result = @cmpxchgWeak(u64, &thread.pending_signals, current, 
                                    current & ~sig_bit, .acq_rel, .acquire);
        if (result) |new_val| {
            current = new_val;
            if ((current & sig_bit) == 0) return null; // Someone else took it
        } else {
            return bit_pos + 1; // Signal numbers are 1-indexed
        }
    }
}
```

This prevents race conditions where multiple threads try to dequeue the same signal.

### si_code Security Restriction

rt_sigqueueinfo and rt_tgsigqueueinfo enforce si_code < 0 from userspace:

```zig
const bytes = [4]u8{ info_buf[8], info_buf[9], info_buf[10], info_buf[11] };
const si_code: i32 = @bitCast(bytes);
if (si_code >= 0) return error.EPERM; // Cannot impersonate kernel signals
```

This prevents userspace from impersonating kernel-generated signals (SI_KERNEL = 0x80).

### Shared Nanosleep Implementation

sys_nanosleep now delegates to clock_nanosleep_internal:

```zig
pub fn sys_nanosleep(req_ptr: usize, rem_ptr: usize) SyscallError!usize {
    return clock_nanosleep_internal(CLOCK_MONOTONIC, 0, req_ptr, rem_ptr);
}
```

This consolidates sleep logic into a single implementation path per user decision.

## Deviations from Plan

None - plan executed exactly as written.

## Test Results

All 10 integration tests pass on both architectures:

### x86_64 Results
- testRtSigtimedwaitImmediate: PASS
- testRtSigtimedwaitTimeout: PASS
- testRtSigtimedwaitClearsPending: PASS
- testRtSigqueueinfoSelf: PASS
- testRtSigqueueinfoRejectsPositiveCode: PASS
- testRtSigqueueinfoToChild: PASS
- testClockNanosleepRelative: PASS
- testClockNanosleepRealtime: PASS
- testClockNanosleepInvalidClock: PASS
- testClockNanosleepAbstimePast: PASS

### aarch64 Results
- All 10 tests: PASS

### Test Coverage
- rt_sigtimedwait: immediate dequeue, timeout, pending bit clearing
- rt_sigqueueinfo: self-signal, si_code validation, child process signal
- clock_nanosleep: relative sleep, CLOCK_REALTIME, invalid clock, TIMER_ABSTIME

## Commits

1. **feat(20-01): implement rt_sigtimedwait, rt_sigqueueinfo, rt_tgsigqueueinfo, clock_nanosleep syscalls** (14c0de6)
   - Kernel syscall implementations
   - UAPI constants and structures
   - Refactored sys_nanosleep

2. **feat(20-01): add userspace wrappers and integration tests for signal extensions** (7b4df0b)
   - Userspace wrappers
   - 10 integration tests
   - Export new symbols

## Self-Check: PASSED

All files exist:
- [x] src/uapi/syscalls/linux.zig (SYS_RT_TGSIGQUEUEINFO = 297)
- [x] src/uapi/syscalls/linux_aarch64.zig (SYS_RT_TGSIGQUEUEINFO = 240)
- [x] src/uapi/process/signal.zig (SI_* codes)
- [x] src/kernel/sys/syscall/process/signals.zig (3 new syscalls)
- [x] src/kernel/sys/syscall/process/scheduling.zig (clock_nanosleep)
- [x] src/user/lib/syscall/signal.zig (4 wrappers)
- [x] src/user/test_runner/tests/syscall/signals.zig (10 tests)

All commits exist:
- [x] 14c0de6: kernel syscalls
- [x] 7b4df0b: userspace wrappers and tests

All tests pass:
- [x] 10/10 tests pass on x86_64
- [x] 10/10 tests pass on aarch64

## Known Limitations

1. **MVP Signal Queue**: Uses bitmask-only tracking, no per-thread siginfo queue
   - rt_sigtimedwait returns siginfo_t with si_signo only (sender info = 0)
   - rt_sigqueueinfo delivers signal but associated data not preserved
   - Acceptable for v1.2 - full queue deferred to v2.0

2. **Clock Support**: clock_nanosleep supports CLOCK_REALTIME and CLOCK_MONOTONIC only
   - Both map to the same tick-based monotonic source (no RTC)
   - CLOCK_PROCESS_CPUTIME_ID and CLOCK_THREAD_CPUTIME_ID return EINVAL

3. **Timeout Granularity**: 10ms tick-based sleep
   - Timeouts round up to next tick boundary
   - Sub-10ms precision not supported

## Next Steps

Phase complete. Ready for Phase 21 (if defined) or v1.2 milestone verification.

## Performance

- Duration: 14.5 minutes (872 seconds)
- Rate: 7.25 minutes per task
- Efficiency: 4 syscalls, 10 tests, dual-arch in < 15 minutes

## References

- Linux man pages: rt_sigtimedwait(2), rt_sigqueueinfo(2), clock_nanosleep(2)
- POSIX.1-2008: Signal concepts, signal.h
- Linux kernel: kernel/signal.c, kernel/time/posix-timers.c
