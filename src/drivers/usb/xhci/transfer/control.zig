const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const io = @import("io");

const types = @import("../types.zig");
const device = @import("../device.zig");
const trb = @import("../trb.zig");
const transfer_pool = @import("../transfer_pool.zig");
const common = @import("common.zig");
const usb_types = @import("../../types.zig");

// Forward declare Controller type (since we use *types.Controller)
const Controller = types.Controller;
const TransferError = common.TransferError;

/// Timeout for control transfers in milliseconds
/// Real hardware: 500ms (USB spec allows up to 5 seconds)
/// Emulators: 50ms (faster failure for non-responsive devices)
pub const CONTROL_TIMEOUT_MS: u32 = 500;
pub const CONTROL_TIMEOUT_MS_EMULATOR: u32 = 50;

/// Maximum retry count for transient errors
/// Reduced on emulators to speed up boot when devices don't respond
pub const MAX_RETRIES: u8 = 3;
pub const MAX_RETRIES_EMULATOR: u8 = 1;

/// Check if running on an emulator with potentially broken USB emulation
fn isEmulatorPlatform() bool {
    const hv = hal.hypervisor.getHypervisor();
    return hv == .qemu_tcg or hv == .unknown;
}

/// Get platform-appropriate timeout
pub fn getControlTimeout() u32 {
    const timeout = if (isEmulatorPlatform()) CONTROL_TIMEOUT_MS_EMULATOR else CONTROL_TIMEOUT_MS;
    return timeout;
}

/// Get platform-appropriate retry count
fn getMaxRetries() u8 {
    return if (isEmulatorPlatform()) MAX_RETRIES_EMULATOR else MAX_RETRIES;
}

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

    // Retry loop for transient errors (fewer retries on emulators for faster boot)
    var retries: u8 = getMaxRetries();
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

    console.err("XHCI: Control transfer failed after {} retries", .{getMaxRetries()});
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

    // Security: Pre-check ring space to prevent orphaned TRBs referencing freed DMA memory.
    // A control transfer needs: Setup TRB + optional Data TRB + Status TRB.
    // If we enqueue partially and then fail, orphaned TRBs remain in the ring.
    // When the next transfer rings the doorbell, the controller processes them,
    // potentially DMA'ing to/from freed physical memory.
    const required_slots: usize = if (has_data) 3 else 2;
    if (ep0_ring.ring.freeSlots() < required_slots) {
        return error.RingFull;
    }

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
        // SECURITY: Do NOT free DMA buffer on timeout - prevents Use-After-Free.
        //
        // When a control transfer times out, the TRBs are still queued in the
        // transfer ring. If we free the DMA buffer here, the xHCI controller may
        // still DMA to/from that memory when it eventually processes the TRBs.
        // This causes memory corruption if the page has been reallocated.
        //
        // Proper fix requires:
        // 1. Stop Endpoint command (xHCI 4.6.9) to halt EP0
        // 2. Set TR Dequeue Pointer command (xHCI 4.6.10) to skip orphaned TRBs
        // 3. Only then free the DMA buffer
        //
        // For now, we intentionally leak the page (1 page per timeout) to prevent
        // UAF. This is acceptable because timeouts should be rare in normal
        // operation and each leak is only 4KB.
        //
        // TODO: Implement proper transfer abort sequence with Stop Endpoint +
        // Set TR Dequeue Pointer commands.
        if (dma_page_phys) |_| {
            console.warn("XHCI: Control transfer timeout - DMA page leaked to prevent UAF", .{});
        }
        return err;
    };

    // Calculate bytes transferred
    // For IN transfers, residual tells us how many bytes were NOT transferred
    const requested = if (buffer) |b| b.len else 0;
    // Security: Explicit type conversion for safe subtraction
    const residual_usize: usize = @intCast(residual);
    const transferred = if (residual_usize <= requested) requested - residual_usize else 0;

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
/// Security: Uses waitForCommandCompletion to avoid racing with the interrupt
/// handler on the event ring. The interrupt handler signals completions via
/// atomic pending_cmd_valid flag, which waitForCommandCompletion checks first.
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

    // Security: Use the centralized command completion mechanism instead of
    // directly polling the event ring. This prevents race conditions where
    // both the interrupt handler and this function try to dequeue events.
    const result = ctrl.waitForCommandCompletion(10000) catch return error.Timeout;

    if (result.code != .Success) {
        return error.TransferFailed;
    }
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
        getControlTimeout(),
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
        getControlTimeout(),
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
        getControlTimeout(),
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
        getControlTimeout(),
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
        getControlTimeout(),
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
        getControlTimeout(),
    );
}

// -----------------------------------------------------------------------------
// Async Control Transfer (IoRequest-based)
// -----------------------------------------------------------------------------

