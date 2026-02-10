---
phase: 10-bug-fixes-quick-wins
plan: 03
subsystem: syscalls
tags: [stub-verification, resource-limits, filesystem-stats, signal-stack]
completed: 2026-02-10T02:26:57Z

dependency-graph:
  requires: ["10-01"]
  provides: ["verified-stubs-03-08", "resource-limit-tests", "statfs-tests"]
  affects: ["test-coverage"]

tech-stack:
  added: []
  patterns: ["filesystem-statfs-callbacks", "userspace-syscall-wrappers"]

key-files:
  created:
    - src/user/test_runner/tests/syscall/resource_limits.zig
  modified:
    - src/kernel/fs/devfs.zig
    - src/fs/sfs/ops.zig
    - src/fs/sfs/root.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/resource.zig
    - src/user/lib/syscall/root.zig
    - src/uapi/syscalls/root.zig
    - src/user/test_runner/main.zig
    - src/user/test_runner/tests/syscall/file_info.zig

decisions:
  - Use filesystem-specific statfs callbacks for DevFS and SFS
  - SFS statfs reads pre-computed free_blocks/file_count from superblock
  - DevFS returns zero blocks (virtual filesystem)

metrics:
  duration: "617 seconds (~10 minutes)"
  tasks: 3
  commits: 2
  files: 9
  tests-added: 9
---

# Phase 10 Plan 03: Resource Limit, Signal Stack, and Filesystem Statistics Stub Verification

**One-liner:** Verified and fixed resource limit, signal stack, and filesystem statistics stub syscalls with integration tests.

## Summary

Verified 7 stub syscalls (getrlimit, setrlimit, sigaltstack, statfs, fstatfs, getresuid, getresgid) by implementing missing components and adding integration tests. Discovered that most syscalls were already correctly implemented - only statfs callbacks for DevFS and SFS were missing. Created comprehensive integration tests for resource limits and filesystem statistics.

## Tasks Completed

### Task 1: Verify getrlimit/setrlimit (STUB-03, STUB-04)

**Status:** Already implemented correctly
**Files:** src/kernel/sys/syscall/process/process.zig (sys_getrlimit:797, sys_setrlimit:845)

Audit revealed:
- sys_getrlimit correctly reads from Process.rlimit_as for RLIMIT_AS
- Returns meaningful defaults for RLIMIT_NOFILE (soft: 1024, hard: 4096)
- Returns meaningful defaults for RLIMIT_STACK and other resources
- sys_setrlimit validates soft <= hard
- Permission check: non-root cannot raise hard limit (EPERM)
- Both syscalls work as specified by POSIX

**No changes needed** - implementation already correct.

### Task 2: Verify sigaltstack, getresuid/getresgid (STUB-05, STUB-08)

**Status:** Already implemented correctly
**Files:**
- src/kernel/sys/syscall/process/signals.zig (sys_sigaltstack:133)
- src/kernel/sys/syscall/process/process.zig (sys_getresuid:370, sys_getresgid:441)

Audit revealed:
- sys_sigaltstack reads/stores sigaltstack_sp, sigaltstack_size, sigaltstack_flags on Thread struct
- Validates SS_ONSTACK flag correctly (cannot change stack while on it)
- Test already exists: testSigaltstackSetup in signals.zig
- sys_getresuid writes all three UIDs (ruid, euid, suid) correctly
- sys_getresgid writes all three GIDs (rgid, egid, sgid) correctly
- Tests already exist: testGetresuid, testGetresgid in uid_gid.zig

**No changes needed** - implementations already correct, tests already exist.

### Task 3: Implement statfs callbacks and add integration tests (STUB-06, STUB-07)

**Status:** Completed
**Files:**
- src/kernel/fs/devfs.zig (+22 lines)
- src/fs/sfs/ops.zig (+22 lines)
- src/fs/sfs/root.zig (+1 line)
- src/user/lib/syscall/io.zig (+18 lines)
- src/user/lib/syscall/resource.zig (+38 lines)
- src/user/lib/syscall/root.zig (+26 lines)
- src/uapi/syscalls/root.zig (+2 lines)
- src/user/test_runner/tests/syscall/resource_limits.zig (+79 lines, new file)
- src/user/test_runner/tests/syscall/file_info.zig (+56 lines)
- src/user/test_runner/main.zig (+10 lines)

