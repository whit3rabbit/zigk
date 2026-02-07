---
phase: 01-quick-wins-trivial-stubs
plan: 02
subsystem: process-scheduling
tags: [syscalls, scheduling, ppoll, stubs]
requires:
  - plan: 01-01
    for: Process.sched_policy and .sched_priority fields
provides:
  - capability: scheduling-policy-query
    exports: [sys_sched_get_priority_max, sys_sched_get_priority_min, sys_sched_getscheduler, sys_sched_getparam]
  - capability: scheduling-policy-set
    exports: [sys_sched_setscheduler, sys_sched_setparam]
  - capability: sched-rr-quantum-query
    exports: [sys_sched_rr_get_interval]
  - capability: ppoll-timeout-stub
    exports: [sys_ppoll]
affects:
  - phase: 03-io-multiplexing
    reason: ppoll will need real FD monitoring when poll infrastructure is implemented
tech-stack:
  added: []
  patterns:
    - name: scheduling-policy-validation
      location: src/kernel/sys/syscall/process/scheduling.zig
      rationale: Validates policy types and priority ranges per POSIX spec
key-files:
  created: []
  modified:
    - path: src/kernel/sys/syscall/process/scheduling.zig
      why: Added 8 new syscall handlers (7 sched_* + ppoll)
    - path: build.zig
      why: Added process module import to syscall_scheduling_module
decisions:
  - what: Implement ppoll as standalone stub instead of delegating to net/poll.zig
    why: The net/poll.zig module requires socket_file_ops which is not available in the scheduling module, and creating cross-module dependencies for an MVP stub adds unnecessary complexity
    alternatives: Could have added net import to scheduling module and delegated to sys_poll
  - what: ppoll with NULL timeout returns 0 immediately for MVP
    why: Infinite wait without FD polling infrastructure would block forever with no way to wake up
    alternatives: Could block and rely on signals, but MVP does not need blocking behavior
  - what: Priority range 1-99 for FIFO/RR, 0 for others
    why: Matches Linux kernel behavior (see sched(7) man page)
    alternatives: None - this is POSIX standard
completed: 2026-02-06
duration: 3min
---

# Phase 01 Plan 02: Scheduling Syscall Stubs Summary

**One-liner:** 7 scheduling policy syscalls (get/set policy, priority ranges, RR quantum) + ppoll timeout stub

## What Was Built

### Scheduling Policy Queries (4 syscalls)
- `sys_sched_get_priority_max`: Returns max priority for a policy (99 for FIFO/RR, 0 for others)
- `sys_sched_get_priority_min`: Returns min priority for a policy (1 for FIFO/RR, 0 for others)
- `sys_sched_getscheduler`: Reads current policy from Process.sched_policy
- `sys_sched_getparam`: Reads current priority from Process.sched_priority

### Scheduling Policy Sets (2 syscalls)
- `sys_sched_setscheduler`: Validates policy and priority, writes to Process struct
- `sys_sched_setparam`: Validates priority against current policy, writes to Process struct

### Scheduling Quantum Query (1 syscall)
- `sys_sched_rr_get_interval`: Returns 100ms RR quantum (Linux default)

### ppoll Timeout Stub (1 syscall)
- `sys_ppoll`: Validates arguments, sleeps for timeout, returns 0 (no FDs ready)
  - nfds=0 with timeout: sleeps and returns 0
  - nfds>0 with timeout=0: returns 0 immediately
  - nfds>0 with timeout>0: sleeps and returns 0
  - NULL timeout: returns 0 immediately (no infinite wait)
  - Signal mask: validated but ignored (MVP limitation)

## Implementation Details

### Process Lookup Pattern
All scheduling syscalls that take a PID argument follow this pattern:
```zig
const proc = if (target_pid == 0)
    base.getCurrentProcess()
else
    process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;
```

### Priority Range Validation
The priority validation enforces POSIX/Linux semantics:
- **SCHED_FIFO / SCHED_RR**: Priority must be in range [1, 99]
- **SCHED_OTHER / SCHED_BATCH / SCHED_IDLE**: Priority must be exactly 0

This validation occurs in both `sys_sched_setscheduler` and `sys_sched_setparam`.

### ppoll Timeout Conversion
The ppoll syscall converts timespec to milliseconds with overflow checks:
```zig
const sec_ms: u64 = @as(u64, @intCast(ts.tv_sec)) * 1000;
const nsec_ms: u64 = @as(u64, @intCast(ts.tv_nsec)) / 1_000_000;
timeout_ms = sec_ms + nsec_ms;
```

Then converts milliseconds to scheduler ticks (10ms per tick):
```zig
const ticks = ms / 10;
sched.sleepForTicks(ticks);
```

## Task Commits

| Task | Description | Commit | Files Modified |
|------|-------------|--------|----------------|
| 1 | Scheduling policy query/set syscalls | 30d0aa8 | build.zig, scheduling.zig |
| 2 | ppoll syscall stub | 5d3c21d | scheduling.zig |

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

- ✅ `zig build -Darch=x86_64` succeeds
- ✅ `zig build -Darch=aarch64` succeeds
- ✅ `zig build test` passes (no regressions)
- ✅ All 8 function names match lowercased SYS_* constants
- ✅ Grep confirms all handlers exist in scheduling.zig

## Next Phase Readiness

**Blockers:** None

**Concerns:**
- ppoll currently does not monitor file descriptors. Phase 3 (I/O Multiplexing) will need to implement real FD polling by delegating to shared poll infrastructure or extending FileOps.poll methods.

**Dependencies for Phase 3:**
- ppoll will need FileOps.poll implementations for pipes, sockets, and regular files
- Current MVP returns 0 (no FDs ready) after timeout, which is correct behavior but not useful for real programs

## Testing Notes

These syscalls are not yet exercised by the integration test suite. Testing will occur when:
1. Programs that call `sched_getscheduler(0)` verify they receive `SCHED_OTHER` (0)
2. Programs that call `sched_get_priority_max(SCHED_FIFO)` verify they receive 99
3. Programs that call `ppoll` with timeout verify the timeout works correctly

## Self-Check: PASSED

Modified files verified:
- ✅ src/kernel/sys/syscall/process/scheduling.zig exists
- ✅ build.zig exists

Commits verified:
- ✅ 30d0aa8 exists
- ✅ 5d3c21d exists
