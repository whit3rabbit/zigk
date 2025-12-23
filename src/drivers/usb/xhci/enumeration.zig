const std = @import("std");
const console = @import("console");
const usb_types = @import("../types.zig"); // Common USB types (not XHCI types)

/// Information about a keyboard interface found in config descriptor
pub const KeyboardInfo = struct {
    interface_num: u8,
    endpoint_addr: u8,
    max_packet: u16,
    interval: u8,
};

/// Information about a mouse interface found in config descriptor
pub const MouseInfo = struct {
    interface_num: u8,
    endpoint_addr: u8,
    max_packet: u16,
    interval: u8,
};

/// Information about an MSC interface found in config descriptor
pub const MscInfo = struct {
    interface_num: u8,
    bulk_in_ep: u8,
    bulk_out_ep: u8,
    max_packet: u16,
};

/// Information about a Hub interface found in config descriptor
pub const HubInfo = struct {
    interface_num: u8,
    int_in_ep: u8,
    max_packet: u16,
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
                    // Security: Copy to aligned buffer instead of pointer cast
                    // This avoids UB from misaligned access on USB descriptors
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

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
                    // Security: Copy to aligned buffer instead of pointer cast
                    var ep: usb_types.EndpointDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

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
                    // Security: Copy to aligned buffer instead of pointer cast
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

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
                    // Security: Copy to aligned buffer instead of pointer cast
                    var ep: usb_types.EndpointDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

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

/// Information about a generic HID interface found in config descriptor
/// Used for devices that don't use Boot Protocol (SubClass != 0x01)
/// such as tablets, touchscreens, and digitizers
pub const GenericHidInfo = struct {
    interface_num: u8,
    endpoint_addr: u8,
    max_packet: u16,
    interval: u8,
    subclass: u8,
    protocol: u8,
};

/// Parse configuration descriptor to find a generic HID interface
/// This matches any HID device (Class=0x03) with an Interrupt IN endpoint,
/// even if it doesn't use Boot Protocol. Used for tablets, touchscreens, etc.
pub fn findGenericHidInterface(config_data: []const u8) ?GenericHidInfo {
    var i: usize = 0;

    var current_interface: ?u8 = null;
    var current_subclass: u8 = 0;
    var current_protocol: u8 = 0;
    var is_hid = false;

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
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

                    current_interface = iface.b_interface_number;
                    current_subclass = iface.b_interface_sub_class;
                    current_protocol = iface.b_interface_protocol;

                    // Any HID device (Class = 0x03)
                    is_hid = (iface.b_interface_class == 0x03);

                    if (is_hid) {
                        console.debug("XHCI: Found HID interface {} (subclass={}, protocol={})", .{
                            iface.b_interface_number,
                            iface.b_interface_sub_class,
                            iface.b_interface_protocol,
                        });
                    }
                }
            },
            usb_types.DescriptorType.ENDPOINT => {
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= ep_desc_size and is_hid and current_interface != null) {
                    var ep: usb_types.EndpointDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

                    const addr = ep.getAddress();
                    const attrs = ep.getAttributes();
                    const is_in = addr.direction == .in;
                    const is_interrupt = attrs.transfer_type == .interrupt;

                    if (is_in and is_interrupt) {
                        console.info("XHCI: Found generic HID interrupt endpoint 0x{x:0>2}, max_packet={}, interval={}", .{
                            ep.b_endpoint_address,
                            ep.w_max_packet_size,
                            ep.b_interval,
                        });

                        return GenericHidInfo{
                            .interface_num = current_interface.?,
                            .endpoint_addr = ep.b_endpoint_address,
                            .max_packet = ep.w_max_packet_size,
                            .interval = ep.b_interval,
                            .subclass = current_subclass,
                            .protocol = current_protocol,
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
                    // Security: Copy to aligned buffer instead of pointer cast
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

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

                if (is_msc and current_interface != null) {
                    if (length >= ep_desc_size) {
                        // Security: Copy to aligned buffer instead of pointer cast
                        var ep: usb_types.EndpointDescriptor = undefined;
                        @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

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

                        if (bulk_in != null and bulk_out != null) {
                            return MscInfo{
                                .interface_num = current_interface.?,
                                .bulk_in_ep = bulk_in.?,
                                .bulk_out_ep = bulk_out.?,
                                .max_packet = max_packet_size,
                            };
                        }
                    }
                }
            },
            else => {},
        }
        i += length;
    }

    return null;
}

