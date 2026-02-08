---
phase: 06-filesystem-extras
plan: 01
subsystem: filesystem
tags: [vfs, symlinks, hardlinks, timestamps, syscalls, uapi]

# Dependency graph
requires:
  - phase: 04-event-notification-fds
    provides: Syscall infrastructure, syscall number definitions for both architectures
provides:
  - Fixed *at syscall double-copy EFAULT bug for link/symlink/readlink operations
  - Kernel-space helpers (linkKernel, symlinkKernel, readlinkKernel) for safe path handling
  - SYS_UTIMENSAT and SYS_FUTIMESAT syscall number constants for both x86_64 and aarch64
  - VFS timestamp infrastructure with nanosecond precision (FileMeta fields, FileSystem callback)
affects: [07-filesystem-permissions, 08-advanced-io]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Kernel-space path helpers pattern for *at syscalls (prevent double-copy EFAULT)"
    - "VFS mount point dispatch for filesystem operations"

key-files:
  created: []
  modified:
    - src/kernel/sys/syscall/fs/fs_handlers.zig
    - src/uapi/syscalls/linux.zig
    - src/uapi/syscalls/linux_aarch64.zig
    - src/uapi/syscalls/root.zig
    - src/fs/meta.zig
    - src/fs/vfs.zig

key-decisions:
  - "Follow existing *Kernel helper pattern (unlinkKernel, mkdirKernel, etc) for consistency"
  - "Use FUTIMESAT compat number 528 on aarch64 (505 already taken by SYS_ACCESS)"
  - "set_timestamps returns NotSupported for read-only/virtual filesystems (InitRD, DevFS)"
  - "VFS timestamp infrastructure ready but syscall implementation deferred to Plan 02"

patterns-established:
  - "All *at syscalls must use kernel-space helpers instead of @intFromPtr(resolved.ptr)"
  - "Timestamp operations follow same mount point dispatch pattern as chmod/chown"

# Metrics
duration: 7min
completed: 2026-02-08
---

# Phase 06 Plan 01: Filesystem Extras Foundation Summary

**Fixed *at syscall double-copy bug for link/symlink/readlink, added VFS timestamp infrastructure with nanosecond precision**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-08T02:03:23Z
- **Completed:** 2026-02-08T02:10:05Z
- **Tasks:** 2
- **Files modified:** 6

## Accomplishments
- Extracted kernel-space helpers (linkKernel, symlinkKernel, readlinkKernel) to fix EFAULT bug in *at syscalls
- Added SYS_UTIMENSAT (280/88) and SYS_FUTIMESAT (261/528) constants for both architectures
- Extended FileMeta with nanosecond timestamp fields (atime_nsec, mtime_nsec)
- Implemented VFS timestamp infrastructure with set_timestamps callback and Vfs.setTimestamps method

## Task Commits

Each task was committed atomically:

1. **Task 1: Extract kernel-space helpers and fix *at double-copy bugs** - `cc09ee0` (fix)
2. **Task 2: Add syscall numbers and VFS timestamp infrastructure** - `0cc9f22` (feat)

## Files Created/Modified
- `src/kernel/sys/syscall/fs/fs_handlers.zig` - Added linkKernel, symlinkKernel, readlinkKernel helpers; fixed linkat/symlinkat/readlinkat
- `src/uapi/syscalls/linux.zig` - Added SYS_FUTIMESAT (261) and SYS_UTIMENSAT (280)
- `src/uapi/syscalls/linux_aarch64.zig` - Added SYS_UTIMENSAT (88) and SYS_FUTIMESAT (528)
- `src/uapi/syscalls/root.zig` - Re-exported SYS_FUTIMESAT and SYS_UTIMENSAT
- `src/fs/meta.zig` - Added atime/atime_nsec/mtime/mtime_nsec fields for nanosecond precision
- `src/fs/vfs.zig` - Added set_timestamps callback to FileSystem struct and Vfs.setTimestamps method

## Decisions Made
- Followed existing *Kernel helper pattern for consistency (unlinkKernel, mkdirKernel, renameKernel, chownKernel already established)
- Used compat number 528 for FUTIMESAT on aarch64 (505 already taken by SYS_ACCESS)
- VFS timestamp infrastructure returns NotSupported for read-only/virtual filesystems (InitRD, DevFS)
- Deferred actual utimensat/futimesat syscall implementation to Plan 02 (this plan only adds infrastructure)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

**Variable shadowing in setTimestamps:**
- Initial implementation used `const mount = findMountPoint(...)` which shadowed the `Vfs.mount` function
- Fixed by renaming local variable to `mp` and inlining mount point finding logic (matching chmod/chown pattern)
- Root cause: No findMountPoint helper exists; chmod/chown implement inline mount point search

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- VFS timestamp infrastructure ready for Plan 02 (utimensat/futimesat syscall implementation)
- *at syscall double-copy pattern fixed across all three operations (link/symlink/readlink)
- Syscall number constants defined and re-exported for both architectures
- No blockers for next plan

---
*Phase: 06-filesystem-extras*
*Completed: 2026-02-08*
