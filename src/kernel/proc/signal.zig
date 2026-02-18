//! Signal Handling Subsystem
//!
//! Implements POSIX-style signal delivery and return mechanisms.
//!
//! Key components:
//! - `checkSignals`: Called by the architecture layer (IDT) when returning to user mode.
//!   Checks for pending signals and modifies the interrupt frame to invoke the signal handler.
//! - `setupSignalFrame`: Constructs the `ucontext_t` structure on the user stack.
//! - `sys_rt_sigreturn` (implied): Restores the thread context from the user stack after the handler returns.

const builtin = @import("builtin");
const std = @import("std");
const sched = @import("sched");
const thread = @import("thread");
const uapi = @import("uapi");
const hal = @import("hal");
const user_mem = @import("user_mem");
const console = @import("console");

const UserPtr = user_mem.UserPtr;
const Thread = @import("thread").Thread;

/// Handle default signal action based on signal type
/// Returns the (possibly modified) interrupt frame, or null if thread terminated
fn handleDefaultAction(frame: *hal.idt.InterruptFrame, current_thread: *Thread, signum: usize) *hal.idt.InterruptFrame {
    const default_action = uapi.signal.getDefaultAction(signum);

    switch (default_action) {
        .Ignore => {
            // Simply ignore the signal (SIGCHLD, SIGURG, SIGWINCH)
            return frame;
        },
        .Stop => {
            // Stop the process (SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU)
            console.info("Signal: Stopping thread {d} due to signal {d}", .{ current_thread.tid, signum });

            // Mark thread as stopped by signal
            current_thread.stopped = true;

            // Block the thread - it will remain blocked until SIGCONT
            sched.block();

            // When we return here, SIGCONT has resumed us
            // Clear the stopped flag (should already be cleared by SIGCONT handler)
            current_thread.stopped = false;

            return frame;
        },
        .Continue => {
            // Continue if stopped (SIGCONT)
            // This is handled specially - we need to resume all stopped threads in the process
            handleSigcont(current_thread);
            return frame;
        },
        .Core => {
            // Terminate with core dump (SIGQUIT, SIGILL, SIGTRAP, SIGABRT, etc.)
            // For now, we just terminate - actual core dump would require filesystem support
            console.info("Signal: Terminating thread {d} with core dump for signal {d}", .{ current_thread.tid, signum });
            sched.exitWithStatus(128 + @as(i32, @intCast(signum)));
            // exitWithStatus doesn't return
            return frame;
        },
        .Terminate => {
            // Terminate the process (SIGHUP, SIGINT, SIGTERM, etc.)
            console.info("Signal: Terminating thread {d} due to signal {d}", .{ current_thread.tid, signum });
            sched.exitWithStatus(128 + @as(i32, @intCast(signum)));
            // exitWithStatus doesn't return
            return frame;
        },
    }
}

/// Handle SIGCONT - resume stopped thread
/// For MVP with single-threaded processes, we just clear the stopped flag
/// on the current thread. Multi-threading support would need to iterate all
/// threads in the process.
fn handleSigcont(current_thread: *Thread) void {
    // For MVP, processes are single-threaded
    // If this thread is stopped (shouldn't happen - we're running), clear it
    if (current_thread.stopped) {
        current_thread.stopped = false;
    }
    // Note: The actual SIGCONT resume logic for blocked threads is in
    // deliverSignalToThread() in syscall/signals.zig, which handles the case
    // where another process sends SIGCONT to a stopped process.
}

