//! E1000e Worker Thread and Interrupt Handling

const std = @import("std");
const hal = @import("hal");
const thread = @import("thread");
const sched = @import("sched");
const console = @import("console");

const types = @import("types.zig");
const regs = @import("regs.zig");
const rx = @import("rx.zig");

const E1000e = types.E1000e;
const mmio = hal.mmio;

/// Default RX callback (just logs packets for now)
fn defaultRxCallback(data: []u8) void {
    _ = data;
    // Placeholder - real implementation would pass to network stack
}

/// Static worker entry point
/// Runs workerLoop then exits cleanly so deinit() can join the thread.
pub fn workerEntry(ctx: ?*anyopaque) callconv(.c) void {
    console.info("E1000e: Worker thread started", .{});
    if (ctx) |ptr| {
        const driver: *E1000e = @ptrCast(@alignCast(ptr));
        console.info("E1000e: Worker thread entering loop with driver={*}", .{driver});

        // Now we can safely call the member function because we have the correct self pointer
        workerLoop(driver);
    } else {
        console.err("E1000e: Worker thread failed to get driver context!", .{});
    }
    // Worker thread finished - call scheduler exit to mark thread as Zombie.
    // This allows deinit() to join (wait for Zombie state) before freeing resources.
    console.info("E1000e: Worker thread exiting", .{});
    sched.exit();
}

/// Worker thread loop (NAPI-style polling)
pub fn workerLoop(driver: *E1000e) void {
    const BATCH_LIMIT = 64;

    while (!@atomicLoad(bool, &driver.shutdown_requested, .acquire)) {
        // Atomic load prevents torn pointer read if setRxCallback() called concurrently
        const cb = @atomicLoad(?*const fn ([]u8) void, &driver.rx_callback, .acquire) orelse &defaultRxCallback;

        // Process a batch of packets
        const processed = rx.processRxLimited(driver, cb, BATCH_LIMIT);

        if (processed < BATCH_LIMIT) {
            // We drained the ring (or close to it).
            // Use NAPI-style: re-enable interrupts BEFORE checking for work.
            // This closes the race window where packets could arrive between
            // the hasPackets() check and the block() call.

            const flags = hal.cpu.disableInterruptsSaveFlags();

            // Re-enable RX interrupts FIRST (before checking for packets).
            // This ensures any packets arriving NOW will trigger an interrupt
            // that will unblock us if we decide to block.
            driver.regs.write(.ims, regs.INT.RXT0 | regs.INT.RXDMT0);

            // Memory barrier to ensure IMS write completes before checking state.
            // On x86 this is sfence which orders stores.
            mmio.writeBarrier();

            // Now check if we should block.
            // If packets arrived after IMS write, hasPackets() will return true.
            // If packets arrive after this check, the interrupt will fire and unblock us.
            if (!rx.hasPackets(driver) and !@atomicLoad(bool, &driver.shutdown_requested, .acquire)) {
                sched.block();
            }
            hal.cpu.restoreInterrupts(flags);
        } else {
            // We hit the batch limit, there might be more packets.
            // Yield to scheduler to allow other threads to run, but keep polling.
            sched.yield();
        }
    }
    // Worker thread is exiting - will be joined by deinit()
}

/// Handle interrupt from NIC (similar to Linux e1000_intr)
pub fn handleIrq(driver: *E1000e) void {
    // Read ICR to get interrupt cause and clear pending interrupt.
    // Reading ICR is atomic with clearing on 82574L.
    const icr = regs.InterruptCause.fromRaw(driver.regs.read(.icr));

    if (icr.hasRxInterrupt()) {
        // RX interrupt - transition to polling mode
        //
        // Mask RX interrupts (IMC = Interrupt Mask Clear) to prevent
        // further interrupts while we're polling. The worker thread
        // will re-enable them via IMS after draining the RX queue.
        //
        // This is the core of NAPI: interrupt to wake, poll to drain,
        // re-enable when done.
        driver.regs.write(.imc, regs.INT.RXT0 | regs.INT.RXDMT0);

        // Wake the worker thread to process received packets
        if (driver.worker_thread) |t| {
            sched.unblock(t);
        }
    }

    if (icr.link_status_change) {
        // Link status change - log new link state
        // This handles cable plug/unplug and auto-negotiation completion
        handleLinkChange(driver);
    }
}

/// Handle link status change - decode and log speed/duplex
fn handleLinkChange(driver: *E1000e) void {
    const status = driver.regs.read(.status);
    const link_up = (status & regs.STATUS.LU) != 0;

    if (link_up) {
        const duplex: []const u8 = if ((status & regs.STATUS.FD) != 0) "Full" else "Half";
        const speed_bits = (status & regs.STATUS.SPEED_MASK) >> regs.STATUS.SPEED_SHIFT;
        const speed: []const u8 = switch (speed_bits) {
            0 => "10",
            1 => "100",
            2 => "1000",
            else => "?",
        };
        console.info("E1000e: Link UP - {s}Mbps {s} Duplex", .{ speed, duplex });
    } else {
        console.info("E1000e: Link DOWN", .{});
    }
}
