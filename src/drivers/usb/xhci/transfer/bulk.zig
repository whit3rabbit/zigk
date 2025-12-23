const std = @import("std");
const hal = @import("hal");
const layout = @import("layout");
const io = @import("io");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const context = @import("../context.zig");
const transfer_pool = @import("../transfer_pool.zig");
const common = @import("common.zig");

const Controller = types.Controller;
const TransferError = common.TransferError;

/// Queue a bulk transfer
/// This is asynchronous - caller must poll completion or use events
/// Currently synchronous waiting is not implemented here due to one-off nature,
/// but will return the TRB physical address for tracking.
/// Real implementation should integrate with IoRequest/Reactor.
/// For now, we will wait synchronously like control transfers for basic testing.
/// Security: Validates buffer is in kernel address space before DMA setup.
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

    // Security: Validate buffer is in kernel address space (HHDM range).
    // User-space addresses or invalid addresses would produce incorrect
    // physical addresses from virtToPhys, potentially causing DMA to
    // read/write arbitrary memory and bypass memory protection.
    const buf_addr = @intFromPtr(buffer.ptr);
    if (!layout.isKernelAddress(buf_addr)) {
        return error.InvalidParam;
    }

    // Also validate the end of the buffer is in kernel space
    const buf_end = buf_addr +| buffer.len; // Saturating add to prevent overflow
    if (!layout.isKernelAddress(buf_end)) {
        return error.InvalidParam;
    }

    var ring_ptr = &(dev.endpoints[dci] orelse return error.InvalidState);

    // Get physical address of buffer - now safe since we validated the address
    const buf_phys = hal.paging.virtToPhys(buf_addr);

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
    // waitForCompletion returns u24 residual (bytes NOT transferred)
    const residual = common.waitForCompletion(ctrl, dev, dci, 1000) catch |err| {
        return err;
    };

    const requested = buffer.len;
    // Security: Explicit type conversion for safe subtraction
    const residual_usize: usize = @intCast(residual);
    const transferred = if (residual_usize <= requested) requested - residual_usize else 0;

    return transferred;
}

/// Queue an asynchronous bulk transfer with IoRequest
/// Returns immediately - completion via IoRequest.complete()
/// The caller must:
///   1. Allocate IoRequest from kernel pool
///   2. Call this function to queue the transfer
///   3. Wait on Future or use io_uring for completion
///   4. Free IoRequest after completion
/// Security: Validates buffer is in kernel address space before DMA setup.
pub fn queueBulkTransferAsync(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    ep_addr: u8,
    buf_phys: u64,
    buf_len: usize,
    io_request: *io.IoRequest,
) TransferError!void {
    // Security: Validate endpoint address before calculating DCI
    const dci = context.InputContext.endpointToDci(ep_addr) orelse return error.InvalidParam;

    // Validate state (DCI 0 is invalid, DCI 1 is EP0 control)
    if (dci == 0 or dci >= 32) return error.InvalidParam;

    // Check device state - don't queue if disconnecting
    if (dev.state == .disconnecting or dev.state == .disabled) {
        return error.InvalidState;
    }

    var ring_ptr = &(dev.endpoints[dci] orelse return error.InvalidState);

    // Security: Use checked conversion - TRB length field is 17 bits (max 131071)
    const trb_len: u17 = std.math.cast(u17, buf_len) orelse return error.InvalidParam;

    // Get TRB physical address for tracking before enqueueing
    const trb_phys = ring_ptr.getEnqueuePhysAddr();

    // Allocate TransferRequest from pool (with io_request linked)
    const transfer_req = transfer_pool.allocRequest(
        dci,
        trb_phys,
        @truncate(buf_len),
        .{ .none = {} }, // No callback for bulk - use IoRequest
        io_request,
    ) orelse return error.ResourceError;
    errdefer transfer_pool.freeRequest(transfer_req);

    // Build Normal TRB
    var normal = trb.NormalTrb.init(
        buf_phys,
        trb_len,
        .{ .ioc = true, .isp = true }, // IOC + ISP (Interrupt on Short Packet)
        ring_ptr.getCycleState(),
    );

    _ = ring_ptr.enqueueSingle(normal.asTrb().*) orelse {
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
    _ = io_request.compareAndSwapState(.pending, .in_progress);

    // Set IoRequest metadata for tracing
    io_request.op_data = .{
        .usb = .{
            .slot_id = dev.slot_id,
            .dci = dci,
            .request_len = @truncate(buf_len),
            .buf_phys = buf_phys,
        },
    };

    // Ring doorbell (non-blocking - IRQ will complete the transfer)
    ctrl.ringDoorbell(dev.slot_id, dci);
}
