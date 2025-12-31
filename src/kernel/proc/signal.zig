//! Signal Handling Subsystem
//!
//! Implements POSIX-style signal delivery and return mechanisms.
//!
//! Key components:
//! - `checkSignals`: Called by the architecture layer (IDT) when returning to user mode.
//!   Checks for pending signals and modifies the interrupt frame to invoke the signal handler.
//! - `setupSignalFrame`: Constructs the `ucontext_t` structure on the user stack.
//! - `sys_rt_sigreturn` (implied): Restores the thread context from the user stack after the handler returns.

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

    // Fast check: any pending signals?
    if (current_thread.pending_signals == 0) return frame;

    // Find the first pending signal that is not blocked
    // Bit 0 corresponds to signal 1, etc.
    const pending = current_thread.pending_signals & ~current_thread.sigmask;
    if (pending == 0) return frame;

    // Find lowest set bit (lowest signal number)
    const sig_bit = @ctz(pending);
    const signum = sig_bit + 1;

    // Clear the pending bit
    // Note: In a full implementation, we might leave it if it's a real-time signal
    // or if we fail to deliver. For now, clear it to avoid loop.
    current_thread.pending_signals &= ~(@as(u64, 1) << @truncate(sig_bit));

    // Get the action for this signal
    // signal_actions index is signum-1
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
    return setupSignalFrame(frame, signum, action);
}

/// Set up the user stack for signal delivery.
///
/// Pushes a `ucontext_t` structure onto the user stack containing the current
/// register state. Updates the interrupt frame to point RIP to the handler
/// and RSP to the new stack location.
fn setupSignalFrame(frame: *hal.idt.InterruptFrame, signum: usize, action: uapi.signal.SigAction) *hal.idt.InterruptFrame {
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

    const ucontext_size = @sizeOf(uapi.signal.UContext);
    sp -= ucontext_size;
    sp &= ~@as(u64, 15); // Force alignment to 16 bytes

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
            .oldmask = current_thread.sigmask, // Save current signal mask for restoration
            // Save CR2 for page fault signals (SIGSEGV, SIGBUS)
            // CR2 contains the faulting virtual address
            .cr2 = if (signum == uapi.signal.SIGSEGV or signum == uapi.signal.SIGBUS)
                hal.cpu.readCr2()
            else
                0,
            .fpstate = fpstate_addr, // Pointer to saved FPU state (or 0)
            .reserved = [_]u64{0} ** 8,
        },
        .sigmask = sched.getCurrentThread().?.sigmask,
        ._pad = [_]u8{0} ** 128,
    };

    // Write ucontext to stack
    UserPtr.from(sp).writeValue(ucontext) catch {
        console.err("Signal: Failed to write ucontext to stack (sp={x})", .{sp});
        // Force exit if we can't deliver signal (stack overflow?)
        sched.exitWithStatus(128 + 11); // SIGSEGV
        return frame;
    };

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
    frame.rdi = @intCast(signum); // Arg 1: signum

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

    // Fast check: any pending signals?
    if (current_thread.pending_signals == 0) return;

    // Find the first pending signal that is not blocked
    const pending = current_thread.pending_signals & ~current_thread.sigmask;
    if (pending == 0) return;

    // Find lowest set bit (lowest signal number)
    const sig_bit = @ctz(pending);
    const signum: usize = sig_bit + 1;

    // Clear the pending bit
    current_thread.pending_signals &= ~(@as(u64, 1) << @truncate(sig_bit));

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
    setupSignalFrameForSyscall(frame, current_thread, signum, action);
}

/// Set up user stack for signal delivery from syscall context
fn setupSignalFrameForSyscall(frame: *hal.syscall.SyscallFrame, current_thread: *Thread, signum: usize, action: uapi.signal.SigAction) void {
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

    // Build ucontext
    const ucontext_size = @sizeOf(uapi.signal.UContext);
    sp -= ucontext_size;
    sp &= ~@as(u64, 15);

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
            .rflags = frame.r11, // SYSCALL saves RFLAGS in R11
            .rsp = frame.getUserRsp(),
            .ss = 0x1b, // User data segment
            .gs = 0,
            .fs = 0,
            .pad0 = 0,
            .err = 0,
            .trapno = 0,
            .oldmask = current_thread.sigmask,
            .cr2 = 0,
            .fpstate = fpstate_addr,
            .reserved = [_]u64{0} ** 8,
        },
        .sigmask = current_thread.sigmask,
        ._pad = [_]u8{0} ** 128,
    };

    UserPtr.from(sp).writeValue(ucontext) catch {
        console.err("Signal: Failed to write ucontext to stack (sp={x})", .{sp});
        sched.exitWithStatus(128 + 11);
        return;
    };

    // Push return address (restorer)
    const restorer = action.restorer;
    if (restorer == 0) {
        console.warn("Signal: No restorer provided for signal {d}", .{signum});
    }
    sp -= 8;
    UserPtr.from(sp).writeValue(restorer) catch {
        sched.exitWithStatus(128 + 11);
        return;
    };

    // Update frame to execute handler
    frame.setReturnRip(action.handler);
    frame.setUserRsp(sp);
    frame.rdi = @intCast(signum); // Arg 1: signum

    // Clear direction flag in R11 (will become RFLAGS on sysret)
    frame.r11 &= ~@as(u64, 0x400);

    // Update signal mask
    current_thread.sigmask |= action.mask;
    if ((action.flags & uapi.signal.SA_NODEFER) == 0) {
        const sig_bit: u64 = @as(u64, 1) << @truncate(signum - 1);
        current_thread.sigmask |= sig_bit;
    }
}

/// Initialize signal subsystem
/// Registers the `checkSignals` callback with the interrupt dispatcher.
pub fn init() void {
    // Register the signal checker with the IDT/arch layer
    hal.idt.setSignalChecker(checkSignals);
}
