---
phase: 35-vfs-page-cache-and-zero-copy
plan: 02
subsystem: io
tags: [splice, sendfile, tee, copy_file_range, page-cache, zero-copy, vfs]

# Dependency graph
requires:
  - phase: 35-vfs-page-cache-and-zero-copy-01
    provides: "page_cache module with getPages/releasePages/getPageData/invalidate API, build.zig wiring"
provides:
  - "Page-cache-based splice (file-to-pipe) eliminating 64KB kernel buffer"
  - "Page-cache-based sendfile eliminating 64KB kernel buffer"
  - "Page-cache-based copy_file_range eliminating 64KB kernel buffer"
  - "Stack-buffered tee (4KB) replacing 64KB heap allocation"
  - "Stack-buffered splicePipeToFile (4KB) with cache invalidation on write"
  - "3 integration tests verifying page cache zero-copy correctness"
affects: []

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "page_cache.getPages/releasePages for zero-copy file reads in syscall handlers"
    - "file_identifier == 0 check for fallback to heap buffer (non-VFS files)"
    - "page_cache.invalidate(file_id) after writing to a file via splicePipeToFile or copy_file_range"
    - "4KB stack buffer for pipe-related transfers (matching PIPE_BUF_SIZE)"

key-files:
  created: []
  modified:
    - "src/kernel/sys/syscall/io/splice.zig"
    - "src/kernel/sys/syscall/io/read_write.zig"
    - "src/user/test_runner/tests/syscall/fs_extras.zig"
    - "src/user/test_runner/main.zig"

key-decisions:
  - "file_identifier == 0 gates page cache path: non-VFS files (devices, sockets) fall back to heap buffer"
  - "4KB stack buffers for pipe-related ops (tee, splicePipeToFile) since pipe buffer is max 4KB"
  - "page_cache.invalidate() called after splicePipeToFile and copy_file_range writes to keep cache consistent"
  - "PipeHandle type is private in pipe module -- kept both code paths inline instead of extracting fallback function"

patterns-established:
  - "Page cache integration pattern: getPages -> iterate PageRefs -> getPageData -> use slice -> releasePages"
  - "VFS file detection: check fd.file_identifier != 0 before using page cache"
  - "Cache invalidation after write: always invalidate destination file's page cache after direct writes"

requirements-completed: [ZCIO-02]

# Metrics
duration: 19min
completed: 2026-02-19
---

# Phase 35 Plan 02: Zero-Copy Page Cache Integration Summary

**splice, sendfile, and copy_file_range refactored to read source file data via page cache references instead of 64KB heap buffers; tee and splicePipeToFile use 4KB stack buffers**

## Performance

- **Duration:** 19 min
- **Started:** 2026-02-19T13:45:18Z
- **Completed:** 2026-02-19T14:03:54Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- Eliminated 64KB kernel heap allocations from splice (file-to-pipe), sendfile, and copy_file_range by reading source file data through the VFS page cache
- Replaced 64KB heap allocations in tee and splicePipeToFile with 4KB stack buffers matching pipe buffer size
- Added cache invalidation after file writes in splicePipeToFile and copy_file_range to maintain page cache consistency
- Added 3 new integration tests (sendfile page cache, splice page cache reuse, copy_file_range page cache) passing on both x86_64 and aarch64
- Preserved heap buffer fallback for non-VFS files (file_identifier == 0) ensuring device-to-device transfers continue working

## Task Commits

Each task was committed atomically:

1. **Task 1: Refactor splice, sendfile, tee, copy_file_range to use page cache** - `6868ebb` (feat)
2. **Task 2: Add page cache zero-copy integration tests** - `4aad3a9` (test)

**Plan metadata:** (pending)

## Files Created/Modified
- `src/kernel/sys/syscall/io/splice.zig` - spliceFileToPipe, splicePipeToFile, sys_tee, sys_copy_file_range refactored to use page cache or stack buffers
- `src/kernel/sys/syscall/io/read_write.zig` - sys_sendfile refactored to use page cache for VFS source files
- `src/user/test_runner/tests/syscall/fs_extras.zig` - Added testSendfilePageCache, testSplicePageCacheReuse, testCopyFileRangePageCache
- `src/user/test_runner/main.zig` - Registered 3 new zero_copy_io page cache tests

## Decisions Made
- **file_identifier gates page cache path:** Non-VFS files (devices, sockets) have file_identifier == 0 and fall back to the original heap buffer approach, ensuring backward compatibility
- **4KB stack buffers for pipe ops:** Pipe buffer is max 4KB (PIPE_BUF_SIZE), so tee and splicePipeToFile can safely use stack-allocated buffers instead of heap
- **Cache invalidation after writes:** splicePipeToFile and copy_file_range call page_cache.invalidate(file_id) after writing to destination files, ensuring stale cached pages are evicted
- **PipeHandle type workaround:** PipeHandle is not pub in pipe.zig, so both page-cache and fallback code paths are kept inline in spliceFileToPipe rather than extracting a separate fallback function

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered
- **Pre-existing test failures:** "splice pipe to file" (FAIL) and "sendfile large transfer" (timeout) were confirmed as pre-existing failures by stashing changes and running the original code. Root cause: sendfile large transfer tries to sendfile 8KB to a 4KB pipe buffer without a concurrent reader, causing a deadlock. These are not caused by page cache changes. Total failure count is 14 before and after changes (identical set).

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness
- Phase 35 (VFS Page Cache and Zero-Copy) is now fully complete
- All v1.3 tech debt cleanup phases (27-35) are complete
- Page cache infrastructure and zero-copy integration are in place for future use

## Self-Check: PASSED

- All 5 files verified present on disk
- Commit `6868ebb` (Task 1 - feat) verified in git log
- Commit `4aad3a9` (Task 2 - test) verified in git log

---
*Phase: 35-vfs-page-cache-and-zero-copy*
*Completed: 2026-02-19*