/// Check for pending signals and set up delivery if needed.
///
/// This function is the hook called by `src/arch/x86_64/idt.zig`'s `dispatch_interrupt`
/// when returning to user mode (RPL 3).
///
/// Returns the (possibly modified) interrupt frame pointer. If a signal is delivered,
/// the frame will point to the signal handler with the stack prepared.
pub fn checkSignals(frame: *hal.idt.InterruptFrame) *hal.idt.InterruptFrame {
    const current_thread = sched.getCurrentThread() orelse return frame;

    // Fast check: any pending signals? (atomic for SMP visibility)
    if (@atomicLoad(u64, &current_thread.pending_signals, .acquire) == 0) return frame;

    // Find the first pending signal that is not blocked
    // Bit 0 corresponds to signal 1, etc.
    const pending = @atomicLoad(u64, &current_thread.pending_signals, .acquire) & ~current_thread.sigmask;
    if (pending == 0) return frame;

    // Find lowest set bit (lowest signal number)
    // BOUNDS SAFETY: @ctz on non-zero u64 returns 0-63, so signum is 1-64.
    // signal_actions is a 64-element array (indices 0-63), so signum-1 is always valid.
    const sig_bit = @ctz(pending);
    const signum = sig_bit + 1;

    // Atomically clear the pending bit to prevent races with signal delivery
    // and signalfd consumption on other CPUs.
    _ = @atomicRmw(u64, &current_thread.pending_signals, .And, ~(@as(u64, 1) << @truncate(sig_bit)), .acq_rel);

    // Dequeue siginfo metadata (may be null if queue was empty/overflowed during delivery)
    const siginfo = current_thread.siginfo_queue.dequeueBySignal(@intCast(signum));

    // Get the action for this signal
    // signal_actions index is signum-1 (0-63 for signals 1-64)
    const action = current_thread.signal_actions[signum - 1];

    // If handler is SIG_DFL (0) or SIG_IGN (1), handle default action
    if (action.handler == 0) {
        // SIG_DFL: Default action based on signal type
        return handleDefaultAction(frame, current_thread, signum);
    } else if (action.handler == 1) {
        // SIG_IGN: Ignore signal
        return frame;
    }

    // Deliver signal to user handler
    return setupSignalFrame(frame, signum, action, siginfo);
}

