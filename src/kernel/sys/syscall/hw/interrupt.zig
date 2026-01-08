const std = @import("std");
const uapi = @import("uapi");
const hal = @import("hal");
const sched = @import("sched");
const process = @import("process");

const SyscallError = uapi.errno.SyscallError;

// Wait queue for each IRQ (0-15)
// Tracks the thread waiting for a specific IRQ
var irq_waiters: [16]?*sched.Thread = [_]?*sched.Thread{null} ** 16;

// Track if we've registered our exit callback.
// NOTE: This has a benign TOCTOU race - multiple threads could both see false and
// register the callback. However, registerExitCallback is idempotent for the same
// function pointer, and clearIrqWaitersForThread is idempotent (just nulls pointers).
// Using atomics here would add complexity for no security benefit.
var exit_callback_registered: bool = false;

/// Ensure the exit callback is registered with the scheduler.
/// Called lazily on first use of sys_wait_interrupt.
fn ensureExitCallbackRegistered() void {
    if (!exit_callback_registered) {
        // Ignore return value - if registration fails, IRQ cleanup on thread
        // exit won't happen, but this is a rare edge case and logged by the callee
        _ = sched.registerExitCallback(clearIrqWaitersForThread);
        exit_callback_registered = true;
    }
}

// Generic IRQ handler callback
// Registered with HAL to be called from ISR context
fn irqHandlerCallback(irq: u8) void {
    if (irq >= 16) return;

    // Wake up waiting thread
    if (irq_waiters[irq]) |thread| {
        sched.unblock(thread);
        // Clear waiter to prevent spurious wakeups.
        // Thread must re-register if it wants to wait again.
        irq_waiters[irq] = null;
    }
}

/// Clear any IRQ waiter registrations for a thread.
/// MUST be called during thread/process cleanup to prevent use-after-free.
/// The thread pointer becomes invalid after exit, so we must remove all references.
pub fn clearIrqWaitersForThread(thread_ptr: *sched.Thread) void {
    // Disable interrupts to prevent IRQ handler from racing with cleanup
    const was_enabled = hal.cpu.interruptsEnabled();
    hal.cpu.disableInterrupts();
    defer if (was_enabled) hal.cpu.enableInterrupts();

    for (&irq_waiters) |*waiter| {
        if (waiter.* == thread_ptr) {
            waiter.* = null;
        }
    }
}

pub fn sys_wait_interrupt(irq: usize) SyscallError!usize {
    if (irq >= 16) return error.EINVAL;
    const irq_u8: u8 = @intCast(irq);

    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasInterruptCapability(irq_u8)) {
        return error.EPERM;
    }

    // SECURITY: Register exit callback to clear IRQ waiters on thread exit.
    // This prevents use-after-free when thread pointer becomes invalid.
    ensureExitCallbackRegistered();

    // Register generic callback if not already set
    // NOTE: This might be redundant to set every time, but idempotent.
    hal.interrupts.setGenericIrqHandler(irq_u8, irqHandlerCallback);

    // SECURITY: Disable interrupts to make check-and-set atomic.
    // This prevents:
    // 1. Race between two threads registering for same IRQ
    // 2. Lost wakeup if IRQ fires between registration and block()
    // The block() call atomically enables interrupts and halts.
    _ = hal.cpu.disableInterrupts();

    // Register self as waiter (atomic with interrupt disable)
    if (irq_waiters[irq_u8] != null) {
        hal.cpu.enableInterrupts();
        return error.EBUSY; // Another thread already waiting
    }
    irq_waiters[irq_u8] = current;

    // Block until IRQ - this atomically enables interrupts and halts.
    // When we return, interrupts are enabled and we were woken by the handler.
    sched.block();

    // Woken up by IRQ handler (which cleared irq_waiters[irq])
    return 0;
}
