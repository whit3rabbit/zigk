// Signal Syscall Handlers
//
// Implements signal-related syscalls:
// - sys_rt_sigprocmask: Examine and change blocked signals
// - sys_rt_sigaction: Examine and change signal actions
// - sys_rt_sigreturn: Return from signal handler
// - sys_set_tid_address: Set pointer to thread ID (TLS support)

const std = @import("std");
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

/// sys_rt_sigpending (127) - Examine pending signals
///
/// Returns the set of signals that are pending for the calling thread and blocked
/// by the current signal mask. This is the intersection of pending_signals and sigmask.
pub fn sys_rt_sigpending(set_ptr: usize, sigsetsize: usize) SyscallError!usize {
    // Validate sigsetsize
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Compute pending signals that are blocked
    const pending = current_thread.pending_signals & current_thread.sigmask;

    // Write to userspace
    UserPtr.from(set_ptr).writeValue(pending) catch {
        return error.EFAULT;
    };

    return 0;
}

/// sys_rt_sigsuspend (130) - Wait for a signal with temporary mask
///
/// Atomically replaces the signal mask with the provided mask, blocks until
/// a signal is delivered, then restores the original mask. Always returns EINTR.
pub fn sys_rt_sigsuspend(mask_ptr: usize, sigsetsize: usize) SyscallError!usize {
    // Validate sigsetsize
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) {
        return error.EINVAL;
    }

    // Read new mask from userspace
    const new_mask = UserPtr.from(mask_ptr).readValue(uapi.signal.SigSet) catch {
        return error.EFAULT;
    };

    const current_thread = sched.getCurrentThread() orelse {
        return error.ESRCH;
    };

    // Save old mask
    const old_mask = current_thread.sigmask;

    // Set new mask (temporarily)
    current_thread.sigmask = new_mask;

    // Ensure SIGKILL and SIGSTOP cannot be blocked (same as rt_sigprocmask)
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGKILL);
    uapi.signal.sigdelset(&current_thread.sigmask, uapi.signal.SIGSTOP);

    // Suspend until a signal arrives
    // CRITICAL BUG FIX: If a signal is already pending and the new mask unblocks it,
    // we must NOT call block() because the signal was already delivered (pending bit set)
    // and deliverSignalToThread won't be called again to wake us up.
    // Instead, just skip blocking - the signal will be delivered when returning to userspace.
    const pending = @atomicLoad(u64, &current_thread.pending_signals, .acquire);
    const unblocked_pending = pending & ~new_mask;
    if (unblocked_pending == 0) {
        sched.block();
    }
    // Else: signal is pending and unblocked - skip block(), return immediately
    // (Signal handler will run when we return to userspace)

    // Save old mask for deferred restoration by checkSignalsOnSyscallExit.
    // The temp mask stays active so signal delivery can see unblocked signals.
    // This fixes the race: previously we restored the mask HERE, before
    // checkSignalsOnSyscallExit ran, so signals unblocked only by the temp
    // mask got re-blocked before delivery.
    current_thread.saved_sigmask = old_mask;
    current_thread.has_saved_sigmask = true;

    // Always return EINTR (sigsuspend always fails with this errno per POSIX)
    return error.EINTR;
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

    // SECURITY: Sanitize saved processor state before restoration.
    if (builtin.cpu.arch == .aarch64) {
        // Restore SPSR_EL1 with sanitization.
        // Allow NZCV condition flags (bits 31:28).
        // Force EL0t mode (bits 4:0 = 0) and interrupts unmasked (bits 9:6 = 0).
        const SAFE_SPSR_MASK: u64 = 0xF000_0000; // NZCV only
        frame.spsr = (mc.rflags & SAFE_SPSR_MASK);
    } else {
        // x86_64: Sanitize RFLAGS.
        // User-controlled RFLAGS could contain dangerous bits:
        // - IOPL (bits 12-13): allows direct IN/OUT if set to 3
        // - VIF/VIP (bits 19-20), VM (bit 17), RF (bit 16), NT (bit 14)
        // We allow: CF, PF, AF, ZF, SF, TF, DF, OF (arithmetic/control flags).
        // We force: IF=1 (interrupts enabled), reserved bit 1 set.
        const SAFE_RFLAGS_MASK: u64 = 0x0000_0000_0000_0CD5;
        const REQUIRED_RFLAGS: u64 = 0x0000_0000_0000_0202;
        frame.r11 = (mc.rflags & SAFE_RFLAGS_MASK) | REQUIRED_RFLAGS;
    }

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

