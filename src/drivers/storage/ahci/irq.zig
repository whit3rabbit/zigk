// AHCI Interrupt Handling
//
// Provides interrupt handling for AHCI controllers.
// Extracted from root.zig for better modularity.

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const io = @import("io");
const sync = @import("sync");

const hba = @import("hba.zig");
const port = @import("port.zig");
const command = @import("command.zig");

pub const SECTOR_SIZE: usize = 512;

/// Port context needed for interrupt handling
/// Mirrors the fields from AhciPort that IRQ handling needs
pub const PortIrqContext = struct {
    base: u64,
    active: bool,
    cmd_list_virt: u64,
    pending_requests: *[32]?*io.IoRequest,
    commands_issued: *u32,
    pending_lock: *sync.Spinlock,
    last_is: *std.atomic.Value(u32),
};

/// Handle AHCI interrupt - processes all ports with pending interrupts
/// Returns true if any port had pending work
pub fn handleControllerInterrupt(
    hba_base: u64,
    ports: []PortIrqContext,
) bool {
    // Read and clear global interrupt status
    const is = hba.readInterruptStatus(hba_base);
    if (is == 0) return false;

    // Clear the bits we're handling
    hba.clearInterruptStatus(hba_base, is);

    var handled = false;

    // Process each port that has an interrupt pending
    var port_mask = is;
    while (port_mask != 0) {
        const port_num: u5 = @intCast(@ctz(port_mask));
        port_mask &= ~(@as(u32, 1) << port_num);

        if (port_num < ports.len) {
            handlePortInterrupt(&ports[port_num]);
            handled = true;
        }
    }

    return handled;
}

/// Handle interrupt for a specific port
pub fn handlePortInterrupt(p: *PortIrqContext) void {
    if (!p.active) return;

    // Read and clear port interrupt status
    const pis = port.readIs(p.base);
    port.clearIs(p.base, pis);

    // Accumulate status for sync commands
    _ = p.last_is.fetchOr(@as(u32, @bitCast(pis)), .acq_rel);

    // Check which commands completed
    const ci = port.readCi(p.base);

    // Commands that were issued but are no longer in CI have completed
    const completed = p.commands_issued.* & ~ci;

    if (completed == 0) return;

    // Check for global error conditions
    const tfd = port.readTfd(p.base);
    const port_has_error = tfd.hasError() or pis.hasError();

    // Get command list for PRDBC verification
    const cmd_list: *command.CommandList = @ptrFromInt(p.cmd_list_virt);

    // Complete each finished command's request with per-slot validation
    var slot_mask = completed;
    while (slot_mask != 0) {
        const slot: u5 = @intCast(@ctz(slot_mask));
        slot_mask &= ~(@as(u32, 1) << slot);

        // Get and clear pending request under lock
        var req: ?*io.IoRequest = null;
        {
            const held = p.pending_lock.acquire();
            defer held.release();

            req = p.pending_requests[slot];
            p.pending_requests[slot] = null;
            p.commands_issued.* &= ~(@as(u32, 1) << slot);
        }

        // Complete the IoRequest
        if (req) |request| {
            // Per-slot validation: check PRDBC (actual bytes transferred)
            const expected_bytes = @as(usize, request.op_data.disk.sector_count) * SECTOR_SIZE;
            const actual_bytes = cmd_list[slot].prdbc;

            // Determine if this specific slot had an error:
            // - Port-level error AND this was the only command = slot errored
            // - Transfer incomplete (PRDBC < expected) = slot errored
            // - Otherwise = successful
            const slot_error = port_has_error or (actual_bytes < expected_bytes);

            if (slot_error) {
                _ = request.complete(.{ .err = error.EIO });
            } else {
                // Success - return verified bytes transferred
                // Cap at expected bytes for safety (don't trust device overreporting)
                const verified_bytes: usize = if (actual_bytes > expected_bytes)
                    expected_bytes
                else
                    @intCast(actual_bytes);
                _ = request.complete(.{ .success = verified_bytes });
            }
        }
    }
}

/// Register AHCI IRQ handler with the interrupt system
/// Returns true if registration succeeded
pub fn registerHandler(
    hba_base: u64,
    irq_line: u8,
    handler: hal.interrupts.InterruptHandler,
    context: ?*anyopaque,
) bool {
    if (irq_line == 0 or irq_line == 255) {
        console.warn("AHCI: No valid IRQ line configured", .{});
        return false;
    }

    // IRQ line + PIC offset (typically 32 for hardware IRQs)
    const vector = irq_line + 32;

    // Register with interrupt system
    hal.interrupts.registerHandler(vector, handler, context);

    // Enable global HBA interrupts
    var ghc = hba.readGhc(hba_base);
    ghc.ie = true;
    hba.writeGhc(hba_base, ghc);

    console.info("AHCI: IRQ handler registered on vector {d}", .{vector});
    return true;
}
