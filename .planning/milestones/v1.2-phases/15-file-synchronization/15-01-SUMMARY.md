---
phase: 15-file-synchronization
plan: 01
subsystem: filesystem
tags: [syscalls, sync, fsync, fdatasync, syncfs, file-io]
dependency_graph:
  requires: [fd-table, vfs]
  provides: [fsync, fdatasync, sync, syncfs]
  affects: [file-operations]
tech_stack:
  added: []
  patterns: [validation-only-sync, no-op-sync]
key_files:
  created: []
  modified:
    - src/kernel/sys/syscall/fs/fs_handlers.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/fs_extras.zig
    - src/user/test_runner/main.zig
decisions:
  - "File synchronization syscalls implemented as validation-only operations since kernel has no write-back buffer cache"
  - "sys_sync takes no arguments and always succeeds per POSIX semantics"
  - "fsync/fdatasync/syncfs validate FD and return success (data already on disk)"
metrics:
  duration_minutes: 8
  completed_date: 2026-02-12
  task_commits: 2
  files_modified: 5
  tests_added: 8
  architectures_tested: [x86_64, aarch64]
---

# Phase 15 Plan 01: File Synchronization Summary

**One-liner:** Implemented fsync, fdatasync, sync, and syncfs syscalls as validation-only operations for synchronous I/O kernel.

## What Was Built

### Kernel Syscalls (src/kernel/sys/syscall/fs/fs_handlers.zig)

Implemented 4 file synchronization syscalls:

1. **sys_fsync (74)** - Synchronize file data and metadata to storage
   - Validates fd_num via std.math.cast to u32
   - Looks up FD in global table, returns EBADF if invalid
   - Returns 0 (data already on disk, no buffer cache to flush)

2. **sys_fdatasync (75)** - Synchronize file data only (skip non-essential metadata)
   - Same implementation as sys_fsync (no buffer cache distinction)
   - Validates FD and returns success

3. **sys_sync (162)** - Commit all filesystem caches globally
   - Takes no arguments (void)
   - Always succeeds per POSIX semantics (no buffer cache)
   - Returns 0

4. **sys_syncfs (306)** - Synchronize a specific filesystem
   - Validates fd_num and looks up FD
   - Returns EBADF for invalid FD, 0 otherwise

**Rationale:** This kernel has no write-back buffer cache. SFS writes go directly to the block device via writeSector, so data is already on disk when the write syscall returns. These syscalls provide POSIX-compliant interfaces that validate FDs and return success, matching Linux behavior for filesystems with synchronous I/O.

### Userspace Wrappers (src/user/lib/syscall/io.zig)

Added 4 wrapper functions:

1. **fsync(fd: i32)** - Calls SYS_FSYNC syscall, returns error on EBADF
2. **fdatasync(fd: i32)** - Calls SYS_FDATASYNC syscall, returns error on EBADF
3. **sync_()** - Calls SYS_SYNC syscall, void return (cannot fail)
4. **syncfs(fd: i32)** - Calls SYS_SYNCFS syscall, returns error on EBADF

All 4 functions re-exported from src/user/lib/syscall/root.zig for public API.

**Note:** sync_() uses trailing underscore to avoid conflict with Zig keyword.

### Integration Tests (src/user/test_runner/tests/syscall/fs_extras.zig)

Added 8 comprehensive tests:

1. **testFsyncOnRegularFile** - Open SFS file, write data, call fsync, verify success
2. **testFsyncOnReadOnlyFile** - Open InitRD file O_RDONLY, call fsync (Linux allows this)
3. **testFsyncInvalidFd** - Call fsync(999), expect EBADF
4. **testFdatasyncOnRegularFile** - Open SFS file, write data, call fdatasync, verify success
5. **testFdatasyncInvalidFd** - Call fdatasync(999), expect EBADF
6. **testSyncGlobal** - Call sync_(), no error checking (void return)
7. **testSyncfsOnOpenFile** - Open file, call syncfs on fd, verify success
8. **testSyncfsInvalidFd** - Call syncfs(999), expect EBADF

**Coverage:**
- Valid FD behavior on both writable (SFS) and read-only (InitRD) files
- Invalid FD error handling (EBADF vs ENOSYS distinction)
- Global flush operation (sync)
- Per-filesystem flush (syncfs)

**Note:** Tests placed BEFORE stress tests in main.zig to avoid SFS close deadlock issues with late file operations.

## Deviations from Plan

None - plan executed exactly as written. All 4 syscalls implemented, all 4 userspace wrappers added, all 8 tests passing on both architectures.

## Test Results

### x86_64
All 8 sync tests: **PASS**
- sync: fsync on regular file
- sync: fsync on read-only file
- sync: fsync invalid fd
- sync: fdatasync on regular file
- sync: fdatasync invalid fd
- sync: sync global
- sync: syncfs on open file
- sync: syncfs invalid fd

### aarch64
All 8 sync tests: **PASS** (same test names)

**Verification Method:**
- Invalid FD tests (fsync/fdatasync/syncfs with fd=999) return EBADF, not ENOSYS
- This confirms dispatch table auto-registration worked correctly
- If registration failed, syscalls would return ENOSYS (syscall not implemented)

