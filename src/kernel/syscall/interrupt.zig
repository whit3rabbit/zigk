const std = @import("std");
const uapi = @import("uapi");
const hal = @import("hal");
const sched = @import("sched");
const capabilities = @import("capabilities");

const SyscallError = uapi.errno.SyscallError;

// Wait queue for each IRQ (0-15)
// Tracks the thread waiting for a specific IRQ
var irq_waiters: [16]?*sched.Thread = [_]?*sched.Thread{null} ** 16;

// Generic IRQ handler callback
// Registered with HAL to be called from ISR context
fn irqHandlerCallback(irq: u8) void {
    if (irq >= 16) return;
    
    // Wake up waiting thread
    if (irq_waiters[irq]) |thread| {
        sched.unblock(thread);
        // Clear waiter? Or keep it for next time?
        // sys_wait_interrupt loops, so clearing is safer to prevent spurious wakeups?
        // But race condition if we clear it here vs thread waking up?
        // Thread is now Ready. It will run.
        // It should re-register itself.
        irq_waiters[irq] = null; 
    }
}

pub fn sys_wait_interrupt(irq: usize) SyscallError!usize {
    if (irq >= 16) return error.EINVAL;
    const irq_u8: u8 = @intCast(irq);

    const process = @import("process");
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasInterruptCapability(irq_u8)) {
        return error.EPERM;
    }

    // Register generic callback if not already set
    // NOTE: This might be redundant to set every time, but idempotent.
    hal.interrupts.setGenericIrqHandler(irq_u8, irqHandlerCallback);

    // Register self as waiter
    // TODO: Locking? sched lock protects thread state, but irq_waiters is global.
    // We should probably hold a lock, but for MVP atomic write is ok if single waiter.
    if (irq_waiters[irq_u8] != null) {
        return error.EBUSY; // Another thread already waiting
    }
    irq_waiters[irq_u8] = current;

    // Block until IRQ
    sched.block();
    
    // Woken up!
    // Check if we were woken by IRQ or something else?
    // irq_waiters[irq] should be null if woken by handler.
    
    return 0; 
}
