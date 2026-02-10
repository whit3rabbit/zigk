---
phase: 12-sfs-feature-expansion
plan: 01
subsystem: filesystem
tags: [sfs, hard-links, timestamps, vfs, nlink, utimensat, linkat]

# Dependency graph
requires:
  - phase: 11-sfs-deadlock-resolution
    provides: SFS lock restructuring with alloc_lock/io_lock ordering
provides:
  - Hard link support on SFS with global nlink synchronization across all entries sharing start_block
  - File timestamp modification via utimensat/futimesat with TOCTOU-safe updates
  - Extended DirEntry structure with nlink and atime fields (128 bytes total)
affects: [13-wait-queues, future-filesystem-enhancements]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Global nlink synchronization: all directory entries sharing start_block must have identical nlink values"
    - "TOCTOU-safe multi-phase lock pattern for link creation with sibling updates"
    - "Backward compatibility: nlink==0 treated as nlink==1 for legacy entries"

key-files:
  created: []
  modified:
    - src/fs/sfs/types.zig
    - src/fs/sfs/ops.zig
    - src/fs/sfs/root.zig

key-decisions:
  - "Hard links to directories are rejected (POSIX EPERM equivalent)"
  - "Hard links to symlinks are rejected for MVP simplicity"
  - "SFS stores timestamps as u32 Unix seconds (nanosecond precision lost)"
  - "UTIME_OMIT (-1) implemented to leave timestamps unchanged"
  - "Global nlink synchronization scans all 64 directory entry slots on link/unlink"

patterns-established:
  - "Global nlink invariant: ALL entries sharing start_block have identical nlink values at all times"
  - "Hard link creation increments nlink on old entry, new entry, and all siblings"
  - "Hard link removal decrements nlink on all siblings; blocks freed only when last link removed"

# Metrics
duration: 12min
completed: 2026-02-10
---

# Phase 12 Plan 01: SFS Feature Expansion Summary

**SFS hard link support with global nlink synchronization and file timestamp modification via utimensat/futimesat**

## Performance

- **Duration:** 12 min
- **Started:** 2026-02-10T23:02:07Z
- **Completed:** 2026-02-10T23:14:33Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Extended DirEntry with nlink and atime fields while maintaining 128-byte size
- Implemented sfsLink with CRITICAL global nlink synchronization ensuring all hard links remain consistent
- Implemented sfsSetTimestamps with TOCTOU-safe timestamp modification
- Updated sfsUnlink to respect nlink count and only free blocks when last link is removed
- Both x86_64 and aarch64 architectures build successfully

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend DirEntry with nlink and atime, update existing operations** - `be6dabf` (feat)
2. **Task 2: Implement sfsLink and sfsSetTimestamps, wire into FileSystem** - `f1c95e0` (feat)

## Files Created/Modified
- `src/fs/sfs/types.zig` - Added nlink and atime fields to DirEntry (128 bytes), updated RefreshedMetadata, added isSymlink() method
- `src/fs/sfs/ops.zig` - Implemented sfsLink and sfsSetTimestamps with TOCTOU-safe patterns, updated sfsUnlink with global nlink synchronization, updated sfsStat to return real timestamps and nlink
- `src/fs/sfs/root.zig` - Wired sfsLink and sfsSetTimestamps into FileSystem interface

## Decisions Made

**DirEntry Layout:**
- Repurposed 8 bytes of padding for nlink (u32) and atime (u32)
- New layout: 60 bytes (original fields) + 8 bytes (new fields) + 60 bytes (padding) = 128 bytes total
- Compile-time size validation ensures structure remains exactly 128 bytes

**Hard Link Restrictions:**
- Rejected hard links to directories (POSIX compliance - EPERM/AccessDenied)
- Rejected hard links to symlinks (simplification for SFS MVP)
- Only regular files can be hard-linked

**Global nlink Synchronization (CRITICAL):**
- At ALL times, every active directory entry sharing the same start_block must have identical nlink values
- When creating a hard link: increment nlink on old entry, new entry, AND all siblings
- When removing a hard link: decrement nlink on ALL siblings, only free blocks when nlink reaches 1
- This invariant is enforced by scanning all 64 directory entry slots on link/unlink operations

**Timestamp Precision:**
- SFS stores timestamps as u32 Unix seconds (lossy, nanosecond precision not retained)
- UTIME_OMIT (-1) supported to leave timestamps unchanged
- Acceptable limitation for SFS filesystem design

**TOCTOU Safety:**
- Both sfsLink and sfsSetTimestamps use established multi-phase lock pattern:
  1. Read directory unlocked (find entries, check conflicts)
  2. Acquire alloc_lock
  3. Re-read specific blocks under lock (TOCTOU prevention)
  4. Validate entries still match expected state
  5. Modify in buffer
  6. Release lock
  7. Write blocks outside lock
- Follows pattern from Phase 11 (SFS deadlock resolution)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None - implementation proceeded smoothly following the established TOCTOU-safe patterns from Phase 11.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SFS hard link support is complete and functional
- File timestamp modification (utimensat/futimesat) is implemented
- linkat and utimensat/futimesat syscalls can now succeed on SFS (no longer return EROFS/NotSupported)
- Ready for Phase 13 (Wait Queues & Blocking) or further SFS enhancements

---
*Phase: 12-sfs-feature-expansion*
*Completed: 2026-02-10*
