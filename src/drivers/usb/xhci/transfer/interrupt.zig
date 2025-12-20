const std = @import("std");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const common = @import("common.zig");

const Controller = types.Controller;
const TransferError = common.TransferError;

/// Queue an interrupt transfer for keyboard/mouse polling
/// This is asynchronous - completion is handled in the interrupt handler
pub fn queueInterruptTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
) TransferError!void {
    const int_dci = dev.interrupt_dci;
    if (int_dci == 0) return error.InvalidState;
    var int_ring = &(dev.endpoints[int_dci] orelse return error.InvalidState);

    // Build Normal TRB for interrupt transfer
    // Use device.max_packet_size for the read length?
    // Or hardcoded 8 for boot keyboard?
    // The original code used 8. But mouse might be less.
    // However, USB transfers can be larger and device sends short packet.
    // dev.report_buffer_len is 64.
    // Let's use 8 for compatibility with old code, or dev.max_packet_size?
    // Old code line 499: `8`.
    // Let's stick to 8. But mouse report is smaller. interrupt transfer of 8 bytes is standard for boot keyboard.
    // For Mouse, report size is 3-8 bytes.
    // If we request 8 and get 4, it's a Short Packet event, which is fine.
    
    var normal = trb.NormalTrb.init(
        dev.report_buffer_phys,
        8, 
        .{ .ioc = true }, // Interrupt on completion
        int_ring.getCycleState(),
    );

    _ = int_ring.enqueueSingle(normal.asTrb().*) orelse return error.RingFull;

    // Ring doorbell for interrupt endpoint
    ctrl.ringDoorbell(dev.slot_id, dev.interrupt_dci);
}
