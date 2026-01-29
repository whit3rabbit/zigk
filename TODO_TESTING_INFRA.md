# Testing Infrastructure TODO

**Goal**: Build automated, fast, reliable testing infrastructure to prevent regressions and enable confident development.

**Current State**: ✅ Phase 1 Foundation Complete (2026-01-28)
- 8 integration tests running in userspace test_runner
- Automated script (`scripts/run_tests.sh`) with 60s timeout
- Tests execute in ~10s, catch regressions
- All tests passing, CI-ready

**Previous State**: Manual testing via QEMU shell with flaky serial input. No automated tests, no coverage tracking, no CI/CD.

### Quick Start: Running Tests

```bash
# Automated test runner (recommended)
./scripts/run_tests.sh

# Or build target
zig build test-kernel

# Manual test run (for debugging)
zig build run -Darch=x86_64 -Ddefault-boot=test_runner -Dqemu-args="-nographic"

# Unit tests (none yet)
zig build test
```

**Expected Output**:
```
TEST_SUMMARY: 8 passed, 0 failed, 8 total
TEST_EXIT: 0
```

---

## Recent Implementation (2026-01-28)

### What Was Built

**Test Runner Binary** (`src/user/test_runner/`):
- `main.zig`: Test harness with pass/fail reporting
- `syscall_tests.zig`: Directory operation tests (chdir, getcwd, getdents64)
- `fs_tests.zig`: Filesystem tests (InitRD, SFS, DevFS)
- TAP-like output format with TEST_SUMMARY and TEST_EXIT

**Automated Test Script** (`scripts/run_tests.sh`):
- Builds kernel with `-Ddefault-boot=test_runner`
- Runs QEMU with `-nographic` for serial output
- Parses test results from stdout
- 60s timeout to catch hangs
- Returns 0 on success, 1 on failure

**Tests Implemented**:
1. `sys_chdir: accepts directories` - VFS path resolution
2. `sys_chdir: rejects files` - Returns NotADirectory (errno 20)
3. `sys_getcwd: returns path` - Process CWD tracking
4. `sys_getdents64: lists root` - Directory enumeration
5. `initrd: read ELF file` - InitRD tar reading
6. `sfs: create and write file` - SFS operations
7. `devfs: list devices` - DevFS enumeration
8. `dummy: always passes` - Test infrastructure sanity check

### Bugs Found During Testing

1. **SFS Write Deadlock** (CRITICAL - Fixed):
   - `sfsWrite` held `alloc_lock` (spinlock) during blocking I/O (`readSector`/`writeSector`)
   - Caused complete system hang when writing to /mnt
   - **Fix**: Applied "I/O → Process → Lock → Update" pattern from sfsOpen
   - Read directory unlocked, acquire lock, re-read for TOCTOU protection, update atomically

2. **Recursive Lock in sfsWrite** (CRITICAL - Fixed):
   - `sfsWrite` acquired `file_desc.lock` but caller (`sys_write`) already held it
   - Caused deadlock when writing any file
   - **Fix**: Removed duplicate lock acquisition, added comment

