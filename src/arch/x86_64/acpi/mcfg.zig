// ACPI MCFG (Memory Mapped Configuration Space) Table Parser
//
// The MCFG table describes PCIe Enhanced Configuration Access Mechanism (ECAM)
// memory regions. Each entry specifies a base address for a PCI segment's
// configuration space, which can be accessed via memory-mapped I/O.
//
// PCIe ECAM Address Calculation:
//   Address = ECAM_Base + (Bus << 20) | (Device << 15) | (Function << 12) | Offset
//
// Reference: PCI Firmware Specification 3.0, Section 4.1.2

const rsdp = @import("rsdp.zig");
const console = @import("console");

/// MCFG table signature
pub const MCFG_SIGNATURE: [4]u8 = "MCFG".*;

/// MCFG table header
/// Followed by 8 reserved bytes, then array of McfgEntry
pub const McfgHeader = extern struct {
    header: rsdp.SdtHeader,
    reserved: [8]u8,        // Reserved, must be zero

    const Self = @This();

    /// Get number of MCFG entries
    pub fn getEntryCount(self: *align(1) const Self) usize {
        // Data length minus reserved bytes, divided by entry size
        const data_len = self.header.getDataLength();
        if (data_len < 8) return 0;
        return (data_len - 8) / @sizeOf(McfgEntry);
    }

    /// Get MCFG entries as bounded slice
    /// Returns null if data is invalid or too small
    pub fn getEntries(self: *align(1) const Self) ?[]align(1) const McfgEntry {
        const data = self.header.getData();
        // Data starts with 8 reserved bytes, then McfgEntry array
        if (data.len < 8) return null;

        const count = self.getEntryCount();
        if (count == 0) return null;

        const entries_data = data[8..];
        if (entries_data.len < count * @sizeOf(McfgEntry)) return null;

        const ptr: [*]align(1) const McfgEntry = @ptrCast(entries_data.ptr);
        return ptr[0..count];
    }

    /// Get entry at index with bounds checking
    pub fn getEntry(self: *align(1) const Self, index: usize) ?*align(1) const McfgEntry {
        const entries = self.getEntries() orelse return null;
        if (index >= entries.len) return null;
        return &entries[index];
    }

    /// Find entry for specific segment and bus range
    pub fn findSegment(self: *align(1) const Self, segment: u16) ?*align(1) const McfgEntry {
        const entries = self.getEntries() orelse return null;
        for (entries) |*entry| {
            if (entry.pci_segment == segment) {
                return entry;
            }
        }
        return null;
    }
};

/// MCFG entry describing one PCI segment's ECAM region
/// Each entry is 16 bytes
pub const McfgEntry = packed struct {
    base_address: u64,      // ECAM base address for this segment
    pci_segment: u16,       // PCI segment group number (usually 0)
    start_bus: u8,          // First bus number covered
    end_bus: u8,            // Last bus number covered
    reserved: u32,          // Reserved, must be zero

    const Self = @This();

    /// Calculate size of ECAM region for this entry
    /// Each bus has 32 devices * 8 functions * 4KB = 256KB per bus
    pub fn getRegionSize(self: *align(1) const Self) usize {
        const bus_count: usize = @as(usize, self.end_bus - self.start_bus) + 1;
        // 32 devices * 8 functions * 4096 bytes = 1MB per bus
        return bus_count * 32 * 8 * 4096;
    }

    /// Calculate config space address for a specific device
    pub fn getConfigAddress(self: *align(1) const Self, bus: u8, device: u5, func: u3) ?u64 {
        // Check bus is in range
        if (bus < self.start_bus or bus > self.end_bus) {
            return null;
        }

        const relative_bus: u64 = bus - self.start_bus;
        return self.base_address +
            (relative_bus << 20) |
            (@as(u64, device) << 15) |
            (@as(u64, func) << 12);
    }
};

/// Result of MCFG lookup
pub const EcamInfo = struct {
    base_address: u64,      // Physical base address of ECAM region
    size: usize,            // Size of ECAM region in bytes
    start_bus: u8,          // First bus number
    end_bus: u8,            // Last bus number
    segment: u16,           // PCI segment number
};

/// Find MCFG table and extract ECAM information for segment 0
/// This is the most common case - single PCI segment
pub fn findEcamBase(rsdp_ptr: *align(1) const rsdp.Rsdp) ?EcamInfo {
    // Find MCFG table
    const mcfg_table = rsdp.findTable(rsdp_ptr, MCFG_SIGNATURE) orelse {
        console.warn("ACPI: MCFG table not found", .{});
        return null;
    };
    console.info("Debug: mcfg_table found at 0x{x}", .{@intFromPtr(mcfg_table)});

    // Validate it's actually MCFG
    if (!mcfg_table.hasSignature(MCFG_SIGNATURE)) {
        console.warn("ACPI: Invalid MCFG signature", .{});
        return null;
    }

    console.info("Debug: casting to McfgHeader", .{});
    const mcfg: *align(1) const McfgHeader = @ptrCast(mcfg_table);
    console.info("Debug: cast success, finding segment 0", .{});

    // Look for segment 0 (most common)
    const entry = mcfg.findSegment(0) orelse mcfg.getEntry(0) orelse {
        console.warn("ACPI: No MCFG entries found", .{});
        return null;
    };

    return EcamInfo{
        .base_address = entry.base_address,
        .size = entry.getRegionSize(),
        .start_bus = entry.start_bus,
        .end_bus = entry.end_bus,
        .segment = entry.pci_segment,
    };
}

/// Find MCFG table and extract ECAM information for a specific segment
pub fn findEcamBaseForSegment(rsdp_ptr: *align(1) const rsdp.Rsdp, segment: u16) ?EcamInfo {
    const mcfg_table = rsdp.findTable(rsdp_ptr, MCFG_SIGNATURE) orelse {
        return null;
    };

    const mcfg: *align(1) const McfgHeader = @ptrCast(mcfg_table);

    const entry = mcfg.findSegment(segment) orelse {
        return null;
    };

    return EcamInfo{
        .base_address = entry.base_address,
        .size = entry.getRegionSize(),
        .start_bus = entry.start_bus,
        .end_bus = entry.end_bus,
        .segment = entry.pci_segment,
    };
}

/// Log MCFG table information for debugging
pub fn logMcfgInfo(rsdp_ptr: *align(1) const rsdp.Rsdp) void {
    const mcfg_table = rsdp.findTable(rsdp_ptr, MCFG_SIGNATURE) orelse {
        console.warn("ACPI: MCFG table not found", .{});
        return;
    };

    const mcfg: *align(1) const McfgHeader = @ptrCast(mcfg_table);

    // Use bounded slice iteration instead of index-based loop
    const entries = mcfg.getEntries() orelse {
        console.warn("ACPI: Invalid MCFG entries", .{});
        return;
    };

    console.info("ACPI: MCFG table found with {d} entries", .{entries.len});

    for (entries) |entry| {
        console.info("  Segment {d}: ECAM base=0x{x:0>16}, buses {d}-{d}, size={d}MB", .{
            entry.pci_segment,
            entry.base_address,
            entry.start_bus,
            entry.end_bus,
            entry.getRegionSize() / (1024 * 1024),
        });
    }
}