/// Helper to iterate all processes and apply a function
fn forEachProcess(init: *base.Process, context: anytype, comptime func: fn (@TypeOf(context), *base.Process) void) void {
    func(context, init);
    var child = init.first_child;
    while (child) |c| {
        forEachProcess(c, context, func);
        child = c.next_sibling;
    }
}

/// Context for process group signal delivery
const PgroupSignalCtx = struct {
    pgid: u32,
    signum: u8,
    sender_proc: ?*base.Process,
    delivered_count: *usize,
    last_error: *?SyscallError,
};

/// Helper: deliver signal to a process if it matches the target process group
fn deliverToPgroupMember(ctx: *PgroupSignalCtx, proc: *base.Process) void {
    // Check if process is in the target process group
    if (proc.pgid != ctx.pgid) {
        return;
    }

    // Find the main thread for this process by matching the process pointer
    const target_thread = sched.findThreadByProcess(proc) orelse {
        return; // Process has no thread, skip
    };

    // Signal 0 is just a check - count it but don't deliver
    if (ctx.signum == 0) {
        ctx.delivered_count.* += 1;
        return;
    }

    // Check permission before delivering
    checkSignalPermission(target_thread, ctx.signum) catch |err| {
        ctx.last_error.* = err;
        return;
    };

    // Deliver the signal with SI_USER metadata from sender process
    const si_pgrp = uapi.signal.KernelSigInfo{
        .signo = ctx.signum,
        .code = uapi.signal.SI_USER,
        .pid = if (ctx.sender_proc) |sp| sp.pid else 0,
        .uid = if (ctx.sender_proc) |sp| sp.uid else 0,
        .value = 0,
    };
    deliverSignalToThreadWithInfo(target_thread, ctx.signum, si_pgrp);
    ctx.delivered_count.* += 1;
}

/// Deliver signal to all processes in a process group
/// Returns the number of processes signaled, or error if permission denied
fn deliverSignalToProcessGroup(pgid: u32, signum: u8, sender_proc: ?*base.Process) SyscallError!usize {
    const process_mod = @import("process");
    const init = process_mod.getInitProcess() catch {
        return error.ESRCH;
    };

    var delivered_count: usize = 0;
    var last_error: ?SyscallError = null;
    var ctx = PgroupSignalCtx{
        .pgid = pgid,
        .signum = signum,
        .sender_proc = sender_proc,
        .delivered_count = &delivered_count,
        .last_error = &last_error,
    };

    // Iterate all processes and deliver to matching pgid
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();
    forEachProcess(init, &ctx, deliverToPgroupMember);

    // If no processes were signaled and we had permission errors, return the error
    if (delivered_count == 0) {
        if (last_error) |err| {
            return err;
        }
        return error.ESRCH; // No matching processes found
    }

    return delivered_count;
}

/// Context for broadcast signal delivery
const BroadcastSignalCtx = struct {
    signum: u8,
    sender_proc: *base.Process,
    delivered_count: *usize,
};