// =============================================================================
// Multi-Interface Enumeration Support
// =============================================================================
// The unified parser below collects ALL interfaces from a configuration
// descriptor, enabling proper support for composite devices (keyboard+mouse,
// USB storage, etc.). The legacy findXxxInterface functions above are kept
// for backwards compatibility but are deprecated.

/// Maximum number of interfaces per USB device
/// USB spec allows up to 256 interfaces, but we cap for memory safety
pub const MAX_INTERFACES_PER_DEVICE: usize = 16;

/// Maximum endpoints per interface
pub const MAX_ENDPOINTS_PER_INTERFACE: usize = 4;

/// Endpoint information extracted from descriptor
pub const EndpointInfo = struct {
    address: u8,
    attributes: u8,
    max_packet_size: u16,
    interval: u8,

    /// Check if this is an IN endpoint
    pub fn isIn(self: EndpointInfo) bool {
        return (self.address & 0x80) != 0;
    }

    /// Check if this is an OUT endpoint
    pub fn isOut(self: EndpointInfo) bool {
        return (self.address & 0x80) == 0;
    }

    /// Get endpoint number (0-15)
    pub fn getNumber(self: EndpointInfo) u4 {
        return @truncate(self.address & 0x0F);
    }

    /// Get transfer type from attributes
    pub fn getTransferType(self: EndpointInfo) usb_types.EndpointAttributes.TransferType {
        return @enumFromInt(self.attributes & 0x03);
    }

    /// Check if this is an interrupt endpoint
    pub fn isInterrupt(self: EndpointInfo) bool {
        return self.getTransferType() == .interrupt;
    }

    /// Check if this is a bulk endpoint
    pub fn isBulk(self: EndpointInfo) bool {
        return self.getTransferType() == .bulk;
    }
};

/// Interface information extracted from descriptor
pub const InterfaceInfo = struct {
    interface_num: u8,
    alternate_setting: u8,
    class: u8,
    subclass: u8,
    protocol: u8,
    num_endpoints: u8,
    endpoints: [MAX_ENDPOINTS_PER_INTERFACE]EndpointInfo,
    endpoint_count: u8,

    /// Check if this is a HID Boot Keyboard (Class 0x03, SubClass 0x01, Protocol 0x01)
    pub fn isKeyboard(self: InterfaceInfo) bool {
        return self.class == 0x03 and self.subclass == 0x01 and self.protocol == 0x01;
    }

    /// Check if this is a HID Boot Mouse (Class 0x03, SubClass 0x01, Protocol 0x02)
    pub fn isMouse(self: InterfaceInfo) bool {
        return self.class == 0x03 and self.subclass == 0x01 and self.protocol == 0x02;
    }

    /// Check if this is any HID device (Class 0x03)
    pub fn isHid(self: InterfaceInfo) bool {
        return self.class == 0x03;
    }

    /// Check if this is MSC BOT (Class 0x08, SubClass 0x06, Protocol 0x50)
    pub fn isMscBot(self: InterfaceInfo) bool {
        return self.class == 0x08 and self.subclass == 0x06 and self.protocol == 0x50;
    }

    /// Check if this is a Hub (Class 0x09)
    pub fn isHub(self: InterfaceInfo) bool {
        return self.class == 0x09;
    }

    /// Find the first interrupt IN endpoint for this interface
    pub fn findInterruptIn(self: *const InterfaceInfo) ?*const EndpointInfo {
        for (&self.endpoints, 0..) |*ep, idx| {
            if (idx >= self.endpoint_count) break;
            if (ep.isIn() and ep.isInterrupt()) {
                return ep;
            }
        }
        return null;
    }

    /// Find the first bulk IN endpoint for this interface
    pub fn findBulkIn(self: *const InterfaceInfo) ?*const EndpointInfo {
        for (&self.endpoints, 0..) |*ep, idx| {
            if (idx >= self.endpoint_count) break;
            if (ep.isIn() and ep.isBulk()) {
                return ep;
            }
        }
        return null;
    }

    /// Find the first bulk OUT endpoint for this interface
    pub fn findBulkOut(self: *const InterfaceInfo) ?*const EndpointInfo {
        for (&self.endpoints, 0..) |*ep, idx| {
            if (idx >= self.endpoint_count) break;
            if (ep.isOut() and ep.isBulk()) {
                return ep;
            }
        }
        return null;
    }
};

