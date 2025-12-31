// Signal Syscall Handlers
//
// Implements signal-related syscalls:
// - sys_rt_sigprocmask: Examine and change blocked signals
// - sys_rt_sigaction: Examine and change signal actions
// - sys_rt_sigreturn: Return from signal handler
// - sys_set_tid_address: Set pointer to thread ID (TLS support)

const builtin = @import("builtin");
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

/// sys_sigaltstack (131) - Set/get signal stack context
///
/// Args:
///   ss_ptr: Pointer to new stack_t (or NULL to query only)
///   old_ss_ptr: Pointer to store previous stack_t (or NULL)
///
/// Returns: 0 on success, negative errno on error
pub fn sys_sigaltstack(ss_ptr: usize, old_ss_ptr: usize) SyscallError!usize {
    const current_thread = sched.getCurrentThread() orelse return error.ESRCH;
    const signal = uapi.signal;

    // Check if we're currently executing on the alternate stack
    // If so, we cannot change it
    const current_sp: u64 = switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mov %%rsp, %[ret]" : [ret] "=r" (-> u64)),
        .aarch64 => asm volatile ("mov %[ret], sp" : [ret] "=r" (-> u64)),
        else => @compileError("Unsupported architecture"),
    };
    const on_altstack = isOnAlternateStack(current_thread, current_sp);

    // Return old stack info if requested
    if (old_ss_ptr != 0) {
        var old_ss = current_thread.alternate_stack;
        // Set SS_ONSTACK flag if currently on alternate stack
        if (on_altstack) {
            old_ss.flags |= signal.SS_ONSTACK;
        }
        UserPtr.from(old_ss_ptr).writeValue(old_ss) catch {
            return error.EFAULT;
        };
    }

    // Set new stack if provided
    if (ss_ptr != 0) {
        // Cannot change stack while on it
        if (on_altstack) {
            return error.EPERM;
        }

        const new_ss = UserPtr.from(ss_ptr).readValue(signal.StackT) catch {
            return error.EFAULT;
        };

        // Validate the new stack
        if ((new_ss.flags & signal.SS_DISABLE) == 0) {
            // Enabling alternate stack - validate size
            // Linux requires at least MINSIGSTKSZ (2048 bytes typically)
            const MINSIGSTKSZ: usize = 2048;
            if (new_ss.size < MINSIGSTKSZ) {
                return error.ENOMEM;
            }
            // Validate stack pointer is a valid user address
            if (!base.isValidUserAccess(new_ss.sp, new_ss.size, base.AccessMode.Write)) {
                return error.EFAULT;
            }
        }

        // Store new alternate stack configuration
        current_thread.alternate_stack = new_ss;
    }

    return 0;
}

