---
phase: 04-event-notification-fds
plan: 02
subsystem: io
tags: [timerfd, timer, syscall, epoll]
requires:
  - phase: 04-event-notification-fds
    plan: 04-01
    provides: "eventfd pattern, UAPI timerfd constants"
provides:
  - "timerfd kernel implementation with create/settime/gettime"
  - "timerfd userspace wrappers"
  - "polling-based timer expiration (10ms granularity)"
affects: ["04-04-tests"]
tech-stack:
  added: []
  patterns: ["TimerFdState with polling-based expiration", "getClockNanoseconds helper for TSC/RTC time"]
key-files:
  created:
    - src/kernel/sys/syscall/io/timerfd.zig
  modified:
    - src/kernel/sys/syscall/io/root.zig
    - src/user/lib/syscall/io.zig
key-decisions:
  - "Polling-based expiration instead of TimerWheel integration (simpler MVP, avoids IoRequest complexity)"
  - "Blocking read uses yield loop similar to epoll_wait (10ms tick granularity acceptable for timers)"
  - "CLOCK_BOOTTIME mapped to CLOCK_MONOTONIC (no suspend time tracking yet)"
duration: 5min
completed: 2026-02-07
---

# Phase 4 Plan 2: Timerfd Implementation Summary

**Polling-based timerfd with one-shot/periodic timers, relative/absolute time, and epoll integration**

## Performance

Execution time: 5 minutes

## Accomplishments

### 1. Timerfd Kernel Implementation (Task 1)

Implemented `sys_timerfd_create`, `sys_timerfd_settime`, and `sys_timerfd_gettime` in `src/kernel/sys/syscall/io/timerfd.zig`:

**TimerFdState:**
- `clockid`: CLOCK_REALTIME or CLOCK_MONOTONIC
- `armed`: Boolean flag for armed/disarmed state
- `next_expiry_ns`: Absolute nanosecond time of next expiration
- `interval_ns`: Repetition interval (0 = one-shot)
- `expiry_count`: Accumulated expirations not yet read
- `blocked_readers`, `reader_woken`: SMP-safe blocking support (currently unused - yield loop pattern)

**Design Decision: Polling-Based Expiration**
Instead of integrating with TimerWheel (which uses IoRequest with complex lifecycle), implemented simpler polling approach:
- `updateExpiryCount()` compares current time vs `next_expiry_ns`
- For periodic timers: calculates elapsed intervals, advances expiry time
- For one-shot timers: increments count once, disarms
- Called on every read() and poll() operation

**getClockNanoseconds() Helper:**
- Returns current time in nanoseconds for given clock ID
- CLOCK_REALTIME: Uses RTC if initialized, falls back to TSC
- CLOCK_MONOTONIC: Uses TSC (preferred) or tick count (10ms resolution fallback)
- CLOCK_BOOTTIME: Mapped to CLOCK_MONOTONIC (no suspend time tracking)

**timerfdRead():**
- Returns EINVAL if buf.len < 8
- Calls `updateExpiryCount()` to check for expirations
- If expiry_count > 0: returns count as u64, resets to 0
- If expiry_count == 0 and O_NONBLOCK: returns EAGAIN
- If expiry_count == 0 and blocking: uses yield loop (similar to epoll_wait pattern)
  - Yields to scheduler every iteration
  - Timer tick (10ms) provides natural wakeup points
  - Acceptable for timer granularity (already 1-10ms)

**timerfdPoll():**
- Calls `updateExpiryCount()` to refresh expiry state
- Returns EPOLLIN if expiry_count > 0
- Enables integration with epoll/select/poll

**timerfdClose():**
- Destroys TimerFdState

**sys_timerfd_create():**
- Validates clockid: CLOCK_REALTIME (0), CLOCK_MONOTONIC (1), CLOCK_BOOTTIME (7 -> mapped to 1)
- Validates flags: TFD_CLOEXEC, TFD_NONBLOCK
- Allocates TimerFdState, initializes with clockid, armed=false
- Allocates FileDescriptor with timerfd_file_ops
- Installs via allocAndInstall, returns fd_num

**sys_timerfd_settime():**
- Validates FD is a timerfd (checks fd.ops.read == timerfdRead)
- Reads ITimerSpec from userspace
- Validates timespec values (tv_sec >= 0, tv_nsec in [0, 1e9))
- Saves old_value if requested (time remaining until next expiry + interval)
- If new it_value is zero: disarms timer
- Else: arms timer with next_expiry_ns (absolute or relative based on TFD_TIMER_ABSTIME flag)
- Resets expiry_count to 0
- Returns 0

