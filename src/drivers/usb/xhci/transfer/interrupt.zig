const std = @import("std");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const common = @import("common.zig");

const Controller = types.Controller;
const TransferError = common.TransferError;

/// Default interrupt transfer request length (boot protocol standard)
pub const DEFAULT_INTERRUPT_REQUEST_LEN: u17 = 8;

/// Queue an interrupt transfer for keyboard/mouse polling
/// This is asynchronous - completion is handled in the interrupt handler
/// Security: Zeros the report buffer before each transfer to prevent
/// information leaks from stale/uninitialized data.
pub fn queueInterruptTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
) TransferError!void {
    const int_dci = dev.interrupt_dci;
    if (int_dci == 0) return error.InvalidState;
    var int_ring = &(dev.endpoints[int_dci] orelse return error.InvalidState);

    // Security: Zero the report buffer before each transfer to prevent
    // stale data from being processed if hardware returns unexpected residual.
    // This is critical because the interrupt handler uses the residual to
    // calculate actual_transferred, and stale data could be misinterpreted.
    @memset(dev.report_buffer, 0);

    // Use the configured report buffer length, capped at default for safety.
    // Boot keyboard/mouse use 8 bytes; short packet events handle smaller reports.
    const request_len: u17 = @min(
        DEFAULT_INTERRUPT_REQUEST_LEN,
        std.math.cast(u17, dev.report_buffer_len) orelse DEFAULT_INTERRUPT_REQUEST_LEN,
    );

    // Security: Store the request length for validation in completion handler
    // This prevents using a hardcoded constant that could diverge from actual queued length
    dev.last_interrupt_request_len = request_len;

    var normal = trb.NormalTrb.init(
        dev.report_buffer_phys,
        request_len,
        .{ .ioc = true }, // Interrupt on completion
        int_ring.getCycleState(),
    );

    _ = int_ring.enqueueSingle(normal.asTrb().*) orelse return error.RingFull;

    // Ring doorbell for interrupt endpoint
    ctrl.ringDoorbell(dev.slot_id, dev.interrupt_dci);
}