### Total Test Count
- **New tests added:** 8
- **Previous test count:** 186 (from TODO_TESTING_INFRA.md baseline)
- **New total:** 194 tests

**Regressions:** None - existing tests continue to pass

## Architecture Notes

### Dispatch Table Registration

All 4 syscalls auto-registered via comptime discovery:
- SYS_FSYNC (74 x86_64, 82 aarch64) → sys_fsync
- SYS_FDATASYNC (75 x86_64, 83 aarch64) → sys_fdatasync
- SYS_SYNC (162 x86_64, 81 aarch64) → sys_sync
- SYS_SYNCFS (306 x86_64, 267 aarch64) → sys_syncfs

**Verification:** Kernel ELF contains all 4 symbols (checked via `strings kernel-x86_64.elf | grep sys_fsync`).

### Syscall Number Differences

| Syscall     | x86_64 | aarch64 | Notes                              |
|-------------|--------|---------|-------------------------------------|
| fsync       | 74     | 82      | Different numbering, same behavior |
| fdatasync   | 75     | 83      | Different numbering, same behavior |
| sync        | 162    | 81      | Different numbering, same behavior |
| syncfs      | 306    | 267     | Different numbering, same behavior |

Dispatch table handles both architectures transparently.

### File Synchronization Model

**Kernel writes are synchronous:**
1. User calls sys_write
2. Kernel validates and copies data
3. VFS routes to filesystem (SFS)
4. SFS.write calls block_device.writeSector
5. writeSector performs direct disk write (AHCI or VirtIO-SCSI)
6. sys_write returns AFTER disk write completes

**Implication:** When write() returns, data is already on disk. No async write-back cache exists. fsync/fdatasync/syncfs have nothing to flush.

**POSIX Compliance:** Linux allows these syscalls on synchronous filesystems. They validate the FD and return success. Applications using fsync for durability guarantees get correct behavior even though the operation is a no-op.

## Commits

**Task 1:** feat(15-01): implement fsync, fdatasync, sync, syncfs syscalls (402b928)
- Kernel handlers in fs_handlers.zig
- Userspace wrappers in io.zig
- Re-exports in root.zig

**Task 2:** test(15-01): add integration tests for sync syscalls (df40568)
- 8 integration tests in fs_extras.zig
- Test registration in main.zig
- Dual-architecture verification (x86_64 + aarch64)

## Self-Check: PASSED

**Created files verified:** N/A (all modifications to existing files)

**Modified files verified:**
- [✓] src/kernel/sys/syscall/fs/fs_handlers.zig - contains sys_fsync, sys_fdatasync, sys_sync, sys_syncfs
- [✓] src/user/lib/syscall/io.zig - contains fsync, fdatasync, sync_, syncfs wrappers
- [✓] src/user/lib/syscall/root.zig - re-exports all 4 functions
- [✓] src/user/test_runner/tests/syscall/fs_extras.zig - contains 8 test functions
- [✓] src/user/test_runner/main.zig - registers all 8 tests

**Commits verified:**
- [✓] 402b928 - feat(15-01): implement fsync, fdatasync, sync, syncfs syscalls
- [✓] df40568 - test(15-01): add integration tests for sync syscalls

**Test verification:**
- [✓] x86_64: 8/8 sync tests pass (verified via test_output_x86_64.log)
- [✓] aarch64: 8/8 sync tests pass (verified via test_output_aarch64.log)
- [✓] EBADF (not ENOSYS) returned for invalid FDs (confirms dispatch registration)

**Build verification:**
- [✓] `zig build -Darch=x86_64` - successful
- [✓] `zig build -Darch=aarch64` - successful
- [✓] Kernel symbols present in both ELFs

All verification steps passed.

## Requirements Satisfied

### FSYNC-01: fsync Implementation
**Status:** ✓ Complete
- [✓] sys_fsync validates FD, returns 0 for valid FD
- [✓] Returns EBADF for invalid FD
- [✓] Userspace wrapper in io.zig
- [✓] Works on both x86_64 and aarch64
- [✓] 3 integration tests (regular file, read-only file, invalid FD)

### FSYNC-02: fdatasync Implementation
**Status:** ✓ Complete
- [✓] sys_fdatasync validates FD, returns 0 for valid FD
- [✓] Returns EBADF for invalid FD
- [✓] Userspace wrapper in io.zig
- [✓] Works on both x86_64 and aarch64
- [✓] 2 integration tests (regular file, invalid FD)

### FSYNC-03: sync Implementation
**Status:** ✓ Complete
- [✓] sys_sync takes no arguments, always succeeds
- [✓] Userspace wrapper sync_() with void return
- [✓] Works on both x86_64 and aarch64
- [✓] 1 integration test (global flush)

### FSYNC-04: syncfs Implementation
**Status:** ✓ Complete
- [✓] sys_syncfs validates FD, returns 0 for valid FD
- [✓] Returns EBADF for invalid FD
- [✓] Userspace wrapper in io.zig
- [✓] Works on both x86_64 and aarch64
- [✓] 2 integration tests (open file, invalid FD)

All 4 requirements satisfied with full dual-architecture test coverage.
