---
phase: 06-filesystem-extras
plan: 02
subsystem: filesystem
tags: [syscall, vfs, timestamps, utimensat, futimesat, posix]

# Dependency graph
requires:
  - phase: 06-01
    provides: VFS setTimestamps infrastructure, SYS_UTIMENSAT/SYS_FUTIMESAT constants
provides:
  - sys_utimensat and sys_futimesat syscall implementations with full POSIX semantics
  - Userspace wrappers for utimensat and futimesat in syscall library
  - UTIME_NOW and UTIME_OMIT constants for timestamp control
affects: [06-03, testing, filesystem-programs]

# Tech tracking
tech-stack:
  added: [hal.timing for current time, sched.getTickCount fallback]
  patterns: [Special timespec values (UTIME_NOW, UTIME_OMIT), microsecond to nanosecond conversion]

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/fs/fs_handlers.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/root.zig
    - build.zig

key-decisions:
  - "Use hal.timing.getTscFrequency() and rdtsc() for nanosecond-precision current time with sched.getTickCount() fallback"
  - "Reuse existing Timeval type from time.zig instead of duplicating in io.zig"
  - "AT_SYMLINK_NOFOLLOW returns ENOSYS for MVP (symlink timestamp modification not supported)"

patterns-established:
  - "getCurrentTimeNs helper pattern for timestamp syscalls (matches timerfd.zig pattern)"
  - "UTIME_NOW (0x3fffffff) and UTIME_OMIT (0x3ffffffe) constants per POSIX spec"

# Metrics
duration: 4min
completed: 2026-02-08
---

# Phase 06 Plan 02: Timestamp Control Syscalls Summary

**Nanosecond-precision file timestamp control via utimensat and futimesat with POSIX UTIME_NOW/UTIME_OMIT semantics**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-08
- **Completed:** 2026-02-08
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- sys_utimensat with full POSIX semantics (NULL times, UTIME_NOW, UTIME_OMIT, normal values)
- sys_futimesat legacy wrapper with microsecond to nanosecond conversion
- Userspace wrappers exported from syscall root module
- Both syscalls auto-registered via dispatch table

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement sys_utimensat and sys_futimesat** - `9b55b00` (feat)
2. **Task 2: Add userspace wrappers** - `df04105` (feat)

## Files Created/Modified
- `src/kernel/sys/syscall/fs/fs_handlers.zig` - sys_utimensat and sys_futimesat implementations with dirfd resolution, UTIME_NOW/UTIME_OMIT handling, VFS delegation
- `src/user/lib/syscall/io.zig` - utimensat and futimesat wrappers with UTIME_NOW/UTIME_OMIT constants
- `src/user/lib/syscall/root.zig` - Re-exports of utimensat, futimesat, UTIME_NOW, UTIME_OMIT
- `build.zig` - Added hal and sched imports to fs_handlers module

## Decisions Made

**1. Use hal.timing for current time (UTIME_NOW implementation)**
- Rationale: Matches existing timerfd pattern (getTscFrequency + rdtsc for nanosecond precision)
- Fallback: sched.getTickCount() with 10ms resolution when TSC unavailable
- Pattern: getCurrentTimeNs() helper function reusable for future timestamp syscalls

**2. Reuse existing Timeval from time.zig**
- Rationale: Avoids type duplication, maintains consistency with existing time types
- Implementation: @import("time.zig").Timeval in futimesat signature

**3. AT_SYMLINK_NOFOLLOW returns ENOSYS**
- Rationale: MVP limitation - symlink timestamp modification not implemented
- POSIX-compliant error code for unsupported operation
- Future work: Add symlink timestamp support when VFS supports lstat operations

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**1. Missing hal import in fs_handlers module**
- Problem: Build failed with "no module named 'hal'" error
- Root cause: fs_handlers module didn't have hal dependency in build.zig
- Resolution: Added hal and sched imports to syscall_fs_handlers_module in build.zig
- Verification: Both x86_64 and aarch64 builds pass

**2. Incorrect sched.getCurrentTick() call**
- Problem: Function doesn't exist in sched module
- Root cause: Plan used incorrect function name from memory
- Resolution: Checked timerfd.zig pattern, corrected to sched.getTickCount()
- Verification: Build passes, fallback time calculation matches timerfd pattern

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

**Ready for Plan 03 (final filesystem extras syscalls):**
- Timestamp control infrastructure complete (utimensat, futimesat)
- VFS setTimestamps fully exercised by both syscalls
- Pattern established for UTIME_NOW/UTIME_OMIT handling
- Build system configured with hal/sched imports for fs_handlers

**No blockers for Plan 03.**

---
*Phase: 06-filesystem-extras*
*Completed: 2026-02-08*
