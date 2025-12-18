// PCI Capabilities List Parser
//
// Traverses the PCI capability linked list to find specific capabilities
// like MSI, MSI-X, Power Management, etc.
//
// The capability list starts at offset 0x34 (Capabilities Pointer) and forms
// a linked list through PCI config space. Each capability node has:
//   - Byte 0: Capability ID
//   - Byte 1: Next capability pointer (0 = end of list)
//   - Bytes 2+: Capability-specific data
//
// Reference: PCI Local Bus Specification 3.0, Section 6.7

const ecam = @import("ecam.zig");
const device = @import("device.zig");

const Ecam = ecam.Ecam;
const PciDevice = device.PciDevice;
const ConfigReg = device.ConfigReg;

/// PCI Capability IDs
pub const CapabilityId = enum(u8) {
    null_cap = 0x00,
    power_management = 0x01,
    agp = 0x02,
    vpd = 0x03, // Vital Product Data
    slot_id = 0x04,
    msi = 0x05, // Message Signaled Interrupts
    compact_pci_hot_swap = 0x06,
    pci_x = 0x07,
    hypertransport = 0x08,
    vendor_specific = 0x09,
    debug_port = 0x0A,
    compact_pci_crc = 0x0B,
    pci_hot_plug = 0x0C,
    pci_bridge_subsystem_vid = 0x0D,
    agp_8x = 0x0E,
    secure_device = 0x0F,
    pci_express = 0x10,
    msi_x = 0x11, // MSI-X
    sata_config = 0x12,
    advanced_features = 0x13,
    enhanced_allocation = 0x14,
    flattening_portal_bridge = 0x15,
    _,
};

/// PCI Status Register bits
pub const StatusBits = struct {
    pub const CAPABILITIES_LIST: u16 = 1 << 4;
};

/// MSI Capability structure info
pub const MsiCapability = struct {
    /// Offset in config space where this capability starts
    offset: u8,
    /// Message Control register value
    msg_control: MsiMessageControl,
    /// True if device supports 64-bit addressing
    is_64bit: bool,
    /// True if device supports per-vector masking
    has_mask: bool,
    /// Number of vectors device can support (1, 2, 4, 8, 16, or 32)
    max_vectors: u8,
};

/// MSI Message Control Register (offset +2 from capability)
pub const MsiMessageControl = packed struct(u16) {
    enable: bool, // Bit 0
    multiple_message_capable: u3, // Bits 3:1 - log2(max_vectors)
    multiple_message_enable: u3, // Bits 6:4 - log2(allocated_vectors)
    is_64bit_capable: bool, // Bit 7
    per_vector_masking: bool, // Bit 8
    _reserved: u7 = 0, // Bits 15:9
};

/// MSI-X Capability structure info
pub const MsixCapability = struct {
    /// Offset in config space where this capability starts
    offset: u8,
    /// Message Control register value
    msg_control: MsixMessageControl,
    /// Number of table entries (actual count, not field value)
    table_size: u16,
    /// BAR index containing the MSI-X table
    table_bir: u3,
    /// Offset within BAR to MSI-X table
    table_offset: u32,
    /// BAR index containing the PBA
    pba_bir: u3,
    /// Offset within BAR to PBA
    pba_offset: u32,
};

/// MSI-X Message Control Register (offset +2 from capability)
pub const MsixMessageControl = packed struct(u16) {
    table_size: u11, // Bits 10:0 - (actual_size - 1)
    _reserved: u3 = 0, // Bits 13:11
    function_mask: bool, // Bit 14
    enable: bool, // Bit 15
};

/// Check if device has capabilities list
pub fn hasCapabilities(pci_ecam: *const Ecam, dev: *const PciDevice) bool {
    const status = pci_ecam.read16(dev.bus, dev.device, dev.func, ConfigReg.STATUS);
    return (status & StatusBits.CAPABILITIES_LIST) != 0;
}

