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
    pub fn getEntryCount(self: *const Self) usize {
        // Data length minus reserved bytes, divided by entry size
        const data_len = self.header.getDataLength();
        if (data_len < 8) return 0;
        return (data_len - 8) / @sizeOf(McfgEntry);
    }

    /// Get entry at index
    pub fn getEntry(self: *const Self, index: usize) ?*const McfgEntry {
        if (index >= self.getEntryCount()) return null;

        // Entries start after header + reserved bytes
        const entries_start = @intFromPtr(self) + @sizeOf(rsdp.SdtHeader) + 8;
        const entry_ptr = entries_start + (index * @sizeOf(McfgEntry));
        return @ptrFromInt(entry_ptr);
    }

    /// Find entry for specific segment and bus range
    pub fn findSegment(self: *const Self, segment: u16) ?*const McfgEntry {
        const count = self.getEntryCount();
        for (0..count) |i| {
            if (self.getEntry(i)) |entry| {
                if (entry.pci_segment == segment) {
                    return entry;
                }
            }
        }
        return null;
    }
};

/// MCFG entry describing one PCI segment's ECAM region
/// Each entry is 16 bytes
pub const McfgEntry = extern struct {
    base_address: u64,      // ECAM base address for this segment
    pci_segment: u16,       // PCI segment group number (usually 0)
    start_bus: u8,          // First bus number covered
    end_bus: u8,            // Last bus number covered
    reserved: u32,          // Reserved, must be zero

    const Self = @This();

    /// Calculate size of ECAM region for this entry
    /// Each bus has 32 devices * 8 functions * 4KB = 256KB per bus
    pub fn getRegionSize(self: *const Self) usize {
        const bus_count: usize = @as(usize, self.end_bus - self.start_bus) + 1;
        // 32 devices * 8 functions * 4096 bytes = 1MB per bus
        return bus_count * 32 * 8 * 4096;
    }

    /// Calculate config space address for a specific device
    pub fn getConfigAddress(self: *const Self, bus: u8, device: u5, func: u3) ?u64 {
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
pub fn findEcamBase(rsdp_ptr: *const rsdp.Rsdp) ?EcamInfo {
    // Find MCFG table
    const mcfg_table = rsdp.findTable(rsdp_ptr, &MCFG_SIGNATURE) orelse {
        console.warn("ACPI: MCFG table not found", .{});
        return null;
    };

    // Validate it's actually MCFG
    if (!mcfg_table.hasSignature(&MCFG_SIGNATURE)) {
        console.warn("ACPI: Invalid MCFG signature", .{});
        return null;
    }

    const mcfg: *const McfgHeader = @ptrCast(@alignCast(mcfg_table));

    // Look for segment 0 (most common)
    const entry = mcfg.findSegment(0) orelse {
        // Try first entry if segment 0 not found
        mcfg.getEntry(0) orelse {
            console.warn("ACPI: No MCFG entries found", .{});
            return null;
        };
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
pub fn findEcamBaseForSegment(rsdp_ptr: *const rsdp.Rsdp, segment: u16) ?EcamInfo {
    const mcfg_table = rsdp.findTable(rsdp_ptr, &MCFG_SIGNATURE) orelse {
        return null;
    };

    const mcfg: *const McfgHeader = @ptrCast(@alignCast(mcfg_table));

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
pub fn logMcfgInfo(rsdp_ptr: *const rsdp.Rsdp) void {
    const mcfg_table = rsdp.findTable(rsdp_ptr, &MCFG_SIGNATURE) orelse {
        console.warn("ACPI: MCFG table not found", .{});
        return;
    };

    const mcfg: *const McfgHeader = @ptrCast(@alignCast(mcfg_table));
    const entry_count = mcfg.getEntryCount();

    console.info("ACPI: MCFG table found with {d} entries", .{entry_count});

    for (0..entry_count) |i| {
        if (mcfg.getEntry(i)) |entry| {
            console.info("  Segment {d}: ECAM base=0x{x:0>16}, buses {d}-{d}, size={d}MB", .{
                entry.pci_segment,
                entry.base_address,
                entry.start_bus,
                entry.end_bus,
                entry.getRegionSize() / (1024 * 1024),
            });
        }
    }
}
