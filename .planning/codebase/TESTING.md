# Testing Patterns

**Analysis Date:** 2026-02-06

## Test Framework

**Unit Tests (Host-side):**
- Framework: `zig test` (Zig standard testing framework)
- Location: `tests/unit/`
- Runner: `zig build test`
- Assertion library: `std.testing` (expectEqual, expect, expectError)

**Integration Tests (Kernel-side):**
- Framework: Custom userspace test harness
- Location: `src/user/test_runner/`
- Runner: Built as boot target with `zig build run -Ddefault-boot=test_runner`
- Invoked via: `scripts/run_tests.sh` (CI/automation)
- Output format: TAP-like with custom markers

**Test Automation:**
- Script: `./scripts/run_tests.sh`
- Single arch: `ARCH=x86_64 ./scripts/run_tests.sh`
- Both architectures: `RUN_BOTH=true ./scripts/run_tests.sh`
- Timeout: 90 seconds per architecture (configurable via `TIMEOUT` env var)

## Run Commands

```bash
# Unit tests (host-side, standard Zig)
zig build test

# Integration tests (kernel + userspace harness)
./scripts/run_tests.sh                    # Single arch (x86_64 by default)
ARCH=aarch64 ./scripts/run_tests.sh      # Specific architecture
RUN_BOTH=true ./scripts/run_tests.sh     # Both x86_64 and aarch64

# Manual test runner invocation (debugging)
zig build run -Darch=x86_64 -Ddefault-boot=test_runner
zig build run -Darch=aarch64 -Ddefault-boot=test_runner -Dqemu-args="-nographic"

# View full test output
strings test_output_x86_64.log | grep "pattern"  # Search full output
cat test_output_x86_64.log                        # Full QEMU output
```

## Test File Organization

**Location:**
- Unit tests: Colocated in modules with the code they test (e.g., inline `test "..."` blocks)
- Integration tests: Separate in `src/user/test_runner/tests/`

**Naming:**
- Integration test files: `<category>.zig` (e.g., `file_ops.zig`, `process.zig`)
- Unit tests: Inline test blocks with descriptive names
- Test functions: `pub fn test<Feature>...() !void`

**Structure:**
```
src/user/test_runner/
├── main.zig                    # Test runner harness (registry of all tests)
├── lib/
│   ├── multi_process.zig      # Shared multi-process test utilities
│   └── ...
└── tests/
    ├── syscall/
    │   ├── dir_ops.zig        # Directory operations (chdir, getcwd, getdents64)
    │   ├── file_ops.zig       # File I/O (open, read, write, lseek, truncate, append)
    │   ├── file_info.zig      # File metadata (stat, fstat, lstat, chmod, access, truncate, rename)
    │   ├── fd_ops.zig         # FD operations (dup, dup2, pipe, pipe2, fcntl, pread64)
    │   ├── memory.zig         # Memory (mmap, munmap, brk, mprotect, mlock, madvise, msync)
    │   ├── process.zig        # Process control (fork, exec, wait, exit, getpid, alarm)
    │   ├── time_ops.zig       # Timers (nanosleep, clock_gettime, clock_getres, gettimeofday)
    │   ├── misc.zig           # Miscellaneous (uname, umask, getrandom, writev, poll)
    │   ├── at_ops.zig         # *at family (fstatat, mkdirat, unlinkat, renameat, fchmodat)
    │   ├── signals.zig        # Signal handling
    │   ├── sockets.zig        # Socket operations
    │   └── uid_gid.zig        # User/group IDs
    ├── fs/
    │   ├── basic.zig          # Basic filesystem operations (InitRD read, SFS create, DevFS list)
    │   ├── errors.zig         # Error conditions (invalid fd, permissions, read-only, etc.)
    │   ├── edge_cases.zig     # Boundary conditions (block boundaries, zero-length ops, filename limits)
    │   └── stress.zig         # Stress tests (large files, many files, concurrent operations)
    └── regression/
        └── sfs_issues.zig     # Known bug fixes (deadlock, TOCTOU, etc.)
```

## Test Structure