**sys_timerfd_gettime():**
- Validates FD is a timerfd
- Returns current settings as ITimerSpec:
  - it_value: time remaining until next expiry (clamped to 0 if expired)
  - it_interval: repetition interval
- If disarmed: both zero

**Exported in io/root.zig:**
- `sys_timerfd_create`, `sys_timerfd_settime`, `sys_timerfd_gettime`

### 2. Timerfd Userspace Wrappers (Task 2)

Added to `src/user/lib/syscall/io.zig`:

**Structures:**
- `TimeSpec`: i64 tv_sec, i64 tv_nsec
- `ITimerSpec`: TimeSpec it_interval, TimeSpec it_value

**Constants:**
- `TFD_CLOEXEC`: 0x80000
- `TFD_NONBLOCK`: 0x800
- `TFD_TIMER_ABSTIME`: 0x1
- `CLOCK_REALTIME`: 0
- `CLOCK_MONOTONIC`: 1

**Functions:**
- `timerfd_create(clockid, flags)`: syscall2, returns i32 fd
- `timerfd_settime(fd, flags, new_value, old_value)`: syscall4, returns void
- `timerfd_gettime(fd, curr_value)`: syscall2, returns void

Placed in "Timer File Descriptors" section after "Event Notification File Descriptors".

## Task Commits

| Task | Commit  | Description                                        |
|------|---------|---------------------------------------------------|
| 1    | 0b1becb | Implement timerfd kernel syscalls with polling    |
| 2    | 4a208a7 | Add timerfd userspace wrappers                    |

## Files Created/Modified

**Created:**
- `src/kernel/sys/syscall/io/timerfd.zig` (420 lines) - Full timerfd implementation

**Modified:**
- `src/kernel/sys/syscall/io/root.zig` - Export sys_timerfd_create/settime/gettime
- `src/user/lib/syscall/io.zig` - Add timerfd_create/settime/gettime wrappers (64 lines)

## Decisions Made

1. **Polling-based expiration instead of TimerWheel**:
   - TimerWheel uses IoRequest with complex lifecycle management
   - Polling approach simpler for MVP: store absolute expiry time, check on read/poll
   - 10ms tick granularity acceptable for timers (Linux timerfd also has ~1-10ms resolution)
   - Avoids callback complexity and IoRequest state machine

2. **Blocking read uses yield loop (not pipe.zig blocking pattern)**:
   - Similar to epoll_wait implementation in scheduling.zig
   - Yields to scheduler, timer tick (10ms) provides natural wakeup
   - No need for blocked_readers wakeup since we poll expiry on every iteration
   - Acceptable for MVP since timer granularity is already 10ms

3. **CLOCK_BOOTTIME maps to CLOCK_MONOTONIC**:
   - No suspend time tracking yet
   - Both clocks behave identically in current implementation
   - Can differentiate later if suspend/resume support added

4. **getClockNanoseconds helper reuses hal.timing and hal.rtc**:
   - CLOCK_REALTIME: RTC (if initialized) else TSC
   - CLOCK_MONOTONIC: TSC (if available) else tick count
   - Same time sources as sys_clock_gettime in scheduling.zig
   - Consistent time semantics across kernel

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Initial compilation error:**
- Used `uapi.timerfd.ITimerSpec.Timespec` instead of `uapi.abi.Timespec`
- ITimerSpec struct uses `abi.Timespec` directly (from UAPI base module)
- Fixed by changing function signatures to use `uapi.abi.Timespec`

## Next Phase Readiness

**Ready for 04-03 (signalfd):**
- UAPI constants already created in 04-01 (SignalFdSigInfo, SFD_* flags)
- Same FileOps pattern established (timerfd and eventfd examples)
- Will need signal module integration for signal mask handling

**Ready for 04-04 (tests):**
- All three event FD types now implemented (eventfd, timerfd, pending signalfd)
- Userspace wrappers available for test usage
- Can test timerfd with one-shot timers, periodic timers, relative/absolute time
- Can test epoll integration (EPOLLIN when timer expires)

## Self-Check: PASSED

All created files verified to exist.
All commit hashes verified in git log.
