---
phase: 29-siginfo-queue
plan: 01
subsystem: signal
tags: [signals, siginfo, per-thread-queue, rt-signals, posix]
dependency_graph:
  requires: [28-01-rt-sigsuspend-race-fix]
  provides: [per-thread-siginfo-queue, deliverSignalToThreadWithInfo, KernelSigInfo, SigInfoQueue]
  affects: [src/uapi/process/signal.zig, src/kernel/proc/thread.zig, src/kernel/sys/syscall/process/signals.zig, src/kernel/proc/signal.zig, src/kernel/sys/syscall/io/signalfd.zig]
tech_stack:
  added: [KernelSigInfo struct, SigInfoQueue fixed-capacity ring buffer (32 entries)]
  patterns: [coalescing-standard-signals, always-queue-rt-signals, best-effort-drop-on-overflow, EAGAIN-on-rt_sigqueueinfo-overflow]
key_files:
  created: []
  modified:
    - src/uapi/process/signal.zig
    - src/kernel/proc/thread.zig
    - src/kernel/sys/syscall/process/signals.zig
    - src/kernel/proc/signal.zig
    - src/kernel/sys/syscall/io/signalfd.zig
decisions:
  - "Standard signals (1-31) coalesce: second send while pending does not double-enqueue (POSIX behavior)"
  - "RT signals (32-64) always enqueue even if already pending (real-time signal queuing)"
  - "General delivery paths (kill/tkill) use best-effort silent drop on queue overflow (graceful degradation)"
  - "rt_sigqueueinfo and rt_tgsigqueueinfo return EAGAIN on queue overflow (POSIX SIGQUEUE_MAX enforcement)"
  - "siginfo is passed through to setupSignalFrame/setupSignalFrameForSyscall as ?KernelSigInfo for Plan 02 SA_SIGINFO support"
  - "Queue capacity 32 entries - sufficient for microkernel (Linux defaults to 128 per UID)"
  - "Enqueue happens BEFORE bitmask atomic set so consumers see metadata ready when they see pending bit"
metrics:
  duration: "10 minutes"
  completed: "2026-02-17"
  tasks_completed: 2
  files_modified: 5
---

# Phase 29 Plan 01: Siginfo Queue Infrastructure Summary

Per-thread siginfo queue built and wired into all signal delivery and consumption paths, replacing bitmask-only signal tracking (SIG-02 tech debt).

## What Was Built

KernelSigInfo struct and SigInfoQueue ring buffer added to uapi/process/signal.zig. Thread struct gains siginfo_queue field initialized in both creation paths. All signal delivery paths enqueue metadata; all consumption paths dequeue it.

## Tasks Completed

### Task 1: Define KernelSigInfo and SigInfoQueue types, add queue to Thread
**Commit:** `9db7331`

Added to `src/uapi/process/signal.zig`:
- `KernelSigInfo` struct: signo (u8), code (i32), pid (u32), uid (u32), value (usize)
- `SigInfoQueue`: fixed-capacity ring buffer (32 entries) with enqueue/dequeue/dequeueBySignal/dequeueByMask/hasSignal methods
- `SIGINFO_QUEUE_CAPACITY = 32` constant

Added to `src/kernel/proc/thread.zig`:
- `siginfo_queue: uapi.signal.SigInfoQueue` field on Thread struct
- Initialized in both `createKernelThread` and `createUserThread` paths

### Task 2: Wire siginfo queue into all delivery and consumption paths
**Commit:** `33ad444`

Changes to `src/kernel/sys/syscall/process/signals.zig`:
- `deliverSignalToThread` now wraps `deliverSignalToThreadWithInfo(target, signum, null)`
- `deliverSignalToThreadWithInfo` enqueues KernelSigInfo before setting bitmask bit
- Standard signals coalesce (already_pending check before enqueue)
- RT signals always enqueue regardless of pending state
- `sys_kill` passes SI_USER siginfo with sender PID/UID
- `sys_tkill` and `sys_tgkill` pass SI_TKILL siginfo with sender PID/UID
- `deliverToPgroupMember` and `deliverToBroadcastTarget` pass SI_USER siginfo
- `tryDequeueSignal` now returns `?uapi.signal.KernelSigInfo` (was `?usize`)
- `writeSigInfo` now accepts `*const KernelSigInfo` and populates full siginfo_t fields (si_code, si_pid, si_uid, si_value at correct ABI offsets)
- `sys_rt_sigtimedwait` updated to use new KernelSigInfo return type from tryDequeueSignal
- `sys_rt_sigqueueinfo`: extracts user-provided PID/UID/value from siginfo_t buffer, stores in queue, returns EAGAIN on overflow
- `sys_rt_tgsigqueueinfo`: same EAGAIN-on-overflow semantics

Changes to `src/kernel/proc/signal.zig`:
- `checkSignals`: dequeues siginfo after clearing bitmask, passes to setupSignalFrame
- `checkSignalsOnSyscallExit`: same dequeue pattern, passes to setupSignalFrameForSyscall
- `setupSignalFrame`: signature extended with `siginfo: ?uapi.signal.KernelSigInfo` parameter (`_ = siginfo` for Plan 02)
- `setupSignalFrameForSyscall`: same signature extension

Changes to `src/kernel/sys/syscall/io/signalfd.zig`:
- `signalfdRead`: dequeues siginfo after clearing bitmask, populates `ssi_code`, `ssi_pid`, `ssi_uid` in SignalFdSigInfo

## Deviations from Plan

None - plan executed exactly as written. The `si_tgsigqueueinfo` suffix naming in locals (si_tg, si_value_tg, etc.) was used to avoid Zig shadowing issues in the same function scope.

## Test Results

All existing signal tests pass on both architectures:
- `signal: sigaction install handler` - PASS
- `signal: sigprocmask block signal` - PASS
- `signal: sigpending after block` - PASS
- `signal: kill self` - PASS
- `signal: kill single process` - PASS
- `signal: kill current/specific process group` - PASS
- `signal_ext: rt_sigtimedwait immediate/timeout/clears_pending` - PASS
- `signal_ext: rt_sigqueueinfo self/rejects_positive_code/to_child` - PASS
- `signal: rt_sigsuspend basic` - PASS
- `misc: rt_sigpending/rt_sigpending after block` - PASS
- `event_fds: signalfd create/read/epoll` - PASS

Pre-existing timeout in `vectored_io: sendfile large transfer` is unrelated to this plan (verified by running tests before changes - same timeout occurs).

## Self-Check: PASSED

All modified files exist on disk. Both task commits verified in git log:
- `9db7331`: feat(29-01): define KernelSigInfo, SigInfoQueue types and add queue to Thread
- `33ad444`: feat(29-01): wire siginfo queue into all signal delivery and consumption paths
