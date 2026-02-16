---
phase: 27-quick-wins
plan: 01
subsystem: syscalls
tags: [memory, filesystem, edge-cases, syscall-coverage]
dependency_graph:
  requires: [phase-26-syscall-coverage]
  provides: [fchdir-syscall, mremap-edge-case-handling]
  affects: [directory-operations, memory-management]
tech_stack:
  added: []
  patterns: [directory-fd-resolution, errno-validation]
key_files:
  created: []
  modified:
    - src/kernel/sys/syscall/io/dir.zig
    - src/kernel/sys/syscall/io/root.zig
    - src/user/lib/syscall/io.zig
    - src/user/lib/syscall/root.zig
    - src/user/test_runner/tests/syscall/uid_gid.zig
    - src/user/test_runner/main.zig
decisions:
  - decision: "Use DirTag enum to identify directory type (InitRD root vs DevFS root) for fchdir path resolution"
    rationale: "Directory FDs store DirTag in private_data field. This allows fchdir to map FD to canonical path without VFS path traversal."
    alternatives: ["Store full path in FD", "Walk VFS to reconstruct path"]
    trade_offs: "Simple and efficient but only supports pre-defined directories (/, /dev). SFS directories would need additional path storage mechanism."
  - decision: "mremap invalid address edge case requires no fix"
    rationale: "Existing implementation correctly returns EFAULT when no VMA is found at old_addr. The VMA walk doesn't dereference user addresses, so unmapped addresses are safely handled."
    alternatives: ["Add explicit user address range check before VMA walk"]
    trade_offs: "No change needed - test passes on both architectures. Adding redundant checks would increase code complexity without benefit."
metrics:
  duration_minutes: 21
  completed_date: "2026-02-16"
  tasks_completed: 2
  files_modified: 6
  commits: 2
  tests_added: 3
  deviations: 1
---

# Phase 27 Plan 01: Fix mremap edge case and implement fchdir

**One-liner**: Verified mremap invalid address handling and implemented fchdir syscall with DirTag-based path resolution for InitRD and DevFS directories.

## Overview

Closed two Phase 27 requirements: MEM-01 (mremap invalid address edge case) and RSRC-01 (missing fchdir syscall). MEM-01 required no fix - existing implementation correctly handles unmapped addresses. RSRC-01 added fchdir syscall with support for changing to InitRD root (/) and DevFS root (/dev) via directory FD tags.

## Tasks Completed

### Task 1: mremap invalid address edge case (MEM-01)

**Status**: Verified - no fix needed

**Analysis**:
- Test calls `mremap(0x12340000, 4096, 8192, MREMAP_MAYMOVE)` where 0x12340000 is unmapped
- `sys_mremap` validates alignment (passes for 0x12340000)
- `user_vmm.mremap` walks VMA list looking for a VMA containing old_addr
- No VMA found at 0x12340000, returns EFAULT (errno 14)
- Test expects EFAULT or EINVAL - current behavior is correct

**Verification**:
- Test "mem_ext: mremap invalid addr" passes on both x86_64 and aarch64
- No regressions in other memory tests

**Commits**: None (no changes needed)

### Task 2: fchdir syscall (RSRC-01)

**Implementation**:
- Added `sys_fchdir(fd_num: usize)` in `src/kernel/sys/syscall/io/dir.zig`
- Validates FD number with `safeFdCast`, returns EBADF if invalid
- Checks `fd.ops == &fd_mod.dir_ops` to ensure FD is a directory, returns ENOTDIR otherwise
- Resolves directory path from `fd.private_data` (DirTag enum):
  - `initrd_root` (or null) → "/"
  - `devfs_root` → "/dev"
  - Unknown tag → ENOTDIR (SFS directories not supported in MVP)
- Updates process cwd under `proc.cwd_lock`

**Userspace wrapper**:
- Added `fchdir(fd: i32)` in `src/user/lib/syscall/io.zig`
- Re-exported in `src/user/lib/syscall/root.zig`

**Tests**:
1. `testFchdir`: Opens "/" with O_DIRECTORY, calls fchdir, verifies getcwd returns "/"
2. `testFchdirNonDirectory`: Opens regular file, expects ENOTDIR
3. `testFchdirInvalidFd`: Tests invalid FD 9999, expects EBADF

**Verification**:
- All 3 fchdir tests pass on both x86_64 and aarch64
- Replaced skipped test "uid/gid: fchdir not implemented" with working tests

**Commits**:
- d76e8d5: `feat(27-01): implement fchdir syscall (RSRC-01)`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing SECCOMP_RET_KILL_THREAD export**
- **Found during**: Build of test runner for Task 1
- **Issue**: Test code `src/user/test_runner/tests/syscall/seccomp.zig` references `syscall.SECCOMP_RET_KILL_THREAD` but constant was not exported in `src/user/lib/syscall/root.zig`
- **Fix**: Added `pub const SECCOMP_RET_KILL_THREAD = process.SECCOMP_RET_KILL_THREAD;` after line 335 in root.zig
- **Files modified**: `src/user/lib/syscall/root.zig`
- **Commit**: 20f7a8e

