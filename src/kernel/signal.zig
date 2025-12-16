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
    // (For MVP, we might just kill the thread/process for fatal signals)
    if (action.handler == 0) {
        // Default action
        // For now, treat all as fatal except ignored ones
        // TODO: Implement proper default actions (ignore, core, stop, etc.)
        console.info("Signal: Terminating thread {d} due to signal {d}", .{current_thread.tid, signum});
        sched.exitWithStatus(128 + @as(i32, @intCast(signum)));
        // exitWithStatus doesn't return, but to satisfy type checker:
        return frame;
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

    // Get current user stack pointer
    var sp = frame.rsp;

    // Align stack to 16 bytes (required by x86_64 ABI)
    // Also reserve red zone (128 bytes) just in case
    sp = (sp - 128) & ~@as(u64, 15);

    // Calculate size of ucontext/sigframe
    // For MVP, we'll use a simplified frame:
    // [return address (trampoline)]
    // [ucontext]
    const ucontext_size = @sizeOf(uapi.signal.UContext);
    sp -= ucontext_size;

    // Save context to user stack
    // We need to construct UContext
    const ucontext = uapi.signal.UContext{
        .flags = 0,
        .link = 0,
        .stack = .{
            .sp = 0, // TODO: sigaltstack support
            .flags = 0,
            .size = 0,
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
            .oldmask = 0, // TODO: Save current signal mask
            .cr2 = 0, // TODO: Save CR2 for page faults
            .fpstate = 0, // TODO: Save FPU state
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

    // Mask signals in action.mask (and the signal itself unless SA_NODEFER)
    // TODO: Update thread.sigmask

    return frame;
}

/// Initialize signal subsystem
/// Registers the `checkSignals` callback with the interrupt dispatcher.
pub fn init() void {
    // Register the signal checker with the IDT/arch layer
    hal.idt.setSignalChecker(checkSignals);
}