/// Set up the user stack for signal delivery.
///
/// Pushes a `ucontext_t` structure onto the user stack containing the current
/// register state. Updates the interrupt frame to point RIP to the handler
/// and RSP to the new stack location.
fn setupSignalFrame(frame: *hal.idt.InterruptFrame, signum: usize, action: uapi.signal.SigAction, siginfo: ?uapi.signal.KernelSigInfo) *hal.idt.InterruptFrame {
    // We need to save the current context (registers) to the user stack
    // so sigreturn can restore them later.
    // The structure we push is ucontext_t (or close approximation).

    const current_thread = sched.getCurrentThread().?;

    // Determine which stack to use for signal delivery
    var sp = frame.rsp;
    var using_altstack = false;

    // Use alternate stack if:
    // 1. SA_ONSTACK flag is set
    // 2. Alternate stack is configured (not SS_DISABLE)
    // 3. We're not already on the alternate stack
    if ((action.flags & uapi.signal.SA_ONSTACK) != 0) {
        const alt = current_thread.alternate_stack;
        if ((alt.flags & uapi.signal.SS_DISABLE) == 0) {
            // Check if we're already on the alternate stack
            const on_altstack = (frame.rsp >= alt.sp and frame.rsp < alt.sp + alt.size);
            if (!on_altstack) {
                // Switch to alternate stack (grows down, so start at top)
                sp = alt.sp + alt.size;
                using_altstack = true;
            }
        }
    }

    // Align stack to 16 bytes (required by x86_64 ABI)
    // Also reserve red zone (128 bytes) just in case
    sp = (sp - 128) & ~@as(u64, 15);

    // Calculate size of ucontext/sigframe
    // Layout:
    // [return address (trampoline)]
    // [ucontext]
    // [fpu_state (512 bytes)]
    
    // Reserve space for FPU state (512 bytes) + alignment
    // We do this first (higher address) so ucontext can point to it
    // FPU state size is dynamic based on XSAVE/FXSAVE support
    var fpstate_addr: usize = 0;
    const fpu_size = hal.fpu.getXsaveAreaSize();

    // Check if we need to save FPU state
    // always save FPU state to stack (it might be in regs or memory)
    if (current_thread.fpu_used) {
        // State is in registers, save to memory first
        hal.fpu.saveState(current_thread.fpu_state_buffer);
    }

    // Now thread's FPU buffer is up to date. Copy to stack.
    sp -= fpu_size; // Dynamic size for XSAVE or FXSAVE
    sp &= ~@as(u64, 63); // Align to 64 bytes for XSAVE compatibility
    fpstate_addr = sp;

    // Copy FPU state to user stack
    _ = UserPtr.from(fpstate_addr).copyFromKernel(current_thread.fpu_state_buffer) catch {
        console.err("Signal: Failed to write FPU state to stack", .{});
        sched.exitWithStatus(128 + 11);
        return frame;
    };

    // Stack layout (x86_64, low address to high):
    //   SA_SIGINFO:    [restorer][ucontext][siginfo_t]
    //   non-SA_SIGINFO:[restorer][ucontext]
    //
    // When the handler does 'ret', RSP advances past restorer to ucontext.
    // sys_rt_sigreturn reads ucontext from RSP (= ucontext_addr).

    // Step 1: For SA_SIGINFO, reserve siginfo space first (higher address).
    var siginfo_sp: usize = 0;
    var si_data_opt: ?uapi.signal.KernelSigInfo = null;
    if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
        sp -= @sizeOf(uapi.signal.SigInfoT);
        sp &= ~@as(u64, 15); // 16-byte align
        siginfo_sp = sp;
        si_data_opt = siginfo orelse uapi.signal.KernelSigInfo{
            .signo = @intCast(signum),
            .code = uapi.signal.SI_USER,
            .pid = 0,
            .uid = 0,
            .value = 0,
        };
    }

    // Step 2: Reserve and write ucontext below siginfo (or directly below FPU area).
    const ucontext_size = @sizeOf(uapi.signal.UContext);
    sp -= ucontext_size;
    sp &= ~@as(u64, 15); // Force alignment to 16 bytes
    const ucontext_addr = sp;

    // Save context to user stack
    // We need to construct UContext
    const ucontext = uapi.signal.UContext{
        .flags = 0,
        .link = 0,
        .stack = blk: {
            // Include alternate stack info in ucontext
            var stack_info = current_thread.alternate_stack;
            // Set SS_ONSTACK if we're delivering on the alternate stack
            if (using_altstack) {
                stack_info.flags |= uapi.signal.SS_ONSTACK;
            }
            break :blk stack_info;
        },
        .mcontext = .{
            .r15 = frame.r15,
            .r14 = frame.r14,
            .r13 = frame.r13,
            .r12 = frame.r12,
            .r11 = frame.r11,
            .r10 = frame.r10,
            .r9 = frame.r9,
            .r8 = frame.r8,
            .rdi = frame.rdi,
            .rsi = frame.rsi,
            .rbp = frame.rbp,
            .rbx = frame.rbx,
            .rdx = frame.rdx,
            .rcx = frame.rcx,
            .rax = frame.rax,
            .rip = frame.rip,
            .cs = @truncate(frame.cs),
            .rflags = frame.rflags,
            .rsp = frame.rsp,
            .ss = frame.ss,
            .gs = 0,
            .fs = 0,
            .pad0 = 0,
            .err = frame.error_code,
            .trapno = frame.vector,
            .oldmask = if (current_thread.has_saved_sigmask) current_thread.saved_sigmask else current_thread.sigmask,
            // Save CR2 for page fault signals (SIGSEGV, SIGBUS)
            // CR2 contains the faulting virtual address
            .cr2 = if (signum == uapi.signal.SIGSEGV or signum == uapi.signal.SIGBUS)
                hal.cpu.readCr2()
            else
                0,
            .fpstate = fpstate_addr, // Pointer to saved FPU state (or 0)
            .reserved = [_]u64{0} ** 8,
        },
        .sigmask = if (current_thread.has_saved_sigmask) current_thread.saved_sigmask else current_thread.sigmask,
        ._pad = [_]u8{0} ** 128,
    };

    // Write ucontext to stack
    UserPtr.from(sp).writeValue(ucontext) catch {
        console.err("Signal: Failed to write ucontext to stack (sp={x})", .{sp});
        // Force exit if we can't deliver signal (stack overflow?)
        sched.exitWithStatus(128 + 11); // SIGSEGV
        return frame;
    };

    // Step 3: Write siginfo_t at siginfo_sp (above ucontext, already allocated).
    if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
        const si_data = si_data_opt.?;
        const user_siginfo = uapi.signal.SigInfoT{
            .si_signo = @intCast(si_data.signo),
            .si_errno = 0,
            .si_code = si_data.code,
            .si_pid = @bitCast(si_data.pid),
            .si_uid = @bitCast(si_data.uid),
            // SIGSYS: carry offending syscall number in si_value_int (for SA_SIGINFO handlers)
            .si_value_int = if (si_data.signo == @as(u8, @intCast(uapi.signal.SIGSYS)))
                si_data.syscall_nr
            else
                @intCast(si_data.value & 0xFFFFFFFF),
            .si_value_ptr = si_data.value,
        };
        UserPtr.from(siginfo_sp).writeValue(user_siginfo) catch {
            console.err("Signal: Failed to write siginfo_t to stack", .{});
            sched.exitWithStatus(128 + 11);
            return frame;
        };
    }

    // Push return address (trampoline)
    // If SA_RESTORER flag is set, use action.restorer
    // Otherwise, we might need a default kernel VDSO trampoline (not yet implemented)
    // Linux libc usually provides the restorer.
    var restorer = action.restorer;
    if (restorer == 0) {
        // If no restorer provided, we can't return!
        // This will crash when handler returns.
        // For now, let's warn.
        console.warn("Signal: No restorer provided for signal {d}", .{signum});
        restorer = 0; // Will cause #PF if returned to
    }

    sp -= 8;
    UserPtr.from(sp).writeValue(restorer) catch {
        sched.exitWithStatus(128 + 11);
        return frame;
    };

    // Update interrupt frame to execute handler
    frame.rip = action.handler;
    frame.rsp = sp;
    // x86_64 C ABI: rdi = arg1, rsi = arg2, rdx = arg3
    frame.rdi = @intCast(signum); // Arg 1: signum (always)
    if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
        frame.rsi = siginfo_sp;    // Arg 2: pointer to siginfo_t
        frame.rdx = ucontext_addr; // Arg 3: pointer to ucontext_t
    }

    // Clear direction flag, etc?
    frame.rflags &= ~@as(u64, 0x400); // Clear DF

    // Update signal mask for the duration of handler execution:
    // 1. Add signals from action.mask
    // 2. Add the signal itself unless SA_NODEFER flag is set
    // The original mask will be restored by rt_sigreturn using oldmask
    current_thread.sigmask |= action.mask;
    if ((action.flags & uapi.signal.SA_NODEFER) == 0) {
        // Block this signal during handler execution
        const sig_bit: u64 = @as(u64, 1) << @truncate(signum - 1);
        current_thread.sigmask |= sig_bit;
    }

    // If rt_sigsuspend saved a mask, clear the flag -- rt_sigreturn
    // will restore the original mask from ucontext.sigmask.
    if (current_thread.has_saved_sigmask) {
        current_thread.has_saved_sigmask = false;
    }

    return frame;
}

