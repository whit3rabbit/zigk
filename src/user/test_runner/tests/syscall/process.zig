const syscall = @import("syscall");
const multi_process = @import("../../lib/multi_process.zig");

// Process Test 1: Basic fork creates child
pub fn testForkCreatesChild() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: just exit successfully
        syscall.exit(0);
    } else {
        // Parent: verify we got a valid child PID
        if (pid <= 0) {
            return error.InvalidPid;
        }

        // Wait for child to exit
        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) {
            return error.WaitFailed;
        }
        if (status != 0) {
            return error.ChildExitedNonZero;
        }
    }
}

// Process Test 2: Fork child and parent have independent memory
pub fn testForkIndependentMemory() !void {
    try multi_process.testForkIndependentMemory();
}

// Process Test 3: Exit with status code
pub fn testExitWithStatus() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: exit with specific status
        syscall.exit(42);
    } else {
        // Parent: verify we can read the exit status
        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) {
            return error.WaitFailed;
        }

        // Linux wait4 returns status in upper 8 bits (status << 8)
        const exit_code = (status >> 8) & 0xFF;
        if (exit_code != 42) {
            return error.WrongExitStatus;
        }
    }
}

// Process Test 4: wait4 blocks until child exits
pub fn testWait4Blocks() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: sleep briefly to ensure parent blocks
        syscall.sleep_ms(50) catch {};
        syscall.exit(0);
    } else {
        // Parent: wait4 should block until child exits
        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) {
            return error.WaitFailed;
        }
        if (status != 0) {
            return error.ChildFailed;
        }
    }
}

// Process Test 5: wait4 with WNOHANG doesn't block
pub fn testWait4Nohang() !void {
    try multi_process.testWait4Nohang();
}

// Process Test 6: getpid returns unique PID
pub fn testGetpidUnique() !void {
    const pid1 = syscall.getpid();
    const pid2 = syscall.getpid();

    // Same process should have same PID
    if (pid1 != pid2) return error.TestFailed;

    // PID should be positive
    if (pid1 <= 0) return error.TestFailed;
}

// Process Test 7: getppid returns parent PID
pub fn testGetppidReturnsParent() !void {
    var mp = multi_process.MultiProcessTest.init();
    try mp.verifyParentPid();
}

// Process Test 8: exec replaces process image
pub fn testExecReplacesProcess() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: exec into test_binary.elf
        const path = "/test_binary.elf";

        // Create null-terminated argv and envp arrays
        const arg0: [*:0]const u8 = "test_binary.elf";
        const argv = [_:null]?[*:0]const u8{arg0};
        const envp = [_:null]?[*:0]const u8{};

        // This should replace the process image
        _ = syscall.execve(path, &argv, &envp) catch |err| {
            // If exec fails, exit with error code 1
            syscall.debug_print("exec failed: ");
            syscall.debug_print(@errorName(err));
            syscall.debug_print("\n");
            syscall.exit(1);
        };

        // Should never reach here if exec succeeds
        syscall.exit(1);
    } else {
        // Parent: wait for child to complete
        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) {
            return error.WaitFailed;
        }

        // test_binary.elf exits with status 42
        const exit_code = (status >> 8) & 0xFF;
        if (exit_code != 42) {
            return error.WrongExitStatus;
        }
    }
}

// Process Test 9: alarm() sets and cancels alarms
pub fn testAlarmSetAndCancel() !void {
    // Set alarm for 5 seconds
    const remaining1 = syscall.alarm(5);

    // First alarm, should return 0
    if (remaining1 != 0) return error.TestFailed;

    // Set alarm for 3 seconds (cancels previous)
    const remaining2 = syscall.alarm(3);

    // Should return ~5 seconds remaining
    if (remaining2 < 4 or remaining2 > 5) return error.TestFailed;

    // Cancel alarm
    const remaining3 = syscall.alarm(0);

    // Should return ~3 seconds remaining
    if (remaining3 < 2 or remaining3 > 3) return error.TestFailed;

    // No alarm set, should return 0
    const remaining4 = syscall.alarm(0);
    if (remaining4 != 0) return error.TestFailed;
}

// Process Test 10: alarm() delivers SIGALRM (basic check)
// NOTE: Full signal testing requires signal handler setup
pub fn testAlarmBasic() !void {
    // Set a very short alarm (1 second)
    const remaining = syscall.alarm(1);

    // Should return 0 (no previous alarm)
    if (remaining != 0) return error.TestFailed;

    // Alarm is now set, cancel it to avoid interference with other tests
    _ = syscall.alarm(0);
}
