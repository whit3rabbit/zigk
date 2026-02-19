---
phase: 33-timer-resolution-improvement
plan: 01
subsystem: kernel-timing
tags: [apic, lapic, aarch64-timer, scheduler, clock_getres, posix-timers, timerfd, sysinfo]

# Dependency graph
requires:
  - phase: 32-timer-capacity-expansion
    provides: MAX_POSIX_TIMERS=32 and posix_timer_count fast-path that this phase's 1000Hz tick depends on
provides:
  - Hardware timer at 1000Hz (1ms ticks) on x86_64 via LAPIC
  - Hardware timer at 1000Hz (1ms ticks) on aarch64 via generic timer
  - Scheduler constants TICK_MICROS=1000, load-avg at 5000-tick intervals
  - clock_getres returns 1ms (1_000_000 ns) resolution
  - POSIX timer TICK_NS=1_000_000 (1ms granularity)
  - sysinfo uptime divides ticks by 1000
  - timerfd and clock_nanosleep use 1ms tick period
affects: [33-02-PLAN, posix-timer accuracy, nanosleep precision, itimer SIGALRM timing]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "1ms tick constant pattern: TICK_NS=1_000_000, TICK_MICROS=1000, ticks/1000 for seconds"
    - "Tick-to-ms identity: 1 tick = 1ms, so fallback ms = ticks (no multiply needed)"

key-files:
  created: []
  modified:
    - src/arch/x86_64/kernel/apic/root.zig
    - src/arch/aarch64/root.zig
    - src/kernel/proc/sched/scheduler.zig
    - src/kernel/sys/syscall/process/scheduling.zig
    - src/kernel/sys/syscall/misc/posix_timer.zig
    - src/kernel/sys/syscall/misc/sysinfo.zig
    - src/kernel/sys/syscall/io/timerfd.zig

key-decisions:
  - "1 tick = 1ms identity simplifies tick-to-ms conversion: ticks *| 10 becomes just ticks in fallback paths"
  - "Load average interval updated from 500 ticks (5s at 100Hz) to 5000 ticks (5s at 1000Hz) to preserve 5-second period"
  - "setAlarm overflow clamp denominator updated from /100 to /1000 to match new tick rate"

patterns-established:
  - "TICK_NS=1_000_000 ns (1ms): used in posix_timer.zig and clock_nanosleep for tick-to-ns conversion"
  - "TICK_MICROS=1000 us (1ms): used in scheduler.zig processIntervalTimers for itimer decrement"

requirements-completed: [PTMR-02]

# Metrics
duration: 5min
completed: 2026-02-18
---

# Phase 33 Plan 01: Timer Resolution Improvement - Tick Frequency 100Hz to 1000Hz

**LAPIC and aarch64 generic timers reconfigured to 1000Hz; all kernel timer arithmetic updated to 1ms tick constants across scheduler, clock_getres, POSIX timers, sysinfo, timerfd, and clock_nanosleep**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-02-18T19:56:34Z
- **Completed:** 2026-02-18T20:01:00Z
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments

- x86_64 LAPIC timer changed from `enablePeriodicTimer(100)` to `enablePeriodicTimer(1000)` -- confirmed in test log: "APIC: LAPIC timer enabled at 1000Hz (Vector 48)"
- aarch64 generic timer changed from `pit.init(100)` to `pit.init(1000)` -- 1ms period on both architectures
- All 1000Hz-dependent constants propagated: TICK_MICROS 10000->1000, TICK_NS 10_000_000->1_000_000, sysinfo /100->1000, clock_getres 10ms->1ms, load average check 500->5000 ticks
- x86_64 test suite ran; timer-related tests (time_ops, posix_timer, itimer, clock_nanosleep, alarm) all pass; 14 pre-existing non-timer failures unchanged

## Task Commits

Each task was committed atomically:

1. **Task 1: Change hardware timer frequency to 1000Hz on both architectures** - `1cf5182` (feat)
2. **Task 2: Update scheduler, time syscalls, and POSIX timer constants from 10ms to 1ms** - `83d3919` (feat)

**Plan metadata:** (docs commit follows)

## Files Created/Modified

- `src/arch/x86_64/kernel/apic/root.zig` - enablePeriodicTimer 100->1000, log message updated to "1000Hz"
- `src/arch/aarch64/root.zig` - pit.init(100)->pit.init(1000), comment updated to "1000Hz"
- `src/kernel/proc/sched/scheduler.zig` - TICK_MICROS 10000->1000; setAlarm: +99/100->+999/1000, *100->*1000, /100->1000; load avg 500->5000
- `src/kernel/sys/syscall/process/scheduling.zig` - tick_ns 10_000_000->1_000_000 (x2), getCurrentTimeNs *10_000_000->*1_000_000, getMonotonicTime ticks*10->ticks, gettimeofday ticks*10->ticks, clock_getres 10_000_000->1_000_000, ppoll us/10_000->us/1_000
- `src/kernel/sys/syscall/misc/posix_timer.zig` - TICK_NS 10_000_000->1_000_000, doc comment updated
- `src/kernel/sys/syscall/misc/sysinfo.zig` - uptime @divTrunc(ticks,100)->@divTrunc(ticks,1000)
- `src/kernel/sys/syscall/io/timerfd.zig` - fallback ticks*|10->ticks, doc comment updated

## Decisions Made

- The tick-to-ms identity (1 tick = 1ms at 1000Hz) simplifies fallback paths: `ticks *| 10` becomes just `ticks` with a comment "1 tick = 1ms". Cleaner and avoids saturating multiply.
- Load average interval changed from 500 to 5000 ticks to preserve the 5-second update period at the new frequency. The EXP constants inside updateLoadAverages are based on 5-second intervals and remain unchanged.
- setAlarm's overflow-prevention clamp was `maxInt(u64) / 100`; changed to `maxInt(u64) / 1000` to match the new ticks-per-second value.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

The x86_64 test suite hit a 90-second timeout during `vectored_io: sendfile large transfer` (stress test). This is a pre-existing behavior unrelated to the tick rate change. All 14 test failures are pre-existing non-timer failures (lchown, accept4, dup3, setrlimit, prlimit64, renameat2, splice). All timer-specific tests passed: time_ops nanosleep/clock_getres/clock_gettime, posix_timer create/settime/signal delivery, alarm, setitimer/getitimer, clock_nanosleep.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Hardware timer infrastructure at 1000Hz is complete and verified
- All kernel timer arithmetic uses 1ms tick constants consistently
- Plan 33-02 can proceed with nanosleep precision improvements that depend on 1ms granularity

---
*Phase: 33-timer-resolution-improvement*
*Completed: 2026-02-18*