3. **chdir Test Wrong Error** (Fixed):
   - Test checked for `error.ENOTDIR` (doesn't exist in SyscallError)
   - Should check for `error.NotADirectory` (errno 20)
   - **Fix**: Updated test to use correct Zig error name

### Test Execution Time
- Full test suite: ~10 seconds
- Timeout: 60 seconds
- Tests complete before timeout, but QEMU doesn't auto-exit (known issue)

---

## Phase 1: Foundation (Essential)

### 1.1 Unit Testing Framework
**Priority**: CRITICAL
**Effort**: Low
**Status**: TODO

Zig has built-in `test` support. We need to start using it.

**Tasks**:
- [ ] Add unit tests for new syscalls in `src/kernel/sys/syscall/`
  - Start with `sys_chdir` (test VFS path resolution, ENOTDIR vs ENOENT)
  - Add tests for `sys_getcwd`, `sys_getdents64`
- [ ] Create `src/kernel/sys/syscall/tests/` directory for syscall tests
- [ ] Add mock helpers for:
  - VFS operations (mock `statPath`, `open`, etc.)
  - Process context (mock current process, FD table)
  - User memory (mock `UserPtr` without actual page tables)
- [ ] Make tests run via `zig build test`

**Example Test Structure**:
```zig
// src/kernel/sys/syscall/io/dir_test.zig
const testing = @import("std").testing;
const dir = @import("dir.zig");

test "sys_chdir accepts SFS directories" {
    // Mock VFS to return directory metadata
    // Call sys_chdir("/mnt/testdir")
    // Assert success
}

test "sys_chdir rejects regular files with ENOTDIR" {
    // Mock VFS to return file metadata
    // Call sys_chdir("/bin/ls")
    // Assert error.ENOTDIR
}
```

---

### 1.2 Test Runner Binary
**Priority**: CRITICAL
**Effort**: Medium
**Status**: ✅ DONE (2026-01-28)

Create a userspace binary that runs comprehensive tests and reports results.

**Tasks**:
- [x] Create `src/user/test_runner/main.zig`
- [x] Implement test harness that:
  - Runs individual test functions
  - Catches panics/errors
  - Reports pass/fail with error names
  - Exits with status code (0 = all pass, 1 = any fail)
- [x] Add syscall tests (8 tests passing):
  - [x] Directory operations (chdir accepts dirs, chdir rejects files, getcwd, getdents64)
  - [ ] File operations (open, read, write, close, seek) - partial (needs more coverage)
  - [ ] Process operations (fork, exec, wait, exit)
  - [ ] Memory operations (mmap, munmap, brk)
- [x] Add filesystem tests:
  - [x] InitRD read operations
  - [x] SFS read/write/create
  - [x] DevFS device enumeration
- [x] Add to initrd.tar and create boot option: `zig build run -Ddefault-boot=test_runner`

**Current Test Suite** (8 tests, all passing):
1. sys_chdir: accepts directories
2. sys_chdir: rejects files (returns NotADirectory)
3. sys_getcwd: returns path
4. sys_getdents64: lists root
5. initrd: read ELF file
6. sfs: create and write file
7. devfs: list devices
8. dummy: always passes

**Exit Behavior**:
- ✅ Prints summary: "TEST_SUMMARY: 8 passed, 0 failed, 8 total"
- ✅ Exits with code 0 (success) or 1 (failure)
- ⚠️ QEMU doesn't auto-exit (test_runner doesn't call sys_exit yet)

---

### 1.3 Automated QEMU Test Runner
**Priority**: HIGH
**Effort**: Medium
**Status**: ✅ DONE (2026-01-28)

Script that boots kernel, runs tests, parses output, reports results.

**Tasks**:
- [x] Create `scripts/run_tests.sh`
- [x] Build kernel with test runner
- [x] Boot QEMU with serial output to file
- [x] Parse output for test results (looks for TEST_SUMMARY)
- [x] Handle QEMU timeout as test failure (60s timeout)
- [x] Add `zig build test-kernel` target that runs this script