/// Result of parsing a complete configuration descriptor
pub const ParseResult = struct {
    interfaces: [MAX_INTERFACES_PER_DEVICE]InterfaceInfo,
    interface_count: u8,
    config_value: u8,

    /// Find first interface matching class (and optionally subclass/protocol)
    pub fn findFirst(self: *const ParseResult, class: u8, subclass_opt: ?u8, protocol_opt: ?u8) ?*const InterfaceInfo {
        for (&self.interfaces, 0..) |*iface, idx| {
            if (idx >= self.interface_count) break;
            if (iface.class != class) continue;
            if (subclass_opt) |sc| if (iface.subclass != sc) continue;
            if (protocol_opt) |pr| if (iface.protocol != pr) continue;
            return iface;
        }
        return null;
    }

    /// Get interface slice for iteration
    pub fn getInterfaces(self: *const ParseResult) []const InterfaceInfo {
        return self.interfaces[0..self.interface_count];
    }
};

/// Parse entire configuration descriptor and extract ALL interfaces
/// Security: Validates all descriptor bounds against actual buffer size,
/// not just the claimed b_length field from untrusted device data.
/// Returns null if parsing fails or no valid interfaces found.
pub fn parseConfigDescriptor(config_data: []const u8) ?ParseResult {
    var result = ParseResult{
        .interfaces = undefined,
        .interface_count = 0,
        .config_value = 0,
    };

    // Zero-initialize all interface data for security
    @memset(std.mem.asBytes(&result.interfaces), 0);

    var i: usize = 0;
    var current_interface_idx: ?usize = null;

    const config_desc_size = @sizeOf(usb_types.ConfigurationDescriptor);
    const iface_desc_size = @sizeOf(usb_types.InterfaceDescriptor);
    const ep_desc_size = @sizeOf(usb_types.EndpointDescriptor);

    while (i + 2 <= config_data.len) {
        const length = config_data[i];
        const desc_type = config_data[i + 1];

        // Validate length field from device data
        if (length < 2) break; // Minimum descriptor size is 2 bytes
        if (i + length > config_data.len) break; // Claimed length exceeds buffer

        switch (desc_type) {
            usb_types.DescriptorType.CONFIGURATION => {
                if (length >= config_desc_size and i + config_desc_size <= config_data.len) {
                    var config: usb_types.ConfigurationDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&config), config_data[i..][0..config_desc_size]);
                    result.config_value = config.b_configuration_value;
                    console.debug("XHCI: Config descriptor: {} interfaces, config_value={}", .{
                        config.b_num_interfaces,
                        config.b_configuration_value,
                    });
                }
            },

            usb_types.DescriptorType.INTERFACE => {
                // Security: Check actual struct size, not just claimed length
                const required_size = @max(length, iface_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= iface_desc_size and result.interface_count < MAX_INTERFACES_PER_DEVICE) {
                    // Security: Copy to aligned buffer instead of pointer cast
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

                    // Only process alternate setting 0 (default)
                    // Alternate settings are for bandwidth negotiation, not additional functionality
                    if (iface.b_alternate_setting == 0) {
                        const idx = result.interface_count;
                        result.interfaces[idx] = InterfaceInfo{
                            .interface_num = iface.b_interface_number,
                            .alternate_setting = iface.b_alternate_setting,
                            .class = iface.b_interface_class,
                            .subclass = iface.b_interface_sub_class,
                            .protocol = iface.b_interface_protocol,
                            .num_endpoints = iface.b_num_endpoints,
                            .endpoints = undefined,
                            .endpoint_count = 0,
                        };
                        @memset(std.mem.asBytes(&result.interfaces[idx].endpoints), 0);

                        current_interface_idx = idx;
                        result.interface_count += 1;

                        console.debug("XHCI: Interface {}: class=0x{x:0>2}, subclass=0x{x:0>2}, protocol=0x{x:0>2}", .{
                            iface.b_interface_number,
                            iface.b_interface_class,
                            iface.b_interface_sub_class,
                            iface.b_interface_protocol,
                        });
                    }
                }
            },

            usb_types.DescriptorType.ENDPOINT => {
                // Security: Check actual struct size, not just claimed length
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (length >= ep_desc_size and current_interface_idx != null) {
                    const iface_idx = current_interface_idx.?;
                    if (result.interfaces[iface_idx].endpoint_count < MAX_ENDPOINTS_PER_INTERFACE) {
                        // Security: Copy to aligned buffer instead of pointer cast
                        var ep: usb_types.EndpointDescriptor = undefined;
                        @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

                        const ep_idx = result.interfaces[iface_idx].endpoint_count;
                        result.interfaces[iface_idx].endpoints[ep_idx] = EndpointInfo{
                            .address = ep.b_endpoint_address,
                            .attributes = ep.bm_attributes,
                            .max_packet_size = ep.w_max_packet_size,
                            .interval = ep.b_interval,
                        };
                        result.interfaces[iface_idx].endpoint_count += 1;

                        console.debug("XHCI:   Endpoint 0x{x:0>2}: type={s}, max_packet={}", .{
                            ep.b_endpoint_address,
                            @tagName(result.interfaces[iface_idx].endpoints[ep_idx].getTransferType()),
                            ep.w_max_packet_size,
                        });
                    }
                }
            },

            else => {},
        }

        i += length;
    }

    if (result.interface_count == 0) {
        console.warn("XHCI: No interfaces found in config descriptor", .{});
        return null;
    }

    console.info("XHCI: Parsed {} interface(s) from config descriptor", .{result.interface_count});
    return result;
}

