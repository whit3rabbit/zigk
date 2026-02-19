---
phase: 35-vfs-page-cache-and-zero-copy
plan: 01
subsystem: kernel-fs
tags: [page-cache, vfs, zero-copy, pmm, refcount, writeback]

requires:
  - phase: none
    provides: n/a
provides:
  - "Page cache module (src/kernel/fs/page_cache.zig) with getPages/releasePages/markDirty/writeback/invalidate API"
  - "FdTable.close auto-flushes dirty pages and invalidates cache on last close"
  - "page_cache_module registered in build.zig with imports wired to fd, syscall_io, and kernel root"
affects: [35-02, splice, sendfile, copy_file_range, tee]

tech-stack:
  added: []
  patterns: ["Hash-chained page cache indexed by (file_id, page_offset)", "Reference-counted physical pages via PMM", "Read-ahead prefetch on cache miss"]

key-files:
  created:
    - src/kernel/fs/page_cache.zig
  modified:
    - build.zig
    - src/kernel/fs/fd.zig
    - src/kernel/core/init_fs.zig

key-decisions:
  - "Fixed-size 256-bucket hash table with linked-list chaining for O(1) average lookup"
  - "MAX_CACHED_PAGES=1024 (4MB) eviction threshold with simple FIFO eviction of unreferenced non-dirty pages"
  - "1-page read-ahead window on cache miss, prefetched pages start with ref_count=0"
  - "Lock ordering: page_cache.lock acquired AFTER fd.lock, released BEFORE read_fn/write_fn calls"
  - "Writeback happens BEFORE close_fn in FdTable.close to ensure backing store is still open"

patterns-established:
  - "Page cache cleanup on FD close: writeback dirty pages then invalidate cache entries"
  - "Lock-drop pattern: release page_cache.lock before calling read_fn/write_fn to avoid lock inversion"
  - "Double-check insertion: after populating page outside lock, re-check cache for concurrent insert"

requirements-completed: [ZCIO-01]

duration: 12min
completed: 2026-02-19
---

# Phase 35 Plan 01: VFS Page Cache Infrastructure Summary

**Hash-chained page cache with ref-counted physical pages, read-ahead prefetch, and FdTable.close writeback/invalidate integration**

## Performance

- **Duration:** 12 min
- **Started:** 2026-02-19T13:29:47Z
- **Completed:** 2026-02-19T13:42:24Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Created page cache module with CachedPage, PageCache, PageRef types and complete public API
- Registered page_cache_module in build.zig with all required imports (pmm, hal, heap, sync, fd, console) and wired to fd_module, syscall_io_module, and kernel root
- Integrated page cache lifecycle into FdTable.close: writeback dirty pages and invalidate cache entries on last file close
- Both x86_64 and aarch64 compile cleanly with zero test regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Create page cache module with core data structures and API** - `778327e` (feat)
2. **Task 2: Register page_cache module in build.zig and integrate with FdTable.close and init** - `638b54b` (feat)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `src/kernel/fs/page_cache.zig` - Core page cache module: CachedPage/PageCache/PageRef structs, init/getPages/releasePages/markDirty/writeback/invalidate/getPageData API
- `build.zig` - page_cache_module registration with imports wired to fd_module, syscall_io_module, kernel root
- `src/kernel/fs/fd.zig` - FdTable.close extended with page_cache writeback/invalidate before close_fn
- `src/kernel/core/init_fs.zig` - page_cache.init() call in initVfs() after VFS.init()

## Decisions Made
- Used fixed-size 256-bucket hash table (not dynamic) for simplicity and deterministic memory use
- Eviction is simple FIFO scan of unreferenced non-dirty pages (not true LRU) -- sufficient for initial implementation
- Read-ahead prefetches exactly 1 page on miss to avoid excessive PMM pressure
- Page cache lock ordering documented between fd.lock and scheduler lock in the hierarchy

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Page cache API is ready for Plan 02 to wire into splice/sendfile/tee/copy_file_range
- syscall_io_module already has page_cache import wired for immediate use
- The getPages/releasePages/getPageData trio provides the zero-copy primitive Plan 02 needs

---
*Phase: 35-vfs-page-cache-and-zero-copy*
*Completed: 2026-02-19*
