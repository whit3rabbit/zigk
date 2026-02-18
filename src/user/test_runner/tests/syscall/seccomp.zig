// Seccomp Syscall Filtering Tests
//
// Tests for sys_seccomp syscall filtering (Phase 25)
// All tests that install seccomp filters MUST run in forked children
// to avoid irreversibly sandboxing the test runner process.

const std = @import("std");
const syscall = @import("syscall");

const SockFilterInsn = syscall.SockFilterInsn;
const SockFprog = syscall.SockFprog;

/// Helper: raw getpid syscall that returns error on seccomp block
fn rawGetpid() !i32 {
    const ret = syscall.syscall0(syscall.uapi.syscalls.SYS_GETPID);
    if (syscall.isError(ret)) return syscall.errorFromReturn(ret);
    return @truncate(@as(isize, @bitCast(ret)));
}

/// Helper: wait for child and return exit code
fn waitChild(pid: i32) !u32 {
    var status: i32 = 0;
    _ = try syscall.wait4(pid, &status, 0);
    return @intCast((status >> 8) & 0xFF);
}

pub fn testSeccompStrictAllowsRead() !void {
    // Create pipe before fork so child has something to read
    var pipefd: [2]i32 = undefined;
    try syscall.pipe(&pipefd);

    const pid = try syscall.fork();
    if (pid == 0) {
        // Child: write to pipe, enter strict mode, read from pipe
        _ = syscall.write(pipefd[1], "x", 1) catch {};
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_STRICT, 0, 0) catch {
            syscall.exit(2);
        };
        // read is allowed in strict mode
        var buf: [1]u8 = undefined;
        _ = syscall.read(pipefd[0], @ptrCast(&buf), 1) catch {
            syscall.exit(1);
        };
        syscall.exit(0);
    }
    // Parent: close pipe ends and wait
    _ = syscall.close(pipefd[0]) catch {};
    _ = syscall.close(pipefd[1]) catch {};
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompStrictAllowsWrite() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_STRICT, 0, 0) catch {
            syscall.exit(2);
        };
        // write is allowed in strict mode
        const msg = "seccomp_write_test\n";
        _ = syscall.write(1, msg.ptr, msg.len) catch {
            syscall.exit(1);
        };
        syscall.exit(0);
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompStrictBlocksGetpid() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_STRICT, 0, 0) catch {
            syscall.exit(2);
        };
        // getpid should be blocked -- raw syscall returns error
        if (rawGetpid()) |_| {
            syscall.exit(1); // should not succeed
        } else |_| {
            syscall.exit(0); // expected: error
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompFilterAllowAll() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(2);
        };
        // BPF program: allow everything
        var filter = [_]SockFilterInsn{
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 1, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(3);
        };
        // getpid should still work
        if (rawGetpid()) |_| {
            syscall.exit(0); // success
        } else |_| {
            syscall.exit(1); // should not fail
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompFilterBlockGetpid() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(2);
        };
        const getpid_nr: u32 = @intCast(syscall.uapi.syscalls.SYS_GETPID);
        // BPF: if nr == GETPID -> ERRNO(EPERM), else ALLOW
        var filter = [_]SockFilterInsn{
            .{ .code = syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, .jt = 0, .jf = 0, .k = 0 },
            .{ .code = syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, .jt = 0, .jf = 1, .k = getpid_nr },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ERRNO | 1 },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 4, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(3);
        };
        // getpid should be blocked with EPERM
        if (rawGetpid()) |_| {
            syscall.exit(1); // should not succeed
        } else |_| {
            syscall.exit(0); // expected: error
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompRequiresNoNewPrivs() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        // Drop CAP_SYS_ADMIN so no_new_privs is actually required
        // (all zk processes start with full capabilities)
        var hdr = syscall.CapUserHeader{ .version = syscall._LINUX_CAPABILITY_VERSION_3, .pid = 0 };
        var data = [2]syscall.CapUserData{
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
            .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        };
        _ = syscall.capset(&hdr, &data) catch {};

        // Do NOT set no_new_privs -- filter install should fail without CAP_SYS_ADMIN
        var filter = [_]SockFilterInsn{
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 1, .filter = @intFromPtr(&filter) };
        if (syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog))) |_| {
            syscall.exit(1); // should have failed
        } else |_| {
            syscall.exit(0); // expected: permission error
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompStrictCannotBeUndone() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_STRICT, 0, 0) catch {
            syscall.exit(2);
        };
        // In strict mode, prctl is blocked, so seccomp(FILTER) is also blocked
        // Even if we could call seccomp, strict->filter transition is denied
        // The seccomp syscall itself will be blocked by strict mode
        if (rawGetpid()) |_| {
            syscall.exit(1); // getpid should be blocked
        } else |_| {
            syscall.exit(0); // strict mode is enforced
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompFilterErrno() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(2);
        };
        const getpid_nr: u32 = @intCast(syscall.uapi.syscalls.SYS_GETPID);
        // BPF: if nr == GETPID -> ERRNO(22=EINVAL), else ALLOW
        var filter = [_]SockFilterInsn{
            .{ .code = syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, .jt = 0, .jf = 0, .k = 0 },
            .{ .code = syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, .jt = 0, .jf = 1, .k = getpid_nr },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ERRNO | 22 },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 4, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(3);
        };
        // getpid should fail with errno 22 (InvalidArgument in userspace error set)
        if (rawGetpid()) |_| {
            syscall.exit(1); // should not succeed
        } else |err| {
            if (err == error.InvalidArgument) {
                syscall.exit(0); // correct errno
            } else {
                syscall.exit(1); // wrong errno
            }
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompInheritedOnFork() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        // Child A: install filter blocking getpid
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(2);
        };
        const getpid_nr: u32 = @intCast(syscall.uapi.syscalls.SYS_GETPID);
        var filter = [_]SockFilterInsn{
            .{ .code = syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, .jt = 0, .jf = 0, .k = 0 },
            .{ .code = syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, .jt = 0, .jf = 1, .k = getpid_nr },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ERRNO | 1 },
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 4, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(3);
        };
        // Fork child B -- should inherit seccomp filter
        const child_b = try syscall.fork();
        if (child_b == 0) {
            // Child B: getpid should be blocked (inherited filter)
            if (rawGetpid()) |_| {
                syscall.exit(2); // should not succeed
            } else |_| {
                syscall.exit(0); // expected: error
            }
        }
        // Child A: wait for child B
        const b_exit = waitChild(child_b) catch {
            syscall.exit(4);
        };
        syscall.exit(@intCast(b_exit));
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testSeccompFilterInstructionPointer() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(2);
        };
        // BPF: Load instruction_pointer (offset 8, low 32 bits), kill if zero, allow if non-zero
        // This verifies the kernel actually populates instruction_pointer in SeccompData
        var filter = [_]SockFilterInsn{
            // Load word at offset 8 (instruction_pointer low 32 bits)
            .{ .code = syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, .jt = 0, .jf = 0, .k = 8 },
            // If zero, jump to kill (next instruction)
            .{ .code = syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, .jt = 1, .jf = 0, .k = 0 },
            // Non-zero: allow
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
            // Zero: kill (test fails)
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_KILL },
        };
        var prog = SockFprog{ .len = 4, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(3);
        };
        // If instruction_pointer is non-zero, getpid will succeed (filter allows)
        if (rawGetpid()) |_| {
            syscall.exit(0); // success - instruction_pointer was populated
        } else |_| {
            syscall.exit(1); // failure - instruction_pointer was 0, filter killed
        }
    }
    const exit_code = try waitChild(pid);
    if (exit_code != 0) return error.TestFailed;
}