/// Check for pending signals on syscall exit
///
/// This function is called by the syscall dispatcher after a syscall completes.
/// If there are pending unmasked signals, it modifies the SyscallFrame to deliver
/// the signal handler instead of returning normally.
///
/// Unlike checkSignals (for interrupts), this works with SyscallFrame which uses
/// RCX for return RIP and R11 for RFLAGS.
pub fn checkSignalsOnSyscallExit(frame: *hal.syscall.SyscallFrame) void {
    const current_thread = sched.getCurrentThread() orelse return;

    // Restore saved signal mask from rt_sigsuspend at function exit.
    // This runs AFTER signal delivery (if any) so the temporary mask is active
    // during signal handler setup. The defer runs on ALL return paths.
    defer {
        if (current_thread.has_saved_sigmask) {
            current_thread.sigmask = current_thread.saved_sigmask;
            current_thread.has_saved_sigmask = false;
        }
    }

    // Fast check: any pending signals? (atomic for SMP visibility)
    const pending_check = @atomicLoad(u64, &current_thread.pending_signals, .acquire);
    if (pending_check == 0) return;

    // Find the first pending signal that is not blocked
    const pending = @atomicLoad(u64, &current_thread.pending_signals, .acquire) & ~current_thread.sigmask;
    if (pending == 0) return;

    // Find lowest set bit (lowest signal number)
    const sig_bit = @ctz(pending);
    const signum: usize = sig_bit + 1;

    // Atomically clear the pending bit to prevent races with signal delivery
    // and signalfd consumption on other CPUs.
    _ = @atomicRmw(u64, &current_thread.pending_signals, .And, ~(@as(u64, 1) << @truncate(sig_bit)), .acq_rel);

    // Dequeue siginfo metadata (may be null if queue was empty/overflowed during delivery)
    const siginfo = current_thread.siginfo_queue.dequeueBySignal(@intCast(signum));

    // Get the action for this signal
    const action = current_thread.signal_actions[signum - 1];

    // If handler is SIG_DFL (0), handle default action
    if (action.handler == 0) {
        const default_action = uapi.signal.getDefaultAction(signum);
        switch (default_action) {
            .Ignore => return,
            .Stop => {
                console.info("Signal: Stopping thread {d} due to signal {d}", .{ current_thread.tid, signum });
                current_thread.stopped = true;
                sched.block();
                current_thread.stopped = false;
                return;
            },
            .Continue => {
                if (current_thread.stopped) {
                    current_thread.stopped = false;
                }
                return;
            },
            .Core, .Terminate => {
                console.info("Signal: Terminating thread {d} due to signal {d}", .{ current_thread.tid, signum });
                sched.exitWithStatus(128 + @as(i32, @intCast(signum)));
                return;
            },
        }
    } else if (action.handler == 1) {
        // SIG_IGN: Ignore signal
        return;
    }

    // Deliver signal to user handler via setupSignalFrameForSyscall
    setupSignalFrameForSyscall(frame, current_thread, signum, action, siginfo);
    // Note: setupSignalFrameForSyscall cleared has_saved_sigmask if it was set.
    // rt_sigreturn will restore the mask from ucontext.sigmask.
    // The defer at function entry handles restoration if no signal was delivered.
}

