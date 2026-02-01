const syscall = @import("syscall");
const syscall_tests = @import("tests/syscall/dir_ops.zig");
const file_io_tests = @import("tests/syscall/file_ops.zig");
const memory_tests = @import("tests/syscall/memory.zig");
const process_tests = @import("tests/syscall/process.zig");
const fs_tests = @import("tests/fs/basic.zig");
const fs_error_tests = @import("tests/fs/errors.zig");
const regression_tests = @import("tests/regression/sfs_issues.zig");
const edge_case_tests = @import("tests/fs/edge_cases.zig");
const stress_tests = @import("tests/fs/stress.zig");

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

fn printNumber(n: usize) void {
    if (n == 0) {
        syscall.debug_print("0");
        return;
    }

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    var num = n;

    while (num > 0) : (i += 1) {
        buf[i] = @intCast((num % 10) + '0');
        num /= 10;
    }

    while (i > 0) {
        i -= 1;
        const c: [1]u8 = .{buf[i]};
        syscall.debug_print(&c);
    }
}

fn testDummy() !void {
    // Always passes
}

export fn main(argc: i32, argv: [*][*:0]u8) i32 {
    _ = argc;
    _ = argv;

    syscall.debug_print("TEST_START: test_runner\n\n");

    var runner = TestRunner{};

    // Syscall tests - directory operations
    runner.runTest("sys_chdir: accepts directories", syscall_tests.testChdirAcceptsDirectories);
    runner.runTest("sys_chdir: rejects files", syscall_tests.testChdirRejectsFiles);
    runner.runTest("sys_getcwd: returns path", syscall_tests.testGetcwd);
    runner.runTest("sys_getdents64: lists root", syscall_tests.testGetdentsInitrd);

    // Syscall tests - file I/O
    runner.runTest("file_io: open read close initrd", file_io_tests.testOpenReadCloseInitrd);
    runner.runTest("file_io: open write close sfs", file_io_tests.testOpenWriteCloseSfs);
    runner.runTest("file_io: open with truncate", file_io_tests.testOpenWithTruncate);
    runner.runTest("file_io: open with append", file_io_tests.testOpenWithAppend);
    runner.runTest("file_io: lseek from start", file_io_tests.testLseekFromStart);
    runner.runTest("file_io: lseek from end", file_io_tests.testLseekFromEnd);
    runner.runTest("file_io: lseek beyond eof", file_io_tests.testLseekBeyondEof);
    runner.runTest("file_io: multiple reads advance position", file_io_tests.testMultipleReadsAdvancePosition);
    runner.runTest("file_io: write one block", file_io_tests.testWriteExactlyOneBlock);
    runner.runTest("file_io: write two blocks", file_io_tests.testWriteTwoBlocks);

    // Filesystem tests
    runner.runTest("initrd: read ELF file", fs_tests.testInitrdReadFile);
    runner.runTest("sfs: create and write file", fs_tests.testSfsCreateFile);
    runner.runTest("devfs: list devices", fs_tests.testDevfsListDevices);

    // Error handling tests
    runner.runTest("error: open nonexistent file", fs_error_tests.testOpenNonexistentFile);
    runner.runTest("error: read from write-only fd", fs_error_tests.testReadFromWriteOnlyFd);
    runner.runTest("error: write to read-only fd", fs_error_tests.testWriteToReadOnlyFd);
    runner.runTest("error: read from invalid fd", fs_error_tests.testReadFromInvalidFd);
    runner.runTest("error: getdents on non-directory", fs_error_tests.testGetdentsOnNonDirectory);
    runner.runTest("error: write to read-only fs", fs_error_tests.testWriteToReadOnlyFs);
    runner.runTest("error: mkdir on read-only fs", fs_error_tests.testMkdirOnReadOnlyFs);
    runner.runTest("error: chdir with empty path", fs_error_tests.testChdirWithEmptyPath);
    runner.runTest("error: chdir with too long path", fs_error_tests.testChdirWithTooLongPath);
    runner.runTest("error: getcwd with small buffer", fs_error_tests.testGetcwdWithSmallBuffer);
    runner.runTest("error: open with conflicting flags", fs_error_tests.testOpenWithConflictingFlags);
    runner.runTest("error: read past EOF", fs_error_tests.testReadPastEOF);

    // Regression tests
    runner.runTest("regression: sfs write no deadlock", regression_tests.testSfsWriteNoDeadlock);
    runner.runTest("regression: sfs write no double-lock fd", regression_tests.testSfsWriteNoDoubleLockFd);
    runner.runTest("regression: size toctou protection", regression_tests.testSizeToctouProtection);
    runner.runTest("regression: chdir returns enotdir", regression_tests.testChdirReturnsEnotdir);
    runner.runTest("regression: getdents small buffer", regression_tests.testGetdentsSmallBuffer);
    runner.runTest("regression: sfs max capacity", regression_tests.testSfsMaxCapacity);

    // Edge case tests
    runner.runTest("edge: read exact block boundary", edge_case_tests.testReadExactBlockBoundary);
    runner.runTest("edge: write across block boundary", edge_case_tests.testWriteAcrossBlockBoundary);
    runner.runTest("edge: read zero bytes", edge_case_tests.testReadZeroBytes);
    runner.runTest("edge: write zero bytes", edge_case_tests.testWriteZeroBytes);
    runner.runTest("edge: open same file twice", edge_case_tests.testOpenSameFileTwice);
    runner.runTest("edge: concurrent reads no block", edge_case_tests.testConcurrentReadsNoBlock);
    runner.runTest("edge: seek max safe offset", edge_case_tests.testSeekMaxSafeOffset);
    runner.runTest("edge: getdents empty directory", edge_case_tests.testGetdentsEmptyDirectory);
    runner.runTest("edge: filename 31 chars on sfs", edge_case_tests.testFilename31CharsOnSfs);
    runner.runTest("edge: filename 32 chars fails", edge_case_tests.testFilename32CharsFails);

    // Memory tests
    runner.runTest("memory: mmap anonymous", memory_tests.testMmapAnonymous);
    runner.runTest("memory: mmap fixed address", memory_tests.testMmapFixed);
    runner.runTest("memory: mmap with protection", memory_tests.testMmapWithProtection);
    runner.runTest("memory: munmap releases memory", memory_tests.testMunmap);
    runner.runTest("memory: brk expand heap", memory_tests.testBrkExpand);
    runner.runTest("memory: brk shrink heap", memory_tests.testBrkShrink);
    runner.runTest("memory: mmap length zero", memory_tests.testMmapLengthZero);
    runner.runTest("memory: mmap length overflow", memory_tests.testMmapLengthOverflow);
    runner.runTest("memory: multiple small allocations", memory_tests.testMultipleSmallAllocations);
    runner.runTest("memory: alloc write munmap realloc", memory_tests.testAllocWriteMunmapRealloc);

    // Process tests
    runner.runTest("process: fork creates child", process_tests.testForkCreatesChild);
    runner.runTest("process: fork independent memory", process_tests.testForkIndependentMemory);
    runner.runTest("process: exit with status", process_tests.testExitWithStatus);
    runner.runTest("process: wait4 blocks", process_tests.testWait4Blocks);
    runner.runTest("process: wait4 nohang", process_tests.testWait4Nohang);
    runner.runTest("process: getpid unique", process_tests.testGetpidUnique);
    runner.runTest("process: getppid returns parent", process_tests.testGetppidReturnsParent);
    runner.runTest("process: exec replaces process", process_tests.testExecReplacesProcess);

    // Stress tests
    runner.runTest("stress: write 10MB file", stress_tests.testWrite10MbFile);
    runner.runTest("stress: create 100 files", stress_tests.testCreate100Files);
    runner.runTest("stress: fragmented writes", stress_tests.testFragmentedWrites);
    runner.runTest("stress: max open FDs", stress_tests.testMaxOpenFds);
    runner.runTest("stress: large directory listing", stress_tests.testLargeDirectoryListing);
    runner.runTest("stress: rapid process ops", stress_tests.testRapidProcessOps);

    // Basic sanity test
    runner.runTest("dummy: always passes", testDummy);

    runner.printSummary();

    const exit_code: i32 = if (runner.failed > 0) 1 else 0;
    syscall.debug_print("TEST_EXIT: ");
    printNumber(@intCast(exit_code));
    syscall.debug_print("\n");

    // Exit cleanly to shutdown QEMU (no timeout needed)
    syscall.exit(exit_code);
}