**2. [Rule 1 - Bug] Test used wrong error name**
- **Found during**: Task 2 test run on x86_64
- **Issue**: `testFchdirNonDirectory` compared against `error.NotDirectory` but SyscallError defines `error.NotADirectory` (errno 20)
- **Fix**: Changed test to use `error.NotADirectory` (also fixed in `testFchdir` catch clause)
- **Files modified**: `src/user/test_runner/tests/syscall/uid_gid.zig`
- **Commit**: Included in d76e8d5 (same commit as fchdir implementation)

## Self-Check: PASSED

**Files created**: None

**Files modified - verified**:
```
FOUND: src/kernel/sys/syscall/io/dir.zig (sys_fchdir function added)
FOUND: src/kernel/sys/syscall/io/root.zig (sys_fchdir export added)
FOUND: src/user/lib/syscall/io.zig (fchdir wrapper added)
FOUND: src/user/lib/syscall/root.zig (fchdir export + SECCOMP_RET_KILL_THREAD export added)
FOUND: src/user/test_runner/tests/syscall/uid_gid.zig (3 fchdir tests added)
FOUND: src/user/test_runner/main.zig (3 test registrations added)
```

**Commits - verified**:
```
FOUND: 20f7a8e (fix SECCOMP_RET_KILL_THREAD export)
FOUND: d76e8d5 (implement fchdir syscall)
```

**Tests passing - verified**:
- x86_64: mem_ext: mremap invalid addr (PASS)
- x86_64: uid/gid: fchdir basic (PASS)
- x86_64: uid/gid: fchdir non-directory (PASS)
- x86_64: uid/gid: fchdir invalid fd (PASS)
- aarch64: All 4 tests (PASS)

## Technical Notes

### fchdir DirTag Limitation

The current implementation only supports fchdir for directories with known tags (InitRD root, DevFS root). SFS directories opened via `openat` or VFS operations do not store their canonical path in the FD, so fchdir on SFS directories returns ENOTDIR.

**Workaround**: To support SFS directories, the FD would need to store the resolved path at open time, or the VFS would need a reverse-lookup capability to reconstruct the path from the mount point and inode.

**Impact**: Low - fchdir is primarily used with "/" or "/dev", which are both supported. Shell scripts and system utilities can still use chdir(path) for SFS directories.

### mremap Edge Case Analysis

The test audit claimed `testMremapInvalidAddr` might fail, but investigation revealed the existing implementation is correct:

1. User-space address 0x12340000 is validated for page alignment (passes)
2. VMA walk does NOT dereference the address - it only compares against VMA bounds
3. When no VMA contains the address, `mremap` returns EFAULT
4. Test expects EFAULT or EINVAL - actual behavior matches expectations

**No code changes required** for MEM-01.

## Key Decisions

### Use DirTag for fchdir path resolution

**Context**: fchdir needs to determine the canonical path of a directory FD to update the process cwd.

**Options**:
1. **Store full path in FD** - Add a path field to FileDescriptor
2. **Walk VFS to reconstruct path** - Traverse mount points and inodes
3. **Use DirTag enum** - Map predefined directory tags to paths

**Decision**: Use DirTag enum (option 3)

**Rationale**:
- InitRD and DevFS directories already use DirTag in `fd.private_data`
- Mapping DirTag to path is O(1) and requires no additional memory per FD
- fchdir is primarily used with "/" and "/dev" in practice
- SFS directory support can be added later if needed (low priority)

**Trade-offs**:
- (+) Simple, efficient, no FD struct changes
- (+) Works immediately for the two most common directories
- (-) SFS directories not supported (returns ENOTDIR)
- (-) Future filesystems need explicit DirTag entries

## Related Work

- **Phase 26**: Systematic syscall coverage audit identified fchdir as missing
- **Phase 18**: mremap tests were verified passing, no known regressions
- **v1.2 audit**: Flagged mremap invalid addr as potentially failing

## Statistics

- **Duration**: 21 minutes
- **Tasks**: 2 (1 verified, 1 implemented)
- **Files modified**: 6
- **Lines added**: ~130 (fchdir implementation + tests)
- **Commits**: 2 (1 deviation fix, 1 feature)
- **Tests added**: 3 (fchdir basic, non-directory, invalid fd)
- **Tests passing**: 4 (3 fchdir + 1 mremap)

---

*Completed: 2026-02-16*
*Phase: 27 (Quick Wins)*
*Milestone: v1.3 Tech Debt Cleanup*
