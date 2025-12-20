// ACPI DMAR (DMA Remapping) Table Parser
//
// Parses the DMAR table to discover DMA Remapping Hardware Units (DRHDs)
// for Intel VT-d IOMMU initialization. Each DRHD represents an IOMMU
// hardware unit that can perform DMA remapping for a set of devices.
//
// Key structures:
//   - DRHD: DMA Remapping Hardware Unit Definition (type 0)
//   - RMRR: Reserved Memory Region Reporting (type 1)
//   - Device Scope: PCI devices covered by each DRHD
//
// Reference: Intel VT-d Specification, Section 8 (DMA Remapping Reporting)
// See: https://www.intel.com/content/dam/www/public/us/en/documents/product-specifications/vt-directed-io-spec.pdf

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const rsdp = @import("rsdp.zig");

const paging = hal.paging;
const SdtHeader = rsdp.SdtHeader;

/// DMAR table signature
pub const DMAR_SIGNATURE: [4]u8 = "DMAR".*;

/// Maximum number of DRHD units to track
pub const MAX_DRHD_UNITS: usize = 8;

/// Maximum number of devices per DRHD scope
pub const MAX_SCOPE_DEVICES: usize = 16;

/// Maximum number of RMRR entries to track
pub const MAX_RMRR_ENTRIES: usize = 8;

/// Remapping Structure Types (VT-d Spec Table 8-1)
pub const RemapStructureType = enum(u16) {
    drhd = 0, // DMA Remapping Hardware Unit Definition
    rmrr = 1, // Reserved Memory Region Reporting
    atsr = 2, // Root Port ATS Capability Reporting
    rhsa = 3, // Remapping Hardware Static Affinity
    andd = 4, // ACPI Name-space Device Declaration
    satc = 5, // SoC Integrated Address Translation Cache
    sidp = 6, // SoC Integrated Device Property Reporting
    _,
};

/// Device Scope Entry Types (VT-d Spec Table 8-5)
pub const DeviceScopeType = enum(u8) {
    pci_endpoint = 1, // PCI Endpoint Device
    pci_sub_hierarchy = 2, // PCI Sub-hierarchy (bridge)
    ioapic = 3, // IOAPIC
    msi_capable_hpet = 4, // MSI Capable HPET
    acpi_namespace_device = 5, // ACPI Namespace Device
    _,
};

/// DMAR Table Header (VT-d Spec Section 8.1)
pub const DmarHeader = extern struct {
    header: SdtHeader,
    host_address_width: u8, // Maximum physical address width minus 1
    flags: DmarFlags,
    reserved: [10]u8,
    // Followed by variable-length remapping structures

    const Self = @This();

    comptime {
        if (@sizeOf(DmarHeader) != 48) @compileError("DmarHeader must be 48 bytes");
    }
};

/// DMAR Header Flags (VT-d Spec Section 8.1)
pub const DmarFlags = packed struct(u8) {
    intr_remap: bool, // Bit 0: Interrupt remapping supported
    x2apic_opt_out: bool, // Bit 1: Platform opts out of x2APIC mode
    dma_ctrl_platform_opt_in: bool, // Bit 2: DMA control platform opt-in
    _reserved: u5 = 0,
};

/// Common Remapping Structure Header
pub const RemapStructureHeader = extern struct {
    structure_type: u16,
    length: u16,

    comptime {
        if (@sizeOf(RemapStructureHeader) != 4) @compileError("RemapStructureHeader must be 4 bytes");
    }
};

/// DRHD Structure (DMA Remapping Hardware Unit Definition)
/// VT-d Spec Section 8.3
pub const DrhdStructure = extern struct {
    header: RemapStructureHeader, // type = 0
    flags: DrhdFlags,
    size: u8, // Deprecated, was address size
    segment: u16, // PCI segment number
    reg_base_addr: u64 align(1), // Physical base of IOMMU registers
    // Followed by Device Scope entries

    const Self = @This();

    /// Get the device scope data after the fixed header
    pub fn getDeviceScopeData(self: *align(1) const Self) []const u8 {
        const fixed_size: u16 = @sizeOf(DrhdStructure);
        if (self.header.length <= fixed_size) return &[_]u8{};

        const scope_len = self.header.length - fixed_size;
        const base: [*]const u8 = @ptrCast(self);
        return base[fixed_size..][0..scope_len];
    }

    comptime {
        if (@sizeOf(DrhdStructure) != 16) @compileError("DrhdStructure must be 16 bytes");
    }
};