**Integration test pattern:**
```zig
const syscall = @import("syscall");

// Simple happy-path test
pub fn testOpenReadCloseInitrd() !void {
    const fd = try syscall.open("/shell.elf", 0, 0); // O_RDONLY
    defer syscall.close(@intCast(fd)) catch {};

    var buf: [256]u8 = undefined;
    const bytes_read = try syscall.read(fd, &buf, buf.len);

    // Verify result
    if (bytes_read < 52) return error.TestFailed;
    if (buf[0] != 0x7F or buf[1] != 'E' or buf[2] != 'L' or buf[3] != 'F') {
        return error.TestFailed;
    }
}

// Process test with fork/wait
pub fn testForkCreatesChild() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child process
        syscall.exit(0);
    } else {
        // Parent process
        if (pid <= 0) return error.InvalidPid;

        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) return error.WaitFailed;
        if (status != 0) return error.ChildExitedNonZero;
    }
}

// Error-handling test (SkipTest for unsupported features)
pub fn testOpenWriteCloseSfs() !void {
    const O_RDWR = 2;
    const O_CREAT = 0x40;
    const O_TRUNC = 0x200;

    const fd = syscall.open("/mnt/test_write.txt", O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
        return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory)
            error.SkipTest
        else
            err;
    };
    defer syscall.close(@intCast(fd)) catch {};

    const data = "Hello, ZK!";
    const written = try syscall.write(fd, data.ptr, data.len);

    if (written != data.len) return error.TestFailed;
}
```

**Unit test pattern (Zig test blocks):**
```zig
const std = @import("std");
const testing = std.testing;
const heap = @import("heap");

// Setup helper
fn initHeap() void {
    heap.reset();
    heap.init(@intFromPtr(&backing_buffer), backing_buffer.len);
}

// Test case
test "heap: basic alloc and free" {
    initHeap();

    const ptr1 = heap.alloc(100) orelse return error.OutOfMemory;
    const ptr2 = heap.alloc(200) orelse return error.OutOfMemory;
    const ptr3 = heap.alloc(300) orelse return error.OutOfMemory;

    // Verify allocations are distinct
    try testing.expect(@intFromPtr(ptr1.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expect(@intFromPtr(ptr2.ptr) != @intFromPtr(ptr3.ptr));

    // Free in different order
    heap.free(ptr2);
    heap.free(ptr1);
    heap.free(ptr3);

    // All memory should be freed
    try testing.expectEqual(@as(usize, 0), heap.getAllocationCount());
}
```

## Test Runner (Integration Harness)

**Main test runner: `src/user/test_runner/main.zig`**

```zig
const TestRunner = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    total: usize = 0,

    fn runTest(self: *TestRunner, name: []const u8, test_fn: fn () anyerror!void) void {
        self.total += 1;

        syscall.debug_print("Running: ");
        syscall.debug_print(name);
        syscall.debug_print("\n");

        test_fn() catch |err| {
            if (err == error.SkipTest) {
                syscall.debug_print("SKIP: ");
                syscall.debug_print(name);
                syscall.debug_print(" (not implemented)\n");
                self.skipped += 1;
                return;
            }
            syscall.debug_print("FAIL: ");
            syscall.debug_print(name);
            syscall.debug_print(" (");
            syscall.debug_print(@errorName(err));
            syscall.debug_print(")\n");
            self.failed += 1;
            return;
        };

        syscall.debug_print("PASS: ");
        syscall.debug_print(name);
        syscall.debug_print("\n");
        self.passed += 1;
    }

    fn printSummary(self: *const TestRunner) void {
        syscall.debug_print("\n====================================\n");
        syscall.debug_print("TEST_SUMMARY: ");
        printNumber(self.passed);
        syscall.debug_print(" passed, ");
        printNumber(self.failed);
        syscall.debug_print(" failed, ");
        printNumber(self.skipped);
        syscall.debug_print(" skipped, ");
        printNumber(self.total);
        syscall.debug_print(" total\n");
        syscall.debug_print("====================================\n");
    }
};

export fn main(argc: i32, argv: [*][*:0]u8) i32 {
    var runner = TestRunner{};

    // Register all test categories
    runner.runTest("sys_chdir: accepts directories", syscall_tests.testChdirAcceptsDirectories);
    runner.runTest("file_io: open read close initrd", file_io_tests.testOpenReadCloseInitrd);
    // ... 180+ more tests ...

    runner.printSummary();
    return if (runner.failed > 0) 1 else 0;
}
```

## Test Output Format

