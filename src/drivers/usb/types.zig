// USB Types and Descriptors
//
// Common USB structures used by host controller drivers and class drivers.
// All structures are packed to match USB wire format (little-endian).
//
// Reference: USB 2.0 Specification, Chapter 9

// =============================================================================
// USB Request Types
// =============================================================================

/// USB Setup Packet (8 bytes)
pub const SetupPacket = packed struct {
    bm_request_type: RequestType,
    b_request: u8,
    w_value: u16,
    w_index: u16,
    w_length: u16,

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("SetupPacket must be 8 bytes");
    }
};

/// bmRequestType field breakdown
pub const RequestType = packed struct(u8) {
    recipient: Recipient,
    type: Type,
    direction: Direction,

    pub const Recipient = enum(u5) {
        device = 0,
        interface = 1,
        endpoint = 2,
        other = 3,
        _,
    };

    pub const Type = enum(u2) {
        standard = 0,
        class = 1,
        vendor = 2,
        reserved = 3,
    };

    pub const Direction = enum(u1) {
        host_to_device = 0,
        device_to_host = 1,
    };
};

/// Standard USB Request codes (bRequest field)
pub const Request = struct {
    pub const GET_STATUS: u8 = 0;
    pub const CLEAR_FEATURE: u8 = 1;
    pub const SET_FEATURE: u8 = 3;
    pub const SET_ADDRESS: u8 = 5;
    pub const GET_DESCRIPTOR: u8 = 6;
    pub const SET_DESCRIPTOR: u8 = 7;
    pub const GET_CONFIGURATION: u8 = 8;
    pub const SET_CONFIGURATION: u8 = 9;
    pub const GET_INTERFACE: u8 = 10;
    pub const SET_INTERFACE: u8 = 11;
    pub const SYNCH_FRAME: u8 = 12;
};

// =============================================================================
// USB Descriptors
// =============================================================================

/// Descriptor type values
pub const DescriptorType = struct {
    pub const DEVICE: u8 = 1;
    pub const CONFIGURATION: u8 = 2;
    pub const STRING: u8 = 3;
    pub const INTERFACE: u8 = 4;
    pub const ENDPOINT: u8 = 5;
    pub const DEVICE_QUALIFIER: u8 = 6;
    pub const OTHER_SPEED_CONFIG: u8 = 7;
    pub const INTERFACE_POWER: u8 = 8;
    pub const OTG: u8 = 9;
    pub const DEBUG: u8 = 10;
    pub const INTERFACE_ASSOCIATION: u8 = 11;
    pub const HID: u8 = 0x21;
    pub const HID_REPORT: u8 = 0x22;
    pub const HID_PHYSICAL: u8 = 0x23;
};

/// Device Descriptor (18 bytes)
pub const DeviceDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8,
    bcd_usb: u16,
    b_device_class: u8,
    b_device_sub_class: u8,
    b_device_protocol: u8,
    b_max_packet_size0: u8,
    id_vendor: u16,
    id_product: u16,
    bcd_device: u16,
    i_manufacturer: u8,
    i_product: u8,
    i_serial_number: u8,
    b_num_configurations: u8,

    comptime {
        if (@sizeOf(@This()) != 18) @compileError("DeviceDescriptor must be 18 bytes");
    }
};

/// Configuration Descriptor Header (9 bytes)
pub const ConfigurationDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8,
    w_total_length: u16,
    b_num_interfaces: u8,
    b_configuration_value: u8,
    i_configuration: u8,
    bm_attributes: ConfigAttributes,
    b_max_power: u8, // In 2mA units

    comptime {
        if (@sizeOf(@This()) != 9) @compileError("ConfigurationDescriptor must be 9 bytes");
    }
};

/// Configuration bmAttributes
pub const ConfigAttributes = packed struct(u8) {
    _reserved0: u5 = 0,
    remote_wakeup: bool,
    self_powered: bool,
    _reserved1: u1 = 1, // Must be 1 for USB 1.0 compatibility
};

