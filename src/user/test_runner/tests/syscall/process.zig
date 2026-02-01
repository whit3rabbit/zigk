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
// NOTE: This test requires a test binary to exec into
// For now we'll skip it until we have a simple test program
pub fn testExecReplacesProcess() !void {
    return error.SkipTest; // Need test binary infrastructure
}
