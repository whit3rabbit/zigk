const std = @import("std");
const hal = @import("hal");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const context = @import("../context.zig");
const common = @import("common.zig");

const Controller = types.Controller;
const TransferError = common.TransferError;

/// Queue a bulk transfer
/// This is asynchronous - caller must poll completion or use events
/// Currently synchronous waiting is not implemented here due to one-off nature,
/// but will return the TRB physical address for tracking.
/// Real implementation should integrate with IoRequest/Reactor.
/// For now, we will wait synchronously like control transfers for basic testing.
pub fn queueBulkTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    ep_addr: u8,
    buffer: []u8,
) TransferError!usize {
    // Security: Validate endpoint address before calculating DCI
    const dci = context.InputContext.endpointToDci(ep_addr) orelse return error.InvalidParam;

    // Validate state (DCI 0 is invalid, DCI 1 is EP0 control)
    if (dci == 0 or dci >= 32) return error.InvalidParam;
    
    var ring_ptr = &(dev.endpoints[dci] orelse return error.InvalidState);

    // Get physical address of buffer
    const buf_phys = hal.paging.virtToPhys(@intFromPtr(buffer.ptr));

    // Security: Use checked conversion - TRB length field is 17 bits (max 131071)
    const trb_len: u17 = std.math.cast(u17, buffer.len) orelse return error.InvalidParam;

    // Build Normal TRB
    var normal = trb.NormalTrb.init(
        buf_phys,
        trb_len,
        .{ .ioc = true, .isp = true }, // IOC + ISP (Interrupt on Short Packet)
        ring_ptr.getCycleState(),
    );

    const trb_phys = ring_ptr.enqueueSingle(normal.asTrb().*) orelse return error.RingFull;

    // Start tracking for completion
    device.startPendingTransfer(trb_phys, dev.slot_id, dci);
    defer device.clearPendingTransfer();

    // Ring doorbell
    ctrl.ringDoorbell(dev.slot_id, dci);

    // Wait for completion (reuse control logic for now)
    const result = common.waitForCompletion(ctrl, dev, dci, 1000) catch |err| {
        return err;
    };

    const requested = buffer.len;
    const residual = result.residual;
    const transferred = if (residual <= requested) requested - residual else 0;

    return transferred;
}
