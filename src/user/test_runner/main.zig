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
const io_mux_tests = @import("tests/syscall/io_mux.zig");
const event_fds_tests = @import("tests/syscall/event_fds.zig");
const fs_extras_tests = @import("tests/syscall/fs_extras.zig");
const vectored_io_tests = @import("tests/syscall/vectored_io.zig");
const process_control_tests = @import("tests/syscall/process_control.zig");
const sysv_ipc_tests = @import("tests/syscall/sysv_ipc.zig");
const resource_limits_tests = @import("tests/syscall/resource_limits.zig");
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
    runner.runTest("uid/gid: setreuid as root", uid_gid_tests.testSetreuidAsRoot);
    runner.runTest("uid/gid: setreuid unchanged", uid_gid_tests.testSetreuidUnchanged);
    runner.runTest("uid/gid: setreuid non-root restricted", uid_gid_tests.testSetreuidNonRootRestricted);
    runner.runTest("uid/gid: setregid as root", uid_gid_tests.testSetregidAsRoot);
    runner.runTest("uid/gid: setregid non-root restricted", uid_gid_tests.testSetregidNonRootRestricted);
    runner.runTest("uid/gid: getgroups initial empty", uid_gid_tests.testGetgroupsInitialEmpty);
    runner.runTest("uid/gid: setgroups as root", uid_gid_tests.testSetgroupsAsRoot);
    runner.runTest("uid/gid: setgroups non-root fails", uid_gid_tests.testSetgroupsNonRootFails);
    runner.runTest("uid/gid: getgroups count only", uid_gid_tests.testGetgroupsCountOnly);
    runner.runTest("uid/gid: setfsuid returns previous", uid_gid_tests.testSetfsuidReturnsPrevious);
    runner.runTest("uid/gid: setfsgid returns previous", uid_gid_tests.testSetfsgidReturnsPrevious);
    runner.runTest("uid/gid: setfsuid non-root restricted", uid_gid_tests.testSetfsuidNonRootRestricted);
    runner.runTest("uid/gid: fsuid auto-sync", uid_gid_tests.testFsuidAutoSync);
    runner.runTest("uid/gid: chown as root", uid_gid_tests.testChownAsRoot);
    runner.runTest("uid/gid: chown non-owner fails", uid_gid_tests.testChownNonOwnerFails);
    runner.runTest("uid/gid: chown non-root can chgrp to own group", uid_gid_tests.testChownNonRootCanChgrpToOwnGroup);
    runner.runTest("uid/gid: chown non-root cannot change uid", uid_gid_tests.testChownNonRootCannotChangeUid);
    runner.runTest("uid/gid: fchown basic", uid_gid_tests.testFchownBasic);
    runner.runTest("uid/gid: fchownat with AT_FDCWD", uid_gid_tests.testFchownatWithATFdcwd);
    runner.runTest("uid/gid: fchownat symlink nofollow", uid_gid_tests.testFchownatSymlinkNofollow);
    runner.runTest("uid/gid: privilege drop full", uid_gid_tests.testPrivilegeDropFull);

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

    // Phase 7: Socket Extras
    runner.runTest("socket: socketpair stream", socket_tests.testSocketpairStream);
    runner.runTest("socket: socketpair bidirectional", socket_tests.testSocketpairBidirectional);
    runner.runTest("socket: socketpair invalid domain", socket_tests.testSocketpairInvalidDomain);
    runner.runTest("socket: shutdown write", socket_tests.testShutdownWrite);
    runner.runTest("socket: shutdown rdwr", socket_tests.testShutdownRdwr);
    runner.runTest("socket: sendto/recvfrom udp", socket_tests.testSendtoRecvfromUdp);
    runner.runTest("socket: sendto connected", socket_tests.testSendtoConnectedSocket);
    runner.runTest("socket: sendmsg/recvmsg basic", socket_tests.testSendmsgRecvmsgBasic);
    runner.runTest("socket: sendmsg scatter-gather", socket_tests.testSendmsgScatterGather);
    runner.runTest("socket: sendmsg invalid fd", socket_tests.testSendmsgInvalidFd);
    runner.runTest("socket: shutdown non-socket", socket_tests.testShutdownNonSocket);
    runner.runTest("socket: socketpair dgram", socket_tests.testSocketpairDgram);
    runner.runTest("socket: accept4 invalid flags", socket_tests.testAccept4InvalidFlags);
    runner.runTest("socket: accept4 valid flags", socket_tests.testAccept4ValidFlags);

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
    runner.runTest("fd_ops: dup3 with O_CLOEXEC", fd_ops_tests.testDup3Cloexec);
    runner.runTest("fd_ops: dup3 same fd returns EINVAL", fd_ops_tests.testDup3SameFdReturnsEinval);
    runner.runTest("fd_ops: dup3 invalid flags", fd_ops_tests.testDup3InvalidFlags);

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
    runner.runTest("file_info: statfs InitRD", file_info_tests.testStatfsInitRD);
    runner.runTest("file_info: statfs DevFS", file_info_tests.testStatfsDevFS);
    runner.runTest("file_info: statfs SFS", file_info_tests.testStatfsSFS);
    runner.runTest("file_info: fstatfs SFS", file_info_tests.testFstatfsSFS);

    // Resource limits tests
    runner.runTest("resource: getrlimit NOFILE", resource_limits_tests.testGetrlimitNofile);
    runner.runTest("resource: getrlimit AS", resource_limits_tests.testGetrlimitAs);
    runner.runTest("resource: setrlimit lower soft", resource_limits_tests.testSetrlimitLowerSoft);
    runner.runTest("resource: setrlimit rejects soft>hard", resource_limits_tests.testSetrlimitRejectsSoftGreaterThanHard);
    runner.runTest("resource: getrlimit multiple resources", resource_limits_tests.testGetrlimitMultipleResources);

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
    runner.runTest("misc: prlimit64 non-root cannot raise", misc_tests.testPrlimit64NonRootCannotRaise);
    runner.runTest("misc: prlimit64 self as non-root", misc_tests.testPrlimit64SelfAsNonRoot);
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

    // I/O Multiplexing tests
    runner.runTest("io_mux: epoll create and close", io_mux_tests.testEpollCreateAndClose);
    runner.runTest("io_mux: epoll ctl add and wait", io_mux_tests.testEpollCtlAddAndWait);
    runner.runTest("io_mux: epoll wait no events", io_mux_tests.testEpollWaitNoEvents);
    runner.runTest("io_mux: epoll pipe HUP", io_mux_tests.testEpollPipeHup);
    runner.runTest("io_mux: epoll regular file always ready", io_mux_tests.testEpollRegularFileAlwaysReady);
    runner.runTest("io_mux: select pipe readable", io_mux_tests.testSelectPipeReadable);
    runner.runTest("io_mux: select pipe writable", io_mux_tests.testSelectPipeWritable);
    runner.runTest("io_mux: select timeout", io_mux_tests.testSelectTimeout);
    runner.runTest("io_mux: poll pipe events", io_mux_tests.testPollPipeEvents);
    runner.runTest("io_mux: poll pipe HUP", io_mux_tests.testPollPipeHup);

    // Event notification FD tests
    runner.runTest("event_fds: eventfd create and close", event_fds_tests.testEventfdCreateAndClose);
    runner.runTest("event_fds: eventfd write and read", event_fds_tests.testEventfdWriteAndRead);
    runner.runTest("event_fds: eventfd semaphore mode", event_fds_tests.testEventfdSemaphoreMode);
    runner.runTest("event_fds: eventfd initial value", event_fds_tests.testEventfdInitialValue);
    runner.runTest("event_fds: eventfd epoll integration", event_fds_tests.testEventfdEpollIntegration);
    runner.runTest("event_fds: timerfd create and close", event_fds_tests.testTimerfdCreateAndClose);
    runner.runTest("event_fds: timerfd set and get time", event_fds_tests.testTimerfdSetAndGetTime);
    runner.runTest("event_fds: timerfd expiration", event_fds_tests.testTimerfdExpiration);
    runner.runTest("event_fds: timerfd disarm", event_fds_tests.testTimerfdDisarm);
    runner.runTest("event_fds: signalfd create and close", event_fds_tests.testSignalfdCreateAndClose);
    runner.runTest("event_fds: signalfd read signal", event_fds_tests.testSignalfdReadSignal);
    runner.runTest("event_fds: signalfd epoll integration", event_fds_tests.testSignalfdEpollIntegration);

    // Filesystem extras tests
    runner.runTest("fs_extras: readlinkat basic", fs_extras_tests.testReadlinkatBasic);
    runner.runTest("fs_extras: readlinkat invalid path", fs_extras_tests.testReadlinkatInvalidPath);
    runner.runTest("fs_extras: linkat basic", fs_extras_tests.testLinkatBasic);
    runner.runTest("fs_extras: linkat cross device", fs_extras_tests.testLinkatCrossDevice);
    runner.runTest("fs_extras: symlinkat basic", fs_extras_tests.testSymlinkatBasic);
    runner.runTest("fs_extras: symlinkat empty target", fs_extras_tests.testSymlinkatEmptyTarget);
    runner.runTest("fs_extras: utimensat null times", fs_extras_tests.testUtimensatNull);
    runner.runTest("fs_extras: utimensat specific time", fs_extras_tests.testUtimensatSpecificTime);
    runner.runTest("fs_extras: utimensat symlink nofollow", fs_extras_tests.testUtimensatSymlinkNofollow);
    runner.runTest("fs_extras: utimensat invalid nsec", fs_extras_tests.testUtimensatInvalidNsec);
    runner.runTest("fs_extras: futimesat basic", fs_extras_tests.testFutimesatBasic);
    runner.runTest("fs_extras: futimesat specific time", fs_extras_tests.testFutimesatSpecificTime);

    // Phase 15: File Synchronization tests
    runner.runTest("sync: fsync on regular file", fs_extras_tests.testFsyncOnRegularFile);
    runner.runTest("sync: fsync on read-only file", fs_extras_tests.testFsyncOnReadOnlyFile);
    runner.runTest("sync: fsync invalid fd", fs_extras_tests.testFsyncInvalidFd);
    runner.runTest("sync: fdatasync on regular file", fs_extras_tests.testFdatasyncOnRegularFile);
    runner.runTest("sync: fdatasync invalid fd", fs_extras_tests.testFdatasyncInvalidFd);
    runner.runTest("sync: sync global", fs_extras_tests.testSyncGlobal);
    runner.runTest("sync: syncfs on open file", fs_extras_tests.testSyncfsOnOpenFile);
    runner.runTest("sync: syncfs invalid fd", fs_extras_tests.testSyncfsInvalidFd);

    // Phase 16: Advanced File Operations tests
    runner.runTest("advanced_file_ops: fallocate default mode", fs_extras_tests.testFallocateDefaultMode);
    runner.runTest("advanced_file_ops: fallocate keep size", fs_extras_tests.testFallocateKeepSize);
    runner.runTest("advanced_file_ops: fallocate punch hole unsupported", fs_extras_tests.testFallocatePunchHoleUnsupported);
    runner.runTest("advanced_file_ops: fallocate invalid fd", fs_extras_tests.testFallocateInvalidFd);
    runner.runTest("advanced_file_ops: fallocate negative length", fs_extras_tests.testFallocateNegativeLength);
    runner.runTest("advanced_file_ops: renameat2 default flags", fs_extras_tests.testRenameat2DefaultFlags);
    runner.runTest("advanced_file_ops: renameat2 noreplace fail", fs_extras_tests.testRenameat2Noreplace);
    runner.runTest("advanced_file_ops: renameat2 noreplace success", fs_extras_tests.testRenameat2NoreplaceSuccess);
    runner.runTest("advanced_file_ops: renameat2 exchange", fs_extras_tests.testRenameat2Exchange);
    runner.runTest("advanced_file_ops: renameat2 invalid flags", fs_extras_tests.testRenameat2InvalidFlags);

    // Phase 17: Zero-Copy I/O tests
    runner.runTest("zero_copy_io: splice file to pipe", fs_extras_tests.testSpliceFileToPipe);
    runner.runTest("zero_copy_io: splice pipe to file", fs_extras_tests.testSplicePipeToFile);
    runner.runTest("zero_copy_io: splice with offset", fs_extras_tests.testSpliceWithOffset);
    runner.runTest("zero_copy_io: splice invalid both pipes", fs_extras_tests.testSpliceInvalidBothPipes);
    runner.runTest("zero_copy_io: tee basic", fs_extras_tests.testTeeBasic);
    runner.runTest("zero_copy_io: vmsplice basic", fs_extras_tests.testVmspliceBasic);
    runner.runTest("zero_copy_io: copy_file_range basic", fs_extras_tests.testCopyFileRangeBasic);
    runner.runTest("zero_copy_io: copy_file_range with offsets", fs_extras_tests.testCopyFileRangeWithOffsets);
    runner.runTest("zero_copy_io: copy_file_range invalid flags", fs_extras_tests.testCopyFileRangeInvalidFlags);
    runner.runTest("zero_copy_io: splice zero length", fs_extras_tests.testSpliceZeroLength);

    // Phase 5: Vectored & Positional I/O tests (non-SFS first, SFS last due to deadlock)
    runner.runTest("vectored_io: readv basic", vectored_io_tests.testReadvBasic);
    runner.runTest("vectored_io: readv empty vec", vectored_io_tests.testReadvEmptyVec);
    runner.runTest("vectored_io: preadv at offset", vectored_io_tests.testPreadvBasic);
    runner.runTest("vectored_io: preadv2 flags zero", vectored_io_tests.testPreadv2FlagsZero);
    runner.runTest("vectored_io: preadv2 offset neg1", vectored_io_tests.testPreadv2OffsetNeg1);
    runner.runTest("vectored_io: preadv2 hipri flag", vectored_io_tests.testPreadv2HipriFlag);
    runner.runTest("vectored_io: sendfile basic", vectored_io_tests.testSendfileBasic);
    runner.runTest("vectored_io: sendfile with offset", vectored_io_tests.testSendfileWithOffset);
    runner.runTest("vectored_io: sendfile invalid fd", vectored_io_tests.testSendfileInvalidFd);
    runner.runTest("vectored_io: sendfile large transfer", vectored_io_tests.testSendfileLargeTransfer);

    // Phase 8: Process Control tests
    runner.runTest("process_control: prctl set/get name", process_control_tests.testPrctlSetGetName);
    runner.runTest("process_control: prctl get name default", process_control_tests.testPrctlGetNameDefault);
    runner.runTest("process_control: prctl set name truncation", process_control_tests.testPrctlSetNameTruncation);
    runner.runTest("process_control: prctl invalid option", process_control_tests.testPrctlInvalidOption);
    runner.runTest("process_control: prctl set name empty", process_control_tests.testPrctlSetNameEmpty);
    runner.runTest("process_control: sched_getaffinity basic", process_control_tests.testSchedGetaffinityBasic);
    runner.runTest("process_control: sched_setaffinity basic", process_control_tests.testSchedSetaffinityBasic);
    runner.runTest("process_control: sched_setaffinity multi cpu", process_control_tests.testSchedSetaffinityMultiCpu);
    runner.runTest("process_control: sched_setaffinity no cpu0", process_control_tests.testSchedSetaffinityNoCpu0);
    runner.runTest("process_control: sched_getaffinity size too small", process_control_tests.testSchedGetaffinitySizeTooSmall);

    // Syscall tests - SysV IPC
    runner.runTest("sysv_ipc: shmget creates segment", sysv_ipc_tests.testShmgetCreatesSegment);
    runner.runTest("sysv_ipc: shmget excl fails", sysv_ipc_tests.testShmgetExclFails);
    runner.runTest("sysv_ipc: shmat write read", sysv_ipc_tests.testShmatWriteRead);
    runner.runTest("sysv_ipc: shmctl stat", sysv_ipc_tests.testShmctlStat);
    runner.runTest("sysv_ipc: semget creates set", sysv_ipc_tests.testSemgetCreateSet);
    runner.runTest("sysv_ipc: semctl set get val", sysv_ipc_tests.testSemctlSetGetVal);
    runner.runTest("sysv_ipc: semop increment", sysv_ipc_tests.testSemopIncrement);
    runner.runTest("sysv_ipc: semop nowait eagain", sysv_ipc_tests.testSemopNowaitEagain);
    runner.runTest("sysv_ipc: msgget creates queue", sysv_ipc_tests.testMsggetCreateQueue);
    runner.runTest("sysv_ipc: msgsnd recv basic", sysv_ipc_tests.testMsgsndRecvBasic);
    runner.runTest("sysv_ipc: msgrcv type filter", sysv_ipc_tests.testMsgrcvTypeFilter);
    runner.runTest("sysv_ipc: msgctl stat", sysv_ipc_tests.testMsgctlStat);

    // Stress tests
    runner.runTest("stress: write 10MB file", stress_tests.testWrite10MbFile);
    runner.runTest("stress: create 100 files", stress_tests.testCreate100Files);
    runner.runTest("stress: fragmented writes", stress_tests.testFragmentedWrites);
    runner.runTest("stress: max open FDs", stress_tests.testMaxOpenFds);
    runner.runTest("stress: large directory listing", stress_tests.testLargeDirectoryListing);
    runner.runTest("stress: rapid process ops", stress_tests.testRapidProcessOps);

    // Basic sanity test
    runner.runTest("dummy: always passes", testDummy);

    // SFS-dependent tests (run last, may timeout due to cumulative SFS deadlock)
    runner.runTest("vectored_io: writev then readv roundtrip", vectored_io_tests.testWritevReadv);
    runner.runTest("vectored_io: pwritev at offset", vectored_io_tests.testPwritevBasic);
    runner.runTest("vectored_io: pwritev2 flags zero", vectored_io_tests.testPwritev2FlagsZero);

    runner.printSummary();

    const exit_code: i32 = if (runner.failed > 0) 1 else 0;
    syscall.debug_print("TEST_EXIT: ");
    printNumber(@intCast(exit_code));
    syscall.debug_print("\n");

    // Exit cleanly to shutdown QEMU (no timeout needed)
    syscall.exit(exit_code);
}
