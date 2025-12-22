// USB Hub Class Driver
//
// Implements Generic Hub Support (Class 0x09).
// Reference: USB 2.0 Specification, Chapter 11 (Hub Specification)

const std = @import("std");
const console = @import("console");
const io = @import("io");

// Use specific imports to avoid cycle with root.zig
const types = @import("../xhci/types.zig");
const device = @import("../xhci/device.zig");
const context = @import("../xhci/context.zig");
const transfer = @import("../xhci/transfer/control.zig"); 

// =============================================================================
// Constants and Types
// =============================================================================

pub const CLASS_HUB = 0x09;
pub const SUBCLASS_HUB = 0x00;
pub const PROTOCOL_FULL_SPEED_HUB = 0x00;
pub const PROTOCOL_HI_SPEED_HUB_SINGLE_TT = 0x01;
pub const PROTOCOL_HI_SPEED_HUB_MULTI_TT = 0x02;

// Class-Specific Request Codes (Table 11-16)
pub const Request = enum(u8) {
    GET_STATUS = 0,
    CLEAR_FEATURE = 1,
    SET_FEATURE = 3,
    GET_DESCRIPTOR = 6,
    SET_DESCRIPTOR = 7,
    CLEAR_TT_BUFFER = 8,
    RESET_TT = 9,
    GET_TT_STATE = 10,
    STOP_TT = 11,
};

// Hub Class Feature Selectors (Table 11-17)
pub const HubFeature = enum(u16) {
    C_HUB_LOCAL_POWER = 0,
    C_HUB_OVER_CURRENT = 1,
};

pub const PortFeature = enum(u16) {
    PORT_CONNECTION = 0,
    PORT_ENABLE = 1,
    PORT_SUSPEND = 2,
    PORT_OVER_CURRENT = 3,
    PORT_RESET = 4,
    PORT_POWER = 8,
    PORT_LOW_SPEED = 9,
    C_PORT_CONNECTION = 16,
    C_PORT_ENABLE = 17,
    C_PORT_SUSPEND = 18,
    C_PORT_OVER_CURRENT = 19,
    C_PORT_RESET = 20,
    PORT_TEST = 21,
    PORT_INDICATOR = 22,
};

/// Hub Descriptor (Table 11-13)
pub const HubDescriptor = extern struct {
    bDescLength: u8,
    bDescriptorType: u8, // 0x29
    bNbrPorts: u8,
    wHubCharacteristics: u16,
    bPwrOn2PwrGood: u8, // Time in 2ms intervals
    bHubContrCurrent: u8,
    // Variable length fields follow, handled manually

    pub const TYPE = 0x29;
};

/// Hub Status (Table 11-19)
pub const HubStatus = extern struct {
    wHubStatus: u16,
    wHubChange: u16,
};

/// Port Status (Table 11-21)
pub const PortStatus = extern struct {
    wPortStatus: u16,
    wPortChange: u16,

    pub const CONNECTION = 1 << 0;
    pub const ENABLE = 1 << 1;
    pub const SUSPEND = 1 << 2;
    pub const OVER_CURRENT = 1 << 3;
    pub const RESET = 1 << 4;
    pub const POWER = 1 << 8;
    pub const LOW_SPEED = 1 << 9;
    pub const HIGH_SPEED = 1 << 10;
    
    // Change bits (for wPortChange)
    pub const C_CONNECTION = 1 << 0;
    pub const C_ENABLE = 1 << 1;
    pub const C_SUSPEND = 1 << 2;
    pub const C_OVER_CURRENT = 1 << 3;
    pub const C_RESET = 1 << 4;
};

// =============================================================================
// Driver State
// =============================================================================

/// Function pointer type for enumerating devices (breaks dependency cycle)
pub const EnumerateDeviceFn = *const fn (
    ctrl: *types.Controller,
    parent: ?*device.UsbDevice,
    port_num: u8,
    route_string: u20,
    root_port_num: u8,
    speed_override: ?context.Speed
) anyerror!?*device.UsbDevice;

