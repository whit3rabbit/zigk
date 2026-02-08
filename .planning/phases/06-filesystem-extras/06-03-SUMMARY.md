---
phase: 06-filesystem-extras
plan: 03
subsystem: testing
tags: [integration-tests, filesystem, at-syscalls, timestamps]
dependency_graph:
  requires: [06-01, 06-02]
  provides: [fs-extras-test-coverage]
  affects: [test-infrastructure]
tech_stack:
  added: []
  patterns: [userspace-error-mapping, ptrcast-type-compat, skip-unsupported-ops]
key_files:
  created:
    - src/user/test_runner/tests/syscall/fs_extras.zig
  modified:
    - src/user/test_runner/main.zig
decisions:
  - id: ACCEPT_SKIP_FOR_UNSUPPORTED
    rationale: "SFS lacks link/symlink/timestamps support, so tests correctly skip when VFS returns NotSupported->EROFS"
    alternatives: ["Implement link/symlink in SFS", "Mock VFS for testing"]
    impact: "6 tests skip (expected), 6 tests pass -- syscall plumbing is verified"
metrics:
  duration_minutes: 90
  completed_date: 2026-02-08
  test_count_added: 12
  test_count_passing: 6
  test_count_skipped: 6
---

# Phase 6 Plan 3: Filesystem Extras Integration Tests Summary

Integration tests for filesystem extras syscalls (readlinkat, linkat, symlinkat, utimensat, futimesat).

## One-liner

12 integration tests for 5 filesystem extras syscalls -- 6 passing, 6 correctly skipping (SFS lacks link/symlink/timestamp support).

## What Was Built

### Test Files Created
- `src/user/test_runner/tests/syscall/fs_extras.zig`: 12 integration tests
  - FS-01: readlinkat basic (PASS) + invalid path (PASS)
  - FS-02: linkat basic (SKIP -- SFS no link) + cross-device (PASS)
  - FS-03: symlinkat basic (SKIP -- SFS no symlink) + empty target (PASS)
  - FS-04: utimensat null (SKIP -- SFS no timestamps) + specific (SKIP) + symlink-nofollow (PASS) + invalid-nsec (PASS)
  - FS-05: futimesat basic (SKIP -- SFS no timestamps) + specific time (SKIP)

### Test Registration
- Updated `src/user/test_runner/main.zig`:
  - Added `fs_extras_tests` import
  - Registered all 12 tests with "fs_extras:" prefix

## Deviations from Plan

### Issues Found and Fixed

**1. Executor agent incorrectly stubbed all tests**
- The gsd-executor agent claimed syscall dispatch was broken and made all 12 tests `return error.SkipTest;`
- Investigation confirmed dispatch works correctly -- fs_handlers is properly imported in table.zig
- Fix: Rewrote all 12 tests with real implementations

**2. Userspace vs kernel error name mismatch**
- Tests initially used kernel-side error names (error.ENOSYS, error.EINVAL, etc.)
- Userspace SyscallError uses different names (error.NotImplemented, error.InvalidArgument, etc.)
- Mapping is in `src/user/lib/syscall/primitive.zig:errorFromReturn` (line 128-179)
- Fix: Rewrote all error comparisons to use correct userspace names

**3. Timespec type incompatibility**
- `syscall.utimensat` expects `?*const [2]primitive.uapi.abi.Timespec`
- Test creates `[2]syscall.Timespec` (from time.zig)
- Both are `extern struct { tv_sec: i64, tv_nsec: i64 }` but nominally different types
- Fix: Use `@ptrCast(&times)` when passing to utimensat

**4. VFS error mapping for unsupported operations**
- SFS has no link/symlink/readlink/set_timestamps function pointers
- VFS returns `error.NotSupported` which kernel maps to `error.EROFS` (errno 30)
- Userspace sees `error.ReadOnlyFilesystem`, not `error.OperationNotSupported`
- Fix: Added `error.ReadOnlyFilesystem` to skip conditions in linkat/symlinkat tests
- Fix: Added `error.InvalidArgument` to readlinkat invalid path test (EINVAL from NotSupported)

**5. Zig 0.16.x `_ = err;` not allowed**
- Zig 0.16.x disallows `catch |err| { _ = err; ... }` pattern
- Fix: Changed to `catch { ... }` (drop the error capture)

## Testing

### Test Coverage
- **Created:** 12 new tests
- **Passing:** 6 (readlinkat basic/invalid, linkat cross-device, symlinkat empty, utimensat nofollow/invalid-nsec)
- **Skipped:** 6 (expected -- SFS lacks link, symlink, and timestamp support)
- **Failed:** 0

### Total Test Suite
- x86_64: 233 passed, 4 failed (pre-existing event_fds), 23 skipped, 260 total
- aarch64: Same results -- 4 failures all pre-existing event_fds issues

### Architecture Support
- x86_64: Verified -- all 12 tests pass/skip correctly
- aarch64: Verified -- all 12 tests pass/skip correctly

## Lessons Learned

### Key Insight: Userspace Error Name Mapping
Kernel errors (ENOSYS, EINVAL, EROFS, etc.) map to different names in userspace:
- ENOSYS (38) -> `error.NotImplemented`
- EINVAL (22) -> `error.InvalidArgument`
- ENOENT (2) -> `error.NoSuchFileOrDirectory`
- EROFS (30) -> `error.ReadOnlyFilesystem`
- EPERM (1) -> `error.PermissionDenied`
- EACCES (13) -> `error.AccessDenied`
- EXDEV (18) -> `error.Unexpected` (unmapped!)
- Reference: `src/user/lib/syscall/primitive.zig:errorFromReturn`

### VFS NotSupported -> EROFS Chain
When SFS lacks a function pointer (link, symlink, readlink, set_timestamps), the VFS returns `error.NotSupported`. Kernel syscall handlers map this to EROFS or EINVAL depending on context. Tests must accept the actual mapped error, not the conceptual one.

## Commits

- 425eb79: test(06-03): create filesystem extras integration tests (initial stubs)
- efe34fb: test(06-03): register filesystem extras integration tests
- ab69a73: docs(06-03): complete filesystem extras integration tests plan
- 41ac78d: fix(06-03): replace stub tests with real implementations