// =============================================================================
// Legacy Functions (Deprecated - kept for backwards compatibility)
// =============================================================================

/// Parse configuration descriptor to find Generic Hub interface
/// Security: Validates all descriptor bounds against actual buffer size,
/// not just the claimed b_length field from untrusted device data.
/// @deprecated Use parseConfigDescriptor() and InterfaceInfo.isHub() instead
pub fn findHubInterface(config_data: []const u8) ?HubInfo {
    var i: usize = 0;

    var current_interface: ?u8 = null;
    var is_hub = false;

    // Default to EP 0 if strangely not found, but we really want the INT IN EP
    var int_in: ?u8 = null;
    var max_packet_size: u16 = 0;

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
                    // Security: Copy to aligned buffer instead of pointer cast
                    var iface: usb_types.InterfaceDescriptor = undefined;
                    @memcpy(std.mem.asBytes(&iface), config_data[i..][0..iface_desc_size]);

                    current_interface = iface.b_interface_number;

                    // Class 0x09 (Hub)
                    is_hub = (iface.b_interface_class == 0x09);

                    // Reset endpoint search
                    int_in = null;
                }
            },
            usb_types.DescriptorType.ENDPOINT => {
                // Security: Check actual struct size for endpoint descriptor
                const required_size = @max(length, ep_desc_size);
                if (i + required_size > config_data.len) break;

                if (is_hub and current_interface != null) {
                    if (length >= ep_desc_size) {
                        // Security: Copy to aligned buffer instead of pointer cast
                        var ep: usb_types.EndpointDescriptor = undefined;
                        @memcpy(std.mem.asBytes(&ep), config_data[i..][0..ep_desc_size]);

                        const addr = ep.getAddress();
                        const attrs = ep.getAttributes();

                        // Interrupt IN endpoint
                        if (attrs.transfer_type == .interrupt and addr.direction == .in) {
                            int_in = ep.b_endpoint_address;
                            max_packet_size = ep.w_max_packet_size;

                            return HubInfo{
                                .interface_num = current_interface.?,
                                .int_in_ep = int_in.?,
                                .max_packet = max_packet_size,
                            };
                        }
                    }
                }
            },
            else => {},
        }
        i += length;
    }

    return null;
}