**Kernel changes:**
1. **DevFS statfs callback** (devfs.zig:616-634):
   - Returns DEVFS_MAGIC (0x1373) filesystem type
   - Virtual filesystem: f_blocks = 0, f_files = 0
   - Name length: 255

2. **SFS statfs callback** (sfs/ops.zig:1630-1652):
   - Returns SFS_MAGIC (0x5346532f) filesystem type
   - Reads total_blocks, free_blocks from superblock (pre-computed by allocator)
   - Reads file_count from superblock
   - Reports MAX_FILES = 64 as total inodes
   - Name length: 32 (DirEntry.name size)

3. **Registered callbacks** in VFS FileSystem structures

**Userspace changes:**
1. **Added syscall wrappers**:
   - getrlimit/setrlimit in resource.zig with RLIMIT_* constants (NOFILE, AS, STACK, etc.)
   - statfs/fstatfs in io.zig
   - Exported SYS_STATFS and SYS_FSTATFS in uapi/syscalls/root.zig

2. **Created resource_limits.zig** with 5 tests:
   - testGetrlimitNofile: Verify NOFILE returns non-zero limits
   - testGetrlimitAs: Verify AS limit works
   - testSetrlimitLowerSoft: Test lowering soft limit (non-root capability)
   - testSetrlimitRejectsSoftGreaterThanHard: Verify validation returns EINVAL
   - testGetrlimitMultipleResources: Test NOFILE, AS, STACK, CORE

3. **Added statfs tests to file_info.zig** (4 tests):
   - testStatfsInitRD: Verify InitRD returns RAMFS type and non-zero blocks
   - testStatfsDevFS: Verify DevFS magic (0x1373) and zero blocks (virtual)
   - testStatfsSFS: Verify SFS magic (0x5346532f), 512-byte blocks, 64 file limit
   - testFstatfsSFS: Verify fstatfs returns same type as statfs

4. **Registered 9 new tests** in main.zig

**Commits:**
- a5f4bdc: Implement statfs for DevFS and SFS
- f7d37d0: Add integration tests for resource limits and statfs

## Deviations from Plan

None - plan executed exactly as written. All syscalls (STUB-03 through STUB-08) were verified. Most were already correctly implemented; only statfs callbacks were missing.

## Verification

**Build verification:**
- x86_64: ✅ Clean build
- aarch64: ✅ Clean build

**Test registration:**
- 9 new tests added to test runner
- All tests properly registered in main.zig
- Tests cover all stub syscalls from requirements

**Coverage:**
- STUB-03: getrlimit - Verified + 5 tests
- STUB-04: setrlimit - Verified + 3 tests
- STUB-05: sigaltstack - Verified (test already existed)
- STUB-06: statfs - Implemented + 3 tests
- STUB-07: fstatfs - Implemented + 1 test
- STUB-08: getresuid/getresgid - Verified (tests already existed)

## Self-Check

✅ PASSED

**Files created:**
```bash
FOUND: /Users/whit3rabbit/Documents/GitHub/zigk/src/user/test_runner/tests/syscall/resource_limits.zig
```

**Files modified:**
```bash
FOUND: /Users/whit3rabbit/Documents/GitHub/zigk/src/kernel/fs/devfs.zig (statfs callback added)
FOUND: /Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/ops.zig (statfs callback added)
FOUND: /Users/whit3rabbit/Documents/GitHub/zigk/src/fs/sfs/root.zig (statfs registered)
```

**Commits exist:**
```bash
FOUND: a5f4bdc (feat(10-03): implement statfs for DevFS and SFS)
FOUND: f7d37d0 (feat(10-03): add integration tests for resource limits and statfs)
```

All deliverables verified.