**Integration test output (TAP-like):**
```
TEST_START: test_runner

Running: sys_chdir: accepts directories
PASS: sys_chdir: accepts directories
Running: sys_chdir: rejects files
PASS: sys_chdir: rejects files
Running: file_io: open read close initrd
PASS: file_io: open read close initrd
Running: error: open nonexistent file
FAIL: error: open nonexistent file (EFAULT)
Running: process: setsid fails for group leader
SKIP: process: setsid fails for group leader (not implemented)

====================================
TEST_SUMMARY: 166 passed, 0 failed, 20 skipped, 186 total
====================================

TEST_EXIT: 0
```

**Exit codes:**
- `0` = All tests passed (failed == 0)
- `1` = At least one test failed (failed > 0)

**Log file location:**
- `test_output_x86_64.log` - Full QEMU output for x86_64 tests
- `test_output_aarch64.log` - Full QEMU output for aarch64 tests

## Test Categories

**186 integration tests organized by category:**

**Filesystem (15 tests):**
- VFS operations (InitRD, SFS, DevFS)
- Directory listing and navigation
- File open/close lifecycle

**Syscalls - Directory Operations (4 tests):**
- `sys_chdir`: Change working directory
- `sys_getcwd`: Get current working directory
- `sys_getdents64`: List directory entries

**Syscalls - File I/O (10 tests):**
- `sys_open`: Open file with various flags
- `sys_read`: Read file content
- `sys_write`: Write file content
- `sys_lseek`: Seek within file
- `sys_truncate`: Truncate file to size
- File append mode (O_APPEND)

**Syscalls - File Descriptor Operations (10 tests):**
- `sys_dup`: Duplicate file descriptor
- `sys_dup2`: Duplicate to specific number
- `sys_pipe`/`sys_pipe2`: Create pipe
- `sys_fcntl`: File descriptor control
- `sys_pread64`: Read at offset

**Syscalls - File Information (12 tests):**
- `sys_stat`: Get file status by path
- `sys_fstat`: Get file status by fd
- `sys_lstat`: Get symlink status (no follow)
- `sys_chmod`: Change file permissions
- `sys_access`: Check file access permissions
- `sys_rename`: Rename file
- `sys_truncate`: Truncate by path

**Syscalls - Time Operations (8 tests):**
- `sys_nanosleep`: Sleep with nanosecond precision
- `sys_clock_gettime`: Get current time
- `sys_clock_getres`: Get clock resolution
- `sys_gettimeofday`: Get current time (legacy)
- `sys_sched_yield`: Yield processor

**Syscalls - Miscellaneous (8 tests):**
- `sys_uname`: System information
- `sys_umask`: Set file creation mask
- `sys_getrandom`: Get random bytes
- `sys_writev`: Write scatter/gather
- `sys_poll`: Wait for I/O events

**Syscalls - *at Family (6 tests):**
- `sys_fstatat`: Stat file relative to directory fd
- `sys_mkdirat`: Create directory relative to fd
- `sys_unlinkat`: Unlink file relative to fd
- `sys_renameat`: Rename relative to directory fd
- `sys_fchmodat`: Change permissions relative to fd

**Error Handling (12 tests):**
- Invalid file descriptors
- Permission denied
- Boundary condition violations
- Conflicting flags (e.g., O_RDONLY | O_WRONLY)

**Regression Tests (6 tests):**
- SFS deadlock prevention
- TOCTOU (Time-Of-Check-Time-Of-Use) race condition handling
- Size tracking protection

**Edge Cases (10 tests):**
- Block boundary reads/writes
- Zero-length operations
- Filename length limits (31 vs 32 chars on SFS)
- Concurrent reads without blocking

**Memory Management (10 tests):**
- `sys_mmap`: Map memory regions
- `sys_munmap`: Unmap regions
- `sys_brk`: Expand/shrink heap
- `sys_mprotect`: Change memory protections
- `sys_mlock`/`sys_munlock`: Lock pages
- `sys_madvise`: Memory usage hints
- `sys_msync`: Sync mmap regions

**Process Management (19 tests):**
- `sys_fork`: Create child process
- `sys_exec`: Replace process image
- `sys_wait4`: Wait for child exit
- `sys_exit`: Terminate process
- `sys_getpid`: Get process ID
- `sys_getppid`: Get parent process ID
- `sys_alarm`: Set alarm signal
- `sys_sysinfo`: System information
- `sys_times`: Process timing
- `sys_getitimer`/`sys_setitimer`: Interval timers
- Process groups and sessions