pub const HubDriver = struct {
    dev: *device.UsbDevice,
    ctrl: *types.Controller,

    // Hub Properties
    num_ports: u8 = 0,
    power_on_delay_ms: u32 = 0,
    
    // Endpoints
    int_in_ep: u8 = 0, // Endpoint address

    // Callback
    enumerate_fn: EnumerateDeviceFn,

    const Self = @This();

    pub fn init(ctrl: *types.Controller, dev: *device.UsbDevice, ep_in: u8, enumerate_fn: EnumerateDeviceFn) Self {
        return Self{
            .dev = dev,
            .ctrl = ctrl,
            .int_in_ep = ep_in,
            .enumerate_fn = enumerate_fn,
        };
    }

    /// Initialize the Hub: Read Descriptor, Power Ports
    pub fn configure(self: *Self) !void {
        console.info("HUB: Configuring Hub...", .{});

        // 1. Get Hub Descriptor
        // Security: Zero-initialize DMA buffer to prevent kernel memory leaks on short transfers
        var desc_buf: [32]u8 align(@alignOf(HubDescriptor)) = [_]u8{0} ** 32;
        try self.getHubDescriptor(&desc_buf);
        
        const desc: *const HubDescriptor = @ptrCast(&desc_buf);
        if (desc.bDescriptorType != HubDescriptor.TYPE) {
            console.warn("HUB: Invalid descriptor type 0x{x}", .{desc.bDescriptorType});
            return error.InvalidDescriptor;
        }

        const max_hub_ports: u8 = 127; 
        if (desc.bNbrPorts == 0 or desc.bNbrPorts > max_hub_ports) {
            console.err("HUB: Invalid port count {d} (must be 1-{d})", .{ desc.bNbrPorts, max_hub_ports });
            return error.InvalidDescriptor;
        }

        self.num_ports = desc.bNbrPorts;
        self.power_on_delay_ms = @as(u32, desc.bPwrOn2PwrGood) * 2;

        console.info("HUB: Found {d} ports, power delay {d}ms", .{self.num_ports, self.power_on_delay_ms});

        // 2. Power On All Ports
        var i: u8 = 1;
        while (i <= self.num_ports) : (i += 1) {
            // console.debug("HUB: Powering Port {d}", .{i});
            self.setPortFeature(i, .PORT_POWER) catch |err| {
                 console.warn("HUB: Failed to power port {d}: {}", .{i, err});
            };
        }

        // 3. Wait for power to stabilize
        if (self.power_on_delay_ms > 0) {
            const delay_ns: u64 = @as(u64, self.power_on_delay_ms) * 1_000_000;
            io.kernel_io.sleep(delay_ns) catch {
                console.warn("HUB: Failed to sleep for power-on delay, busy-waiting instead.", .{});
                self.busyWaitMs(self.power_on_delay_ms);
            };
        }
        console.info("HUB: Ports powered, waiting for devices...", .{});

        // 4. Start Status Change Interrupt Polling
        try self.checkStatus();
    }

    /// Send Get Hub Descriptor Request
    fn getHubDescriptor(self: *Self, buffer: []u8) !void {
        const transferred = try transfer.controlTransfer(
            self.ctrl,
            self.dev,
            @bitCast(@as(u8, 0xA0)), // Dir=IN, Type=Class, Recip=Device
            @intFromEnum(Request.GET_DESCRIPTOR), // bRequest
            @as(u16, HubDescriptor.TYPE) << 8, // wValue (Descriptor Type)
            0, // wIndex
            buffer,
            transfer.CONTROL_TIMEOUT_MS,
        );
        
        if (transferred < 7) { 
             return error.ShortTransfer;
        }
    }

    /// Get Hub Status
    fn getHubStatus(self: *Self) !HubStatus {
        // Security: Zero-initialize to prevent kernel memory leaks on short transfers
        var status: HubStatus = std.mem.zeroes(HubStatus);
        const buffer = std.mem.asBytes(&status);

        const transferred = try transfer.controlTransfer(
            self.ctrl,
            self.dev,
            @bitCast(@as(u8, 0xA0)), 
            @intFromEnum(Request.GET_STATUS),
            0, 
            0, 
            buffer,
            transfer.CONTROL_TIMEOUT_MS,
        );

        if (transferred != 4) return error.ShortTransfer;
        return status;
    }

    /// Clear Hub Feature
    fn clearHubFeature(self: *Self, feature: HubFeature) !void {
        _ = try transfer.controlTransfer(
            self.ctrl,
            self.dev,
            @bitCast(@as(u8, 0x20)), // Dir=OUT, Type=Class, Recip=Device
            @intFromEnum(Request.CLEAR_FEATURE),
            @intFromEnum(feature),
            0, 
            null,
            transfer.CONTROL_TIMEOUT_MS,
        );
    }

    /// Set Port Feature
    fn setPortFeature(self: *Self, port: u8, feature: PortFeature) !void {
        _ = try transfer.controlTransfer(
            self.ctrl,
            self.dev,
            @bitCast(@as(u8, 0x23)), // Dir=OUT, Type=Class, Recip=Other (Port)
            @intFromEnum(Request.SET_FEATURE), 
            @intFromEnum(feature), 
            @as(u16, port), 
            null,
            transfer.CONTROL_TIMEOUT_MS,
        );
    }
    
    /// Get Port Status
    pub fn getPortStatus(self: *Self, port: u8) !PortStatus {
        // Security: Zero-initialize to prevent kernel memory leaks on short transfers
        var status: PortStatus = std.mem.zeroes(PortStatus);
        const buffer = std.mem.asBytes(&status);
        
        const transferred = try transfer.controlTransfer(
            self.ctrl,
            self.dev,
            @bitCast(@as(u8, 0xA3)), // Dir=IN, Type=Class, Recip=Other (Port)
            @intFromEnum(Request.GET_STATUS),
            0, 
            @as(u16, port), 
            buffer,
            transfer.CONTROL_TIMEOUT_MS,
        );
        
        if (transferred != 4) return error.ShortTransfer;
        return status;
    }


    /// Start polling for status changes
    pub fn checkStatus(self: *Self) !void {
        // Start interrupt polling via XHCI controller (using device manager through callback?)
        // Wait, startInterruptPolling is in device_manager.zig.
        // But HubDriver doesn't know about device_manager.zig.
        // It knows about self.ctrl and self.dev.
        // The original code called self.ctrl.startInterruptPolling(self.dev).
        // Since Controller has no methods, this fails.
        // I need pass a callback for polling too? Or assume enumerate_fn is enough?
        // Wait, checkStatus -> startInterruptPolling.
        // startInterruptPolling -> queueInterruptTransfer.
        // queueInterruptTransfer is in transfer/interrupt.zig.
        // hub.zig can import transfer/interrupt.zig?
        // No, startInterruptPolling also sets device state to .polling.
        // I should probably move startInterruptPolling to `transfer/interrupt.zig` or keep in `device_manager`.
        
        // Strategy:
        // Import `transfer/interrupt.zig` here and use it directly?
        // `const interrupt_transfer = @import("../xhci/transfer/interrupt.zig");`
        // `interrupt_transfer.queueInterruptTransfer(self.ctrl, self.dev);`
        // `self.dev.state = .polling;`
        // This duplicates logic from `device_manager.startInterruptPolling`.
        // But acceptable.
        
        const interrupt_transfer = @import("../xhci/transfer/interrupt.zig");
        try interrupt_transfer.queueInterruptTransfer(self.ctrl, self.dev);
        self.dev.state = .polling;
    }

    /// Handle Interrupt IN report (Status Change Bitmap)
    pub fn handleInterrupt(self: *Self, report: []u8) void {
        const len = report.len;
        if (len == 0) return;

        // Bit 0: Hub Status Change
        if ((report[0] & 1) != 0) {
            console.info("HUB: Hub Status Change detected", .{});
            self.handleHubStatusChange();
        }

        // Port Status Changes (Bits 1..N)
        var port_idx: u8 = 1;
        while (port_idx <= self.num_ports) : (port_idx += 1) {
            const byte_idx = port_idx / 8;
            const bit_mask = @as(u8, 1) << @truncate(port_idx % 8);
            
            if (byte_idx < len and (report[byte_idx] & bit_mask) != 0) {
                console.info("HUB: Port {d} Status Change", .{port_idx});
                self.handlePortStatusChange(port_idx) catch |err| {
                    console.err("HUB: Failed to handle port {d} change: {}", .{port_idx, err});
                };
            }
        }
    }

    /// Handle Port Status Change Event
    fn handlePortStatusChange(self: *Self, port: u8) !void {
        const status = try self.getPortStatus(port);
        console.debug("HUB: Port {d} Status: 0x{x} Change: 0x{x}", .{ port, status.wPortStatus, status.wPortChange });
        
        // Handle Connect Status Change
        if ((status.wPortChange & PortStatus.C_CONNECTION) != 0) {
            try self.setPortFeature(port, .C_PORT_CONNECTION);
            
            if ((status.wPortStatus & PortStatus.CONNECTION) != 0) {
                console.info("HUB: Port {d} Device Connected", .{port});
                try self.handleConnect(port);
            } else {
                console.info("HUB: Port {d} Device Disconnected", .{port});
                self.handleDisconnect(port);
            }
        }
        
        if ((status.wPortChange & PortStatus.C_RESET) != 0) {
            try self.setPortFeature(port, .C_PORT_RESET);
            console.info("HUB: Port {d} Reset Complete", .{port});
        }
    }

    /// Handle Device Connection
    fn handleConnect(self: *Self, port: u8) !void {
        console.info("HUB: Resetting Port {d}...", .{port});
        try self.setPortFeature(port, .PORT_RESET);
        
        var timeout: u32 = 100;
        while (timeout > 0) : (timeout -= 1) {
            const status = try self.getPortStatus(port);
            if ((status.wPortChange & PortStatus.C_RESET) != 0) {
                break;
            }
             var delay: u32 = 10000;
            while (delay > 0) : (delay -= 1) {
                std.atomic.spinLoopHint();
            }
        }
        
        try self.setPortFeature(port, .C_PORT_RESET);
        
        const status = try self.getPortStatus(port);
        if ((status.wPortStatus & PortStatus.ENABLE) == 0) {
            console.err("HUB: Port {d} failed to enable after reset", .{port});
            return error.ResetFailed;
        }

        var speed: context.Speed = .full_speed; 
        if ((status.wPortStatus & PortStatus.LOW_SPEED) != 0) {
            speed = .low_speed;
        } else if ((status.wPortStatus & PortStatus.HIGH_SPEED) != 0) {
            speed = .high_speed;
        }

        console.info("HUB: Port {d} Enabled, Speed={}, Enumerating...", .{port, @intFromEnum(speed)});

        var route_string: u20 = 0;
        if (self.dev.parent != null) {
             route_string = port;
        } else {
             route_string = port;
        }

        // Call recursive enumeration via callback
       const maybe_child = try self.enumerate_fn(self.ctrl, self.dev, port, route_string, self.dev.port, speed);
       
       if (maybe_child) |child| {
           // Start polling for child devices that need it
           const interrupt_tr = @import("../xhci/transfer/interrupt.zig");
           if (child.is_hub or child.hid_driver.is_keyboard or child.hid_driver.is_mouse) {
               interrupt_tr.queueInterruptTransfer(self.ctrl, child) catch |err| {
                   console.err("HUB: Failed to start child polling: {}", .{err});
               };
               child.state = .polling;
           }
       }
    }

    fn handleDisconnect(self: *Self, port: u8) void {
        if (device.findChildDevice(self.dev, port)) |child| {
            const slot_id = child.slot_id;
            device.unregisterDevice(slot_id);
            child.deinit();
            console.info("HUB: Port {d} device removed (slot {d})", .{ port, slot_id });
        } else {
            console.warn("HUB: Port {d} disconnect without tracked device", .{port});
        }
    }

    fn handleHubStatusChange(self: *Self) void {
        const status = self.getHubStatus() catch |err| {
            console.warn("HUB: Failed to read hub status: {}", .{err});
            return;
        };

        if ((status.wHubChange & 1) != 0) {
            self.clearHubFeature(.C_HUB_LOCAL_POWER) catch {};
        }

        if ((status.wHubChange & 2) != 0) {
            self.clearHubFeature(.C_HUB_OVER_CURRENT) catch {};
        }
    }

    fn busyWaitMs(self: *Self, ms: u32) void {
        _ = self;
        var remaining: u32 = ms;
        while (remaining > 0) : (remaining -= 1) {
            var delay: u32 = 10000;
            while (delay > 0) : (delay -= 1) {
                std.atomic.spinLoopHint();
            }
        }
    }
};