/// DRHD Flags (VT-d Spec Section 8.3)
pub const DrhdFlags = packed struct(u8) {
    include_pci_all: bool, // Bit 0: This unit handles all PCI devices in segment
    _reserved: u7 = 0,
};

/// Device Scope Entry (VT-d Spec Section 8.3.1)
pub const DeviceScopeEntry = extern struct {
    scope_type: u8, // DeviceScopeType
    length: u8, // Total length of this entry
    flags: u8, // Reserved in current spec
    reserved: u8,
    enumeration_id: u8, // IOAPIC ID, HPET ID, or 0
    start_bus: u8, // Start PCI bus number
    // Followed by Path entries (bus:device.function pairs)

    const Self = @This();

    /// Get path data as pairs of (device, function) bytes
    /// Each path entry is 2 bytes: device (5 bits) and function (3 bits)
    pub fn getPathData(self: *align(1) const Self) []const u8 {
        const fixed_size: u8 = @sizeOf(DeviceScopeEntry);
        if (self.length <= fixed_size) return &[_]u8{};

        const path_len = self.length - fixed_size;
        const base: [*]const u8 = @ptrCast(self);
        return base[fixed_size..][0..path_len];
    }

    /// Get the final PCI device from the path
    /// Returns (bus, device, function) tuple or null if invalid
    pub fn getFinalDevice(self: *align(1) const Self) ?BDF {
        const path = self.getPathData();
        if (path.len < 2) return null;

        // Walk the path to find final device
        // Each path entry: byte 0 = device (upper 5 bits used), byte 1 = function (lower 3 bits used)
        var bus = self.start_bus;
        var i: usize = 0;
        while (i + 1 < path.len) : (i += 2) {
            // This is a device on the current bus
            // If there are more path entries, it's a bridge and we need to follow it
            if (i + 2 >= path.len) {
                // This is the final device
                return BDF{
                    .bus = bus,
                    .device = @truncate(path[i] & 0x1F),
                    .func = @truncate(path[i + 1] & 0x07),
                };
            }
            // For bridges, the secondary bus number would come from PCI config
            // For simplicity, we assume flat path (common in most BIOS tables)
            bus +%= 1;
        }
        return null;
    }

    comptime {
        if (@sizeOf(DeviceScopeEntry) != 6) @compileError("DeviceScopeEntry must be 6 bytes");
    }
};

/// RMRR Structure (Reserved Memory Region Reporting)
/// VT-d Spec Section 8.4
pub const RmrrStructure = extern struct {
    header: RemapStructureHeader, // type = 1
    reserved: u16,
    segment: u16, // PCI segment number
    region_base: u64 align(1), // Physical base of reserved region
    region_limit: u64 align(1), // Physical limit (inclusive)
    // Followed by Device Scope entries

    const Self = @This();

    /// Get size of the reserved region
    pub fn getRegionSize(self: *align(1) const Self) u64 {
        if (self.region_limit < self.region_base) return 0;
        return self.region_limit - self.region_base + 1;
    }

    /// Get the device scope data after the fixed header
    pub fn getDeviceScopeData(self: *align(1) const Self) []const u8 {
        const fixed_size: u16 = @sizeOf(RmrrStructure);
        if (self.header.length <= fixed_size) return &[_]u8{};

        const scope_len = self.header.length - fixed_size;
        const base: [*]const u8 = @ptrCast(self);
        return base[fixed_size..][0..scope_len];
    }

    comptime {
        if (@sizeOf(RmrrStructure) != 24) @compileError("RmrrStructure must be 24 bytes");
    }
};

