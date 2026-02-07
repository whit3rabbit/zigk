---
phase: 02-credentials-ownership
plan: 03
subsystem: syscall-ownership
tags: [chown, fchown, lchown, fchownat, posix, fsuid, suid-sgid-clearing]

# Dependency graph
requires:
  - phase: 02-01
    provides: fsuid/fsgid fields, infrastructure for filesystem permission checks
provides:
  - Complete chown family syscalls with POSIX permission enforcement
  - FileOps.chown method for fd-based ownership changes
  - VFS chownNoFollow wrapper for lchown semantics
  - Suid/sgid bit clearing on ownership change
affects: [phase-3-io-multiplexing, phase-8-security-hardening]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "chownKernel helper pattern for shared POSIX permission logic across chown variants"
    - "FileOps optional methods pattern for fd-specific operations"
    - "Suid/sgid clearing on ownership change for security compliance"

key-files:
  created: []
  modified:
    - src/kernel/fs/fd.zig
    - src/fs/vfs.zig
    - src/kernel/sys/syscall/fs/fs_handlers.zig

key-decisions:
  - "Use fsuid (not euid) for permission checks per plan 02-01 infrastructure"
  - "Clear suid/sgid bits on ownership change for POSIX security compliance"
  - "fchown uses FileOps.chown for direct fd access, avoiding path TOCTOU"
  - "chownKernel helper consolidates POSIX permission logic for all variants"

patterns-established:
  - "FileOps optional method pattern: Add new methods with default null to avoid breaking existing code"
  - "VFS wrapper pattern: VFS.chownNoFollow delegates to chown (current VFS doesn't follow symlinks, but API correctness maintained)"
  - "POSIX permission enforcement: Root can change anything, owner can chgrp to own group only"

# Metrics
duration: 5min
completed: 2026-02-07
---

# Phase 02 Plan 03: Chown Family Summary

**Complete chown family syscalls (chown, fchown, lchown, fchownat) with POSIX permission enforcement, suid/sgid clearing, and fd-based TOCTOU prevention**

## Performance

- **Duration:** 5 minutes
- **Started:** 2026-02-07T02:58:11Z
- **Completed:** 2026-02-07T03:03:26Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- All four chown syscalls implemented with full POSIX permission rules
- Suid/sgid bit clearing on ownership change for security compliance
- Direct fd-based fchown avoids path TOCTOU vulnerabilities
- Uses fsuid (not euid) for permission checks, leveraging 02-01 infrastructure

## Task Commits

Each task was committed atomically:

1. **Task 1: Add FileOps.chown and extend VFS chown for nofollow** - `4a6a498` (feat)
2. **Task 2: Enhance sys_chown and implement fchown, lchown, fchownat** - `404095f` (feat)

**Plan metadata:** Not yet committed (pending STATE.md update)

## Files Created/Modified
- `src/kernel/fs/fd.zig` - Added optional chown method to FileOps struct for fchown support
- `src/fs/vfs.zig` - Added chownNoFollow wrapper for lchown API correctness
- `src/kernel/sys/syscall/fs/fs_handlers.zig` - Enhanced sys_chown with POSIX enforcement, implemented sys_fchown/sys_lchown/sys_fchownat, added chownKernel helper

## Decisions Made

1. **Use fsuid for permission checks**: Leverages plan 02-01 infrastructure. POSIX filesystem operations check fsuid, not euid.
2. **Clear suid/sgid bits on ownership change**: Security requirement. When ownership changes, setuid/setgid bits are cleared to prevent privilege escalation.
3. **fchown via FileOps.chown**: Operates on fd directly, avoiding TOCTOU race conditions inherent in path-based syscalls.
4. **chownKernel helper**: Consolidates POSIX permission logic (root can change anything, owner can chgrp to own groups only) for code reuse across all chown variants.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Initial compilation error**: Used `uapi.fs.stat.Stat` instead of `uapi.stat.Stat`. Fixed by checking uapi/root.zig exports - stat is directly under uapi, not uapi.fs.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Chown family complete (4/4 syscalls implemented)
- Plan 02-04 (setuid family) ready to proceed
- All syscalls auto-register via dispatch table comptime name matching
- Test suite passes (166/186 tests passing, 20 skipped for known SFS/environment limitations)

---
*Phase: 02-credentials-ownership*
*Completed: 2026-02-07*

## Self-Check: PASSED

All commits verified to exist in git history.