/// Set up user stack for signal delivery from syscall context
fn setupSignalFrameForSyscall(frame: *hal.syscall.SyscallFrame, current_thread: *Thread, signum: usize, action: uapi.signal.SigAction, siginfo: ?uapi.signal.KernelSigInfo) void {

    // Determine which stack to use
    var sp = frame.getUserRsp();
    var using_altstack = false;

    if ((action.flags & uapi.signal.SA_ONSTACK) != 0) {
        const alt = current_thread.alternate_stack;
        if ((alt.flags & uapi.signal.SS_DISABLE) == 0) {
            const on_altstack = (sp >= alt.sp and sp < alt.sp + alt.size);
            if (!on_altstack) {
                sp = alt.sp + alt.size;
                using_altstack = true;
            }
        }
    }

    // Align stack to 16 bytes, reserve red zone
    sp = (sp - 128) & ~@as(u64, 15);

    // Save FPU state (dynamic size for XSAVE/FXSAVE)
    var fpstate_addr: usize = 0;
    const fpu_size = hal.fpu.getXsaveAreaSize();
    if (current_thread.fpu_used) {
        hal.fpu.saveState(current_thread.fpu_state_buffer);
    }
    sp -= fpu_size;
    sp &= ~@as(u64, 63); // 64-byte alignment for XSAVE
    fpstate_addr = sp;

    _ = UserPtr.from(fpstate_addr).copyFromKernel(current_thread.fpu_state_buffer) catch {
        console.err("Signal: Failed to write FPU state to stack", .{});
        sched.exitWithStatus(128 + 11);
        return;
    };

    // Stack layout (low address to high):
    //   x86_64, non-SA_SIGINFO: [ucontext]        <- sp, SP set here, ret -> nothing above
    //   x86_64, SA_SIGINFO:     [restorer][ucontext][siginfo_t]
    //     - SP when handler called points to restorer
    //     - ret -> RSP = ucontext (sigreturn reads from here)
    //   aarch64, non-SA_SIGINFO:[ucontext]         <- sp=ucontext, LR=restorer
    //   aarch64, SA_SIGINFO:    [ucontext][siginfo_t] <- sp=ucontext, LR=restorer, x1=siginfo, x2=ucontext

    // Step 1: For SA_SIGINFO, reserve siginfo space first (higher address, allocated before ucontext).
    var siginfo_sp: usize = 0;
    var si_data_opt: ?uapi.signal.KernelSigInfo = null;
    if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
        sp -= @sizeOf(uapi.signal.SigInfoT);
        sp &= ~@as(u64, 15); // 16-byte align
        siginfo_sp = sp;
        si_data_opt = siginfo orelse uapi.signal.KernelSigInfo{
            .signo = @intCast(signum),
            .code = uapi.signal.SI_USER,
            .pid = 0,
            .uid = 0,
            .value = 0,
        };
    }

    // Step 2: Build ucontext below siginfo (or directly below FPU area).
    const ucontext_size = @sizeOf(uapi.signal.UContext);
    sp -= ucontext_size;
    sp &= ~@as(u64, 15);
    const ucontext_addr = sp;

    const ucontext = uapi.signal.UContext{
        .flags = 0,
        .link = 0,
        .stack = blk: {
            var stack_info = current_thread.alternate_stack;
            if (using_altstack) {
                stack_info.flags |= uapi.signal.SS_ONSTACK;
            }
            break :blk stack_info;
        },
        .mcontext = .{
            .r15 = frame.r15,
            .r14 = frame.r14,
            .r13 = frame.r13,
            .r12 = frame.r12,
            .r11 = frame.r11, // Original RFLAGS
            .r10 = frame.r10,
            .r9 = frame.r9,
            .r8 = frame.r8,
            .rdi = frame.rdi,
            .rsi = frame.rsi,
            .rbp = frame.rbp,
            .rbx = frame.rbx,
            .rdx = frame.rdx,
            .rcx = frame.rcx, // Original RIP
            .rax = frame.rax,
            .rip = frame.getReturnRip(),
            .cs = 0x23, // User code segment
            .rflags = if (builtin.cpu.arch == .aarch64) frame.spsr else frame.r11,
            .rsp = frame.getUserRsp(),
            .ss = 0x1b, // User data segment
            .gs = 0,
            .fs = 0,
            .pad0 = 0,
            .err = 0,
            .trapno = 0,
            .oldmask = if (current_thread.has_saved_sigmask) current_thread.saved_sigmask else current_thread.sigmask,
            .cr2 = 0,
            .fpstate = fpstate_addr,
            .reserved = [_]u64{0} ** 8,
        },
        .sigmask = if (current_thread.has_saved_sigmask) current_thread.saved_sigmask else current_thread.sigmask,
        ._pad = [_]u8{0} ** 128,
    };

    UserPtr.from(sp).writeValue(ucontext) catch {
        console.err("Signal: Failed to write ucontext to stack (sp={x})", .{sp});
        sched.exitWithStatus(128 + 11);
        return;
    };

    // Step 3: Write siginfo_t at siginfo_sp (above ucontext, already allocated).
    if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
        const si_data = si_data_opt.?;
        const user_siginfo = uapi.signal.SigInfoT{
            .si_signo = @intCast(si_data.signo),
            .si_errno = 0,
            .si_code = si_data.code,
            .si_pid = @bitCast(si_data.pid),
            .si_uid = @bitCast(si_data.uid),
            // SIGSYS: carry offending syscall number in si_value_int (for SA_SIGINFO handlers)
            .si_value_int = if (si_data.signo == @as(u8, @intCast(uapi.signal.SIGSYS)))
                si_data.syscall_nr
            else
                @intCast(si_data.value & 0xFFFFFFFF),
            .si_value_ptr = si_data.value,
        };
        UserPtr.from(siginfo_sp).writeValue(user_siginfo) catch {
            console.err("Signal: Failed to write siginfo_t to stack", .{});
            sched.exitWithStatus(128 + 11);
            return;
        };
    }

    // Push return address (restorer trampoline)
    const restorer = action.restorer;
    if (restorer == 0) {
        console.warn("Signal: No restorer provided for signal {d}", .{signum});
    }

    if (builtin.cpu.arch == .aarch64) {
        // On aarch64, 'ret' branches to x30 (link register), not stack.
        // Set LR to restorer. SP must point to ucontext so sys_rt_sigreturn reads correctly.
        frame.r15 = restorer; // r15 = x30 (LR)
    } else {
        // On x86_64, 'ret' pops return address from stack.
        // Push restorer below ucontext so that after 'ret', RSP points to ucontext.
        sp -= 8;
        UserPtr.from(sp).writeValue(restorer) catch {
            sched.exitWithStatus(128 + 11);
            return;
        };
    }

    // Update frame to execute handler
    frame.setReturnRip(action.handler);
    frame.setUserRsp(sp);

    // Set handler arguments.
    // x86_64 C ABI: rdi=arg1, rsi=arg2, rdx=arg3.
    // aarch64 C ABI: x0(rax)=arg1, x1(rdi)=arg2, x2(rsi)=arg3.
    if (builtin.cpu.arch == .aarch64) {
        frame.rax = @intCast(signum); // x0 = arg1: signum
        if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
            frame.rdi = siginfo_sp;    // x1 = arg2: pointer to siginfo_t
            frame.rsi = ucontext_addr; // x2 = arg3: pointer to ucontext_t
        }
    } else {
        frame.rdi = @intCast(signum); // rdi = arg1: signum
        if ((action.flags & uapi.signal.SA_SIGINFO) != 0) {
            frame.rsi = siginfo_sp;    // rsi = arg2: pointer to siginfo_t
            frame.rdx = ucontext_addr; // rdx = arg3: pointer to ucontext_t
        }
    }

    if (builtin.cpu.arch == .x86_64) {
        // Clear direction flag in R11 (will become RFLAGS on sysret)
        frame.r11 &= ~@as(u64, 0x400);
    }
    // aarch64: SPSR is set correctly by exception return, no DF flag to clear

    // Update signal mask
    current_thread.sigmask |= action.mask;
    if ((action.flags & uapi.signal.SA_NODEFER) == 0) {
        const sig_bit: u64 = @as(u64, 1) << @truncate(signum - 1);
        current_thread.sigmask |= sig_bit;
    }

    // If rt_sigsuspend saved a mask, clear the flag -- rt_sigreturn
    // will restore the original mask from ucontext.sigmask.
    if (current_thread.has_saved_sigmask) {
        current_thread.has_saved_sigmask = false;
    }
}

/// Initialize signal subsystem
/// Registers the `checkSignals` callback with the interrupt dispatcher.
pub fn init() void {
    // Register the signal checker with the IDT/arch layer
    hal.idt.setSignalChecker(checkSignals);
}