/// PCI Bus/Device/Function identifier
pub const BDF = struct {
    bus: u8,
    device: u5,
    func: u3,

    /// Pack into u16: bus[15:8] | device[7:3] | func[2:0]
    pub fn pack(self: BDF) u16 {
        return (@as(u16, self.bus) << 8) |
            (@as(u16, self.device) << 3) |
            @as(u16, self.func);
    }

    /// Unpack from u16
    pub fn unpack(val: u16) BDF {
        return BDF{
            .bus = @truncate(val >> 8),
            .device = @truncate((val >> 3) & 0x1F),
            .func = @truncate(val & 0x07),
        };
    }
};

/// Parsed DRHD information
pub const DrhdInfo = struct {
    reg_base: u64, // Physical base of IOMMU registers
    segment: u16, // PCI segment number
    include_pci_all: bool, // Handles all devices in segment
    scope_devices: [MAX_SCOPE_DEVICES]BDF, // Specific devices in scope
    scope_count: u8, // Number of devices in scope
    scope_ioapic_id: u8, // IOAPIC enumeration ID (0 if none)
    scope_hpet_id: u8, // HPET enumeration ID (0 if none)
};

/// Parsed RMRR information
pub const RmrrInfo = struct {
    region_base: u64,
    region_limit: u64,
    segment: u16,
    devices: [4]BDF, // Devices requiring access to this region
    device_count: u8,
};

/// Complete parsed DMAR information
pub const DmarInfo = struct {
    /// Maximum physical address width (host_address_width + 1)
    host_addr_width: u8,

    /// Interrupt remapping is supported
    intr_remap_supported: bool,

    /// Platform requests x2APIC opt-out
    x2apic_opt_out: bool,

    /// DRHD units discovered
    drhd_units: [MAX_DRHD_UNITS]DrhdInfo,
    drhd_count: u8,

    /// Reserved memory regions
    rmrr_entries: [MAX_RMRR_ENTRIES]RmrrInfo,
    rmrr_count: u8,

    /// Find DRHD for a specific PCI device
    /// First checks explicit scope, then looks for INCLUDE_PCI_ALL unit
    pub fn findDrhdForDevice(self: *const DmarInfo, bus: u8, device: u5, func: u3) ?*const DrhdInfo {
        const target = BDF{ .bus = bus, .device = device, .func = func };
        const target_packed = target.pack();

        // First, check explicit device scopes
        for (self.drhd_units[0..self.drhd_count]) |*drhd| {
            for (drhd.scope_devices[0..drhd.scope_count]) |scope_dev| {
                if (scope_dev.pack() == target_packed) {
                    return drhd;
                }
            }
        }

        // Fall back to INCLUDE_PCI_ALL unit for this segment
        for (self.drhd_units[0..self.drhd_count]) |*drhd| {
            if (drhd.include_pci_all and drhd.segment == 0) {
                return drhd;
            }
        }

        return null;
    }

    /// Find DRHD with INCLUDE_PCI_ALL for the given segment
    pub fn findCatchAllDrhd(self: *const DmarInfo, segment: u16) ?*const DrhdInfo {
        for (self.drhd_units[0..self.drhd_count]) |*drhd| {
            if (drhd.include_pci_all and drhd.segment == segment) {
                return drhd;
            }
        }
        return null;
    }

    /// Check if a device needs identity mapping (RMRR region)
    pub fn findRmrrForDevice(self: *const DmarInfo, bus: u8, device: u5, func: u3) ?*const RmrrInfo {
        const target = BDF{ .bus = bus, .device = device, .func = func };
        const target_packed = target.pack();

        for (self.rmrr_entries[0..self.rmrr_count]) |*rmrr| {
            for (rmrr.devices[0..rmrr.device_count]) |dev| {
                if (dev.pack() == target_packed) {
                    return rmrr;
                }
            }
        }
        return null;
    }
};

/// Parse DMAR table from RSDP
pub fn parse(rsdp_ptr: *align(1) const rsdp.Rsdp) ?DmarInfo {
    const dmar_header = rsdp.findTable(rsdp_ptr, DMAR_SIGNATURE) orelse {
        return null; // DMAR not present (no IOMMU or not reported)
    };

    return parseFromHeader(dmar_header);
}

