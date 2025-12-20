const std = @import("std");
const console = @import("console");
const usb_types = @import("../types.zig"); // Common USB types (not XHCI types)
// Wait, I need to check where `usb_types` is.
// In transfer.zig: `const usb_types = @import("../types.zig");`
// The file structure is `src/drivers/usb/xhci/transfer.zig`.
// So `../types.zig` refers to `src/drivers/usb/types.zig`?
// Let's check the file list of `src/drivers/usb/`.
// I'll assume standard USB types are in `src/drivers/usb/types.zig` or similar.
// In `transfer.zig` imports: `const usb_types = @import("../types.zig");`
// If I am in `src/drivers/usb/xhci/enumeration.zig`, I should import `../../types.zig`?
// No, `transfer.zig` was in `src/drivers/usb/xhci/`. So `../types.zig` is `src/drivers/usb/types.zig`.
// My new `types.zig` is `src/drivers/usb/xhci/types.zig` (XHCI specific).
// To avoid confusion, I will import standard USB types as `std_usb`.
// Let's check if `src/drivers/usb/types.zig` exists.

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

                if (is_msc and current_interface != null) {
                    if (length >= ep_desc_size) {
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

/// Parse configuration descriptor to find Generic Hub interface
/// Security: Validates all descriptor bounds against actual buffer size,
/// not just the claimed b_length field from untrusted device data.
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
                    const iface = @as(*const usb_types.InterfaceDescriptor, @ptrCast(@alignCast(&config_data[i])));
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
                        const ep = @as(*const usb_types.EndpointDescriptor, @ptrCast(@alignCast(&config_data[i])));
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