/// Helper: deliver signal to a process in broadcast mode (kill(-1, sig))
fn deliverToBroadcastTarget(ctx: *BroadcastSignalCtx, proc: *base.Process) void {
    // Don't signal init (pid 1)
    if (proc.pid == 1) {
        return;
    }

    // Don't signal the sender
    if (proc == ctx.sender_proc) {
        return;
    }

    // Find the main thread for this process by matching the process pointer
    const target_thread = sched.findThreadByProcess(proc) orelse {
        return; // Process has no thread, skip
    };

    // Signal 0 is just a check - count it but don't deliver
    if (ctx.signum == 0) {
        ctx.delivered_count.* += 1;
        return;
    }

    // Check permission (silently skip if denied)
    checkSignalPermission(target_thread, ctx.signum) catch {
        return; // Permission denied, skip this process
    };

    // Deliver the signal with SI_USER metadata from sender process
    const si_bcast = uapi.signal.KernelSigInfo{
        .signo = ctx.signum,
        .code = uapi.signal.SI_USER,
        .pid = ctx.sender_proc.pid,
        .uid = ctx.sender_proc.uid,
        .value = 0,
    };
    deliverSignalToThreadWithInfo(target_thread, ctx.signum, si_bcast);
    ctx.delivered_count.* += 1;
}

/// Deliver signal to all processes (broadcast mode: kill(-1, sig))
/// Skips init (pid 1) and the sender process
/// Returns the number of processes signaled
fn deliverSignalBroadcast(signum: u8, sender_proc: *base.Process) SyscallError!usize {
    const process_mod = @import("process");
    const init = process_mod.getInitProcess() catch {
        return error.ESRCH;
    };

    var delivered_count: usize = 0;
    var ctx = BroadcastSignalCtx{
        .signum = signum,
        .sender_proc = sender_proc,
        .delivered_count = &delivered_count,
    };

    // Iterate all processes and deliver to valid targets
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();
    forEachProcess(init, &ctx, deliverToBroadcastTarget);

    // Broadcast always succeeds (even if no processes signaled)
    return delivered_count;
}

/// Deliver a signal to a thread (best-effort, no metadata).
/// Constructs a default KernelSigInfo with SI_KERNEL code.
pub fn deliverSignalToThread(target: *sched.Thread, signum: u8) void {
    deliverSignalToThreadWithInfo(target, signum, null);
}

