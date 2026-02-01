// Multi-Process Test Infrastructure
//
// Provides helper functions for testing multi-process syscalls (fork, wait4, execve).
// These helpers make it easier to write tests that involve process creation and coordination.

const syscall = @import("syscall");

/// Result of a child process execution
pub const ChildResult = struct {
    pid: i32,
    exit_status: i32,
};

/// Helper context for multi-process tests
pub const MultiProcessTest = struct {
    parent_pid: i32,

    pub fn init() MultiProcessTest {
        return .{
            .parent_pid = syscall.getpid(),
        };
    }

    /// Fork and run a function in the child process
    /// The child function should return an error to indicate failure, which will be converted to exit status 1
    /// On success, the child exits with status 0
    /// The parent waits for the child and returns the child's PID and exit status
    pub fn forkAndWait(self: *const MultiProcessTest, child_fn: *const fn () anyerror!void) !ChildResult {
        _ = self;

        const pid = try syscall.fork();

        if (pid == 0) {
            // Child process
            child_fn() catch {
                syscall.exit(1);
            };
            syscall.exit(0);
        } else {
            // Parent process
            var status: i32 = 0;
            const wait_pid = try syscall.wait4(pid, &status, 0);

            if (wait_pid != pid) {
                return error.WaitFailed;
            }

            return ChildResult{
                .pid = pid,
                .exit_status = status,
            };
        }
    }

    /// Fork and run a function in the child, expecting it to succeed (exit status 0)
    /// Returns error if child exits with non-zero status
    pub fn forkAndExpectSuccess(self: *const MultiProcessTest, child_fn: *const fn () anyerror!void) !i32 {
        const result = try self.forkAndWait(child_fn);
        if (result.exit_status != 0) {
            return error.ChildFailed;
        }
        return result.pid;
    }

    /// Fork and verify the child can access the parent PID via getppid()
    pub fn verifyParentPid(self: *const MultiProcessTest) !void {
        const parent_pid = self.parent_pid;

        const pid = try syscall.fork();
        if (pid == 0) {
            // Child: verify getppid returns parent
            const ppid = syscall.getppid();
            if (ppid != parent_pid) {
                syscall.exit(1);
            }
            syscall.exit(0);
        } else {
            // Parent: wait for child
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
};

/// Test that wait4 with WNOHANG doesn't block when no child has exited
pub fn testWait4Nohang() !void {
    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: sleep briefly then exit
        syscall.sleep_ms(100) catch {};
        syscall.exit(0);
    } else {
        // Parent: immediately try wait4 with WNOHANG
        // Should return 0 (no child ready) rather than blocking
        var status: i32 = 0;
        const result = syscall.wait4(pid, &status, syscall.WNOHANG) catch |err| {
            // Clean up child before returning error
            _ = syscall.wait4(pid, null, 0) catch {};
            return err;
        };

        if (result != 0) {
            // wait4 should have returned 0 (no child ready)
            // Clean up and fail
            _ = syscall.wait4(pid, null, 0) catch {};
            return error.TestFailed;
        }

        // Now wait for child to actually exit
        const wait_pid = try syscall.wait4(pid, &status, 0);
        if (wait_pid != pid) {
            return error.WaitFailed;
        }
    }
}

/// Verify fork creates independent memory spaces
pub fn testForkIndependentMemory() !void {
    var shared_value: i32 = 42;

    const pid = try syscall.fork();

    if (pid == 0) {
        // Child: modify the shared value
        shared_value = 100;

        // Verify child sees the modified value
        if (shared_value != 100) {
            syscall.exit(1);
        }
        syscall.exit(0);
    } else {
        // Parent: wait for child, then verify our value is unchanged
        var status: i32 = 0;
        const wait_pid = try syscall.wait4(pid, &status, 0);

        if (wait_pid != pid) {
            return error.WaitFailed;
        }
        if (status != 0) {
            return error.ChildFailed;
        }

        // Parent should still see original value (copy-on-write)
        if (shared_value != 42) {
            return error.MemoryNotIndependent;
        }
    }
}
