const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const common = @import("common.zig");
const usb_types = @import("../../types.zig");

// Forward declare Controller type (since we use *types.Controller)
const Controller = types.Controller;
const TransferError = common.TransferError;

/// Timeout for control transfers in milliseconds
pub const CONTROL_TIMEOUT_MS: u32 = 500;

/// Maximum retry count for transient errors
pub const MAX_RETRIES: u8 = 3;

/// Perform a USB control transfer
/// Returns number of bytes transferred in data stage, or error
pub fn controlTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    buffer: ?[]u8,
    timeout_ms: u32,
) TransferError!usize {
    // Validate device state
    if (dev.state == .err) {
        return error.InvalidState;
    }

    // Retry loop for transient errors
    var retries: u8 = MAX_RETRIES;
    while (retries > 0) : (retries -= 1) {
        const result = doControlTransfer(ctrl, dev, request_type, request, value, index, buffer, timeout_ms) catch |err| {
            switch (err) {
                error.Timeout => {
                    console.warn("XHCI: Control transfer timeout, {} retries left", .{retries - 1});
                    continue;
                },
                error.StallError => {
                    console.warn("XHCI: Control transfer stalled, resetting EP0", .{});
                    resetEndpoint(ctrl, dev, 1) catch {}; // EP0 DCI = 1
                    continue;
                },
                else => return err,
            }
        };
        return result;
    }

    console.err("XHCI: Control transfer failed after {} retries", .{MAX_RETRIES});
    return error.TransferFailed;
}

/// Internal control transfer implementation (single attempt)
fn doControlTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    buffer: ?[]u8,
    timeout_ms: u32,
) TransferError!usize {
    const ep0_ring = &(dev.endpoints[1] orelse return error.InvalidState);

    // Determine transfer type (direction of data stage)
    const is_in = (request_type & 0x80) != 0;
    const has_data = buffer != null and buffer.?.len > 0;

    const trt: trb.SetupStageTrb.TransferType = if (!has_data)
        .no_data
    else if (is_in)
        .in
    else
        .out;

    // Build Setup Stage TRB
    // Security: Use checked conversion to prevent silent truncation of large buffers
    const w_length: u16 = if (buffer) |b|
        std.math.cast(u16, b.len) orelse return error.InvalidParam
    else
        0;

    const setup_data = trb.SetupData{
        .bm_request_type = request_type,
        .b_request = request,
        .w_value = value,
        .w_index = index,
        .w_length = w_length,
    };

    var setup_trb = trb.SetupStageTrb.init(
        setup_data,
        trt,
        ep0_ring.getCycleState(),
    );

    // Queue Setup TRB
    _ = ep0_ring.enqueueSingle(setup_trb.asTrb().*) orelse return error.RingFull;

    // Data Stage TRB (if needed)
    // For DMA, we need a buffer in HHDM range. Stack buffers are NOT in HHDM.
    // Allocate a DMA-safe page and copy data to/from it.
    var data_trb_phys: u64 = 0;
    var dma_page_phys: ?u64 = null;
    var dma_buf: ?[*]u8 = null;

    if (has_data) {
        const buf = buffer.?;
        // Security: Use checked conversion - TRB length field is 17 bits (max 131071)
        const trb_len: u17 = std.math.cast(u17, buf.len) orelse return error.InvalidParam;

        // Allocate DMA-safe page for data transfer
        dma_page_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const buf_phys = dma_page_phys.?;
        dma_buf = hal.paging.physToVirt(buf_phys);

        // For OUT transfers, copy data to DMA buffer before transfer
        if (!is_in) {
            @memcpy(dma_buf.?[0..buf.len], buf);
        }

        var data_trb = trb.DataStageTrb.init(
            buf_phys,
            trb_len,
            is_in,
            false, // IOC on data stage
            false, // No chain
            ep0_ring.getCycleState(),
        );

        data_trb_phys = ep0_ring.enqueueSingle(data_trb.asTrb().*) orelse {
            pmm.freePages(dma_page_phys.?, 1);
            return error.RingFull;
        };
    }

    // Status Stage TRB (direction opposite to data stage)
    // For Device-to-Host: Status is OUT (host sends ZLP)
    // For Host-to-Device or No-Data: Status is IN (device sends ZLP)
    const status_dir = if (has_data and is_in) false else true;

    var status_trb = trb.StatusStageTrb.init(
        status_dir,
        true, // IOC - Interrupt On Completion
        ep0_ring.getCycleState(),
    );

    const status_trb_phys = ep0_ring.enqueueSingle(status_trb.asTrb().*) orelse {
        if (dma_page_phys) |phys| pmm.freePages(phys, 1);
        return error.RingFull;
    };

    // Mark pending transfer for event matching
    device.startPendingTransfer(status_trb_phys, dev.slot_id, 1); // EP0 DCI = 1
    defer device.clearPendingTransfer();

    // Ring doorbell to start transfer
    ctrl.ringDoorbell(dev.slot_id, 1); // EP0 DCI = 1

    // Wait for completion
    const residual = common.waitForCompletion(ctrl, dev, 1, timeout_ms) catch |err| {
        if (dma_page_phys) |phys| pmm.freePages(phys, 1);
        return err;
    };

    // Calculate bytes transferred
    // For IN transfers, residual tells us how many bytes were NOT transferred
    const requested = if (buffer) |b| b.len else 0;
    const transferred = if (residual <= requested) requested - residual else 0;

    // For IN transfers, copy data from DMA buffer back to user buffer
    if (has_data and is_in and dma_buf != null and buffer != null) {
        @memcpy(buffer.?[0..transferred], dma_buf.?[0..transferred]);
    }

    // Free DMA page
    if (dma_page_phys) |phys| {
        pmm.freePages(phys, 1);
    }

    return transferred;
}