/// Check if the given stack pointer is within the alternate signal stack
fn isOnAlternateStack(thread: *sched.Thread, rsp: u64) bool {
    const alt = thread.alternate_stack;
    // If alternate stack is disabled, we're not on it
    if ((alt.flags & uapi.signal.SS_DISABLE) != 0) {
        return false;
    }
    // Check if rsp is within [sp, sp + size)
    return rsp >= alt.sp and rsp < alt.sp + alt.size;
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
    if (!base.isValidUserAccess(mc.rip, 1, base.AccessMode.Execute)) {
        console.err("sys_rt_sigreturn: Invalid RIP {x}", .{mc.rip});
        sched.exitWithStatus(128 + 11); // SIGSEGV
        unreachable;
    }

    frame.setReturnRip(mc.rip);
    frame.setUserRsp(mc.rsp); // Restore stack pointer

    // SECURITY: Sanitize RFLAGS before restoration.
    // User-controlled RFLAGS could contain dangerous bits that must be cleared:
    // - IOPL (bits 12-13): If set to 3, allows user to execute IN/OUT instructions
    //   directly, bypassing kernel I/O port protection. This would allow arbitrary
    //   hardware access (disk, network, display).
    // - VIF/VIP (bits 19-20): Virtual interrupt flags, should be kernel-controlled.
    // - VM (bit 17): Virtual-8086 mode, must not be set.
    // - RF (bit 16): Resume flag, kernel-controlled.
    // - NT (bit 14): Nested task flag, kernel-controlled.
    //
    // We allow: CF, PF, AF, ZF, SF, TF, DF, OF (arithmetic/control flags).
    // We force: IF=1 (interrupts enabled), reserved bit 1 set.
    const SAFE_RFLAGS_MASK: u64 = 0x0000_0000_0000_0CD5; // CF,PF,AF,ZF,SF,DF,OF
    const REQUIRED_RFLAGS: u64 = 0x0000_0000_0000_0202; // IF=1, reserved bit 1
    frame.r11 = (mc.rflags & SAFE_RFLAGS_MASK) | REQUIRED_RFLAGS;

    // Restore FS/GS bases
    // GS is kernel-managed, but FS is TLS.
    if (sched.getCurrentThread()) |t| {
        t.fs_base = @intCast(mc.fs); // Actually we need `fs_base` from ARCH_PRCTL, not segment selector.
        // Userspace Linux `ucontext` usually doesn't have the FS_BASE directly in `fs` field (which is u16).
        // It's often implied or stored in extra padding.
        // For now, we trust the `fs_base` we have, OR we could look for it.
        // Since we don't save FS_BASE in `setupSignalFrame` (we saved 0), we shouldn't overwrite it with garbage.
        // In `setupSignalFrame`: `.fs = 0`.
        // So let's skip FS/GS base restoration for now until we properly save it.

        t.sigmask = ucontext.sigmask;

        // Restore FPU state if present (dynamic size for XSAVE/FXSAVE)
        if (mc.fpstate != 0) {
            const fpu_size = hal.fpu.getXsaveAreaSize();
            // Validate pointer with dynamic FPU state size
            if (base.isValidUserAccess(mc.fpstate, fpu_size, base.AccessMode.Read)) {
                _ = UserPtr.from(mc.fpstate).copyToKernel(t.fpu_state_buffer) catch {
                    sched.exitWithStatus(128 + 11);
                    unreachable;
                };

                // Update thread state and restore to hardware
                t.fpu_used = true;
                hal.fpu.restoreState(t.fpu_state_buffer);
            }
        }
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
    const current = sched.getCurrentThread() orelse return error.ESRCH;

    // Set the clear_child_tid address for the current thread.
    // This address will be cleared and futex-woken when the thread exits.
    current.clear_child_tid = tidptr;

    return @intCast(current.tid);
}

// =============================================================================
// Signal Sending Syscalls
// =============================================================================

/// Check if the current process has permission to send a signal to the target thread.
/// SECURITY: Implements POSIX signal permission model to prevent:
/// - Unprivileged processes from killing system processes (e.g., init/PID 1)
/// - Cross-user signal injection attacks
/// - Privilege escalation via signal handler exploitation
///
/// Permission rules (simplified POSIX model):
/// - Process can always signal itself
/// - PID 1 (init) is protected from SIGKILL/SIGSTOP by non-root processes
/// POSIX signal permission check
/// A process can send a signal to another process if:
/// 1. The sender's real or effective UID matches the target's real or saved UID
/// 2. The sender is root (UID 0)
/// 3. The sender has CAP_KILL capability (TODO: not fully implemented yet)
fn checkSignalPermission(target: *sched.Thread, signum: u8) SyscallError!void {
    const current = sched.getCurrentThread() orelse return error.ESRCH;

    // Process can always signal its own threads
    if (target.process != null and current.process != null) {
        if (target.process == current.process) {
            return; // Same process, always allowed
        }
    }

    // Get process info
    const Process = base.Process;
    const current_proc: ?*Process = if (current.process) |p| @ptrCast(@alignCast(p)) else null;
    const target_proc: ?*Process = if (target.process) |p| @ptrCast(@alignCast(p)) else null;

    // SECURITY: Protect PID 1 (init) from termination signals.
    // If init dies, the system becomes unstable. Only root can send SIGKILL/SIGSTOP to init.
    if (target_proc) |tp| {
        if (tp.pid == 1) {
            if (signum == uapi.signal.SIGKILL or signum == uapi.signal.SIGSTOP) {
                // Only root can send SIGKILL/SIGSTOP to init
                if (current_proc) |cp| {
                    if (cp.euid != 0) {
                        console.warn("Signal: Non-root process blocked from sending sig={} to init (pid=1)", .{signum});
                        return error.EPERM;
                    }
                } else {
                    return error.EPERM;
                }
            }
        }
    }

    // Permission checks for signals between different processes
    if (current_proc) |cp| {
        if (target_proc) |tp| {
            // POSIX DAC: Root (euid 0) can always send signals.
            // This is standard Unix behavior per POSIX signal permission model,
            // distinct from capability-based hardware access controls.
            // TODO: Consider adding CAP_KILL capability check as alternative to root.
            if (cp.euid == 0) {
                return; // Privileged sender, allowed
            }

            // POSIX permission model:
            // The sender's real UID or effective UID must match
            // the target's real UID or saved UID.
            // (For MVP, we check real UID and effective UID since we don't have saved UID yet)
            const sender_uid = cp.uid;
            const sender_euid = cp.euid;
            const target_uid = tp.uid;
            const target_euid = tp.euid; // Use euid as proxy for saved UID for now

            if (sender_uid == target_uid or sender_uid == target_euid or
                sender_euid == target_uid or sender_euid == target_euid)
            {
                return; // UID match, allowed
            }

            // No permission match found
            console.debug("Signal: Permission denied: sender uid={}/euid={} -> target uid={}/euid={}", .{ sender_uid, sender_euid, target_uid, target_euid });
            return error.EPERM;
        }
    }

    // If we can't determine processes, allow for kernel threads
}

/// Deliver a signal to a thread
fn deliverSignalToThread(target: *sched.Thread, signum: u8) void {
    const signal = @import("uapi").signal;

    // Special handling for SIGCONT: resume stopped threads
    if (signum == signal.SIGCONT) {
        if (target.stopped) {
            target.stopped = false;
            // Unblock if thread is blocked due to being stopped
            if (target.state == .Blocked) {
                sched.unblock(target);
            }
        }
        // SIGCONT is still delivered (pending_signals set below) so handler can run if set
    }

    // Set pending signal bit
    const sig_bit: u64 = @as(u64, 1) << @intCast(signum - 1);
    target.pending_signals |= sig_bit;

    // If thread is blocked, wake it to handle signal
    if (target.state == .Blocked) {
        sched.unblock(target);
    }
}

/// sys_kill (62) - Send signal to a process
///
/// Args:
///   pid: Target process ID (or special values)
///   sig: Signal number (0 to check permissions only)
///
/// Special pid values:
///   pid > 0: Send to process with that PID
///   pid == 0: Send to all processes in caller's process group (not impl)
///   pid == -1: Send to all processes (not impl)
///   pid < -1: Send to process group -pid (not impl)
///
/// Returns: 0 on success, negative errno on error
pub fn sys_kill(pid: usize, sig: usize) SyscallError!usize {
    const pid_i: i32 = @bitCast(@as(u32, @truncate(pid)));
    const signum: u8 = @truncate(sig);

    // Signal 0 is used to check if process exists (no signal sent)
    if (signum > 64) {
        return error.EINVAL;
    }

    // Only handle positive PIDs for now
    if (pid_i <= 0) {
        // Process groups not implemented
        return error.ESRCH;
    }

    // Find the target process's main thread
    // For MVP, we search threads by PID (treating PID as TID of main thread)
    const target = sched.findThreadByTid(@intCast(pid_i)) orelse {
        return error.ESRCH;
    };

    // Signal 0 is just a check - don't actually deliver
    if (signum == 0) {
        return 0;
    }

    // SECURITY: Check permission before delivering signal
    try checkSignalPermission(target, signum);

    // Deliver the signal
    deliverSignalToThread(target, signum);

    return 0;
}

/// sys_tkill (200) - Send signal to a specific thread
///
/// Args:
///   tid: Target thread ID
///   sig: Signal number
///
/// Returns: 0 on success, negative errno on error
pub fn sys_tkill(tid: usize, sig: usize) SyscallError!usize {
    const tid_i: i32 = @bitCast(@as(u32, @truncate(tid)));
    const signum: u8 = @truncate(sig);

    if (tid_i <= 0) {
        return error.EINVAL;
    }

    if (signum > 64) {
        return error.EINVAL;
    }

    const target = sched.findThreadByTid(@intCast(tid_i)) orelse {
        return error.ESRCH;
    };

    // Signal 0 is just a check
    if (signum == 0) {
        return 0;
    }

    // SECURITY: Check permission before delivering signal
    try checkSignalPermission(target, signum);

    deliverSignalToThread(target, signum);

    return 0;
}

/// sys_tgkill (234) - Send signal to a thread in a thread group
///
/// Args:
///   tgid: Thread group ID (process ID)
///   tid: Target thread ID
///   sig: Signal number
///
/// This is the preferred interface for sending signals to threads
/// as it prevents race conditions where TID gets reused.
///
/// Returns: 0 on success, negative errno on error
pub fn sys_tgkill(tgid: usize, tid: usize, sig: usize) SyscallError!usize {
    const tgid_i: i32 = @bitCast(@as(u32, @truncate(tgid)));
    const tid_i: i32 = @bitCast(@as(u32, @truncate(tid)));
    const signum: u8 = @truncate(sig);

    if (tgid_i <= 0 or tid_i <= 0) {
        return error.EINVAL;
    }

    if (signum > 64) {
        return error.EINVAL;
    }

    const target = sched.findThreadByTid(@intCast(tid_i)) orelse {
        return error.ESRCH;
    };

    // Verify thread belongs to the specified thread group
    // MVP: We check if the thread's process PID matches tgid
    if (target.process) |proc| {
        const process: *base.Process = @ptrCast(@alignCast(proc));
        if (process.pid != @as(u32, @intCast(tgid_i))) {
            return error.ESRCH;
        }
    }

    // Signal 0 is just a check
    if (signum == 0) {
        return 0;
    }

    // SECURITY: Check permission before delivering signal
    try checkSignalPermission(target, signum);

    deliverSignalToThread(target, signum);

    return 0;
}
