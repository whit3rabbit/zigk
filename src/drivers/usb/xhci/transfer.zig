// XHCI Transfer Operations
//
// Implements USB transfers using XHCI Transfer Rings:
//   - Control transfers (Setup + Data + Status stages)
//   - Interrupt transfers (for HID polling)
//
// Control transfers are synchronous - we queue TRBs and poll for completion.
// Interrupt transfers are asynchronous - completion triggers HID handler.
//
// Reference: xHCI Specification 1.2, Chapter 4.11

const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");

const trb = @import("trb.zig");
const ring = @import("ring.zig");
const context = @import("context.zig");
const device = @import("device.zig");
const usb_types = @import("../types.zig");

// Forward declare Controller type (defined in root.zig)
const Controller = @import("root.zig").Controller;

// =============================================================================
// Transfer Errors
// =============================================================================

pub const TransferError = error{
    /// Transfer timed out waiting for completion
    Timeout,
    /// Device returned STALL (protocol error)
    Stall,
    /// Data buffer error
    DataBuffer,
    /// Babble detected (device sent too much data)
    Babble,
    /// USB transaction error
    Transaction,
    /// TRB error
    TrbError,
    /// Ring is full
    RingFull,
    /// No pending transfer to complete
    NoPending,
    /// Transfer failed after retries
    TransferFailed,
    /// Out of memory
    OutOfMemory,
    /// Invalid parameter
    InvalidParam,
    /// Device not in correct state
    InvalidState,
    /// Short packet received
    ShortPacket,
};