/// Reset an endpoint that has stalled
fn resetEndpoint(ctrl: *Controller, dev: *device.UsbDevice, ep_dci: u5) !void {
    // Build Reset Endpoint command TRB
    var reset_cmd = trb.ResetEndpointCmdTrb.init(
        dev.slot_id,
        ep_dci,
        false, // Don't preserve transfer state
        ctrl.command_ring.getCycleState(),
    );

    // Enqueue command
    _ = ctrl.command_ring.enqueue(reset_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    // Ring command doorbell
    ctrl.ringDoorbell(0, 0);

    // Wait for command completion (short timeout)
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        if (ctrl.event_ring.hasPending()) {
            const event = ctrl.event_ring.dequeue() orelse continue;
            // Note: In refined model we should use event handler, but here we peek/consume synchronously
            // which steals from main handler if strict. But resetEndpoint is rare.
            // For robust design, we should ideally use a command completion waiter.
            // But preserving existing logic for now.
             
             // Wait: `ctrl.event_ring.dequeue` consumes it. If it's NOT our command completion, we act as if we lost it?
             // Yes, this is a limitation of the current simple synchronous logic. 
             // Ideally we should integrate with the event loop.
             // Given this is a refactor, I won't rewrite the async engine yet.
            const completion = trb.CommandCompletionEventTrb.fromTrb(event);
            ctrl.updateErdp();
            
            if (completion.status.completion_code == .Success) {
                return;
            }
        }
        hal.cpu.stall(10);
    }
    return error.Timeout;
}

// -----------------------------------------------------------------------------
// Standard Request Helpers
// -----------------------------------------------------------------------------

/// GET_DESCRIPTOR request for device descriptor
pub fn getDeviceDescriptor(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    buffer: []u8,
) TransferError!usize {
    if (buffer.len < 8) return error.InvalidParam;

    const request_type = usb_types.makeRequestType(
        .device_to_host,
        .standard,
        .device,
    );

    return controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        usb_types.Request.GET_DESCRIPTOR,
        usb_types.descriptorValue(usb_types.DescriptorType.DEVICE, 0),
        0,
        buffer,
        CONTROL_TIMEOUT_MS,
    );
}

/// GET_DESCRIPTOR request for configuration descriptor
pub fn getConfigDescriptor(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    index: u8,
    buffer: []u8,
) TransferError!usize {
    if (buffer.len < 9) return error.InvalidParam;

    const request_type = usb_types.makeRequestType(
        .device_to_host,
        .standard,
        .device,
    );

    return controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        usb_types.Request.GET_DESCRIPTOR,
        usb_types.descriptorValue(usb_types.DescriptorType.CONFIGURATION, index),
        0,
        buffer,
        CONTROL_TIMEOUT_MS,
    );
}

/// GET_DESCRIPTOR request for HID report descriptor
pub fn getReportDescriptor(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    iface: u8,
    buffer: []u8,
) TransferError!usize {
    if (buffer.len < 1) return error.InvalidParam;

    const request_type = usb_types.makeRequestType(
        .device_to_host,
        .standard,
        .interface,
    );

    const wValue: u16 = 0x2200; // Report descriptor type

    return controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        usb_types.Request.GET_DESCRIPTOR,
        wValue,
        @as(u16, iface),
        buffer,
        CONTROL_TIMEOUT_MS,
    );
}

/// SET_CONFIGURATION request
pub fn setConfiguration(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    config_value: u8,
) TransferError!void {
    const request_type = usb_types.makeRequestType(
        .host_to_device,
        .standard,
        .device,
    );

    _ = try controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        usb_types.Request.SET_CONFIGURATION,
        @as(u16, config_value),
        0,
        null,
        CONTROL_TIMEOUT_MS,
    );
}

/// SET_PROTOCOL request for HID devices
pub fn setProtocol(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    interface: u8,
    protocol: u8,
) TransferError!void {
    const request_type = usb_types.makeRequestType(
        .host_to_device,
        .class,
        .interface,
    );

    const HID_SET_PROTOCOL: u8 = 0x0B;

    _ = try controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        HID_SET_PROTOCOL,
        @as(u16, protocol),
        @as(u16, interface),
        null,
        CONTROL_TIMEOUT_MS,
    );
}

/// SET_IDLE request for HID devices
pub fn setIdle(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    interface: u8,
    duration: u8,
    report_id: u8,
) TransferError!void {
    const request_type = usb_types.makeRequestType(
        .host_to_device,
        .class,
        .interface,
    );

    const HID_SET_IDLE: u8 = 0x0A;

    _ = try controlTransfer(
        ctrl,
        dev,
        @bitCast(request_type),
        HID_SET_IDLE,
        (@as(u16, duration) << 8) | @as(u16, report_id),
        @as(u16, interface),
        null,
        CONTROL_TIMEOUT_MS,
    );
}
