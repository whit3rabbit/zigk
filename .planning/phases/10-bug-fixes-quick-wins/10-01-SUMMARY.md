---
phase: 10-bug-fixes-quick-wins
plan: 01
subsystem: security
tags: [syscall, permission-checks, user-memory, filesystem, sfs]

# Dependency graph
requires:
  - phase: 02-uid-gid-infrastructure
    provides: "Process credential management (gid, egid, sgid fields)"
  - phase: 06-filesystem-extras
    provides: "SFS filesystem with ownership tracking"
provides:
  - "POSIX-compliant sys_setregid permission enforcement"
  - "Stack buffer support in copyStringFromUser"
  - "SFS fchown support via FileOps.chown"
affects: [permission-model, user-memory-validation, sfs-metadata-operations]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "canSetGid helper for POSIX permission checks"
    - "isValidUserPtr for bounds-only validation (demand paging support)"
    - "FD-based metadata update pattern for SFS"

key-files:
  created: []
  modified:
    - "src/kernel/sys/syscall/process/process.zig"
    - "src/kernel/sys/syscall/core/user_mem.zig"
    - "src/fs/sfs/ops.zig"

key-decisions:
  - "Remove hasSetGidCapability bypass from sys_setregid (POSIX compliance)"
  - "Use isValidUserPtr instead of isValidUserAccess for string copy (demand paging)"
  - "Implement FD-based chown (sfsFdChown) separate from path-based sfsChown"

patterns-established:
  - "Permission checks use canSetGid(proc, target_gid) pattern matching sys_setresgid"
  - "Assembly fixup mechanism handles page faults for user memory access"
  - "SFS metadata updates follow lock → read sector → modify → write pattern"

# Metrics
duration: 4min
completed: 2026-02-09
---

# Phase 10 Plan 01: Bug Fixes & Quick Wins Summary

**Fixed three critical kernel bugs: POSIX permission checks in sys_setregid, stack buffer validation in copyStringFromUser, and SFS fchown support**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-10T02:04:09Z
- **Completed:** 2026-02-10T02:08:08Z
- **Tasks:** 3
- **Files modified:** 3

## Accomplishments
- sys_setregid enforces POSIX permission rules (unprivileged process cannot set arbitrary GIDs)
- copyStringFromUser accepts stack-allocated userspace buffers without EFAULT
- SFS files support fchown syscall via FileOps.chown implementation

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix sys_setregid permission enforcement (BUGFIX-01)** - `fe6cc0d` (fix)
2. **Task 2: Fix copyStringFromUser stack buffer validation (BUGFIX-03)** - `941d88d` (fix)
3. **Task 3: Implement SFS FileOps.chown (BUGFIX-02)** - `24d7793` (feat)

## Files Created/Modified
- `src/kernel/sys/syscall/process/process.zig` - Removed hasSetGidCapability bypass, enforces POSIX gid/egid/sgid checks
- `src/kernel/sys/syscall/core/user_mem.zig` - Replaced isValidUserAccess with isValidUserPtr for demand paging support
- `src/fs/sfs/ops.zig` - Added sfsFdChown function and registered in sfs_ops FileOps struct

## Decisions Made

1. **sys_setregid permission fix:** Removed hasSetGidCapability check entirely. POSIX requires unprivileged process can only set rgid/egid to current gid, egid, or sgid. The hasSetGidCapability check allowed setting to ANY group in supplementary groups list, violating POSIX.

2. **copyStringFromUser validation:** Removed page presence check (isValidUserAccess) in favor of bounds-only check (isValidUserPtr). The assembly fixup mechanism (_asm_copy_from_user) handles page faults gracefully, supporting demand paging for stack buffers not yet faulted-in.

3. **SFS chown naming:** Named FD-based chown function `sfsFdChown` to avoid collision with existing path-based `sfsChown` VFS operation.

## Deviations from Plan

None - plan executed exactly as written. All three bugs fixed as specified.

## Issues Encountered

None - all tasks completed without problems. Build succeeded on both x86_64 and aarch64 architectures.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Bug fixes complete, kernel builds cleanly on both architectures
- POSIX permission model now correct for setregid
- User memory validation supports demand paging (stack buffers work correctly)
- SFS fchown syscall fully functional

## Self-Check: PASSED

**Files verified:**
- ✓ src/kernel/sys/syscall/process/process.zig
- ✓ src/kernel/sys/syscall/core/user_mem.zig
- ✓ src/fs/sfs/ops.zig
- ✓ .planning/phases/10-bug-fixes-quick-wins/10-01-SUMMARY.md

**Commits verified:**
- ✓ fe6cc0d (Task 1)
- ✓ 941d88d (Task 2)
- ✓ 24d7793 (Task 3)

---
*Phase: 10-bug-fixes-quick-wins*
*Completed: 2026-02-09*
