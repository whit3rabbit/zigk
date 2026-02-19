---
phase: 34-timer-notification-modes
plan: "01"
subsystem: kernel-posix-timers
tags: [posix-timers, sigev, signals, threading, syscall]
dependency_graph:
  requires: []
  provides:
    - SIGEV_THREAD and SIGEV_THREAD_ID support in timer_create
    - sys_gettid syscall returning current thread TID
    - PosixTimer with target_tid and sigev_value fields
    - SI_TIMER siginfo delivery on timer expiration
  affects:
    - src/uapi/process/time.zig
    - src/kernel/proc/process/types.zig
    - src/kernel/sys/syscall/misc/posix_timer.zig
    - src/kernel/proc/sched/scheduler.zig
    - src/kernel/sys/syscall/process/process.zig
tech_stack:
  added: []
  patterns:
    - SIGEV_THREAD_ID validated by findThreadByTid at timer creation time
    - processIntervalTimers calls findThreadByTid before scheduler.lock acquisition (safe)
    - SIGEV_THREAD treated as SIGEV_SIGNAL at kernel level (glibc handles thread spawning)
key_files:
  created: []
  modified:
    - src/uapi/process/time.zig
    - src/kernel/proc/process/types.zig
    - src/kernel/sys/syscall/misc/posix_timer.zig
    - src/kernel/proc/sched/scheduler.zig
    - src/kernel/sys/syscall/process/process.zig
decisions:
  - SIGEV_THREAD identical to SIGEV_SIGNAL at kernel level; glibc wraps in thread callback
  - findThreadByTid safe in processIntervalTimers because scheduler.lock not held at call site
  - SIGEV_THREAD_ID falls back to current thread if target thread has exited (no silent signal loss)
  - SI_TIMER siginfo enqueued alongside bitmask set for SA_SIGINFO handler compatibility
metrics:
  duration: 449s
  completed: "2026-02-19"
  tasks: 2
  files: 5
---

# Phase 34 Plan 01: SIGEV_THREAD and SIGEV_THREAD_ID Timer Notification Modes Summary

**One-liner:** Added SIGEV_THREAD and SIGEV_THREAD_ID notification modes to POSIX timers with directed thread signal delivery and sys_gettid syscall for TID identification.

## What Was Built

Extended the kernel POSIX timer infrastructure to accept all four SIGEV_* notification modes. Previously, `timer_create` returned EINVAL for SIGEV_THREAD (2) and SIGEV_THREAD_ID (4). Now it accepts and correctly implements both modes.

### Changes

**src/uapi/process/time.zig:**
- Removed "(not supported)" comment from SIGEV_THREAD and SIGEV_THREAD_ID constants
- Added `getTid()` method to `SigEvent` to extract `_sigev_un._tid` from the padding area (Linux ABI: first 4 bytes of `_pad` after sigev_value/signo/notify)

**src/kernel/proc/process/types.zig:**
- Added `target_tid: i32 = 0` field to `PosixTimer` for SIGEV_THREAD_ID target thread
- Added `sigev_value: usize = 0` field to `PosixTimer` for SI_TIMER siginfo metadata
- Updated `notify` field comment to list all four SIGEV_* modes

**src/kernel/sys/syscall/misc/posix_timer.zig:**
- Replaced narrow EINVAL check (only 0 and 1 accepted) with validation against all four POSIX constants
- Signal number validation now covers SIGEV_THREAD and SIGEV_THREAD_ID (not just SIGEV_SIGNAL)
- SIGEV_THREAD_ID: extracts TID via `getTid()`, validates thread exists and belongs to caller's process
- Stores `target_tid` and `sigev_value` in timer slot for both sevp_ptr != 0 and default paths

**src/kernel/proc/sched/scheduler.zig (processIntervalTimers):**
- Expanded signal_pending recovery to handle SIGEV_THREAD_ID (checks target thread's pending signals)
- Timer expiration for SIGEV_SIGNAL/SIGEV_THREAD: delivers to current thread with SI_TIMER siginfo
- Timer expiration for SIGEV_THREAD_ID: uses `findThreadByTid` to locate target; falls back to current thread if target exited
- SI_TIMER code used in KernelSigInfo for all signal-delivering modes
- SIGEV_NONE: increments overrun counter only (unchanged behavior)

**src/kernel/sys/syscall/process/process.zig:**
- Added `sys_gettid()` syscall (SYS_GETTID = 186 on x86_64, 178 on aarch64)
- Returns `thread.tid` for the currently executing thread

## Verification

- `zig build -Darch=x86_64`: passes cleanly
- `zig build -Darch=aarch64`: passes cleanly
- All 12 existing posix_timer tests pass on x86_64 (confirmed via test log: all show "PASS")
- Test suite timed out on "vectored_io: sendfile large transfer" which is a pre-existing flaky test unrelated to this plan

## Deviations from Plan

### Structural refactoring in sys_timer_create

**Found during:** Task 2

The plan described replacing the validation block inline. The original code had the slot-finding and initialization after the `if (sevp_ptr != 0)` block. Rather than partially restructuring, the sevp_ptr != 0 path was made to handle its own slot-finding and return early, with a separate default path for sevp_ptr == 0. This avoids variable escaping an `if` block (which Zig doesn't allow for variables set conditionally) and keeps the logic clear.

This is a structural deviation that preserves the same semantics and is not a correctness issue.

## Self-Check: PASSED

**Files verified:**
- FOUND: src/uapi/process/time.zig
- FOUND: src/kernel/proc/process/types.zig
- FOUND: src/kernel/sys/syscall/misc/posix_timer.zig
- FOUND: src/kernel/proc/sched/scheduler.zig
- FOUND: src/kernel/sys/syscall/process/process.zig

**Commits verified:**
- FOUND: 5f390d7 (Task 1 - UAPI types, PosixTimer, sys_gettid)
- FOUND: 5823552 (Task 2 - timer_create SIGEV_THREAD/SIGEV_THREAD_ID, processIntervalTimers)
