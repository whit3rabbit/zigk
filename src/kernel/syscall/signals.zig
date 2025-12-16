// Signal Syscall Handlers
//
// Implements signal-related syscalls:
// - sys_rt_sigprocmask: Examine and change blocked signals
// - sys_rt_sigaction: Examine and change signal actions
// - sys_rt_sigreturn: Return from signal handler
// - sys_set_tid_address: Set pointer to thread ID (TLS support)

const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

// =============================================================================
// Signal and Thread Control
// =============================================================================

/// sys_rt_sigprocmask (14) - Examine and change blocked signals
///
/// Implements signal masking (SIG_BLOCK, SIG_UNBLOCK, SIG_SETMASK).
/// Returns 0 on success, negative errno on error.
pub fn sys_rt_sigprocmask(how: usize, set_ptr: usize, oldset_ptr: usize, sigsetsize: usize) SyscallError!usize {
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Store old set if requested
    if (oldset_ptr != 0) {
        UserPtr.from(oldset_ptr).writeValue(current_thread.sigmask) catch {
            return error.EFAULT;
        };
    }

    // If set_ptr is NULL, we are just querying
    if (set_ptr == 0) {
        return 0;
    }

    const new_set = UserPtr.from(set_ptr).readValue(uapi.signal.SigSet) catch {
        return error.EFAULT;
    };

    // Apply change based on 'how'
    switch (how) {
        uapi.signal.SIG_BLOCK => {
            current_thread.sigmask |= new_set;
        },
        uapi.signal.SIG_UNBLOCK => {
            current_thread.sigmask &= ~new_set;
        },
        uapi.signal.SIG_SETMASK => {
            current_thread.sigmask = new_set;
        },
        else => {
            return error.EINVAL;
        },
    }

    // SIGKILL and SIGSTOP cannot be blocked
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGKILL);
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGSTOP);

    return 0;
}

/// sys_rt_sigaction (13) - Examine and change a signal action
///
/// Args:
///   signum: Signal number
///   act_ptr: Pointer to new SigAction struct (or NULL)
///   oldact_ptr: Pointer to store old SigAction struct (or NULL)
///   sigsetsize: Size of sigset_t (should be 8 bytes)
///
/// Returns: 0 on success, negative errno on error.
pub fn sys_rt_sigaction(signum: usize, act_ptr: usize, oldact_ptr: usize, sigsetsize: usize) SyscallError!usize {
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    if (signum == 0 or signum > 64) {
        return error.EINVAL;
    }

    // SIGKILL and SIGSTOP cannot be caught, blocked, or ignored
    if (signum == uapi.signal.SIGKILL or signum == uapi.signal.SIGSTOP) {
        return error.EINVAL;
    }

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Store old action if requested
    if (oldact_ptr != 0) {
        const old_action = current_thread.signal_actions[signum - 1];
        UserPtr.from(oldact_ptr).writeValue(old_action) catch {
            return error.EFAULT;
        };
    }

    // If act_ptr is NULL, we are just querying
    if (act_ptr == 0) {
        return 0;
    }

    // Read new action
    const new_action = UserPtr.from(act_ptr).readValue(uapi.signal.SigAction) catch {
        return error.EFAULT;
    };

    // Update action table
    current_thread.signal_actions[signum - 1] = new_action;

    return 0;
}

/// sys_rt_sigreturn (15) - Return from signal handler and restore context
///
/// This syscall is called by the signal trampoline. It restores the user context
/// saved on the stack (ucontext_t).
///
/// MVP: Does not return (returns via iretq with restored context).
pub fn sys_rt_sigreturn(frame: *hal.syscall.SyscallFrame) SyscallError!usize {
    // Get user stack pointer
    const user_rsp = frame.getUserRsp();

    // Read ucontext from stack
    // It should be at the top of the stack (after handler popped return address)
    const ucontext = UserPtr.from(user_rsp).readValue(uapi.signal.UContext) catch {
        // If we can't read the context, we can't restore state.
        // This is a fatal error for the thread.
        console.err("sys_rt_sigreturn: Failed to read ucontext from {x}", .{user_rsp});
        sched.exitWithStatus(128 + 11); // SIGSEGV
        unreachable;
    };

    // Restore registers from mcontext
    // We update the syscall frame, which will be used to restore state on return
    const mc = ucontext.mcontext;

    frame.r15 = mc.r15;
    frame.r14 = mc.r14;
    frame.r13 = mc.r13;
    frame.r12 = mc.r12;
    frame.r11 = mc.r11;
    frame.r10 = mc.r10;
    frame.r9 = mc.r9;
    frame.r8 = mc.r8;
    frame.rdi = mc.rdi;
    frame.rsi = mc.rsi;
    frame.rbp = mc.rbp;
    frame.rbx = mc.rbx;
    frame.rdx = mc.rdx;
    frame.rcx = mc.rcx;
    frame.rax = mc.rax;

    // Restore special registers
    // Note: We don't restore CS, SS, GS, FS blindly as it might be unsafe
    // But we should restore RFLAGS and RIP

    // Validate that the restored RIP is a canonical user address.
    // If it's non-canonical or in kernel space, sysretq would fault.
    if (!base.isValidUserPtr(mc.rip, 1)) {
        console.err("sys_rt_sigreturn: Invalid RIP {x}", .{mc.rip});
        sched.exitWithStatus(128 + 11); // SIGSEGV
        unreachable;
    }

    frame.setReturnRip(mc.rip);
    frame.setUserRsp(mc.rsp); // Restore stack pointer
    frame.r11 = mc.rflags; // Sysret restores RFLAGS from R11

    // Restore signal mask
    if (sched.getCurrentThread()) |t| {
        t.sigmask = ucontext.sigmask;
    }

    // Return value is ignored since we overwrote RAX/RDI/RSI etc.
    // The syscall exit stub will restore registers from frame.
    return 0; // Dummy return
}

/// sys_set_tid_address (218) - Set pointer to thread ID
///
/// Args:
///   tidptr: Pointer to int where kernel writes TID on thread exit (and futex wake)
///
/// Returns: Thread ID
///
/// MVP: Returns current TID. musl uses this for thread cancellation/cleanup.
pub fn sys_set_tid_address(tidptr: usize) SyscallError!usize {
    _ = tidptr; // We should store this in the Thread struct if we supported it

    if (sched.getCurrentThread()) |t| {
        return @intCast(t.tid);
    }
    return 1;
}