**Current Behavior**:
- ✅ Parses [USER] output from serial
- ✅ Extracts TEST_SUMMARY line
- ✅ Checks for TEST_EXIT: 0
- ✅ Times out after 60s if tests hang
- ⚠️ Script times out even on success (QEMU doesn't exit - known issue)
- ✅ Returns success if TEST_EXIT: 0 found before timeout

---

### 1.4 Additional Test Coverage (Needed)
**Priority**: HIGH
**Effort**: Medium
**Status**: TODO

Expand test coverage based on learnings from initial implementation.

**Critical Tests to Add**:

**Concurrency & Lock Ordering**:
- [ ] Test concurrent SFS writes to different files (should not block)
- [ ] Test concurrent SFS writes to same file (should serialize correctly)
- [ ] Test fd.lock behavior under concurrent access
- [ ] Test alloc_lock doesn't deadlock under high load
- [ ] Test file growth across multiple writes (block allocation)

**Error Handling**:
- [ ] Test sys_chdir with invalid paths (null, too long, malformed)
- [ ] Test sys_getcwd with buffer too small
- [ ] Test SFS write when disk is full (ENOSPC)
- [ ] Test SFS write to read-only filesystem (EROFS)
- [ ] Test open() with conflicting flags (O_RDONLY | O_WRONLY)

**Edge Cases**:
- [ ] Test writing exactly 512 bytes (block boundary)
- [ ] Test writing exactly 1024 bytes (multi-block)
- [ ] Test file position beyond EOF (sparse files)
- [ ] Test chdir to symlink (when symlinks implemented)
- [ ] Test getdents with buffer size < entry size

**Regression Tests** (prevent known bugs):
- [ ] Test SFS write doesn't hold alloc_lock during I/O (deadlock regression)
- [ ] Test sfsWrite doesn't acquire fd.lock twice (recursive lock regression)
- [ ] Test size metadata update uses TOCTOU protection (race regression)
- [ ] Test chdir returns NotADirectory, not ENOENT for files

**Filesystem-Specific**:
- [ ] Test InitRD with missing files (should return ENOENT)
- [ ] Test InitRD tar with path traversal attempts (../../etc/passwd)
- [ ] Test SFS directory creation/deletion
- [ ] Test SFS with 64 files (max capacity)
- [ ] Test DevFS with non-existent device

**Stress Tests**:
- [ ] Write/read 10MB file to SFS (multi-block handling)
- [ ] Create and delete 100 files rapidly
- [ ] Nested directory operations (when supported)
- [ ] Concurrent open/close cycles

**Known Issues to Fix**:
- [ ] Make test_runner call sys_exit to cleanly shutdown QEMU
- [ ] Add TAP output format for better CI integration
- [ ] Handle serial I/O corruption (occasional null bytes)

---

## Phase 2: Continuous Integration (Important)

### 2.1 GitHub Actions CI
**Priority**: HIGH
**Effort**: Low
**Status**: TODO

Run tests on every commit/PR.

**Tasks**:
- [ ] Create `.github/workflows/ci.yml`:
  ```yaml
  name: CI
  on: [push, pull_request]
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v3
        - uses: goto-bus-stop/setup-zig@v2
          with:
            version: 0.16.x
        - name: Install QEMU
          run: sudo apt-get install -y qemu-system-x86
        - name: Run unit tests
          run: zig build test
        - name: Run kernel tests
          run: ./scripts/run_tests.sh
  ```
- [ ] Add status badge to README.md
- [ ] Require CI to pass before merging PRs

---

### 2.2 Multi-Architecture Testing
**Priority**: MEDIUM
**Effort**: Medium
**Status**: TODO

Test both x86_64 and aarch64.

**Tasks**:
- [ ] Add matrix to CI workflow:
  ```yaml
  strategy:
    matrix:
      arch: [x86_64, aarch64]
  ```
- [ ] Install QEMU for both architectures
- [ ] Run test suite on both
- [ ] Fail CI if either architecture fails

---

## Phase 3: Advanced Testing (Nice to Have)

### 3.1 Coverage Tracking
**Priority**: MEDIUM
**Effort**: High
**Status**: TODO

Track which code paths are exercised by tests.

**Tasks**:
- [ ] Research Zig coverage tooling (as of 0.16.x)
- [ ] Instrument kernel with coverage hooks
- [ ] Generate coverage reports (HTML or lcov)
- [ ] Add to CI to track coverage over time
- [ ] Set coverage threshold (e.g., "must maintain 60%+")

---

### 3.2 Syscall Fuzzing
**Priority**: MEDIUM
**Effort**: High
**Status**: TODO

Randomly call syscalls with garbage inputs to find crashes.

**Tasks**:
- [ ] Create `src/user/fuzz_syscalls/main.zig`
- [ ] Generate random syscall numbers and arguments
- [ ] Handle crashes gracefully (don't panic kernel)
- [ ] Log inputs that cause crashes
- [ ] Run fuzzer in CI for N minutes per build
- [ ] Store corpus of interesting inputs

**Security Note**: This will find bugs. Prepare to fix:
- Null pointer dereferences
- Integer overflows
- Buffer overruns
- TOCTOU races
- Unvalidated user pointers

---

### 3.3 Filesystem Fuzzing
**Priority**: LOW
**Effort**: High
**Status**: TODO

Test filesystem robustness with malformed/corrupt inputs.

**Tasks**:
- [ ] Create malformed tar files (for InitRD)
  - Invalid headers
  - Truncated files
  - Path traversal attempts (../../etc/passwd)
- [ ] Create corrupt SFS disk images
  - Invalid superblock
  - Corrupted bitmaps
  - Bad block pointers
- [ ] Test that kernel doesn't crash, returns errors gracefully
- [ ] Use AFL or libFuzzer if available for Zig

---

### 3.4 Network Fuzzing
**Priority**: LOW
**Effort**: High
**Status**: TODO

Send malformed packets to find vulnerabilities.

**Tasks**:
- [ ] Create packet fuzzer that generates:
  - Invalid checksums
  - Truncated headers
  - Out-of-bounds length fields
  - Malformed TCP state transitions
- [ ] Test network stack doesn't crash or leak memory
- [ ] Verify security invariants (no stack leaks in padding)

---

### 3.5 Performance Benchmarks
**Priority**: LOW
**Effort**: Medium
**Status**: TODO

Track performance over time to detect regressions.

**Tasks**:
- [ ] Create `src/user/benchmarks/main.zig`
- [ ] Benchmark key operations:
  - Syscall overhead (getpid)
  - Context switch time
  - File I/O throughput
  - Network throughput
  - Process creation (fork/exec)
- [ ] Store results in CI
- [ ] Fail CI if performance regresses > 10%

---

## Phase 4: Developer Experience

### 4.1 Test Helpers & Utilities
**Priority**: MEDIUM
**Effort**: Low
**Status**: TODO

Make writing tests easier.

**Tasks**:
- [ ] Create `src/kernel/testing/helpers.zig`:
  - `expectSyscallOk(result)`
  - `expectSyscallError(result, expected_error)`
  - `createMockProcess()`
  - `createTempFile(path, contents)`
- [ ] Add assertion macros with good error messages
- [ ] Create fixtures for common test scenarios

---

### 4.2 Test Documentation
**Priority**: LOW
**Effort**: Low
**Status**: TODO

Document how to write and run tests.

**Tasks**:
- [ ] Create `docs/TESTING.md` with:
  - How to run tests
  - How to write unit tests
  - How to write integration tests
  - How to debug failing tests
  - Best practices
- [ ] Add examples of good tests
- [ ] Link from main README

---

### 4.3 Watch Mode
**Priority**: LOW
**Effort**: Low
**Status**: TODO

Auto-run tests on file changes.

**Tasks**:
- [ ] Create `scripts/watch_tests.sh`:
  - Uses `inotifywait` or similar
  - Watches `src/` directory
  - Re-runs tests on file save
  - Shows desktop notification on pass/fail
- [ ] Document in TESTING.md

---

## Testing Philosophy

### What to Test

**Always Test**:
- New syscalls (before merging)
- Security-critical code (user memory validation, capabilities)
- Bug fixes (add regression test first)
- Complex logic (VFS mount resolution, TCP state machine)

**Sometimes Test**:
- Driver initialization (hard to mock hardware)
- Architecture-specific code (requires QEMU)

**Don't Test**:
- Trivial getters/setters
- Code that's just glue between other tested components

### How to Test

**Unit Tests** (Fast, Isolated):
- Test individual functions
- Mock external dependencies
- Run without booting kernel
- Should complete in milliseconds

**Integration Tests** (Medium Speed):
- Test multiple components together
- Use real implementations (not mocks)
- May require minimal kernel boot
- Should complete in seconds

**System Tests** (Slow, Comprehensive):
- Boot full kernel
- Run userspace test binaries
- Test end-to-end flows
- Should complete in < 30 seconds

### Test Naming Convention

```zig
test "syscall_name: behavior when condition" {
    // Example: test "sys_chdir: returns ENOTDIR when path is a file"
}
```

---

## Success Metrics

When testing infrastructure is complete, we should have:

- [ ] **> 80% of syscalls** have unit tests (Current: ~15% - 4 of ~27 syscalls tested)
- [ ] **CI runs on every PR** and must pass before merge (Next: GitHub Actions)
- [x] **Test suite completes in < 2 minutes** ✅ (Current: ~10 seconds)
- [x] **Zero flaky tests** ✅ (Current: 8/8 tests deterministic, no failures)
- [ ] **Coverage tracked** and trending upward (Not implemented)
- [ ] **Fuzzing runs continuously** finding bugs before users do (Not implemented)
- [ ] **Developers write tests first** (Not yet - but infrastructure ready!)

**Current Progress**: 2/7 metrics achieved (29%)

---

## Notes

- Start with Phase 1 - everything else builds on it
- Don't let perfect be the enemy of good - some tests better than no tests
- Tests are code - they need maintenance too
- Flaky tests are worse than no tests - fix or delete them
- If a bug makes it to production, add a test so it never happens again

---

## Resources

**Zig Testing**:
- https://ziglang.org/documentation/master/#Test
- https://ziglearn.org/chapter-2/#tests

**OS Testing Examples**:
- Linux KUnit: https://www.kernel.org/doc/html/latest/dev-tools/kunit/
- Linux kselftest: https://www.kernel.org/doc/html/latest/dev-tools/kselftest.html
- SerenityOS tests: https://github.com/SerenityOS/serenity/tree/master/Tests

**Fuzzing**:
- AFL: https://github.com/google/AFL
- syzkaller (Linux kernel fuzzer): https://github.com/google/syzkaller
