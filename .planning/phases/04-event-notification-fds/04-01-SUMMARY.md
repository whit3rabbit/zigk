---
phase: 04-event-notification-fds
plan: 01
subsystem: io
tags: [eventfd, timerfd, signalfd, uapi, syscall]
requires:
  - phase: 03-io-multiplexing
    provides: "epoll infrastructure and FileOps.poll pattern"
provides:
  - "eventfd kernel implementation with read/write/poll/close"
  - "UAPI constants for eventfd, timerfd, signalfd"
  - "eventfd userspace wrappers"
affects: ["04-02-timerfd", "04-03-signalfd", "04-04-tests"]
tech-stack:
  added: []
  patterns: ["EventFdState with FileOps vtable", "atomic counter with blocking I/O"]
key-files:
  created:
    - src/uapi/io/eventfd.zig
    - src/uapi/io/timerfd.zig
    - src/uapi/io/signalfd.zig
    - src/kernel/sys/syscall/io/eventfd.zig
  modified:
    - src/uapi/root.zig
    - src/kernel/sys/syscall/io/root.zig
    - src/user/lib/syscall/io.zig
    - build.zig
key-decisions:
  - "Created all three UAPI constant files upfront (eventfd, timerfd, signalfd) to avoid repeated modification of uapi module"
  - "Used Spinlock + atomic flags for SMP-safe wakeup prevention (pipe.zig pattern)"
  - "MAX_COUNTER set to 0xfffffffffffffffe per Linux semantics"
  - "Added sched and sync module imports to syscall_io in build.zig"
duration: 7min
completed: 2026-02-07
---

# Phase 4 Plan 1: UAPI Constants + Eventfd Implementation Summary

**Eventfd syscall with full semantics (normal/semaphore mode, blocking/nonblocking, epoll integration) and UAPI constants for all event FD types**

## Performance

Execution time: 7 minutes

## Accomplishments

### 1. UAPI Constants (Task 1)
Created three UAPI constant files under `src/uapi/io/`:

**eventfd.zig:**
- `EFD_CLOEXEC`, `EFD_NONBLOCK`, `EFD_SEMAPHORE` flags

**timerfd.zig:**
- `TFD_*` flags (CLOEXEC, NONBLOCK, TIMER_ABSTIME, TIMER_CANCEL_ON_SET)
- `CLOCK_*` constants (REALTIME, MONOTONIC, BOOTTIME)
- `ITimerSpec` struct using existing `abi.Timespec`

**signalfd.zig:**
- `SFD_*` flags (CLOEXEC, NONBLOCK)
- `SignalFdSigInfo` struct (128 bytes, comptime-verified size)

All three modules exported in `uapi/root.zig`. Creating all constants upfront avoids repeated uapi module modification in subsequent plans.

### 2. Eventfd Kernel Implementation (Task 2)
Implemented `sys_eventfd2` and `sys_eventfd` in `src/kernel/sys/syscall/io/eventfd.zig`:

**EventFdState:**
- 64-bit atomic counter
- Semaphore mode flag
- Spinlock-protected waiter lists (blocked_readers/blocked_writers)
- Atomic woken flags for SMP-safe lost wakeup prevention

**eventfdRead:**
- Returns EINVAL if buf.len < 8
- Blocks when counter == 0 (unless O_NONBLOCK)
- Normal mode: returns counter, resets to 0
- Semaphore mode: returns 1, decrements by 1
- Wakes blocked writers after decrementing counter
- Uses pipe.zig blocking pattern (disable interrupts, check woken flag, block)

**eventfdWrite:**
- Returns EINVAL if buf.len < 8 or value == maxInt(u64)
- Blocks on overflow (counter + value > MAX_COUNTER, unless O_NONBLOCK)
- Atomically adds value to counter
- Wakes blocked readers after increment

**eventfdPoll:**
- Returns EPOLLIN when counter > 0
- Returns EPOLLOUT when counter < MAX_COUNTER

**eventfdClose:**
- Destroys EventFdState

**Build system changes:**
- Added `sched` and `sync` module imports to `syscall_io_module` in build.zig
- Exported `sys_eventfd2` and `sys_eventfd` in `io/root.zig`

### 3. Userspace Wrappers (Task 3)
Added to `src/user/lib/syscall/io.zig`:

- `eventfd2(initval, flags)` wrapper using syscall2
- `eventfd(initval)` wrapper delegating to eventfd2(initval, 0)
- Exported `EFD_CLOEXEC`, `EFD_NONBLOCK`, `EFD_SEMAPHORE` constants
- Placed in new "Event Notification File Descriptors" section

## Task Commits

| Task | Commit  | Description                                      |
|------|---------|--------------------------------------------------|
| 1    | 9c462b4 | Add UAPI constants for eventfd, timerfd, signalfd |
| 2    | 2e98d45 | Implement eventfd2 and eventfd syscalls          |
| 3    | 0948071 | Add eventfd userspace wrappers                   |

## Files Created/Modified

**Created:**
- `src/uapi/io/eventfd.zig` - EFD_* flags
- `src/uapi/io/timerfd.zig` - TFD_* flags, ITimerSpec, CLOCK_* constants
- `src/uapi/io/signalfd.zig` - SFD_* flags, SignalFdSigInfo (128 bytes)
- `src/kernel/sys/syscall/io/eventfd.zig` - EventFdState, FileOps, syscalls

**Modified:**
- `src/uapi/root.zig` - Export eventfd, timerfd, signalfd modules
- `src/kernel/sys/syscall/io/root.zig` - Export sys_eventfd2, sys_eventfd
- `src/user/lib/syscall/io.zig` - Add eventfd2/eventfd wrappers and constants
- `build.zig` - Add sched and sync imports to syscall_io_module

## Decisions Made

1. **UAPI upfront:** Created all three event FD UAPI files at once to avoid repeated module changes (timerfd/signalfd plans won't touch uapi again)

2. **Blocking pattern:** Followed pipe.zig SMP-safe pattern:
   - Disable interrupts before releasing lock
   - Check atomic woken flag before blocking
   - Prevents lost wakeups on multicore systems

3. **MAX_COUNTER:** Set to `0xfffffffffffffffe` per Linux semantics (one less than maxInt(u64) - 1 to allow overflow detection)

4. **Build dependencies:** Added `sched` and `sync` to `syscall_io_module` since eventfd needs scheduler blocking and spinlock protection

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Module import path:** Initial implementation used `@import("../base.zig")` which failed with "import outside module path". Fixed by using `@import("base.zig")` (relative imports not allowed in Zig 0.16).

**Missing module dependencies:** `syscall_io_module` lacked `sched` and `sync` imports. Added both to build.zig following the pattern used by other syscall modules.

## Next Phase Readiness

**Ready for 04-02 (timerfd):**
- UAPI constants for timerfd already created (ITimerSpec, TFD_* flags)
- EventFdState pattern established for timerfd state management
- FileOps vtable pattern clear for timerfd read/poll/close
- build.zig dependencies already in place

**Ready for 04-03 (signalfd):**
- UAPI constants for signalfd already created (SignalFdSigInfo, SFD_* flags)
- Same FileOps pattern applies
- Will need signal module integration for signal mask handling

**Ready for 04-04 (tests):**
- All UAPI constants available for test imports
- Userspace wrappers ready for test usage
- Can test eventfd, timerfd, signalfd together

## Self-Check: PASSED

All created files verified to exist.
All commit hashes verified in git log.
