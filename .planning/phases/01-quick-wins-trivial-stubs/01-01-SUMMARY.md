---
phase: 01-quick-wins-trivial-stubs
plan: 01
subsystem: kernel-syscalls
tags: [syscall-numbers, memory-management, process-struct, madvise, mlock, mincore]

requires:
  - phase: none
    provides: "First phase, no dependencies"
provides:
  - "14 missing SYS_* constants for both x86_64 and aarch64"
  - "sched_policy and sched_priority fields on Process struct"
  - "6 memory management no-op syscalls (madvise, mlock, munlock, mlockall, munlockall, mincore)"
affects: [01-02, 01-03, 01-04]

tech-stack:
  added: []
  patterns: ["no-op syscall stub pattern with argument validation"]

key-files:
  created: []
  modified:
    - "src/uapi/syscalls/linux.zig"
    - "src/uapi/syscalls/linux_aarch64.zig"
    - "src/uapi/syscalls/root.zig"
    - "src/kernel/proc/process/types.zig"
    - "src/kernel/sys/syscall/memory/memory.zig"

key-decisions:
  - "Memory stubs validate arguments but always return success (kernel never swaps)"
  - "mincore writes 1 to each byte in vec (all pages always resident)"
  - "aarch64 syscall numbers verified unique against existing constants"

patterns-established:
  - "No-op syscall pattern: validate args, return 0 (for features the kernel does not implement)"

duration: 5min
completed: 2026-02-06
---

# Phase 1 Plan 01: Infrastructure Summary

**Syscall number definitions for 8 new constants on both architectures, Process scheduler fields, and 6 memory management no-op syscalls**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-06T23:24:00Z
- **Completed:** 2026-02-06T23:29:00Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- All 8 missing SYS_* constants defined for x86_64 and aarch64 with correct Linux ABI numbers
- Process struct extended with sched_policy (u8) and sched_priority (i32) fields
- 6 memory management no-op syscalls with proper argument validation
- Zero syscall number collisions on either architecture
- Both architectures compile cleanly

## Task Commits

Each task was committed atomically:

1. **Task 1: Add missing SYS_* constants and Process struct fields** - `1a9e463` (feat)
2. **Task 2: Implement memory management no-op syscalls** - `d84d7ff` (feat)

## Files Created/Modified
- `src/uapi/syscalls/linux.zig` - Added 8 x86_64 syscall number constants
- `src/uapi/syscalls/linux_aarch64.zig` - Added 8 aarch64 syscall number constants
- `src/uapi/syscalls/root.zig` - Re-exported all new constants
- `src/kernel/proc/process/types.zig` - Added sched_policy, sched_priority to Process
- `src/kernel/sys/syscall/memory/memory.zig` - 6 new sys_m* handler functions

## Decisions Made
- Memory stubs validate arguments but always return success since the kernel has no swap
- mincore writes 1 (resident) per page since all pages are always memory-resident
- aarch64 numbers verified unique via grep (no collisions with existing constants)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed mincore UserPtr API usage**
- **Found during:** Task 2 (mincore implementation)
- **Issue:** Agent used non-existent `UserPtr.asSlice()` method
- **Fix:** Changed to byte-at-a-time writes using `UserPtr.from(vec_ptr + i).writeValue(@as(u8, 1))`
- **Files modified:** src/kernel/sys/syscall/memory/memory.zig
- **Verification:** Both architectures compile cleanly
- **Committed in:** d84d7ff

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Fix necessary for compilation. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All syscall number constants available for Plans 02 and 03
- Process struct scheduler fields ready for scheduling syscall handlers
- Memory no-ops ready for integration testing in Plan 04

---
*Phase: 01-quick-wins-trivial-stubs*
*Completed: 2026-02-06*

## Self-Check: PASSED