// =============================================================================
// Control Transfer
// =============================================================================

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
                error.Stall => {
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
    const setup_data = trb.SetupData{
        .bm_request_type = request_type,
        .b_request = request,
        .w_value = value,
        .w_index = index,
        .w_length = if (buffer) |b| @truncate(b.len) else 0,
    };

    var setup_trb = trb.SetupStageTrb.init(
        setup_data,
        trt,
        ep0_ring.getCycleState(),
    );

    // Queue Setup TRB
    _ = ep0_ring.enqueueSingle(setup_trb.asTrb().*) orelse return error.RingFull;

    // Data Stage TRB (if needed)
    var data_trb_phys: u64 = 0;
    if (has_data) {
        const buf = buffer.?;
        // Get physical address of buffer
        // Note: buffer must be in kernel memory (not user space)
        const buf_phys = hal.paging.virtToPhys(@intFromPtr(buf.ptr));

        var data_trb = trb.DataStageTrb.init(
            buf_phys,
            @truncate(buf.len),
            is_in,
            false, // IOC on data stage
            false, // No chain
            ep0_ring.getCycleState(),
        );

        data_trb_phys = ep0_ring.enqueueSingle(data_trb.asTrb().*) orelse return error.RingFull;
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

    const status_trb_phys = ep0_ring.enqueueSingle(status_trb.asTrb().*) orelse return error.RingFull;

    // Mark pending transfer for event matching
    device.startPendingTransfer(status_trb_phys, dev.slot_id, 1); // EP0 DCI = 1
    defer device.clearPendingTransfer();

    // Ring doorbell to start transfer
    ctrl.ringDoorbell(dev.slot_id, 1); // EP0 DCI = 1

    // Wait for completion
    const result = waitForCompletion(ctrl, dev.slot_id, 1, timeout_ms) catch |err| {
        return err;
    };

    // Calculate bytes transferred
    // For IN transfers, residual tells us how many bytes were NOT transferred
    const requested = if (buffer) |b| b.len else 0;
    const residual = result.residual;
    const transferred = if (residual <= requested) requested - residual else 0;

    return transferred;
}

/// Wait for a transfer to complete
fn waitForCompletion(
    ctrl: *Controller,
    slot_id: u8,
    ep_dci: u5,
    timeout_ms: u32,
) TransferError!struct { code: trb.CompletionCode, residual: usize } {
    // Calculate deadline using busy-wait loop count
    // Approximately 1ms per 1000 iterations with pause
    const iterations_per_ms: u32 = 1000;
    var remaining = timeout_ms * iterations_per_ms;

    while (remaining > 0) : (remaining -= 1) {
        // Check event ring for completion
        while (ctrl.event_ring.hasPending()) {
            const event = ctrl.event_ring.dequeue() orelse break;
            const event_type = ring.getTrbType(event);

            if (event_type == .TransferEvent) {
                const transfer_evt = trb.TransferEventTrb.fromTrb(event);

                // Check if this event is for our transfer
                if (transfer_evt.control.slot_id == slot_id and
                    transfer_evt.control.ep_id == ep_dci)
                {
                    const code = transfer_evt.status.completion_code;
                    const residual = transfer_evt.status.trb_transfer_length;

                    // Update ERDP
                    ctrl.updateErdp();

                    // Check completion code
                    return switch (code) {
                        .Success => .{ .code = code, .residual = residual },
                        .ShortPacket => .{ .code = code, .residual = residual },
                        .StallError => error.Stall,
                        .DataBufferError => error.DataBuffer,
                        .BabbleDetectedError => error.Babble,
                        .USBTransactionError => error.Transaction,
                        .TRBError => error.TrbError,
                        else => {
                            console.err("XHCI: Transfer failed with code {}", .{@intFromEnum(code)});
                            return error.TransferFailed;
                        },
                    };
                }
            } else if (event_type == .CommandCompletionEvent) {
                // Command completion - might be from parallel operation
                ctrl.updateErdp();
            } else if (event_type == .PortStatusChangeEvent) {
                // Port status change - handle later
                ctrl.updateErdp();
            }
        }

        hal.cpu.pause();
    }

    return error.Timeout;
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
    const cmd_phys = ctrl.command_ring.enqueue(reset_cmd.asTrb().*) orelse {
        return error.RingFull;
    };
    _ = cmd_phys;

    // Ring command doorbell
    ctrl.ringDoorbell(0, 0);

    // Wait for command completion (short timeout)
    var timeout: u32 = 10000;
    while (timeout > 0) : (timeout -= 1) {
        if (ctrl.event_ring.hasPending()) {
            const event = ctrl.event_ring.dequeue() orelse continue;
            const event_type = ring.getTrbType(event);

            if (event_type == .CommandCompletionEvent) {
                const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                ctrl.updateErdp();

                if (completion.status.completion_code == .Success) {
                    console.debug("XHCI: Endpoint {} reset successfully", .{ep_dci});
                    return;
                } else {
                    console.warn("XHCI: Reset endpoint failed: {}", .{@intFromEnum(completion.status.completion_code)});
                    return error.TransferFailed;
                }
            }
        }
        hal.cpu.pause();
    }

    return error.Timeout;
}

// =============================================================================
// USB Descriptor Helpers
// =============================================================================

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
/// This retrieves the report descriptor which describes the format of HID reports
pub fn getReportDescriptor(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    iface: u8,
    buffer: []u8,
) TransferError!usize {
    if (buffer.len < 1) return error.InvalidParam;

    // HID Report Descriptor request goes to interface
    const request_type = usb_types.makeRequestType(
        .device_to_host,
        .standard,
        .interface,
    );

    // wValue: descriptor type (0x22 = Report) in high byte, index (0) in low byte
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
/// protocol: 0 = Boot Protocol, 1 = Report Protocol
pub fn setProtocol(
    ctrl: *Controller,
    dev: *device.UsbDevice,
    interface: u8,
    protocol: u8,
) TransferError!void {
    // Class request to interface
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

/// SET_IDLE request for HID devices (reduce report rate)
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

// =============================================================================
// Interrupt Transfer (for HID polling)
// =============================================================================

/// Queue an interrupt transfer for keyboard polling
/// This is asynchronous - completion is handled in the interrupt handler
pub fn queueInterruptTransfer(
    ctrl: *Controller,
    dev: *device.UsbDevice,
) TransferError!void {
    const int_dci = dev.interrupt_dci;
    if (int_dci == 0) return error.InvalidState;
    var int_ring = &(dev.endpoints[int_dci] orelse return error.InvalidState);

    // Build Normal TRB for interrupt transfer
    var normal = trb.NormalTrb.init(
        dev.report_buffer_phys,
        8, // Boot protocol keyboard reports are 8 bytes
        .{ .ioc = true }, // Interrupt on completion
        int_ring.getCycleState(),
    );

    _ = int_ring.enqueueSingle(normal.asTrb().*) orelse return error.RingFull;

    // Ring doorbell for interrupt endpoint
    ctrl.ringDoorbell(dev.slot_id, dev.interrupt_dci);
}

// =============================================================================
// Bulk Transfer
// =============================================================================

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
    const dci = context.InputContext.endpointToDci(ep_addr);
    
    // Validate state
    if (dci == 0 or dci >= 32) return error.InvalidParam;
    
    var ring_ptr = &(dev.endpoints[dci] orelse return error.InvalidState);

    // Get physical address of buffer
    const buf_phys = hal.paging.virtToPhys(@intFromPtr(buffer.ptr));

    // Build Normal TRB
    var normal = trb.NormalTrb.init(
        buf_phys,
        @truncate(buffer.len),
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
    // TODO: Move to IoRequest
    const result = waitForCompletion(ctrl, dev.slot_id, dci, 1000) catch |err| {
        return err;
    };

    const requested = buffer.len;
    const residual = result.residual;
    const transferred = if (residual <= requested) requested - residual else 0;

    return transferred;
}

// =============================================================================
// Configuration Descriptor Parsing
// =============================================================================

/// Information about a keyboard interface found in config descriptor
pub const KeyboardInfo = struct {
    interface_num: u8,
    endpoint_addr: u8,
    max_packet: u16,
    interval: u8,
};

/// Parse configuration descriptor to find HID keyboard interface
/// Security: Validates all descriptor bounds against actual buffer size,
/// not just the claimed b_length field from untrusted device data.
pub fn findKeyboardInterface(config_data: []const u8) ?KeyboardInfo {
    var i: usize = 0;

    // Current interface info
    var current_interface: ?u8 = null;
    var is_boot_keyboard = false;

    const iface_desc_size = @sizeOf(usb_types.InterfaceDescriptor);
    const ep_desc_size = @sizeOf(usb_types.EndpointDescriptor);

    while (i + 2 <= config_data.len) {
        const length = config_data[i];
        const desc_type = config_data[i + 1];

        // Validate length field from device data
        if (length < 2) break; // Minimum descriptor size is 2 bytes
        if (i + length > config_data.len) break; // Claimed length exceeds buffer

        switch (desc_type) {
            usb_types.DescriptorType.INTERFACE => {
                // Security: Check actual struct size, not just claimed length
                // A malicious device could claim length=9 near buffer end
                const required_size = @max(length, iface_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= iface_desc_size) {
                    const iface = @as(*const usb_types.InterfaceDescriptor, @ptrCast(@alignCast(&config_data[i])));

                    current_interface = iface.b_interface_number;

                    // Check for HID Boot Keyboard:
                    // Class = 0x03 (HID)
                    // SubClass = 0x01 (Boot Interface)
                    // Protocol = 0x01 (Keyboard)
                    is_boot_keyboard = (iface.b_interface_class == 0x03 and
                        iface.b_interface_sub_class == 0x01 and
                        iface.b_interface_protocol == 0x01);

                    if (is_boot_keyboard) {
                        console.info("XHCI: Found HID Boot Keyboard on interface {}", .{iface.b_interface_number});
                    }
                }
            },
            usb_types.DescriptorType.ENDPOINT => {
                // Security: Check actual struct size, not just claimed length
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= ep_desc_size and is_boot_keyboard and current_interface != null) {
                    const ep = @as(*const usb_types.EndpointDescriptor, @ptrCast(@alignCast(&config_data[i])));

                    // Check for Interrupt IN endpoint
                    const addr = ep.getAddress();
                    const attrs = ep.getAttributes();
                    const is_in = addr.direction == .in;
                    const is_interrupt = attrs.transfer_type == .interrupt;

                    if (is_in and is_interrupt) {
                        console.info("XHCI: Found keyboard interrupt endpoint 0x{x:0>2}, max_packet={}, interval={}", .{
                            ep.b_endpoint_address,
                            ep.w_max_packet_size,
                            ep.b_interval,
                        });

                        return KeyboardInfo{
                            .interface_num = current_interface.?,
                            .endpoint_addr = ep.b_endpoint_address,
                            .max_packet = ep.w_max_packet_size,
                            .interval = ep.b_interval,
                        };
                    }
                }
            },
            else => {},
        }

        i += length;
    }

    return null;
}

/// Information about a mouse interface found in config descriptor
pub const MouseInfo = struct {
    interface_num: u8,
    endpoint_addr: u8,
    max_packet: u16,
    interval: u8,
};

/// Parse configuration descriptor to find HID mouse interface
/// Security: Validates all descriptor bounds against actual buffer size,
/// not just the claimed b_length field from untrusted device data.
pub fn findMouseInterface(config_data: []const u8) ?MouseInfo {
    var i: usize = 0;

    // Current interface info
    var current_interface: ?u8 = null;
    var is_boot_mouse = false;

    const iface_desc_size = @sizeOf(usb_types.InterfaceDescriptor);
    const ep_desc_size = @sizeOf(usb_types.EndpointDescriptor);

    while (i + 2 <= config_data.len) {
        const length = config_data[i];
        const desc_type = config_data[i + 1];

        // Validate length field from device data
        if (length < 2) break; // Minimum descriptor size is 2 bytes
        if (i + length > config_data.len) break; // Claimed length exceeds buffer

        switch (desc_type) {
            usb_types.DescriptorType.INTERFACE => {
                // Security: Check actual struct size, not just claimed length
                const required_size = @max(length, iface_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= iface_desc_size) {
                    const iface = @as(*const usb_types.InterfaceDescriptor, @ptrCast(@alignCast(&config_data[i])));

                    current_interface = iface.b_interface_number;

                    // Check for HID Boot Mouse:
                    // Class = 0x03 (HID)
                    // SubClass = 0x01 (Boot Interface)
                    // Protocol = 0x02 (Mouse)
                    is_boot_mouse = (iface.b_interface_class == 0x03 and
                        iface.b_interface_sub_class == 0x01 and
                        iface.b_interface_protocol == 0x02);

                    if (is_boot_mouse) {
                        console.info("XHCI: Found HID Boot Mouse on interface {}", .{iface.b_interface_number});
                    }
                }
            },
            usb_types.DescriptorType.ENDPOINT => {
                // Security: Check actual struct size, not just claimed length
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= ep_desc_size and is_boot_mouse and current_interface != null) {
                    const ep = @as(*const usb_types.EndpointDescriptor, @ptrCast(@alignCast(&config_data[i])));

                    // Check for Interrupt IN endpoint
                    const addr = ep.getAddress();
                    const attrs = ep.getAttributes();
                    const is_in = addr.direction == .in;
                    const is_interrupt = attrs.transfer_type == .interrupt;

                    if (is_in and is_interrupt) {
                        console.info("XHCI: Found mouse interrupt endpoint 0x{x:0>2}, max_packet={}, interval={}", .{
                            ep.b_endpoint_address,
                            ep.w_max_packet_size,
                            ep.b_interval,
                        });

                        return MouseInfo{
                            .interface_num = current_interface.?,
                            .endpoint_addr = ep.b_endpoint_address,
                            .max_packet = ep.w_max_packet_size,
                            .interval = ep.b_interval,
                        };
                    }
                }
            },
            else => {},
        }

        i += length;
    }

    return null;
}

/// Information about an MSC interface found in config descriptor
pub const MscInfo = struct {
    interface_num: u8,
    bulk_in_ep: u8,
    bulk_out_ep: u8,
    max_packet: u16,
};

/// Parse configuration descriptor to find Mass Storage interface
pub fn findMscInterface(config_data: []const u8) ?MscInfo {
    var i: usize = 0;

    var current_interface: ?u8 = null;
    var is_msc = false;
    var bulk_in: ?u8 = null;
    var bulk_out: ?u8 = null;
    var max_packet_size: u16 = 0;

    const iface_desc_size = @sizeOf(usb_types.InterfaceDescriptor);
    const ep_desc_size = @sizeOf(usb_types.EndpointDescriptor);

    while (i + 2 <= config_data.len) {
        const length = config_data[i];
        const desc_type = config_data[i + 1];

        if (length < 2) break;
        if (i + length > config_data.len) break;

        switch (desc_type) {
            usb_types.DescriptorType.INTERFACE => {
               const required_size = @max(length, iface_desc_size);
                if (i + required_size > config_data.len) break;

                 if (length >= iface_desc_size) {
                    const iface = @as(*const usb_types.InterfaceDescriptor, @ptrCast(@alignCast(&config_data[i])));
                    current_interface = iface.b_interface_number;
                    
                    // Reset endpoint finding for new interface
                    bulk_in = null;
                    bulk_out = null;

                    // Class 0x08 (MSC), Subclass 0x06 (SCSI), Protocol 0x50 (BOT)
                    is_msc = (iface.b_interface_class == 0x08 and
                             iface.b_interface_sub_class == 0x06 and
                             iface.b_interface_protocol == 0x50);
                    
                    if (is_msc) {
                        console.info("XHCI: Found MSC Interface {}", .{iface.b_interface_number});
                    }
                 }
            },
            usb_types.DescriptorType.ENDPOINT => {
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= ep_desc_size and is_msc and current_interface != null) {
                    const ep = @as(*const usb_types.EndpointDescriptor, @ptrCast(@alignCast(&config_data[i])));
                    const addr = ep.getAddress();
                    const attrs = ep.getAttributes();

                    if (attrs.transfer_type == .bulk) {
                        if (addr.direction == .in) {
                            bulk_in = ep.b_endpoint_address;
                             max_packet_size = ep.w_max_packet_size;
                        } else {
                            bulk_out = ep.b_endpoint_address;
                        }
                    }

                    // If we have both, we are good
                    if (bulk_in != null and bulk_out != null) {
                        return MscInfo{
                            .interface_num = current_interface.?,
                            .bulk_in_ep = bulk_in.?,
                            .bulk_out_ep = bulk_out.?,
                            .max_packet = max_packet_size,
                        };
                    }
                }
            },
            else => {},
        }
        i += length;
    }
    return null;
}