/// Interface Descriptor (9 bytes)
pub const InterfaceDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8,
    b_interface_number: u8,
    b_alternate_setting: u8,
    b_num_endpoints: u8,
    b_interface_class: u8,
    b_interface_sub_class: u8,
    b_interface_protocol: u8,
    i_interface: u8,

    comptime {
        if (@sizeOf(@This()) != 9) @compileError("InterfaceDescriptor must be 9 bytes");
    }
};

/// Endpoint Descriptor (7 bytes)
pub const EndpointDescriptor = packed struct {
    b_length: u8,
    b_descriptor_type: u8,
    b_endpoint_address: EndpointAddress,
    bm_attributes: EndpointAttributes,
    w_max_packet_size: u16,
    b_interval: u8,

    comptime {
        if (@sizeOf(@This()) != 7) @compileError("EndpointDescriptor must be 7 bytes");
    }
};

/// Endpoint address breakdown
pub const EndpointAddress = packed struct(u8) {
    endpoint_number: u4,
    _reserved: u3 = 0,
    direction: Direction,

    pub const Direction = enum(u1) {
        out = 0,
        in = 1,
    };
};

/// Endpoint bmAttributes
pub const EndpointAttributes = packed struct(u8) {
    transfer_type: TransferType,
    sync_type: u2,
    usage_type: u2,
    _reserved: u2 = 0,

    pub const TransferType = enum(u2) {
        control = 0,
        isochronous = 1,
        bulk = 2,
        interrupt = 3,
    };
};

// =============================================================================
// USB Device Classes
// =============================================================================

pub const DeviceClass = struct {
    pub const PER_INTERFACE: u8 = 0x00;
    pub const AUDIO: u8 = 0x01;
    pub const CDC: u8 = 0x02;
    pub const HID: u8 = 0x03;
    pub const PHYSICAL: u8 = 0x05;
    pub const IMAGE: u8 = 0x06;
    pub const PRINTER: u8 = 0x07;
    pub const MASS_STORAGE: u8 = 0x08;
    pub const HUB: u8 = 0x09;
    pub const CDC_DATA: u8 = 0x0A;
    pub const SMART_CARD: u8 = 0x0B;
    pub const CONTENT_SECURITY: u8 = 0x0D;
    pub const VIDEO: u8 = 0x0E;
    pub const PERSONAL_HEALTHCARE: u8 = 0x0F;
    pub const AUDIO_VIDEO: u8 = 0x10;
    pub const DIAGNOSTIC: u8 = 0xDC;
    pub const WIRELESS: u8 = 0xE0;
    pub const MISCELLANEOUS: u8 = 0xEF;
    pub const APPLICATION_SPECIFIC: u8 = 0xFE;
    pub const VENDOR_SPECIFIC: u8 = 0xFF;
};

// =============================================================================
// USB Speed
// =============================================================================

pub const Speed = enum(u3) {
    invalid = 0,
    full = 1, // 12 Mbps (USB 1.1)
    low = 2, // 1.5 Mbps (USB 1.1)
    high = 3, // 480 Mbps (USB 2.0)
    super = 4, // 5 Gbps (USB 3.0)
    super_plus = 5, // 10 Gbps (USB 3.1)
    _,

    pub fn maxPacketSize(self: Speed) u16 {
        return switch (self) {
            .low => 8,
            .full => 64,
            .high => 512,
            .super, .super_plus => 1024,
            else => 8,
        };
    }
};

// =============================================================================
// USB Device State
// =============================================================================

pub const DeviceState = enum {
    detached,
    attached,
    powered,
    default,
    addressed,
    configured,
    suspended,
};

// =============================================================================
// Helper functions
// =============================================================================

/// Build wValue for GET_DESCRIPTOR request
pub fn descriptorValue(desc_type: u8, desc_index: u8) u16 {
    return (@as(u16, desc_type) << 8) | @as(u16, desc_index);
}

/// Build RequestType byte
pub fn makeRequestType(
    direction: RequestType.Direction,
    req_type: RequestType.Type,
    recipient: RequestType.Recipient,
) RequestType {
    return RequestType{
        .direction = direction,
        .type = req_type,
        .recipient = recipient,
    };
}