/// Find a capability by ID in the device's capability list
/// Returns the config space offset of the capability, or null if not found
///
/// SECURITY: Tracks visited offsets to detect circular or duplicate capability
/// lists from malicious devices, preventing infinite loops and ensuring we
/// return the first occurrence of a capability.
pub fn findCapability(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    cap_id: CapabilityId,
) ?u8 {
    // Check if capabilities are supported
    if (!hasCapabilities(pci_ecam, dev)) {
        return null;
    }

    // Get initial capability pointer
    var offset = pci_ecam.read8(dev.bus, dev.device, dev.func, ConfigReg.CAPABILITIES);

    // Capability pointers must be DWORD aligned (bottom 2 bits should be 0)
    offset &= 0xFC;

    // SECURITY: Track visited offsets using a bitmap.
    // Config space is 256 bytes, DWORD-aligned offsets means 64 possible positions (0-252 step 4).
    // A u64 bitmap covers all 64 possible DWORD-aligned offsets.
    var visited: u64 = 0;

    // Traverse the linked list (max 48 iterations to prevent infinite loops)
    var iterations: u8 = 0;
    while (offset != 0 and iterations < 48) : (iterations += 1) {
        // SECURITY: Check if we've already visited this offset (cycle detection)
        const offset_idx: u6 = @intCast(offset >> 2);
        const offset_bit: u64 = @as(u64, 1) << offset_idx;
        if ((visited & offset_bit) != 0) {
            // Already visited - malicious device created a cycle
            break;
        }
        visited |= offset_bit;

        const id = pci_ecam.read8(dev.bus, dev.device, dev.func, offset);
        if (id == @intFromEnum(cap_id)) {
            return offset;
        }

        // Get next pointer
        offset = pci_ecam.read8(dev.bus, dev.device, dev.func, offset + 1);
        offset &= 0xFC;
    }

    return null;
}

/// Find all capabilities and return count
///
/// SECURITY: Uses visited-offset tracking to prevent cycles from malicious devices.
pub fn enumerateCapabilities(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    out_caps: []CapabilityInfo,
) usize {
    if (!hasCapabilities(pci_ecam, dev)) {
        return 0;
    }

    var count: usize = 0;
    var offset = pci_ecam.read8(dev.bus, dev.device, dev.func, ConfigReg.CAPABILITIES);
    offset &= 0xFC;

    // SECURITY: Track visited offsets using a bitmap (same as findCapability)
    var visited: u64 = 0;

    var iterations: u8 = 0;
    while (offset != 0 and iterations < 48 and count < out_caps.len) : (iterations += 1) {
        // SECURITY: Check for cycles
        const offset_idx: u6 = @intCast(offset >> 2);
        const offset_bit: u64 = @as(u64, 1) << offset_idx;
        if ((visited & offset_bit) != 0) {
            break;
        }
        visited |= offset_bit;

        const id = pci_ecam.read8(dev.bus, dev.device, dev.func, offset);
        out_caps[count] = .{
            .id = @enumFromInt(id),
            .offset = offset,
        };
        count += 1;

        offset = pci_ecam.read8(dev.bus, dev.device, dev.func, offset + 1);
        offset &= 0xFC;
    }

    return count;
}

/// Basic capability info
pub const CapabilityInfo = struct {
    id: CapabilityId,
    offset: u8,
};

/// Parse MSI capability at given offset
pub fn parseMsiCapability(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    offset: u8,
) MsiCapability {
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, offset + 2);
    const msg_ctrl: MsiMessageControl = @bitCast(msg_ctrl_raw);

    return MsiCapability{
        .offset = offset,
        .msg_control = msg_ctrl,
        .is_64bit = msg_ctrl.is_64bit_capable,
        .has_mask = msg_ctrl.per_vector_masking,
        .max_vectors = @as(u8, 1) << msg_ctrl.multiple_message_capable,
    };
}

/// Parse MSI-X capability at given offset
pub fn parseMsixCapability(
    pci_ecam: *const Ecam,
    dev: *const PciDevice,
    offset: u8,
) MsixCapability {
    const msg_ctrl_raw = pci_ecam.read16(dev.bus, dev.device, dev.func, offset + 2);
    const msg_ctrl: MsixMessageControl = @bitCast(msg_ctrl_raw);

    const table_offset_reg = pci_ecam.read32(dev.bus, dev.device, dev.func, offset + 4);
    const pba_offset_reg = pci_ecam.read32(dev.bus, dev.device, dev.func, offset + 8);

    return MsixCapability{
        .offset = offset,
        .msg_control = msg_ctrl,
        .table_size = @as(u16, msg_ctrl.table_size) + 1,
        .table_bir = @truncate(table_offset_reg & 0x07),
        .table_offset = table_offset_reg & 0xFFFFFFF8,
        .pba_bir = @truncate(pba_offset_reg & 0x07),
        .pba_offset = pba_offset_reg & 0xFFFFFFF8,
    };
}

/// Find MSI capability and parse it
pub fn findMsi(pci_ecam: *const Ecam, dev: *const PciDevice) ?MsiCapability {
    const offset = findCapability(pci_ecam, dev, .msi) orelse return null;
    return parseMsiCapability(pci_ecam, dev, offset);
}

/// Find MSI-X capability and parse it
pub fn findMsix(pci_ecam: *const Ecam, dev: *const PciDevice) ?MsixCapability {
    const offset = findCapability(pci_ecam, dev, .msi_x) orelse return null;
    return parseMsixCapability(pci_ecam, dev, offset);
}
