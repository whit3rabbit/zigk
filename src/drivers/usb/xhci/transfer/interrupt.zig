const std = @import("std");
const io = @import("io");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const transfer_pool = @import("../transfer_pool.zig");
const common = @import("common.zig");

const Controller = types.Controller;
const TransferError = common.TransferError;

/// Default interrupt transfer request length (boot protocol standard)
pub const DEFAULT_INTERRUPT_REQUEST_LEN: u17 = 8;

/// Queue an interrupt transfer for keyboard/mouse polling
/// This is asynchronous - completion is handled in the interrupt handler
/// Security: Zeros the report buffer before each transfer to prevent
/// information leaks from stale/uninitialized data.
/// @deprecated Use queueInterruptTransferForDci for multi-interface devices
pub fn queueInterruptTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
) TransferError!void {
    // Delegate to the DCI-aware version using the legacy interrupt_dci field
    return queueInterruptTransferForDci(ctrl, dev, dev.interrupt_dci);
}

/// Queue an interrupt transfer for a specific DCI (supports multi-interface devices)
/// This is asynchronous - completion is handled in the interrupt handler
/// Security: Zeros the report buffer before each transfer to prevent
/// information leaks from stale/uninitialized data.
pub fn queueInterruptTransferForDci(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    dci: u5,
) TransferError!void {
    if (dci == 0) return error.InvalidState;
    var int_ring = &(dev.endpoints[dci] orelse return error.InvalidState);

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

    // Ring doorbell for this specific DCI
    ctrl.ringDoorbell(dev.slot_id, dci);
}

// -----------------------------------------------------------------------------
// Async Interrupt Transfer (Dual Mode: Callback OR IoRequest)
// -----------------------------------------------------------------------------

/// Queue an async interrupt transfer with dual mode support
///
/// Mode selection via io_request parameter:
///
/// **Callback mode (io_request = null):**
///   - Uses device's internal report_buffer
///   - On completion: invokes HID callback via device_manager.handleInterrupt
///   - Kernel automatically re-queues for continuous polling
///   - Used by: Kernel HID driver for keyboard/mouse input
///
/// **IoRequest mode (io_request = non-null):**
///   - Uses caller-provided DMA buffer (buf_phys)
///   - On completion: completes IoRequest, does NOT re-queue
///   - Caller must resubmit for next report
///   - Used by: Userspace io_uring for direct HID access
///   - Enables applications to receive raw HID reports without kernel intervention
///
/// Security:
///   - For callback mode: zeros report_buffer before transfer
///   - For IoRequest mode: caller must zero-init buf_phys before call
///   - Validates DCI and device state
///
/// Example userspace io_uring flow:
///   1. Allocate DMA buffer and IoRequest
///   2. Zero the DMA buffer
///   3. Call queueInterruptTransferAsync() with IoRequest
///   4. Wait on IoRequest completion (or io_uring CQE)
///   5. Read HID report from DMA buffer
///   6. Optionally resubmit for next report
pub fn queueInterruptTransferAsync(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    dci: u5,
    buf_phys: ?u64,
    buf_len: ?usize,
    io_request: ?*io.IoRequest,
) TransferError!void {
    if (dci == 0) return error.InvalidState;

    // Validate device state
    if (dev.state == .err or dev.state == .disconnecting or dev.state == .disabled) {
        return error.InvalidState;
    }

    var int_ring = &(dev.endpoints[dci] orelse return error.InvalidState);

    // Determine mode based on io_request parameter
    if (io_request) |io_req| {
        // IoRequest mode: use caller-provided buffer, no re-queue on completion
        const phys = buf_phys orelse return error.InvalidParam;
        const len = buf_len orelse return error.InvalidParam;

        // Security: Use checked conversion - TRB length field is 17 bits
        const request_len: u17 = std.math.cast(u17, len) orelse return error.InvalidParam;

        // Get TRB physical address for tracking BEFORE enqueueing
        const trb_phys = int_ring.getEnqueuePhysAddr();

        // Allocate TransferRequest from pool (with io_request linked)
        const transfer_req = transfer_pool.allocRequest(
            dci,
            trb_phys,
            request_len,
            .{ .none = {} }, // No callback - IoRequest mode
            io_req,
        ) orelse return error.ResourceError;
        errdefer transfer_pool.freeRequest(transfer_req);

        // Build Normal TRB with IOC
        var normal = trb.NormalTrb.init(
            phys,
            request_len,
            .{ .ioc = true, .isp = true }, // IOC + ISP for short packet
            int_ring.getCycleState(),
        );

        _ = int_ring.enqueueSingle(normal.asTrb().*) orelse {
            transfer_pool.freeRequest(transfer_req);
            return error.RingFull;
        };

        // Transition TransferRequest to in_progress
        _ = transfer_req.compareAndSwapState(.pending, .in_progress);

        // Register pending transfer under device lock
        {
            const held = dev.device_lock.acquire();
            defer held.release();
            dev.registerPendingTransfer(dci, transfer_req);
        }

        // Transition IoRequest to in_progress
        _ = io_req.compareAndSwapState(.pending, .in_progress);

        // Set IoRequest metadata for tracing
        io_req.op_data = .{
            .usb = .{
                .slot_id = dev.slot_id,
                .dci = dci,
                .request_len = request_len,
                .buf_phys = phys,
            },
        };

        // Ring doorbell (non-blocking - IRQ will complete the transfer)
        ctrl.ringDoorbell(dev.slot_id, dci);
    } else {
        // Callback mode: use device's report_buffer, handled by legacy path
        // This path is equivalent to queueInterruptTransferForDci

        // Security: Zero the report buffer before each transfer
        @memset(dev.report_buffer, 0);

        const request_len: u17 = @min(
            DEFAULT_INTERRUPT_REQUEST_LEN,
            std.math.cast(u17, dev.report_buffer_len) orelse DEFAULT_INTERRUPT_REQUEST_LEN,
        );

        // Store request length for validation in completion handler
        dev.last_interrupt_request_len = request_len;

        var normal = trb.NormalTrb.init(
            dev.report_buffer_phys,
            request_len,
            .{ .ioc = true },
            int_ring.getCycleState(),
        );

        _ = int_ring.enqueueSingle(normal.asTrb().*) orelse return error.RingFull;

        // Ring doorbell - legacy path handles completion via getInterruptEventData
        ctrl.ringDoorbell(dev.slot_id, dci);
    }
}
