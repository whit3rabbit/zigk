---
phase: 48-directory-traversal-path-resolution-inode-cache
plan: 01
subsystem: ext2-filesystem
tags: [ext2, path-resolution, getdents, readlink, statfs, inode-cache, vfs, filesystems]
dependency_graph:
  requires: [47-01-SUMMARY.md]
  provides: [ext2 multi-component path resolution, directory listing (getdents), fast symlink readlink, statfs, 16-entry LRU inode cache]
  affects: [src/fs/ext2/, src/user/test_runner/tests/fs/, build.zig, src/fs/meta.zig]
tech_stack:
  added:
    - src/fs/ext2/inode.zig -- resolvePath, lookupInDir, getCachedInode, InodeCacheEntry, Ext2DirFd, ext2_dir_ops, ext2GetdentsFromFd, openDirInode
  patterns:
    - 16-entry LRU inode cache with generation counter (eliminates redundant readInode during path traversal)
    - DirEntry stride via rec_len (not computed from name_len) to handle last-entry padding
    - ext2 directory FDs use separate ext2_dir_ops vtable with getdents callback
    - Fast symlink detection via i_size <= 60 AND i_blocks == 0
    - nlink wired through FileMeta to stat results for POSIX directory link count
key_files:
  created: []
  modified:
    - src/fs/ext2/inode.zig
    - src/fs/ext2/mount.zig
    - src/fs/meta.zig
    - src/kernel/sys/syscall/io/stat.zig
    - src/user/test_runner/tests/fs/ext2_basic.zig
    - src/user/test_runner/main.zig
    - build.zig
decisions:
  - Inode cache is 16 entries with LRU eviction via generation counter on Ext2Fs struct
  - resolvePath does NOT follow symlinks during traversal (correct for Phase 48, future enhancement)
  - nlink field added to FileMeta (default 1) and wired through statPathKernel for directory link count verification
  - ext2 test image extended with nested dirs a/b/c/file.txt and fast symlink link_to_hello -> /mnt2/hello.txt
  - openDirInode replaces openRootDir for all directory open operations
patterns_established:
  - "Ext2DirFd + ext2_dir_ops: directory FDs with getdents callback for ext2"
  - "getCachedInode: always use inode cache for path-related lookups"
  - "rec_len stride: always walk DirEntry by rec_len, never computed alignment"
requirements-completed: [DIR-01, DIR-02, DIR-03, DIR-04, DIR-05, INODE-05]
metrics:
  duration: "18 minutes"
  completed: "2026-02-24"
  tasks_completed: 2
  files_changed: 7
---

# Phase 48 Plan 01: Directory Traversal, Path Resolution, Inode Cache Summary

**Multi-component ext2 path resolution with 16-entry LRU inode cache, getdents directory listing, fast symlink readlink, statfs, and 7 integration tests all passing on x86_64**

## Performance

- **Duration:** 18 min
- **Started:** 2026-02-24
- **Completed:** 2026-02-24
- **Tasks:** 2
- **Files modified:** 7

## Accomplishments
- Multi-component path resolution (resolvePath) replaces root-only lookup -- open("/mnt2/a/b/c/file.txt") works
- 16-entry LRU inode cache eliminates redundant disk reads during path traversal (visible as cache HIT in logs)
- getdents on ext2 directory FDs returns Dirent64 entries with correct rec_len stride and DT_* types
- Fast symlink readlink returns target from i_block[] inline storage
- statfs returns EXT2_SUPER_MAGIC (0xEF53), block size, free counts from superblock
- nlink wired through FileMeta for POSIX-compliant directory stat (nlink >= 2)
- 7 new integration tests all pass, 176 total passing (up from 166), 0 regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend ext2 image and implement core path resolution with inode cache** - `144cf34` (feat)
2. **Task 2: Add Phase 48 ext2 integration tests** - `d7f9b48` (feat)
3. **Fix: Wire nlink through FileMeta to stat results** - `7f2b8fa` (fix)

## Files Created/Modified
- `build.zig` - Extended ext2 populate script with nested dirs (a/b/c/file.txt) and fast symlink (link_to_hello)
- `src/fs/ext2/inode.zig` - resolvePath, lookupInDir, getCachedInode, InodeCacheEntry, Ext2DirFd, ext2_dir_ops, ext2GetdentsFromFd, openDirInode
- `src/fs/ext2/mount.zig` - Ext2Fs inode_cache fields, ext2Open/ext2StatPath use resolvePath, ext2Readlink, ext2Statfs, VFS callbacks wired
- `src/fs/meta.zig` - Added nlink field (default 1) to FileMeta
- `src/kernel/sys/syscall/io/stat.zig` - statPathKernel uses meta.nlink instead of hardcoded 1
- `src/user/test_runner/tests/fs/ext2_basic.zig` - 7 new test functions (DIR-01 through DIR-05, INODE-05)
- `src/user/test_runner/main.zig` - Registered 7 new ext2 Phase 48 tests

## Decisions Made
- Inode cache size 16 with LRU eviction -- sufficient for typical path depths (ext2 max path components ~255)
- resolvePath does not follow symlinks during traversal (lookupInDir returns symlink inode, next isDir() check fails) -- correct behavior, symlink-following is future enhancement
- Added nlink to FileMeta as a deviation from the plan -- required for testExt2StatDirectory which verifies nlink >= 2

## Deviations from Plan

### Auto-fixed Issues

**1. nlink not available through stat path**
- **Found during:** Task 2 (testExt2StatDirectory)
- **Issue:** stat on directories returned nlink=1 (hardcoded in statPathKernel) but test expects nlink >= 2
- **Fix:** Added nlink field to FileMeta, populated from ext2 i_links_count in ext2StatPath, consumed in statPathKernel
- **Files modified:** src/fs/meta.zig, src/fs/ext2/mount.zig, src/kernel/sys/syscall/io/stat.zig
- **Verification:** testExt2StatDirectory passes with nlink >= 2
- **Committed in:** 7f2b8fa

---

**Total deviations:** 1 auto-fixed (nlink wiring)
**Impact on plan:** Essential for correctness. No scope creep.

## Issues Encountered
None beyond the nlink deviation.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Path resolution and directory operations complete -- Phase 49 (bitmap allocation, write support) can build on top
- Inode cache ready for write-through invalidation when write support is added
- ext2 test image has nested directories for future traversal tests

---
*Phase: 48-directory-traversal-path-resolution-inode-cache*
*Completed: 2026-02-24*
