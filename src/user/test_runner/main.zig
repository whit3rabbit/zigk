const syscall = @import("syscall");
const syscall_tests = @import("tests/syscall/dir_ops.zig");
const file_io_tests = @import("tests/syscall/file_ops.zig");
const memory_tests = @import("tests/syscall/memory.zig");
const process_tests = @import("tests/syscall/process.zig");
const uid_gid_tests = @import("tests/syscall/uid_gid.zig");
const signal_tests = @import("tests/syscall/signals.zig");
const socket_tests = @import("tests/syscall/sockets.zig");
const fd_ops_tests = @import("tests/syscall/fd_ops.zig");
const file_info_tests = @import("tests/syscall/file_info.zig");
const time_ops_tests = @import("tests/syscall/time_ops.zig");
const misc_tests = @import("tests/syscall/misc.zig");
const at_ops_tests = @import("tests/syscall/at_ops.zig");
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
    runner.runTest("file_io: flock shared lock", file_io_tests.testFlockSharedLock);
    runner.runTest("file_io: flock exclusive lock", file_io_tests.testFlockExclusiveLock);
    runner.runTest("file_io: flock non-blocking", file_io_tests.testFlockNonBlocking);

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
    runner.runTest("error: write to bad fd", fs_error_tests.testWriteToBadFd);
    runner.runTest("error: lseek invalid whence", fs_error_tests.testLseekInvalidWhence);
    runner.runTest("error: open too many fds", fs_error_tests.testOpenTooManyFds);
    runner.runTest("error: open directory for write", fs_error_tests.testOpenDirectoryForWrite);
    runner.runTest("error: write after close", fs_error_tests.testWriteAfterClose);
    runner.runTest("error: double close", fs_error_tests.testDoubleClose);
    runner.runTest("error: read null buffer", fs_error_tests.testReadNullBuffer);
    runner.runTest("error: write null buffer", fs_error_tests.testWriteNullBuffer);
    runner.runTest("error: open null path", fs_error_tests.testOpenNullPath);

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
    runner.runTest("memory: mprotect read-only", memory_tests.testMprotectReadOnly);
    runner.runTest("memory: mprotect read-write", memory_tests.testMprotectReadWrite);
    runner.runTest("memory: mprotect invalid addr", memory_tests.testMprotectInvalidAddr);
    runner.runTest("memory: mlock pages", memory_tests.testMlockPages);
    runner.runTest("memory: munlock pages", memory_tests.testMunlockPages);
    runner.runTest("memory: madvise sequential", memory_tests.testMadviseSequential);
    runner.runTest("memory: msync no-op", memory_tests.testMsyncNoOp);
    runner.runTest("memory: mlockall munlockall", memory_tests.testMlockallMunlockall);
    runner.runTest("memory: mincore basic", memory_tests.testMincoreBasic);
    runner.runTest("memory: madvise invalid align", memory_tests.testMadviseInvalidAlign);
    runner.runTest("memory: mlockall invalid flags", memory_tests.testMlockallInvalidFlags);
    runner.runTest("memory: mincore invalid align", memory_tests.testMincoreInvalidAlign);
    runner.runTest("memory: mlockall future flag", memory_tests.testMlockallFutureFlag);

    // Process tests
    runner.runTest("process: fork creates child", process_tests.testForkCreatesChild);
    runner.runTest("process: fork independent memory", process_tests.testForkIndependentMemory);
    runner.runTest("process: exit with status", process_tests.testExitWithStatus);
    runner.runTest("process: wait4 blocks", process_tests.testWait4Blocks);
    runner.runTest("process: wait4 nohang", process_tests.testWait4Nohang);
    runner.runTest("process: getpid unique", process_tests.testGetpidUnique);
    runner.runTest("process: getppid returns parent", process_tests.testGetppidReturnsParent);
    runner.runTest("process: exec replaces process", process_tests.testExecReplacesProcess);
    runner.runTest("process: alarm set and cancel", process_tests.testAlarmSetAndCancel);
    runner.runTest("process: alarm basic", process_tests.testAlarmBasic);
    runner.runTest("process: sysinfo valid", process_tests.testSysinfoValid);
    runner.runTest("process: sysinfo consistent", process_tests.testSysinfoConsistent);
    runner.runTest("process: times basic", process_tests.testTimesBasic);
    runner.runTest("process: times children", process_tests.testTimesChildren);
    runner.runTest("process: getitimer basic", process_tests.testGetitimerBasic);
    runner.runTest("process: setitimer basic", process_tests.testSetitimerBasic);
    runner.runTest("process: setitimer periodic", process_tests.testSetitimerPeriodic);
    runner.runTest("process: setitimer cancel", process_tests.testSetitimerCancel);
    runner.runTest("process: itimer independent", process_tests.testItimerIndependent);
    runner.runTest("process: getpgid basic", process_tests.testGetpgidBasic);
    runner.runTest("process: getpgrp equivalence", process_tests.testGetpgrpEquivalence);
    runner.runTest("process: setpgid self", process_tests.testSetpgidSelf);
    runner.runTest("process: setpgid child", process_tests.testSetpgidChild);
    runner.runTest("process: setsid basic", process_tests.testSetsidBasic);
    runner.runTest("process: setsid fails for group leader", process_tests.testSetsidFailsForGroupLeader);
    runner.runTest("process: getsid basic", process_tests.testGetsidBasic);
    runner.runTest("signal: kill single process", process_tests.testKillToSingleProcess);
    runner.runTest("signal: kill current process group", process_tests.testKillToCurrentProcessGroup);
    runner.runTest("signal: kill specific process group", process_tests.testKillToSpecificProcessGroup);
    runner.runTest("signal: killpg wrapper", process_tests.testKillpgWrapper);
    runner.runTest("wait: waitpid wrapper", process_tests.testWaitpidWrapper);
    runner.runTest("wait: wait4 process group (pid=0)", process_tests.testWait4ProcessGroup);
    runner.runTest("wait: wait4 specific process group", process_tests.testWait4SpecificProcessGroup);

    // Job control tests
    runner.runTest("job: terminal foreground pgroup", process_tests.testTerminalForegroundPgroup);
    runner.runTest("job: SIGTSTP stops process", process_tests.testSigtstpStopsProcess);
    runner.runTest("job: SIGCONT resumes process", process_tests.testSigcontResumesProcess);
    runner.runTest("job: controlling terminal", process_tests.testControllingTerminal);
    runner.runTest("job: SIGTTOU background write", process_tests.testSigttouBackgroundWrite);
    runner.runTest("job: background process group", process_tests.testBackgroundProcessGroup);

    // UID/GID tests
    runner.runTest("uid/gid: getuid returns 0", uid_gid_tests.testGetuidReturnsZero);
    runner.runTest("uid/gid: geteuid returns 0", uid_gid_tests.testGeteuidReturnsZero);
    runner.runTest("uid/gid: getgid returns 0", uid_gid_tests.testGetgidReturnsZero);
    runner.runTest("uid/gid: getegid returns 0", uid_gid_tests.testGetegidReturnsZero);
    runner.runTest("uid/gid: setuid as root succeeds", uid_gid_tests.testSetuidAsRootSucceeds);
    runner.runTest("uid/gid: setgid as root succeeds", uid_gid_tests.testSetgidAsRootSucceeds);
    runner.runTest("uid/gid: getresuid returns all zeros", uid_gid_tests.testGetresuidReturnsAllZeros);
    runner.runTest("uid/gid: getresgid returns all zeros", uid_gid_tests.testGetresgidReturnsAllZeros);

    // Signal handling tests
    runner.runTest("signal: sigaction install handler", signal_tests.testSigactionInstallHandler);
    runner.runTest("signal: sigprocmask block signal", signal_tests.testSigprocmaskBlockSignal);
    runner.runTest("signal: sigpending after block", signal_tests.testSigpendingAfterBlock);
    runner.runTest("signal: kill self", signal_tests.testKillSelf);
    runner.runTest("signal: sigaltstack setup", signal_tests.testSigaltstackSetup);
    runner.runTest("signal: multiple handlers", signal_tests.testMultipleHandlers);

    // Socket tests
    runner.runTest("socket: create TCP", socket_tests.testSocketCreateTcp);
    runner.runTest("socket: create UDP", socket_tests.testSocketCreateUdp);
    runner.runTest("socket: invalid domain", socket_tests.testSocketInvalidDomain);
    runner.runTest("socket: bind localhost", socket_tests.testBindLocalhost);
    runner.runTest("socket: listen on socket", socket_tests.testListenOnSocket);
    runner.runTest("socket: getsockname", socket_tests.testGetSockName);
    runner.runTest("socket: setsockopt SO_REUSEADDR", socket_tests.testSetSockoptReuseAddr);
    runner.runTest("socket: connect to unbound port", socket_tests.testConnectToUnboundPort);

    // FD operations tests
    runner.runTest("fd_ops: dup basic", fd_ops_tests.testDupBasic);
    runner.runTest("fd_ops: dup2 basic", fd_ops_tests.testDup2Basic);
    runner.runTest("fd_ops: dup2 same fd", fd_ops_tests.testDup2SameFd);
    runner.runTest("fd_ops: dup2 closes target", fd_ops_tests.testDup2ClosesTarget);
    runner.runTest("fd_ops: pipe basic", fd_ops_tests.testPipeBasic);
    runner.runTest("fd_ops: pipe direction", fd_ops_tests.testPipeDirection);
    runner.runTest("fd_ops: pipe close EOF", fd_ops_tests.testPipeClose);
    runner.runTest("fd_ops: fcntl getflags", fd_ops_tests.testFcntlGetFlags);
    runner.runTest("fd_ops: fcntl dupfd", fd_ops_tests.testFcntlDupfd);
    runner.runTest("fd_ops: pread64 basic", fd_ops_tests.testPread64Basic);

    // File info tests
    runner.runTest("file_info: stat basic file", file_info_tests.testStatBasicFile);
    runner.runTest("file_info: fstat open file", file_info_tests.testFstatOpenFile);
    runner.runTest("file_info: stat size matches", file_info_tests.testStatSize);
    runner.runTest("file_info: stat directory mode", file_info_tests.testStatModeDirectory);
    runner.runTest("file_info: ftruncate file", file_info_tests.testFtruncateFile);
    runner.runTest("file_info: rename file", file_info_tests.testRenameFile);
    runner.runTest("file_info: chmod file", file_info_tests.testChmodFile);
    runner.runTest("file_info: unlink file", file_info_tests.testUnlinkFile);
    runner.runTest("file_info: rmdir directory", file_info_tests.testRmdirDirectory);
    runner.runTest("file_info: access exists", file_info_tests.testAccessExists);
    runner.runTest("file_info: access nonexistent", file_info_tests.testAccessNonexistent);
    runner.runTest("file_info: lstat basic", file_info_tests.testLstatBasic);

    // Time operations tests
    runner.runTest("time_ops: nanosleep basic", time_ops_tests.testNanosleepBasic);
    runner.runTest("time_ops: clock_gettime monotonic", time_ops_tests.testClockGettimeMonotonic);
    runner.runTest("time_ops: clock_gettime realtime", time_ops_tests.testClockGettimeRealtime);
    runner.runTest("time_ops: monotonic 2 calls", time_ops_tests.testClockGettimeMonotonic2Calls);
    runner.runTest("time_ops: clock_getres monotonic", time_ops_tests.testClockGetresMonotonic);
    runner.runTest("time_ops: gettimeofday basic", time_ops_tests.testGettimeofdayBasic);
    runner.runTest("time_ops: sleep_ms basic", time_ops_tests.testSleepMsBasic);
    runner.runTest("time_ops: sched_yield", time_ops_tests.testSchedYield);

    // Misc syscall tests
    runner.runTest("misc: uname basic", misc_tests.testUnameBasic);
    runner.runTest("misc: uname machine arch", misc_tests.testUnameMachineArch);
    runner.runTest("misc: umask basic", misc_tests.testUmaskBasic);
    runner.runTest("misc: umask restore", misc_tests.testUmaskRestore);
    runner.runTest("misc: getrandom basic", misc_tests.testGetrandomBasic);
    runner.runTest("misc: getrandom nonblocking", misc_tests.testGetrandomNonblocking);
    runner.runTest("misc: writev basic", misc_tests.testWritevBasic);
    runner.runTest("misc: poll timeout", misc_tests.testPollTimeout);
    runner.runTest("misc: sched_get_priority_max", misc_tests.testSchedGetPriorityMax);
    runner.runTest("misc: sched_get_priority_min", misc_tests.testSchedGetPriorityMin);
    runner.runTest("misc: sched_get_priority_invalid", misc_tests.testSchedGetPriorityInvalid);
    runner.runTest("misc: sched_getscheduler", misc_tests.testSchedGetScheduler);
    runner.runTest("misc: sched_getparam", misc_tests.testSchedGetParam);
    runner.runTest("misc: sched_setscheduler", misc_tests.testSchedSetScheduler);
    runner.runTest("misc: sched_rr_get_interval", misc_tests.testSchedRrGetInterval);
    runner.runTest("misc: prlimit64 get NOFILE", misc_tests.testPrlimit64GetNofile);
    runner.runTest("misc: getrusage self", misc_tests.testGetrusageSelf);
    runner.runTest("misc: getrusage invalid", misc_tests.testGetrusageInvalid);
    runner.runTest("misc: rt_sigpending", misc_tests.testRtSigpending);

    // AT* family tests
    runner.runTest("at_ops: fstatat basic", at_ops_tests.testFstatatBasic);
    runner.runTest("at_ops: mkdirat basic", at_ops_tests.testMkdiratBasic);
    runner.runTest("at_ops: unlinkat file", at_ops_tests.testUnlinkatFile);
    runner.runTest("at_ops: unlinkat dir", at_ops_tests.testUnlinkatDir);
    runner.runTest("at_ops: renameat basic", at_ops_tests.testRenameatBasic);
    runner.runTest("at_ops: fchmodat basic", at_ops_tests.testFchmodatBasic);

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
