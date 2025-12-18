// USB Hub Class Driver
//
// Implements Generic Hub Support (Class 0x09).
// Reference: USB 2.0 Specification, Chapter 11 (Hub Specification)

const std = @import("std");
const console = @import("console");
const usb = @import("../xhci/root.zig"); // Access to generic USB types/transfer
const device = @import("../xhci/device.zig");

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
pub const Feature = enum(u16) {
    C_HUB_LOCAL_POWER = 0,
    C_HUB_OVER_CURRENT = 1,
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
/// Note: Variable length due to DeviceRemovable and PortPwrCtrlMask
pub const HubDescriptor = extern struct {
    bDescLength: u8,
    bDescriptorType: u8, // 0x29
    bNbrPorts: u8,
    wHubCharacteristics: u16,
    bPwrOn2PwrGood: u8, // Time in 2ms intervals
    bHubContrCurrent: u8,
    // Variable length fields follow, handled manually
    // DeviceRemovable: [bNbrPorts/8 + 1]u8
    // PortPwrCtrlMask: [bNbrPorts/8 + 1]u8

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
};

// =============================================================================
// Driver State
// =============================================================================

pub const HubDriver = struct {
    dev: *device.UsbDevice,
    ctrl: *usb.Controller,

    // Hub Properties
    num_ports: u8 = 0,
    power_on_delay_ms: u32 = 0,
    
    // Endpoints
    int_in_ep: u8 = 0, // Endpoint address

    const Self = @This();

    pub fn init(ctrl: *usb.Controller, dev: *device.UsbDevice, ep_in: u8) Self {
        return Self{
            .dev = dev,
            .ctrl = ctrl,
            .int_in_ep = ep_in,
        };
    }

    /// Initialize the Hub: Read Descriptor, Power Ports
    pub fn configure(self: *Self) !void {
        console.info("HUB: Configuring Hub...", .{});

        // 1. Get Hub Descriptor
        var desc_buf: [32]u8 = undefined; // Max size for standard hub desc
        try self.getHubDescriptor(&desc_buf);
        
        const desc: *const HubDescriptor = @ptrCast(&desc_buf);
        if (desc.bDescriptorType != HubDescriptor.TYPE) {
            console.warn("HUB: Invalid descriptor type 0x{x}", .{desc.bDescriptorType});
            return error.InvalidDescriptor;
        }

        self.num_ports = desc.bNbrPorts;
        self.power_on_delay_ms = @as(u32, desc.bPwrOn2PwrGood) * 2;

        console.info("HUB: Found {d} ports, power delay {d}ms", .{self.num_ports, self.power_on_delay_ms});

        // 2. Power On All Ports
        var i: u8 = 1;
        while (i <= self.num_ports) : (i += 1) {
            console.debug("HUB: Powering Port {d}", .{i});
            self.setPortFeature(i, .PORT_POWER) catch |err| {
                 console.warn("HUB: Failed to power port {d}: {}", .{i, err});
            };
        }

        // 3. Wait for power to stabilize
        // TODO: Implement proper sleep. For now, we assume the boot delay covers it or rely on busy wait if available.
        // hal.timer.sleep(self.power_on_delay_ms); 
        console.info("HUB: Ports powered, waiting for devices...", .{});
    }

    /// Send Get Hub Descriptor Request
    fn getHubDescriptor(self: *Self, buffer: []u8) !void {
        const setup = usb.SetupPacket{
            .bmRequestType = 0xA0, // Dir=IN, Type=Class, Recip=Device
            .bRequest = @intFromEnum(Request.GET_DESCRIPTOR),
            .wValue = @as(u16, HubDescriptor.TYPE) << 8, // Descriptor Type
            .wIndex = 0,
            .wLength = @truncate(buffer.len),
        };
        
        const transferred = try usb.Transfer.controlTransfer(
            self.ctrl, 
            self.dev, 
            setup, 
            buffer
        );
        
        if (transferred < 7) { // Min Hub Desc length
             return error.ShortTransfer;
        }
    }

    /// Set Port Feature
    fn setPortFeature(self: *Self, port: u8, feature: Feature) !void {
         const setup = usb.SetupPacket{
            .bmRequestType = 0x23, // Dir=OUT, Type=Class, Recip=Other (Port)
            .bRequest = @intFromEnum(Request.SET_FEATURE),
            .wValue = @intFromEnum(feature),
            .wIndex = port, // Port number in wIndex
            .wLength = 0,
        };

        _ = try usb.Transfer.controlTransfer(
            self.ctrl,
            self.dev,
            setup,
            null
        );
    }
    
    /// Get Port Status
    pub fn getPortStatus(self: *Self, port: u8) !PortStatus {
        var status: PortStatus = undefined;
        const buffer = std.mem.asBytes(&status);
        
        const setup = usb.SetupPacket{
            .bmRequestType = 0xA3, // Dir=IN, Type=Class, Recip=Other (Port)
            .bRequest = @intFromEnum(Request.GET_STATUS),
            .wValue = 0,
            .wIndex = port,
            .wLength = 4,
        };

        const transferred = try usb.Transfer.controlTransfer(
            self.ctrl,
            self.dev,
            setup,
            buffer
        );
        
        if (transferred != 4) return error.ShortTransfer;
        return status;
    }

    // TODO: Implement Interrupt Transfer handling for Status Change
};
