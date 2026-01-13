const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const iommu = @import("iommu");
const keyboard = @import("keyboard");

const types = @import("types.zig");
const device = @import("device.zig");
const context = @import("context.zig");
const ring = @import("ring.zig");
const trb = @import("trb.zig");
const regs = @import("regs.zig");

// Transfer modules
const control_transfer = @import("transfer/control.zig");
const interrupt_transfer = @import("transfer/interrupt.zig");
const enumeration = @import("enumeration.zig");

// Class drivers
const hid = @import("../class/hid/root.zig");
// const msc = @import("../class/msc.zig"); // Assuming MSC exists as imported in root.zig
const hub = @import("../class/hub.zig");

const Controller = types.Controller;

/// Error type for command operations
const CommandError = error{
    RingFull,
    CommandFailed,
    Timeout,
    InvalidSpeed,
};

// =============================================================================
// USB Device Enumeration Commands
// =============================================================================

/// Send Enable Slot command and return allocated slot ID
pub fn enableSlot(ctrl: *Controller) CommandError!u8 {
    console.info("XHCI: Sending Enable Slot command...", .{});

    var enable_cmd = trb.EnableSlotCmdTrb.init(ctrl.command_ring.getCycleState());
    _ = ctrl.command_ring.enqueue(enable_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(50000) catch return error.Timeout;
    if (result.code == .Success) {
        console.info("XHCI: Enable Slot succeeded, slot_id={}", .{result.slot_id});
        return result.slot_id;
    } else {
        console.err("XHCI: Enable Slot failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

/// Send Address Device command
pub fn addressDevice(ctrl: *Controller, dev: *device.UsbDevice, bsr: bool) CommandError!void {
    console.info("XHCI: Sending Address Device command (slot={}, BSR={})...", .{ dev.slot_id, bsr });

    // Build Address Device command TRB
    var addr_cmd = trb.AddressDeviceCmdTrb.init(
        dev.input_context_phys,
        dev.slot_id,
        bsr,
        ctrl.command_ring.getCycleState(),
    );

    _ = ctrl.command_ring.enqueue(addr_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    // Register device context in DCBAA
    ctrl.dcbaa.setSlot(dev.slot_id, dev.device_context_phys);

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(100000) catch return error.Timeout;
    if (result.code == .Success) {
        console.info("XHCI: Address Device succeeded", .{});
    } else {
        console.err("XHCI: Address Device failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

/// Send Configure Endpoint command
pub fn configureEndpoint(ctrl: *Controller, dev: *device.UsbDevice) CommandError!void {
    console.info("XHCI: Sending Configure Endpoint command (slot={})...", .{dev.slot_id});

    var config_cmd = trb.ConfigureEndpointCmdTrb.init(
        dev.input_context_phys,
        dev.slot_id,
        false, // Not deconfiguring
        ctrl.command_ring.getCycleState(),
    );

    _ = ctrl.command_ring.enqueue(config_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(100000) catch return error.Timeout;
    if (result.code == .Success) {
        console.info("XHCI: Configure Endpoint succeeded", .{});

        // Verify configured endpoints are in Running state
        const dc = dev.device_context;
        for (0..31) |i| {
            const ep_state = dc.endpoints[i].dw0.ep_state;
            if (ep_state != .disabled and ep_state != .running) {
                const dci: u5 = @intCast(i + 1);
                console.warn("XHCI: EP DCI {} in unexpected state {}", .{ dci, @intFromEnum(ep_state) });
            }
        }
    } else {
        console.err("XHCI: Configure Endpoint failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

/// Send Evaluate Context command (for updating EP0 max packet size)
pub fn evaluateContext(ctrl: *Controller, dev: *device.UsbDevice) CommandError!void {
    console.info("XHCI: Sending Evaluate Context command (slot={})...", .{dev.slot_id});

    var eval_cmd = trb.EvaluateContextCmdTrb.init(
        dev.input_context_phys,
        dev.slot_id,
        ctrl.command_ring.getCycleState(),
    );

    _ = ctrl.command_ring.enqueue(eval_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(50000) catch return error.Timeout;
    if (result.code == .Success) {
        console.info("XHCI: Evaluate Context succeeded", .{});
    } else {
        console.err("XHCI: Evaluate Context failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

// =============================================================================
// Device Disconnect Commands
// =============================================================================

/// Send Stop Endpoint command
/// xHCI Spec 4.6.9: Stops an endpoint to prevent further transfers
/// Must be sent before disabling a slot during device disconnect
pub fn stopEndpoint(ctrl: *Controller, dev: *device.UsbDevice, dci: u5) CommandError!void {
    // Don't stop EP0 (DCI 1) - it's handled by Disable Slot
    if (dci < 2) return;

    console.debug("XHCI: Sending Stop Endpoint command (slot={}, dci={})...", .{ dev.slot_id, dci });

    var stop_cmd = trb.StopEndpointCmdTrb.init(
        dev.slot_id,
        dci,
        false, // suspend=false means full stop (not suspend)
        ctrl.command_ring.getCycleState(),
    );

    _ = ctrl.command_ring.enqueue(stop_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    // Wait with shorter timeout - endpoint might already be stopped
    const result = ctrl.waitForCommandCompletion(10000) catch return error.Timeout;

    // Success or Context State Error are both acceptable
    // Context State Error means endpoint was already stopped
    if (result.code == .Success) {
        console.debug("XHCI: Stop Endpoint succeeded", .{});
    } else if (result.code == .ContextStateError) {
        console.debug("XHCI: Endpoint already stopped", .{});
    } else {
        console.warn("XHCI: Stop Endpoint failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

/// Send Disable Slot command
/// xHCI Spec 4.6.4: Releases all resources for a device slot
/// Must be called after stopping all endpoints during device disconnect
pub fn disableSlot(ctrl: *Controller, slot_id: u8) CommandError!void {
    console.info("XHCI: Sending Disable Slot command (slot={})...", .{slot_id});

    var disable_cmd = trb.DisableSlotCmdTrb.init(
        slot_id,
        ctrl.command_ring.getCycleState(),
    );

    _ = ctrl.command_ring.enqueue(disable_cmd.asTrb().*) orelse {
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(50000) catch return error.Timeout;
    if (result.code == .Success) {
        console.info("XHCI: Disable Slot succeeded", .{});

        // Clear DCBAA entry for this slot
        ctrl.dcbaa.setSlot(slot_id, 0);
    } else {
        console.err("XHCI: Disable Slot failed: {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}

/// Start interrupt polling for a device (uses legacy interrupt_dci)
/// @deprecated Use startInterruptPollingForDci for multi-interface devices
pub fn startInterruptPolling(ctrl: *Controller, dev: *device.UsbDevice) !void {
    if (dev.state != .polling) {
        console.info("XHCI: Starting HID polling for slot {}", .{dev.slot_id});
    }
    try interrupt_transfer.queueInterruptTransfer(ctrl, dev);
    dev.state = .polling;
}

/// Start interrupt polling for a specific DCI (supports multi-interface devices)
pub fn startInterruptPollingForDci(ctrl: *Controller, dev: *device.UsbDevice, dci: u5) !void {
    if (dev.state != .polling) {
        console.info("XHCI: Starting polling for slot {} DCI {}", .{ dev.slot_id, dci });
    }
    try interrupt_transfer.queueInterruptTransferForDci(ctrl, dev, dci);
    dev.state = .polling;
}

// =============================================================================
// Device Enumeration State Machine
// =============================================================================

/// Enumerate a USB device on a port (Root or Hub)
/// Returns configured device if successful
/// Security: Depth parameter limits hub nesting to prevent stack exhaustion.
/// USB spec allows max 5 hub tiers; we reject enumeration beyond that.
pub fn enumerateDevice(
    ctrl: *Controller,
    parent: ?*device.UsbDevice,
    port_num: u8,
    route_string: u20,
    root_port_num: u8,
    speed_override: ?context.Speed,
    depth: u8,
) !?*device.UsbDevice {
    // Security: Reject devices nested beyond USB spec maximum (5 hub tiers)
    // This prevents stack exhaustion from malicious or buggy hub chains.
    if (depth > hub.MAX_HUB_DEPTH) {
        console.err("XHCI: Rejecting device at depth {} (max {})", .{ depth, hub.MAX_HUB_DEPTH });
        return error.TooManyHubLevels;
    }

    var speed: context.Speed = .invalid;

    if (parent == null) {
        // Root Hub Port logic
        const port_base = ctrl.op_base + regs.portBaseOffset(port_num);
        const port_dev = hal.mmio_device.MmioDevice(regs.PortReg).init(port_base, 0x10);
        const portsc = port_dev.readTyped(.portsc, regs.PortSc);

        if (!portsc.ccs or !portsc.ped) {
            console.warn("XHCI: Port {} not connected or enabled", .{port_num});
            return null;
        }
        speed = @enumFromInt(portsc.speed);
    } else {
        // Hub Port logic - speed passed from Hub Driver
        if (speed_override) |s| {
            speed = s;
        } else {
            return error.InvalidSpeed;
        }
    }
    
    console.info("XHCI: Enumerating device on port {} (speed={}, parent={s})", .{ 
        port_num, 
        @intFromEnum(speed),
        if (parent != null) "Hub" else "Root" 
    });

    // 1. Enable Slot
    const slot_id = try enableSlot(ctrl);

    // 2. Allocate device structure (IOMMU-aware via controller's BDF)
    const bdf = iommu.DeviceBdf{
        .bus = ctrl.pci_dev.bus,
        .device = ctrl.pci_dev.device,
        .func = ctrl.pci_dev.func,
    };
    const dev = try device.UsbDevice.init(bdf, slot_id, root_port_num, speed, parent, port_num, route_string);
    errdefer dev.deinit();

    // 3. Build Input Context for Address Device
    dev.buildAddressDeviceContext();

    // 4. Address Device (BSR=0 sends SET_ADDRESS automatically)
    try addressDevice(ctrl, dev, false);
    dev.state = .addressed;

    // 5. GET_DESCRIPTOR(Device, 8 bytes) - get max packet size
    // Security: Zero-initialize DMA buffer to prevent kernel memory leaks on short transfers
    var desc_buf: [18]u8 = [_]u8{0} ** 18;
    const bytes_read = control_transfer.getDeviceDescriptor(ctrl, dev, desc_buf[0..8]) catch |err| {
        console.err("XHCI: Failed to get device descriptor (short): {}", .{err});
        return err;
    };

    if (bytes_read < 8) {
        console.err("XHCI: Device descriptor too short: {} bytes", .{bytes_read});
        return error.InvalidDescriptor;
    }

    // Update max packet size from descriptor
    // Security: Validate max packet size against USB specification limits
    // Note: USB 3.0 devices report bMaxPacketSize0 as an exponent (9 = 2^9 = 512)
    const desc_max_packet = desc_buf[7];
    const actual_max_packet: u16 = switch (dev.speed) {
        .low_speed => blk: {
            if (desc_max_packet != 8) {
                console.err("XHCI: Invalid max packet size {} for low speed (must be 8)", .{desc_max_packet});
                return error.InvalidDescriptor;
            }
            break :blk 8;
        },
        .full_speed => blk: {
            if (desc_max_packet != 8 and desc_max_packet != 16 and desc_max_packet != 32 and desc_max_packet != 64) {
                console.err("XHCI: Invalid max packet size {} for full speed", .{desc_max_packet});
                return error.InvalidDescriptor;
            }
            break :blk desc_max_packet;
        },
        .high_speed => blk: {
            if (desc_max_packet != 64) {
                console.err("XHCI: Invalid max packet size {} for high speed (must be 64)", .{desc_max_packet});
                return error.InvalidDescriptor;
            }
            break :blk 64;
        },
        // USB 3.0 spec: bMaxPacketSize0 is the exponent (9 means 2^9 = 512)
        .super_speed, .super_speed_plus => blk: {
            if (desc_max_packet != 9) {
                console.err("XHCI: Invalid max packet size exponent {} for SuperSpeed (must be 9)", .{desc_max_packet});
                return error.InvalidDescriptor;
            }
            break :blk 512; // 2^9 = 512 bytes
        },
        else => blk: {
            if (desc_max_packet < 8 or desc_max_packet > 64) {
                console.err("XHCI: Invalid max packet size {} for unknown speed", .{desc_max_packet});
                return error.InvalidDescriptor;
            }
            break :blk desc_max_packet;
        },
    };

    if (actual_max_packet != dev.max_packet_size) {
        console.info("XHCI: Updating max packet size from {} to {}", .{ dev.max_packet_size, actual_max_packet });
        dev.updateMaxPacketSize(actual_max_packet);
        dev.buildEvaluateContext();
        try evaluateContext(ctrl, dev);
    }

    // 6. GET_DESCRIPTOR(Device, full 18 bytes)
    _ = control_transfer.getDeviceDescriptor(ctrl, dev, &desc_buf) catch |err| {
        console.err("XHCI: Failed to get full device descriptor: {}", .{err});
        return err;
    };

    const vid = @as(u16, desc_buf[8]) | (@as(u16, desc_buf[9]) << 8);
    const pid = @as(u16, desc_buf[10]) | (@as(u16, desc_buf[11]) << 8);
    console.info("XHCI: Device VID={x:0>4} PID={x:0>4}", .{ vid, pid });

    // 7. GET_DESCRIPTOR(Configuration)
    // Security: Zero-initialize DMA buffer to prevent kernel memory leaks on short transfers
    var config_buf: [256]u8 = [_]u8{0} ** 256;
    const config_len = control_transfer.getConfigDescriptor(ctrl, dev, 0, &config_buf) catch |err| {
        console.err("XHCI: Failed to get config descriptor: {}", .{err});
        return err;
    };

    // 8. Parse configuration for ALL interfaces (multi-interface support)
    const parse_result = enumeration.parseConfigDescriptor(config_buf[0..config_len]) orelse {
        console.info("XHCI: No valid interfaces found in config descriptor", .{});
        dev.deinit();
        return null;
    };

    // 9. SET_CONFIGURATION first (must be done before endpoint configuration)
    control_transfer.setConfiguration(ctrl, dev, parse_result.config_value) catch |err| {
        console.err("XHCI: Failed to set configuration: {}", .{err});
        return err;
    };
    console.info("XHCI: Configuration {} set", .{parse_result.config_value});

    // 10. Collect endpoint configurations for ALL supported interfaces
    var endpoint_configs: [32]device.UsbDevice.EndpointConfig = undefined;
    var endpoint_count: usize = 0;
    var has_hub = false;
    var hub_int_in: u8 = 0;

    for (parse_result.getInterfaces()) |*iface| {
        if (iface.isHub()) {
            // Hub interface - handle specially
            if (iface.findInterruptIn()) |ep| {
                has_hub = true;
                hub_int_in = ep.address;
                dev.is_hub = true;

                // Add hub interrupt endpoint
                if (endpoint_count < 32) {
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = ep.address,
                        .ep_type = .interrupt_in,
                        .max_packet = ep.max_packet_size,
                        .interval = 12, // ~32ms for hub
                    };
                    endpoint_count += 1;

                    const dci = context.InputContext.endpointToDci(ep.address) orelse continue;
                    _ = dev.registerActiveInterface(iface.interface_num, dci, .hub, 0);
                }
                console.info("XHCI: Found USB Hub on interface {}", .{iface.interface_num});
            }
        } else if (iface.isKeyboard()) {
            // HID Keyboard
            if (iface.findInterruptIn()) |ep| {
                if (endpoint_count < 32) {
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = ep.address,
                        .ep_type = .interrupt_in,
                        .max_packet = ep.max_packet_size,
                        .interval = ep.interval,
                    };
                    endpoint_count += 1;

                    const dci = context.InputContext.endpointToDci(ep.address) orelse continue;
                    _ = dev.registerActiveInterface(iface.interface_num, dci, .hid_keyboard, 0);
                    dev.hid_driver.is_keyboard = true;
                }
                console.info("XHCI: Found HID Keyboard on interface {}", .{iface.interface_num});
                // Initialize keyboard subsystem for USB HID input
                keyboard.initForUsb();
            }
        } else if (iface.isMouse()) {
            // HID Mouse
            if (iface.findInterruptIn()) |ep| {
                if (endpoint_count < 32) {
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = ep.address,
                        .ep_type = .interrupt_in,
                        .max_packet = ep.max_packet_size,
                        .interval = ep.interval,
                    };
                    endpoint_count += 1;

                    const dci = context.InputContext.endpointToDci(ep.address) orelse continue;
                    _ = dev.registerActiveInterface(iface.interface_num, dci, .hid_mouse, 0);
                    dev.hid_driver.is_mouse = true;
                }
                console.info("XHCI: Found HID Mouse on interface {}", .{iface.interface_num});
            }
        } else if (iface.isHid()) {
            // Generic HID (tablet, touchscreen, etc.)
            if (iface.findInterruptIn()) |ep| {
                if (endpoint_count < 32) {
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = ep.address,
                        .ep_type = .interrupt_in,
                        .max_packet = ep.max_packet_size,
                        .interval = ep.interval,
                    };
                    endpoint_count += 1;

                    const dci = context.InputContext.endpointToDci(ep.address) orelse continue;
                    _ = dev.registerActiveInterface(iface.interface_num, dci, .hid_generic, 0);
                    dev.hid_driver.is_mouse = true; // Treat as mouse until report descriptor parsed
                }
                console.info("XHCI: Found generic HID on interface {} (subclass={}, protocol={})", .{
                    iface.interface_num,
                    iface.subclass,
                    iface.protocol,
                });
            }
        } else if (iface.isMscBot()) {
            // MSC Bulk-Only Transport
            const bulk_in = iface.findBulkIn();
            const bulk_out = iface.findBulkOut();
            if (bulk_in != null and bulk_out != null) {
                const in_ep = bulk_in.?;
                const out_ep = bulk_out.?;

                if (endpoint_count + 1 < 32) {
                    // Add BULK IN endpoint
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = in_ep.address,
                        .ep_type = .bulk_in,
                        .max_packet = in_ep.max_packet_size,
                        .interval = 0,
                    };
                    endpoint_count += 1;

                    // Add BULK OUT endpoint
                    endpoint_configs[endpoint_count] = .{
                        .ep_addr = out_ep.address,
                        .ep_type = .bulk_out,
                        .max_packet = out_ep.max_packet_size,
                        .interval = 0,
                    };
                    endpoint_count += 1;

                    const in_dci = context.InputContext.endpointToDci(in_ep.address) orelse continue;
                    const out_dci = context.InputContext.endpointToDci(out_ep.address) orelse continue;
                    _ = dev.registerActiveInterface(iface.interface_num, in_dci, .msc, out_dci);
                }
                console.info("XHCI: Found MSC BOT on interface {} (bulk_in=0x{x}, bulk_out=0x{x})", .{
                    iface.interface_num,
                    in_ep.address,
                    out_ep.address,
                });
            }
        } else {
            console.debug("XHCI: Skipping unsupported interface {} (class=0x{x:0>2})", .{
                iface.interface_num,
                iface.class,
            });
        }
    }

    // Check if we found any supported interfaces
    if (dev.active_interface_count == 0) {
        console.info("XHCI: Device has no supported interface classes", .{});
        dev.deinit();
        return null;
    }

    // 11. Configure ALL endpoints in ONE command (fixes critical memset bug)
    if (endpoint_count > 0) {
        try dev.buildMultiEndpointContext(endpoint_configs[0..endpoint_count]);
        try configureEndpoint(ctrl, dev);
    }
    dev.state = .configured;

    // 12. Post-configuration setup for each interface type
    for (dev.getActiveInterfaces()) |*active| {
        switch (active.driver_type) {
            .hub => {
                // Initialize Hub Driver
                dev.hub_driver = hub.HubDriver.init(ctrl, dev, hub_int_in, enumerateDevice, depth);
                try dev.hub_driver.configure();
                console.info("XHCI: Hub driver configured", .{});
            },
            .hid_keyboard, .hid_mouse, .hid_generic => {
                // Get and parse report descriptor for HID devices
                var report_desc_buf: [512]u8 = [_]u8{0} ** 512;
                const report_desc_len: usize = control_transfer.getReportDescriptor(ctrl, dev, active.interface_num, &report_desc_buf) catch |err| blk: {
                    console.warn("XHCI: Failed to get report descriptor for interface {}: {}", .{ active.interface_num, err });
                    break :blk 0;
                };

                if (report_desc_len > 0) {
                    dev.hid_driver.parseReportDescriptor(report_desc_buf[0..report_desc_len]) catch |err| {
                        console.warn("XHCI: Failed to parse report descriptor: {}", .{err});
                    };

                    if (dev.hid_driver.is_tablet) {
                        console.info("XHCI: Device identified as tablet with absolute positioning", .{});
                    }
                }

                // SET_PROTOCOL for boot protocol devices (not tablets)
                if (!dev.hid_driver.is_tablet) {
                    control_transfer.setProtocol(ctrl, dev, active.interface_num, 0) catch |err| {
                        console.warn("XHCI: Failed to set boot protocol for interface {}: {}", .{ active.interface_num, err });
                    };
                }

                // SET_IDLE(0) to get reports only on change
                control_transfer.setIdle(ctrl, dev, active.interface_num, 0, 0) catch |err| {
                    console.warn("XHCI: Failed to set idle for interface {}: {}", .{ active.interface_num, err });
                };
            },
            .msc => {
                // MSC initialization would go here
                console.info("XHCI: MSC interface {} ready (driver not yet implemented)", .{active.interface_num});
            },
            .none => {},
        }
    }

    // 13. Register device
    device.registerDevice(dev);

    // Log what we found
    console.info("XHCI: USB device enumerated on slot {} with {} interface(s)", .{ slot_id, dev.active_interface_count });

    // 14. Start interrupt polling for all HID interfaces
    for (dev.getActiveInterfaces()) |*active| {
        if (active.driver_type.isHid()) {
            startInterruptPollingForDci(ctrl, dev, active.dci) catch |err| {
                console.err("XHCI: Failed to start polling for interface {}: {}", .{ active.interface_num, err });
            };
        } else if (active.driver_type == .hub) {
            // Hub also needs interrupt polling for port status changes
            startInterruptPollingForDci(ctrl, dev, active.dci) catch |err| {
                console.err("XHCI: Failed to start hub polling: {}", .{err});
            };
        }
    }

    return dev;
}

/// Handle interrupt for a device (called from interrupt handler)
/// @deprecated Use handleInterruptForDci for multi-interface devices
pub fn handleInterrupt(ctrl: *Controller, dev: *device.UsbDevice, buffer: []u8) void {
    // Delegate to DCI-aware version using legacy interrupt_dci
    handleInterruptForDci(ctrl, dev, dev.interrupt_dci, buffer);
}

/// Handle interrupt for a specific DCI (supports multi-interface devices)
/// Routes the interrupt data to the correct driver based on which interface owns the DCI
pub fn handleInterruptForDci(ctrl: *Controller, dev: *device.UsbDevice, dci: u5, buffer: []u8) void {
    // Find which interface this DCI belongs to
    if (dev.findActiveInterfaceByDci(dci)) |active| {
        switch (active.driver_type) {
            .hid_keyboard, .hid_mouse, .hid_generic => {
                dev.hid_driver.handleInputReport(buffer);
            },
            .hub => {
                dev.hub_driver.handleInterrupt(buffer);
            },
            .msc => {
                // MSC bulk transfers don't use this interrupt path
                console.warn("XHCI: Unexpected interrupt for MSC interface", .{});
            },
            .none => {},
        }

        // Re-queue interrupt transfer for this specific DCI
        startInterruptPollingForDci(ctrl, dev, dci) catch |err| {
            console.err("XHCI: Failed to re-queue interrupt for slot {} DCI {}: {}", .{ dev.slot_id, dci, err });
            dev.state = .err;
        };
    } else {
        // Fallback: use legacy behavior if no active interface found
        if (dev.hid_driver.is_keyboard or dev.hid_driver.is_mouse or dev.hid_driver.is_tablet) {
            dev.hid_driver.handleInputReport(buffer);
        } else if (dev.is_hub) {
            dev.hub_driver.handleInterrupt(buffer);
        }

        startInterruptPolling(ctrl, dev) catch |err| {
            console.err("XHCI: Failed to re-queue interrupt for slot {}: {}", .{ dev.slot_id, err });
            dev.state = .err;
        };
    }
}