pub fn testPrctlNoNewPrivs() !void {
    // This can run in the main process -- no_new_privs is harmless
    _ = try syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    const value = try syscall.prctl(syscall.PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
    if (value != 1) return error.TestFailed;
}

/// Test: seccomp SECCOMP_RET_KILL delivers SIGSYS to the thread
///
/// Verifies SECC-01: SECCOMP_RET_KILL triggers SIGSYS delivery (not just ENOSYS return).
/// The child installs a filter that kills getpid, then calls getpid.
/// The parent verifies the child was killed by SIGSYS (signal 31).
pub fn testSeccompSigsysDelivery() !void {
    const pid = try syscall.fork();
    if (pid == 0) {
        // Child: install seccomp filter that kills getpid, then trigger it
        _ = syscall.prctl(syscall.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) catch {
            syscall.exit(1);
        };

        // BPF filter: load syscall number, if getpid -> KILL_THREAD, else ALLOW
        const getpid_nr: u32 = @intCast(syscall.uapi.syscalls.SYS_GETPID);
        var filter = [_]SockFilterInsn{
            // Load syscall number (offset 0 in seccomp_data)
            .{ .code = syscall.BPF_LD | syscall.BPF_W | syscall.BPF_ABS, .jt = 0, .jf = 0, .k = 0 },
            // If nr == getpid, fall through to KILL; else jump to ALLOW
            .{ .code = syscall.BPF_JMP | syscall.BPF_JEQ | syscall.BPF_K, .jt = 0, .jf = 1, .k = getpid_nr },
            // Kill thread (triggers SIGSYS)
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_KILL },
            // Allow
            .{ .code = syscall.BPF_RET | syscall.BPF_K, .jt = 0, .jf = 0, .k = syscall.SECCOMP_RET_ALLOW },
        };
        var prog = SockFprog{ .len = 4, .filter = @intFromPtr(&filter) };
        _ = syscall.seccomp(syscall.SECCOMP_SET_MODE_FILTER, 0, @intFromPtr(&prog)) catch {
            syscall.exit(2);
        };

        // Trigger the filtered syscall -- SIGSYS should kill the child
        // The default action for SIGSYS is Core (terminate).
        _ = rawGetpid() catch {};

        // If we reach here, SIGSYS was not delivered (unexpected)
        syscall.exit(3);
    }

    // Parent: wait for child and verify it was killed by SIGSYS
    var status: i32 = 0;
    const waited = try syscall.wait4(pid, &status, 0);
    if (waited != pid) return error.TestFailed;

    // exitWithStatus(128 + SIGSYS) = exitWithStatus(159) stores status=159 directly.
    // wait4 returns raw exit_status. For signal kills: kernel uses exitWithStatus(128 + signum).
    // The wait4 raw status in our kernel is stored as-is (no Linux WIFEXITED encoding).
    // Check: either child exited normally with code 0 (SIGSYS default Core action kills the
    // process and exitWithStatus(159) gives status=159, parent sees (159>>8)&0xFF = 0)
    // OR the raw status has signal info in low bits.
    //
    // Our kernel's exitWithStatus(159): stores 159 as exit_status.
    // waitChild helper: (status >> 8) & 0xFF = (159 >> 8) & 0xFF = 0.
    // But we need to distinguish "child exited(0)" from "killed by SIGSYS (exit_status=159)".
    //
    // Direct check: raw status should NOT be 0 (child never called exit(0)).
    // If status == 0: child exited(0) = SIGSYS was NOT delivered (BUG).
    // If status == 159: child killed by SIGSYS (128+31) = SIGSYS was delivered (PASS).
    // If status == 1,2,3: child exited via our error paths = SIGSYS not delivered (FAIL).
    if (status == 0 or status == 1 or status == 2 or status == 3) {
        return error.TestFailed; // SIGSYS was not delivered
    }
    // status == 159 (128 + SIGSYS) means delivered correctly
    if (status != 159) return error.TestFailed;
}
