const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const iommu = @import("iommu");

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

/// Start interrupt polling for a HID device (keyboard or mouse)
pub fn startInterruptPolling(ctrl: *Controller, dev: *device.UsbDevice) !void {
    if (dev.state != .polling) {
        console.info("XHCI: Starting HID polling for slot {}", .{dev.slot_id});
    }
    try interrupt_transfer.queueInterruptTransfer(ctrl, dev);
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
    const new_max_packet = desc_buf[7];
    const valid_max_packet = switch (dev.speed) {
        .low_speed => new_max_packet == 8,
        .full_speed => new_max_packet == 8 or new_max_packet == 16 or new_max_packet == 32 or new_max_packet == 64,
        .high_speed => new_max_packet == 64,
        .super_speed, .super_speed_plus => new_max_packet == 9, // 2^9 = 512
        else => new_max_packet >= 8 and new_max_packet <= 64, // Fallback for unknown speeds
    };

    if (!valid_max_packet) {
        console.err("XHCI: Invalid max packet size {} for speed {}", .{ new_max_packet, @intFromEnum(dev.speed) });
        return error.InvalidDescriptor;
    }

    if (new_max_packet != dev.max_packet_size) {
        console.info("XHCI: Updating max packet size from {} to {}", .{ dev.max_packet_size, new_max_packet });
        dev.updateMaxPacketSize(new_max_packet);
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

    // 8. Parse configuration for HID interface (keyboard or mouse)
    var interface_num: u8 = 0;
    var endpoint_addr: u8 = 0;
    var max_packet: u16 = 0;
    var interval: u8 = 0;

    if (enumeration.findKeyboardInterface(config_buf[0..config_len])) |info| {
        console.info("XHCI: Found HID Keyboard", .{});
        dev.hid_driver.is_keyboard = true;
        interface_num = info.interface_num;
        endpoint_addr = info.endpoint_addr;
        max_packet = info.max_packet;
        interval = info.interval;
    } else if (enumeration.findMouseInterface(config_buf[0..config_len])) |info| {
        console.info("XHCI: Found HID Mouse", .{});
        dev.hid_driver.is_mouse = true;
        interface_num = info.interface_num;
        endpoint_addr = info.endpoint_addr;
        max_packet = info.max_packet;
        interval = info.interval;
    } else if (enumeration.findGenericHidInterface(config_buf[0..config_len])) |info| {
        // Generic HID device (not Boot Protocol) - could be tablet, touchscreen, etc.
        // We'll parse the report descriptor later to determine exact type
        console.info("XHCI: Found generic HID device (subclass={}, protocol={})", .{ info.subclass, info.protocol });
        // Mark as potential mouse/tablet - report descriptor parsing will refine this
        dev.hid_driver.is_mouse = true;
        interface_num = info.interface_num;
        endpoint_addr = info.endpoint_addr;
        max_packet = info.max_packet;
        interval = info.interval;
    } else if (enumeration.findHubInterface(config_buf[0..config_len])) |hub_info| {
         console.info("XHCI: Found USB Hub Interface {d}", .{hub_info.interface_num});
         
         // Initialize Hub Driver
         dev.is_hub = true;
         
         const int_in = hub_info.int_in_ep;
         const max_packet_size = hub_info.max_packet;
         
         // Initialize Endpoint
         console.debug("XHCI: Hub Int IN Endpoint 0x{x} max={d}", .{int_in, max_packet_size});
         try dev.initBulkEndpoint(int_in); // Reusing bulk helper, works for allocating ring
         try dev.buildConfigureEndpointContext(int_in, .interrupt_in, max_packet_size, 12); // Interval 12 (~32ms)
         
         // Send Configuration Command
         try configureEndpoint(ctrl, dev); 
         
         // Initialize Driver
         // Note: Passing enumerateDevice function pointer to HubDriver to break cycle
         // Security: Pass current depth so hub can enforce nesting limits for child devices
         dev.hub_driver = hub.HubDriver.init(ctrl, dev, int_in, enumerateDevice, depth);
         try dev.hub_driver.configure();
         
         console.info("XHCI: USB Hub device enumerated on slot {d}", .{slot_id});
         
         device.registerDevice(dev);
         return dev; 

    } else {
        console.info("XHCI: Device is not a supported device class", .{});
        dev.deinit();
        return null; // Don't return error, just null for "unsupported"
    }

    // 9. SET_CONFIGURATION
    const config_value = config_buf[5]; // bConfigurationValue
    control_transfer.setConfiguration(ctrl, dev, config_value) catch |err| {
        console.err("XHCI: Failed to set configuration: {}", .{err});
        return err;
    };
    console.info("XHCI: Configuration {} set", .{config_value});

    // 10. Configure interrupt endpoint
    try dev.buildConfigureEndpointContext(
        endpoint_addr,
        .interrupt_in,
        max_packet,
        interval,
    );
    try configureEndpoint(ctrl, dev);
    dev.state = .configured;

    // 11. GET_REPORT_DESCRIPTOR to parse full HID capabilities
    // Security: Zero-initialize DMA buffer to prevent kernel memory leaks on short transfers
    var report_desc_buf: [512]u8 = [_]u8{0} ** 512;
    const report_desc_len: usize = control_transfer.getReportDescriptor(ctrl, dev, interface_num, &report_desc_buf) catch |err| blk: {
        console.warn("XHCI: Failed to get report descriptor: {} - using boot protocol", .{err});
        break :blk 0;
    };

    // 12. Parse report descriptor if we got one
    if (report_desc_len > 0) {
        dev.hid_driver.parseReportDescriptor(report_desc_buf[0..report_desc_len]) catch |err| {
            console.warn("XHCI: Failed to parse report descriptor: {}", .{err});
        };

        // Check if parser detected tablet (overrides initial detection)
        if (dev.hid_driver.is_tablet) {
            console.info("XHCI: Device identified as tablet with absolute positioning", .{});
        }
    }

    // 13. SET_PROTOCOL - only for boot protocol devices (keyboard/mouse, not tablets)
    if (!dev.hid_driver.is_tablet) {
        control_transfer.setProtocol(ctrl, dev, interface_num, 0) catch |err| {
            console.warn("XHCI: Failed to set boot protocol (may be OK): {}", .{err});
        };
    }

    // 14. SET_IDLE(0) to get reports only on change
    control_transfer.setIdle(ctrl, dev, interface_num, 0, 0) catch |err| {
        console.warn("XHCI: Failed to set idle (may be OK): {}", .{err});
    };

    // 15. Register device and start polling
    device.registerDevice(dev);
    const device_type: []const u8 = if (dev.hid_driver.is_keyboard)
        "keyboard"
    else if (dev.hid_driver.is_tablet)
        "tablet"
    else
        "mouse";
    console.info("XHCI: USB {s} enumerated successfully on slot {}", .{ device_type, slot_id });

    // TODO: Re-enable input subsystem integration once build.zig adds 'input' dependency to USB module
    // if (dev.hid_driver.is_mouse or dev.hid_driver.is_tablet) {
    //     const dev_type: input.DeviceType = if (dev.hid_driver.is_tablet) .usb_tablet else .usb_mouse;
    //     const has_buttons = dev.hid_driver.capabilities.has_buttons;
    //     if (input.isInitialized()) {
    //         dev.hid_driver.input_device_id = input.registerDevice(.{
    //             .device_type = dev_type,
    //             .name = if (dev.hid_driver.is_tablet) "usb-tablet" else "usb-mouse",
    //             .capabilities = .{
    //                 .has_rel = dev.hid_driver.is_mouse,
    //                 .has_abs = dev.hid_driver.is_tablet,
    //                 .has_left = has_buttons,
    //                 .has_right = has_buttons,
    //                 .has_middle = has_buttons,
    //             },
    //             .is_absolute = dev.hid_driver.is_tablet,
    //         }) catch 0;
    //     }
    // }

    // Start polling if it's a HID device
    try startInterruptPolling(ctrl, dev);

    return dev;
}

/// Handle interrupt for a device (called from interrupt handler)
pub fn handleInterrupt(ctrl: *Controller, dev: *device.UsbDevice, buffer: []u8) void {
    // 1. Process valid data (Short Packet event might give less than buffer size)
    // We assume buffer contains the transferred data.
    
    // Pass to class driver
    if (dev.hid_driver.is_keyboard or dev.hid_driver.is_mouse or dev.hid_driver.is_tablet) {
        dev.hid_driver.handleInputReport(buffer);
    } else if (dev.is_hub) {
        dev.hub_driver.handleInterrupt(buffer);
    }
    
    // 2. Re-queue interrupt transfer to keep polling
    // This maintains the polling loop
    startInterruptPolling(ctrl, dev) catch |err| {
        console.err("XHCI: Failed to re-queue interrupt transfer for slot {}: {}", .{ dev.slot_id, err });
        dev.state = .err;
    };
}