/// Parse DMAR from a direct table pointer
pub fn parseFromHeader(header: *align(1) const SdtHeader) ?DmarInfo {
    if (!header.hasSignature(DMAR_SIGNATURE)) {
        console.warn("DMAR: Invalid signature", .{});
        return null;
    }

    if (!header.validateChecksum()) {
        console.warn("DMAR: Checksum validation failed", .{});
        return null;
    }

    const dmar: *align(1) const DmarHeader = @ptrCast(header);

    var info = DmarInfo{
        .host_addr_width = dmar.host_address_width + 1,
        .intr_remap_supported = dmar.flags.intr_remap,
        .x2apic_opt_out = dmar.flags.x2apic_opt_out,
        .drhd_units = undefined,
        .drhd_count = 0,
        .rmrr_entries = undefined,
        .rmrr_count = 0,
    };

    // Get remapping structure data (after DMAR header)
    const struct_data = getRemapStructureData(dmar);
    if (struct_data.len == 0) {
        console.warn("DMAR: No remapping structures found", .{});
        return info;
    }

    // Iterate through remapping structures
    var offset: usize = 0;
    while (offset + @sizeOf(RemapStructureHeader) <= struct_data.len) {
        const remap_header: *align(1) const RemapStructureHeader = @ptrCast(&struct_data[offset]);

        // Validate structure length
        if (remap_header.length < @sizeOf(RemapStructureHeader) or
            offset + remap_header.length > struct_data.len)
        {
            console.warn("DMAR: Invalid remapping structure length at offset {d}", .{offset});
            break;
        }

        // Process structure based on type
        const struct_type: RemapStructureType = @enumFromInt(remap_header.structure_type);
        switch (struct_type) {
            .drhd => {
                if (remap_header.length >= @sizeOf(DrhdStructure) and
                    info.drhd_count < MAX_DRHD_UNITS)
                {
                    const drhd_struct: *align(1) const DrhdStructure = @ptrCast(remap_header);
                    info.drhd_units[info.drhd_count] = parseDrhd(drhd_struct);
                    info.drhd_count += 1;
                }
            },
            .rmrr => {
                if (remap_header.length >= @sizeOf(RmrrStructure) and
                    info.rmrr_count < MAX_RMRR_ENTRIES)
                {
                    const rmrr_struct: *align(1) const RmrrStructure = @ptrCast(remap_header);
                    info.rmrr_entries[info.rmrr_count] = parseRmrr(rmrr_struct);
                    info.rmrr_count += 1;
                }
            },
            else => {
                // Ignore other structure types (ATSR, RHSA, ANDD, SATC, SIDP)
            },
        }

        offset += remap_header.length;
    }

    return info;
}

/// Parse a DRHD structure
fn parseDrhd(drhd: *align(1) const DrhdStructure) DrhdInfo {
    var info = DrhdInfo{
        .reg_base = drhd.reg_base_addr,
        .segment = drhd.segment,
        .include_pci_all = drhd.flags.include_pci_all,
        .scope_devices = undefined,
        .scope_count = 0,
        .scope_ioapic_id = 0,
        .scope_hpet_id = 0,
    };

    // Parse device scope entries
    const scope_data = drhd.getDeviceScopeData();
    var offset: usize = 0;

    while (offset + @sizeOf(DeviceScopeEntry) <= scope_data.len) {
        const scope: *align(1) const DeviceScopeEntry = @ptrCast(&scope_data[offset]);

        if (scope.length < @sizeOf(DeviceScopeEntry) or
            offset + scope.length > scope_data.len)
        {
            break;
        }

        const scope_type: DeviceScopeType = @enumFromInt(scope.scope_type);
        switch (scope_type) {
            .pci_endpoint, .pci_sub_hierarchy => {
                if (scope.getFinalDevice()) |bdf| {
                    if (info.scope_count < MAX_SCOPE_DEVICES) {
                        info.scope_devices[info.scope_count] = bdf;
                        info.scope_count += 1;
                    }
                }
            },
            .ioapic => {
                info.scope_ioapic_id = scope.enumeration_id;
                if (scope.getFinalDevice()) |bdf| {
                    if (info.scope_count < MAX_SCOPE_DEVICES) {
                        info.scope_devices[info.scope_count] = bdf;
                        info.scope_count += 1;
                    }
                }
            },
            .msi_capable_hpet => {
                info.scope_hpet_id = scope.enumeration_id;
                if (scope.getFinalDevice()) |bdf| {
                    if (info.scope_count < MAX_SCOPE_DEVICES) {
                        info.scope_devices[info.scope_count] = bdf;
                        info.scope_count += 1;
                    }
                }
            },
            else => {},
        }

        offset += scope.length;
    }

    return info;
}