/// Queue an asynchronous control transfer with IoRequest
/// Returns immediately - completion via IoRequest.complete()
///
/// Caller responsibilities:
///   1. Allocate IoRequest from kernel pool
///   2. For OUT transfers: copy data to buf_phys BEFORE calling
///   3. Call this function to queue the transfer
///   4. Wait on IoRequest.wait() or use io_uring for completion
///   5. For IN transfers: copy data from buf_phys AFTER completion
///   6. Free DMA buffer and IoRequest after completion
///
/// Security:
///   - buf_phys must be a valid DMA-capable physical address (from pmm)
///   - buf_len must fit in 17-bit TRB length field (max 131071)
///   - Device state is validated before queueing
pub fn controlTransferAsync(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    buf_phys: ?u64,
    buf_len: usize,
    io_request: *io.IoRequest,
) TransferError!void {
    // Validate device state
    if (dev.state == .err or dev.state == .disconnecting or dev.state == .disabled) {
        return error.InvalidState;
    }

    const ep0_ring = &(dev.endpoints[1] orelse return error.InvalidState);

    // Determine transfer type (direction of data stage)
    const is_in = (request_type & 0x80) != 0;
    const has_data = buf_phys != null and buf_len > 0;

    const trt: trb.SetupStageTrb.TransferType = if (!has_data)
        .no_data
    else if (is_in)
        .in
    else
        .out;

    // Security: Pre-check ring space to prevent orphaned TRBs referencing freed DMA memory.
    // A control transfer needs: Setup TRB + optional Data TRB + Status TRB.
    // If we enqueue partially and then fail, orphaned TRBs remain in the ring.
    // When the next transfer rings the doorbell, the controller processes them,
    // potentially DMA'ing to/from freed physical memory.
    const required_slots: usize = if (has_data) 3 else 2;
    if (ep0_ring.ring.freeSlots() < required_slots) {
        return error.RingFull;
    }

    // Security: Use checked conversion to prevent silent truncation
    const w_length: u16 = std.math.cast(u16, buf_len) orelse return error.InvalidParam;

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
    if (has_data) {
        // Security: Use checked conversion - TRB length field is 17 bits (max 131071)
        const trb_len: u17 = std.math.cast(u17, buf_len) orelse return error.InvalidParam;

        var data_trb = trb.DataStageTrb.init(
            buf_phys.?,
            trb_len,
            is_in,
            false, // IOC on data stage (we want it on status)
            false, // No chain
            ep0_ring.getCycleState(),
        );

        _ = ep0_ring.enqueueSingle(data_trb.asTrb().*) orelse return error.RingFull;
    }

    // Status Stage TRB (direction opposite to data stage)
    // For Device-to-Host: Status is OUT (host sends ZLP)
    // For Host-to-Device or No-Data: Status is IN (device sends ZLP)
    const status_dir = if (has_data and is_in) false else true;

    // Get TRB physical address for tracking BEFORE enqueueing
    const status_trb_phys = ep0_ring.getEnqueuePhysAddr();

    var status_trb = trb.StatusStageTrb.init(
        status_dir,
        true, // IOC - Interrupt On Completion
        ep0_ring.getCycleState(),
    );

    // Allocate TransferRequest from pool (with io_request linked)
    // EP0 DCI = 1
    // Security: @truncate is safe here because w_length check (line 464) already
    // validated buf_len <= 65535 (u16 max), which fits in u24 request_len field.
    const transfer_req = transfer_pool.allocRequest(
        1, // EP0 DCI
        status_trb_phys,
        @truncate(buf_len),
        .{ .none = {} }, // No callback for async - use IoRequest
        io_request,
    ) orelse return error.ResourceError;
    errdefer transfer_pool.freeRequest(transfer_req);

    // Enqueue Status TRB
    _ = ep0_ring.enqueueSingle(status_trb.asTrb().*) orelse {
        transfer_pool.freeRequest(transfer_req);
        return error.RingFull;
    };

    // Transition TransferRequest to in_progress
    _ = transfer_req.compareAndSwapState(.pending, .in_progress);

    // Register pending transfer under device lock
    {
        const held = dev.device_lock.acquire();
        defer held.release();
        dev.registerPendingTransfer(1, transfer_req); // EP0 DCI = 1
    }

    // Transition IoRequest to in_progress
    _ = io_request.compareAndSwapState(.pending, .in_progress);

    // Set IoRequest metadata for tracing
    // Security: @truncate is safe - buf_len already validated to fit in u16 (line 464)
    io_request.op_data = .{
        .usb = .{
            .slot_id = dev.slot_id,
            .dci = 1, // EP0 DCI
            .request_len = @truncate(buf_len),
            .buf_phys = buf_phys orelse 0,
        },
    };

    // Ring doorbell (non-blocking - IRQ will complete the transfer)
    ctrl.ringDoorbell(dev.slot_id, 1); // EP0 DCI = 1
}