/// Deliver a signal with optional siginfo metadata.
/// If info is null, a default KernelSigInfo with SI_KERNEL code is created.
///
/// INVARIANT: Enqueue happens BEFORE the atomic bitmask set so consumers always
/// find the metadata entry ready when they see the pending bit.
///
/// Standard signals (1-31) coalesce: if already pending, do NOT double-enqueue.
/// RT signals (32-64) always enqueue even if already pending.
/// Queue overflow for general delivery (kill/tkill): best-effort silent drop.
pub fn deliverSignalToThreadWithInfo(target: *sched.Thread, signum: u8, info: ?uapi.signal.KernelSigInfo) void {
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

    // Special handling for stopping signals (SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU)
    // These signals stop the thread if using default action
    if (signum == signal.SIGSTOP or
        signum == signal.SIGTSTP or
        signum == signal.SIGTTIN or
        signum == signal.SIGTTOU)
    {
        // SIGSTOP cannot be caught or ignored (always stops)
        // Others only stop if using default action
        const action = target.signal_actions[signum - 1];
        const uses_default = (action.handler == signal.SIG_DFL);
        const is_ignored = (action.handler == signal.SIG_IGN);

        if (signum == signal.SIGSTOP or (uses_default and !is_ignored)) {
            // Stop the thread
            target.stopped = true;

            // If thread is currently running or ready, block it
            if (target.state == .Running or target.state == .Ready) {
                // Mark as blocked - scheduler will skip it
                target.state = .Blocked;
            }

            // Don't set pending signal for default stop action
            // (signal is consumed by stopping the thread)
            if (uses_default or signum == signal.SIGSTOP) {
                return; // Don't queue signal
            }
        }
    }

    // Enqueue siginfo metadata before setting the pending bitmask bit.
    // This ensures that when a consumer sees the pending bit, the metadata entry is ready.
    const sig_bit: u64 = @as(u64, 1) << @intCast(signum - 1);
    const is_rt_signal = signum >= 32;
    const already_pending = (@atomicLoad(u64, &target.pending_signals, .acquire) & sig_bit) != 0;

    if (is_rt_signal or !already_pending) {
        // RT signals always queue; standard signals only queue if not already pending
        const si = info orelse uapi.signal.KernelSigInfo{
            .signo = signum,
            .code = uapi.signal.SI_KERNEL,
            .pid = 0,
            .uid = 0,
            .value = 0,
        };
        // Best-effort enqueue: if queue is full, signal still delivered via bitmask
        // but metadata is lost (graceful degradation, not failure).
        _ = target.siginfo_queue.enqueue(si);
    }

    // Set pending signal bit (atomic for SMP safety - signalfd and signal
    // handlers clear bits concurrently without holding a shared lock)
    _ = @atomicRmw(u64, &target.pending_signals, .Or, sig_bit, .release);

    // If thread is blocked (and not stopped), wake it to handle signal
    if (target.state == .Blocked and !target.stopped) {
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
///
/// ABI Note: The truncation of pid/sig from usize to u32/u8 is intentional and
/// correct per Linux x86_64 ABI. pid_t is a 32-bit signed type, and signal
/// numbers fit in 8 bits. The syscall receives full 64-bit register values
/// but only the low bits are meaningful. This matches Linux kernel behavior.
pub fn sys_kill(pid: usize, sig: usize) SyscallError!usize {
    const pid_i: i32 = @bitCast(@as(u32, @truncate(pid)));
    const signum: u8 = @truncate(sig);

    // Signal 0 is used to check if process exists (no signal sent)
    if (signum > 64) {
        return error.EINVAL;
    }

    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const current_proc: *base.Process = if (current.process) |p|
        @ptrCast(@alignCast(p))
    else
        return error.ESRCH;

    // Handle process group and broadcast modes
    if (pid_i <= 0) {
        if (pid_i == 0) {
            // pid == 0: Send to all processes in current process group
            _ = try deliverSignalToProcessGroup(current_proc.pgid, signum, current_proc);
            return 0;
        } else if (pid_i == -1) {
            // pid == -1: Send to all processes (broadcast)
            _ = try deliverSignalBroadcast(signum, current_proc);
            return 0;
        } else {
            // pid < -1: Send to all processes in process group |pid|
            const target_pgid: u32 = @intCast(-pid_i);
            _ = try deliverSignalToProcessGroup(target_pgid, signum, current_proc);
            return 0;
        }
    }

    // pid > 0: Send to specific process
    // Find the target process's main thread by process PID
    const target = sched.findThreadByPid(@intCast(pid_i)) orelse {
        return error.ESRCH;
    };

    // Signal 0 is just a check - don't actually deliver
    if (signum == 0) {
        return 0;
    }

    // SECURITY: Check permission before delivering signal
    try checkSignalPermission(target, signum);

    // Deliver the signal with SI_USER metadata (sender PID and UID)
    const si = uapi.signal.KernelSigInfo{
        .signo = signum,
        .code = uapi.signal.SI_USER,
        .pid = current_proc.pid,
        .uid = current_proc.uid,
        .value = 0,
    };
    deliverSignalToThreadWithInfo(target, signum, si);

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

    // Deliver with SI_TKILL metadata (sender PID and UID via current thread's process)
    const sender = sched.getCurrentThread();
    const sender_proc: ?*base.Process = if (sender) |s| (if (s.process) |p| @ptrCast(@alignCast(p)) else null) else null;
    const si_tkill = uapi.signal.KernelSigInfo{
        .signo = signum,
        .code = uapi.signal.SI_TKILL,
        .pid = if (sender_proc) |sp| sp.pid else 0,
        .uid = if (sender_proc) |sp| sp.uid else 0,
        .value = 0,
    };
    deliverSignalToThreadWithInfo(target, signum, si_tkill);

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

    // Deliver with SI_TKILL metadata
    const current_tgkill = sched.getCurrentThread();
    const sender_proc_tgkill: ?*base.Process = if (current_tgkill) |s| (if (s.process) |p| @ptrCast(@alignCast(p)) else null) else null;
    const si_tgkill = uapi.signal.KernelSigInfo{
        .signo = signum,
        .code = uapi.signal.SI_TKILL,
        .pid = if (sender_proc_tgkill) |sp| sp.pid else 0,
        .uid = if (sender_proc_tgkill) |sp| sp.uid else 0,
        .value = 0,
    };
    deliverSignalToThreadWithInfo(target, signum, si_tgkill);

    return 0;
}

// =============================================================================
// Phase 20: Signal Handling Extensions
// =============================================================================

/// Timespec structure for rt_sigtimedwait timeout (matches scheduling.zig)
const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

/// sys_rt_sigtimedwait (128) - Synchronously wait for a queued signal
///
/// Dequeues a signal from the set of pending signals matching `set`.
/// If no signal is pending, blocks until one arrives or timeout expires.
///
/// Per user decision: block using yield with polling, timeout returns EAGAIN.
/// Per user decision: has priority over signalfd (synchronous consumption wins).
/// Per user decision: use atomic CAS loop on pending_signals to check-and-clear.
///
/// MVP: Uses bitmask-only tracking (no per-signal queue for siginfo data).
/// siginfo_t is populated with minimal data (si_signo only, sender info = 0).
///
/// Args:
///   set_ptr: Pointer to sigset_t describing which signals to wait for
///   info_ptr: Pointer to siginfo_t to fill with signal info (can be 0)
///   timeout_ptr: Pointer to timespec timeout (NULL = wait forever)
///   sigsetsize: Size of sigset_t (must be 8)
///
/// Returns: Signal number on success, negative errno on error
pub fn sys_rt_sigtimedwait(set_ptr: usize, info_ptr: usize, timeout_ptr: usize, sigsetsize: usize) SyscallError!usize {
    if (sigsetsize != @sizeOf(uapi.signal.SigSet)) return error.EINVAL;
    if (set_ptr == 0) return error.EINVAL;

    const wait_set = UserPtr.from(set_ptr).readValue(uapi.signal.SigSet) catch return error.EFAULT;
    if (wait_set == 0) return error.EINVAL;

    const current = sched.getCurrentThread() orelse return error.ESRCH;

    // Parse timeout
    var timeout_ns: ?u64 = null;
    if (timeout_ptr != 0) {
        const ts = UserPtr.from(timeout_ptr).readValue(Timespec) catch return error.EFAULT;
        if (ts.tv_sec < 0 or ts.tv_nsec < 0 or ts.tv_nsec >= 1_000_000_000) return error.EINVAL;
        const sec_ns: u64 = @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000;
        const nsec_u: u64 = @as(u64, @intCast(ts.tv_nsec));
        timeout_ns = std.math.add(u64, sec_ns, nsec_u) catch return error.EINVAL;
    }

    // Try to dequeue a matching signal immediately (atomic CAS loop)
    if (tryDequeueSignal(current, wait_set)) |si| {
        // Fill siginfo if requested
        if (info_ptr != 0) {
            writeSigInfo(info_ptr, &si) catch return error.EFAULT;
        }
        return si.signo;
    }

    // No signal pending -- check timeout
    if (timeout_ns) |ns| {
        if (ns == 0) return error.EAGAIN; // Zero timeout, no signal
    }

    // Block with timeout waiting for a matching signal
    // Use tick-based sleep with polling (consistent with timerfd/signalfd WaitQueue pattern)
    const tick_ns: u64 = 10_000_000; // 10ms per tick

    if (timeout_ns) |ns| {
        const duration_ticks = std.math.divCeil(u64, ns, tick_ns) catch 1;
        var ticks_waited: u64 = 0;
        while (ticks_waited < duration_ticks) {
            sched.yield();
            ticks_waited += 1;

            // Check for matching signal after each yield
            if (tryDequeueSignal(current, wait_set)) |si| {
                if (info_ptr != 0) {
                    writeSigInfo(info_ptr, &si) catch return error.EFAULT;
                }
                return si.signo;
            }
        }
        // Timeout expired without signal
        return error.EAGAIN;
    } else {
        // Infinite wait (NULL timeout)
        // Poll with yields until signal arrives
        var iterations: u64 = 0;
        while (true) {
            sched.yield();
            iterations += 1;

            if (tryDequeueSignal(current, wait_set)) |si| {
                if (info_ptr != 0) {
                    writeSigInfo(info_ptr, &si) catch return error.EFAULT;
                }
                return si.signo;
            }

            // Safety: check for thread interruption
            if (iterations > 100_000_000) return error.EINTR;
        }
    }
}

/// Try to atomically dequeue one signal from pending_signals matching wait_set.
/// Uses @cmpxchgWeak per user decision for race-safe check-and-clear.
/// Returns KernelSigInfo with metadata (or fallback SI_USER if queue entry missing).
fn tryDequeueSignal(thread: *sched.Thread, wait_set: uapi.signal.SigSet) ?uapi.signal.KernelSigInfo {
    // Read pending atomically
    const pending = @atomicLoad(u64, &thread.pending_signals, .acquire);
    const matching = pending & wait_set;
    if (matching == 0) return null;

    // Find the lowest-numbered matching signal
    const bit_pos = @ctz(matching);
    const sig_bit: u64 = @as(u64, 1) << @intCast(bit_pos);

    // Atomic CAS loop to clear the bit
    var current = pending;
    while (true) {
        const result = @cmpxchgWeak(u64, &thread.pending_signals, current, current & ~sig_bit, .acq_rel, .acquire);
        if (result) |new_val| {
            // CAS failed, retry with updated value
            current = new_val;
            if ((current & sig_bit) == 0) return null; // Someone else took it
        } else {
            // CAS succeeded -- dequeue siginfo metadata
            const signo: u8 = @intCast(bit_pos + 1);
            if (thread.siginfo_queue.dequeueBySignal(signo)) |si| {
                return si;
            }
            // Fallback: no siginfo entry (race or queue was full during delivery)
            return uapi.signal.KernelSigInfo{
                .signo = signo,
                .code = uapi.signal.SI_USER,
                .pid = 0,
                .uid = 0,
                .value = 0,
            };
        }
    }
}

/// Write siginfo_t to user memory for a dequeued signal.
/// Populates si_signo, si_code, si_pid, si_uid, si_value from KernelSigInfo.
fn writeSigInfo(info_ptr: usize, si: *const uapi.signal.KernelSigInfo) !void {
    // Build siginfo_t (128 bytes, zero-initialized for all unused fields)
    // Layout (Linux x86_64 siginfo_t):
    //   Offset  0: si_signo (i32)
    //   Offset  4: si_errno (i32) = 0
    //   Offset  8: si_code  (i32)
    //   Offset 12: padding  (i32) = 0
    //   Offset 16: si_pid   (i32) for SI_USER/SI_QUEUE/SI_TKILL
    //   Offset 20: si_uid   (i32)
    //   Offset 24: si_value (union: first 8 bytes as usize)
    var buf = [_]u8{0} ** 128;
    const signo_i32: i32 = @intCast(si.signo);
    @memcpy(buf[0..4], std.mem.asBytes(&signo_i32));
    // si_errno at offset 4 = 0 (already zeroed)
    @memcpy(buf[8..12], std.mem.asBytes(&si.code));
    // padding at offset 12 = 0 (already zeroed)
    const pid_i32: i32 = @bitCast(si.pid);
    @memcpy(buf[16..20], std.mem.asBytes(&pid_i32));
    const uid_i32: i32 = @bitCast(si.uid);
    @memcpy(buf[20..24], std.mem.asBytes(&uid_i32));
    @memcpy(buf[24..32], std.mem.asBytes(&si.value));

    const uptr = UserPtr.from(info_ptr);
    _ = uptr.copyFromKernel(&buf) catch return error.EFAULT;
}

/// sys_rt_sigqueueinfo (129) - Send a signal with data to a process
///
/// Per user decision: enforce si_code restriction -- only SI_QUEUE (negative codes)
/// allowed from userspace. Reject si_code >= 0 to prevent kernel signal impersonation.
///
/// Per user decision: permission check uses UID match (same real/effective UID as target).
/// CAP_KILL check deferred to Phase 24.
///
/// MVP: Signal is delivered to process, but siginfo_t data is not preserved
/// (bitmask-only tracking). Acceptable for v1.2.
///
/// Args:
///   pid: Target process ID
///   sig: Signal number
///   info_ptr: Pointer to siginfo_t with signal data
///
/// Returns: 0 on success
pub fn sys_rt_sigqueueinfo(pid: usize, sig: usize, info_ptr: usize) SyscallError!usize {
    const pid_i: i32 = @bitCast(@as(u32, @truncate(pid)));
    const signum: u8 = @truncate(sig);

    if (pid_i <= 0) return error.EINVAL;
    if (signum == 0 or signum > 64) return error.EINVAL;
    if (info_ptr == 0) return error.EFAULT;

    // Read siginfo_t from userspace (only need first 16 bytes for validation)
    var info_buf = [_]u8{0} ** 128;
    _ = UserPtr.from(info_ptr).copyToKernel(&info_buf) catch return error.EFAULT;

    // Validate si_code: userspace can only send SI_QUEUE or other negative codes
    const bytes = [4]u8{ info_buf[8], info_buf[9], info_buf[10], info_buf[11] };
    const si_code: i32 = @bitCast(bytes);
    if (si_code >= 0) return error.EPERM; // Cannot impersonate kernel signals

    // Find target
    const target = sched.findThreadByPid(@intCast(pid_i)) orelse return error.ESRCH;

    // Permission check (reuse existing checkSignalPermission)
    try checkSignalPermission(target, signum);

    // Extract sender PID/UID and si_value from the user-provided siginfo_t buffer
    // Layout: si_signo (i32 @ 0), si_errno (i32 @ 4), si_code (i32 @ 8), padding (i32 @ 12),
    //         si_pid (i32 @ 16), si_uid (i32 @ 20), si_value (union @ 24, first 8 bytes as usize)
    const si_pid_bytes = [4]u8{ info_buf[16], info_buf[17], info_buf[18], info_buf[19] };
    const si_pid: i32 = @bitCast(si_pid_bytes);
    const si_uid_bytes = [4]u8{ info_buf[20], info_buf[21], info_buf[22], info_buf[23] };
    const si_uid: i32 = @bitCast(si_uid_bytes);
    const si_value_bytes = [8]u8{ info_buf[24], info_buf[25], info_buf[26], info_buf[27], info_buf[28], info_buf[29], info_buf[30], info_buf[31] };
    const si_value: usize = @bitCast(si_value_bytes);

    const si = uapi.signal.KernelSigInfo{
        .signo = signum,
        .code = si_code,
        .pid = @bitCast(si_pid),
        .uid = @bitCast(si_uid),
        .value = si_value,
    };

    // For rt_sigqueueinfo, queue overflow MUST return EAGAIN per POSIX (SIGQUEUE_MAX enforcement).
    // Unlike general delivery paths (kill/tkill) which use best-effort silent drop,
    // rt_sigqueueinfo is the explicit queuing API and callers need to know when queue is full.
    const sig_bit_q: u64 = @as(u64, 1) << @intCast(signum - 1);
    const is_rt_signal_q = signum >= 32;
    const already_pending_q = (@atomicLoad(u64, &target.pending_signals, .acquire) & sig_bit_q) != 0;

    if (is_rt_signal_q or !already_pending_q) {
        if (!target.siginfo_queue.enqueue(si)) {
            // Queue full -- POSIX mandates EAGAIN for rt_sigqueueinfo overflow
            return error.EAGAIN;
        }
    }

    // Set pending bitmask
    _ = @atomicRmw(u64, &target.pending_signals, .Or, sig_bit_q, .release);

    // Wake target if blocked
    if (target.state == .Blocked and !target.stopped) {
        sched.unblock(target);
    }

    return 0;
}

/// sys_rt_tgsigqueueinfo (297/240) - Send a signal with data to a specific thread
///
/// Same as rt_sigqueueinfo but targets a specific thread within a thread group.
///
/// Args:
///   tgid: Thread group ID (process PID)
///   tid: Target thread ID
///   sig: Signal number
///   info_ptr: Pointer to siginfo_t
///
/// Returns: 0 on success
pub fn sys_rt_tgsigqueueinfo(tgid: usize, tid: usize, sig: usize, info_ptr: usize) SyscallError!usize {
    const tgid_i: i32 = @bitCast(@as(u32, @truncate(tgid)));
    const tid_i: i32 = @bitCast(@as(u32, @truncate(tid)));
    const signum: u8 = @truncate(sig);

    if (tgid_i <= 0 or tid_i <= 0) return error.EINVAL;
    if (signum == 0 or signum > 64) return error.EINVAL;
    if (info_ptr == 0) return error.EFAULT;

    // Read and validate si_code
    var info_buf = [_]u8{0} ** 128;
    _ = UserPtr.from(info_ptr).copyToKernel(&info_buf) catch return error.EFAULT;

    const bytes = [4]u8{ info_buf[8], info_buf[9], info_buf[10], info_buf[11] };
    const si_code: i32 = @bitCast(bytes);
    if (si_code >= 0) return error.EPERM;

    // Find target thread
    const target = sched.findThreadByTid(@intCast(tid_i)) orelse return error.ESRCH;

    // Verify thread belongs to the specified thread group
    if (target.process) |proc| {
        const process: *base.Process = @ptrCast(@alignCast(proc));
        if (process.pid != @as(u32, @intCast(tgid_i))) return error.ESRCH;
    }

    // Permission check
    try checkSignalPermission(target, signum);

    // Extract sender metadata from user-provided siginfo_t buffer
    const si_pid_bytes_tg = [4]u8{ info_buf[16], info_buf[17], info_buf[18], info_buf[19] };
    const si_pid_tg: i32 = @bitCast(si_pid_bytes_tg);
    const si_uid_bytes_tg = [4]u8{ info_buf[20], info_buf[21], info_buf[22], info_buf[23] };
    const si_uid_tg: i32 = @bitCast(si_uid_bytes_tg);
    const si_value_bytes_tg = [8]u8{ info_buf[24], info_buf[25], info_buf[26], info_buf[27], info_buf[28], info_buf[29], info_buf[30], info_buf[31] };
    const si_value_tg: usize = @bitCast(si_value_bytes_tg);

    const si_tg = uapi.signal.KernelSigInfo{
        .signo = signum,
        .code = si_code,
        .pid = @bitCast(si_pid_tg),
        .uid = @bitCast(si_uid_tg),
        .value = si_value_tg,
    };

    // Return EAGAIN on queue overflow (POSIX SIGQUEUE_MAX enforcement)
    const sig_bit_tg: u64 = @as(u64, 1) << @intCast(signum - 1);
    const is_rt_signal_tg = signum >= 32;
    const already_pending_tg = (@atomicLoad(u64, &target.pending_signals, .acquire) & sig_bit_tg) != 0;

    if (is_rt_signal_tg or !already_pending_tg) {
        if (!target.siginfo_queue.enqueue(si_tg)) {
            return error.EAGAIN;
        }
    }

    // Set pending bitmask
    _ = @atomicRmw(u64, &target.pending_signals, .Or, sig_bit_tg, .release);

    // Wake target if blocked
    if (target.state == .Blocked and !target.stopped) {
        sched.unblock(target);
    }

    return 0;
}