/// Parse an RMRR structure
fn parseRmrr(rmrr: *align(1) const RmrrStructure) RmrrInfo {
    var info = RmrrInfo{
        .region_base = rmrr.region_base,
        .region_limit = rmrr.region_limit,
        .segment = rmrr.segment,
        .devices = undefined,
        .device_count = 0,
    };

    // Parse device scope entries
    const scope_data = rmrr.getDeviceScopeData();
    var offset: usize = 0;

    while (offset + @sizeOf(DeviceScopeEntry) <= scope_data.len) {
        const scope: *align(1) const DeviceScopeEntry = @ptrCast(&scope_data[offset]);

        if (scope.length < @sizeOf(DeviceScopeEntry) or
            offset + scope.length > scope_data.len)
        {
            break;
        }

        if (scope.getFinalDevice()) |bdf| {
            if (info.device_count < 4) {
                info.devices[info.device_count] = bdf;
                info.device_count += 1;
            }
        }

        offset += scope.length;
    }

    return info;
}

/// Get remapping structure data slice (bytes after the DMAR header)
fn getRemapStructureData(dmar: *align(1) const DmarHeader) []const u8 {
    const total_len = dmar.header.length;
    const header_size: u32 = @sizeOf(DmarHeader);

    if (total_len <= header_size) {
        return &[_]u8{};
    }

    const data_len = total_len - header_size;
    const base: [*]const u8 = @ptrCast(dmar);
    return base[header_size..][0..data_len];
}

/// Log parsed DMAR information for debugging
pub fn logDmarInfo(info: *const DmarInfo) void {
    console.info("DMAR: Host address width: {d} bits", .{info.host_addr_width});
    console.info("DMAR: Interrupt remapping: {}", .{info.intr_remap_supported});
    console.info("DMAR: x2APIC opt-out: {}", .{info.x2apic_opt_out});
    console.info("DMAR: {d} DRHD unit(s), {d} RMRR region(s)", .{ info.drhd_count, info.rmrr_count });

    for (info.drhd_units[0..info.drhd_count], 0..) |drhd, i| {
        console.info("  DRHD {d}: base=0x{x:0>16} segment={d} include_all={}", .{
            i,
            drhd.reg_base,
            drhd.segment,
            drhd.include_pci_all,
        });

        if (drhd.scope_count > 0) {
            for (drhd.scope_devices[0..drhd.scope_count]) |dev| {
                console.info("    Device: {x:0>2}:{x:0>2}.{d}", .{
                    dev.bus,
                    @as(u8, dev.device),
                    @as(u8, dev.func),
                });
            }
        }

        if (drhd.scope_ioapic_id != 0) {
            console.info("    IOAPIC ID: {d}", .{drhd.scope_ioapic_id});
        }
        if (drhd.scope_hpet_id != 0) {
            console.info("    HPET ID: {d}", .{drhd.scope_hpet_id});
        }
    }

    for (info.rmrr_entries[0..info.rmrr_count], 0..) |rmrr, i| {
        console.info("  RMRR {d}: 0x{x:0>16}-0x{x:0>16} ({d}KB)", .{
            i,
            rmrr.region_base,
            rmrr.region_limit,
            (rmrr.region_limit - rmrr.region_base + 1) / 1024,
        });
        for (rmrr.devices[0..rmrr.device_count]) |dev| {
            console.info("    Device: {x:0>2}:{x:0>2}.{d}", .{
                dev.bus,
                @as(u8, dev.device),
                @as(u8, dev.func),
            });
        }
    }
}