**Stress Tests (6 tests):**
- Large file operations (10MB files)
- Many files (100+ files)
- Concurrent operations
- Rapid allocation/deallocation

## Coverage Status

**Test Coverage:**
- 95+ syscalls tested
- 15 test categories
- Both x86_64 and aarch64 architectures
- 186 tests total: 166 passing, 20 skipped

**Architecture Support:**
- **x86_64**: Full test coverage, all tests passing
- **aarch64**: Full test coverage, all tests passing (previously had collision/ABI bugs, now fixed)

**Skipped Tests (20 total):**

1. **process: setsid fails for group leader** (`testSetsidFailsForGroupLeader`)
   - **Reason**: Test environment constraint - every spawned process starts as its own session leader
   - **Status**: Syscall implementation is POSIX-compliant; test environment limitation
   - **Action**: Do not attempt to fix - documented limitation, not a kernel bug

2. **SFS-related skips (16 tests)**:
   - Tests requiring close/rmdir/rename after many SFS operations are skipped
   - Reason: Known SFS limitations (flat filesystem, max 64 files, 32-char filename limit)
   - Affected categories: file_info, at_ops, filesystem operations
   - **Note**: These are SFS limitations, not syscall bugs

3. **Pre-existing skips (3 tests)**: Earlier process and filesystem tests skipped for known limitations

## Mocking

**Framework:** None (tests use real kernel syscalls)

**What to mock (N/A):** Tests run against live kernel, all syscalls hit real implementation

**What NOT to mock (N/A):** All I/O is real

## Fixtures and Factories

**Test data:**
```zig
const filepath = "/mnt/test_write.txt";
const O_RDWR = 2;
const O_CREAT = 0x40;
const O_TRUNC = 0x200;

const fd = syscall.open(filepath, O_RDWR | O_CREAT | O_TRUNC, 0o644) catch |err| {
    return if (err == error.ReadOnlyFilesystem or err == error.NoSuchFileOrDirectory)
        error.SkipTest
    else
        err;
};
```

**Shared utilities:** `src/user/test_runner/lib/multi_process.zig`
- `MultiProcessTest.init()` - Setup multi-process test harness
- `testForkIndependentMemory()` - Verify fork isolation
- `testWait4Nohang()` - Non-blocking wait test

**Location:** `src/user/test_runner/lib/`

## Coverage Requirements

**Target:** 95+ syscalls with integration tests

**Current status:** Met
- 166 passing tests
- 20 skipped (known limitations, not failures)
- 0 failing tests on both x86_64 and aarch64

**Coverage by type:**
- File I/O: 90% (10/12 syscalls tested)
- Process: 85% (15/18 syscalls tested)
- Memory: 80% (8/10 syscalls tested)
- Networking: 50% (sockets available, full TCP/UDP in progress)

## Test Running

**CI/Automation:**
- GitHub Actions workflow: `.github/workflows/ci.yml`
- Runs on every PR/push
- Tests both x86_64 and aarch64
- Timeout: 90 seconds per architecture

**Manual testing:**
```bash
# Quick single-arch test
./scripts/run_tests.sh                    # x86_64 by default
ARCH=aarch64 ./scripts/run_tests.sh      # aarch64

# Multi-arch CI mode
RUN_BOTH=true ./scripts/run_tests.sh

# Unit tests
zig build test

# Debug: Full output inspection
strings test_output_x86_64.log | tail -100
```

## Known Test Limitations

**SFS filesystem constraints:**
- Flat filesystem (no nested subdirectories under /mnt)
- 64 files/directories maximum
- 32-character filename limit
- Close deadlock after 50+ operations

**Process environment:**
- Every spawned process starts as its own session leader (pid == pgid == sid)
- Limits testing of non-leader process scenarios
- `setsid` cannot fail in test environment

**Architecture-specific fixes (aarch64):**
- Fixed: `sys_execve` page table switching (must use `writeTtbr0`, not `writeCr3`)
- Fixed: Data abort fixup handler for `ldtrb` unprivileged loads
- Fixed: Syscall number collision handling (SYS_* uniqueness enforcement)

---

*Testing analysis: 2026-02-06*
