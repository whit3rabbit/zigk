// ACPI RSDP (Root System Description Pointer) Parser
//
// Parses RSDP v1 (ACPI 1.0) and v2 (ACPI 2.0+) structures to locate
// the RSDT/XSDT which contains pointers to other ACPI tables.
//
// Reference: ACPI Specification 6.4, Section 5.2.5

const hal = @import("hal");
const console = @import("console");

const paging = hal.paging;

/// RSDP signature: "RSD PTR " (8 bytes with trailing space)
pub const RSDP_SIGNATURE: [8]u8 = "RSD PTR ".*;

/// ACPI RSDP v1 structure (ACPI 1.0)
/// 20 bytes, used when revision = 0
pub const Rsdp = extern struct {
    signature: [8]u8,      // "RSD PTR "
    checksum: u8,          // Checksum of first 20 bytes
    oem_id: [6]u8,         // OEM identifier
    revision: u8,          // 0 = ACPI 1.0, 2 = ACPI 2.0+
    rsdt_address: u32,     // 32-bit physical address of RSDT

    const Self = @This();

    /// Validate RSDP v1 checksum (sum of first 20 bytes must be 0)
    /// Uses std.mem.asBytes for safe bounded access instead of raw pointer cast
    pub fn validateChecksum(self: *align(1) const Self) bool {
        const bytes = std.mem.asBytes(self);
        var sum: u8 = 0;
        for (bytes[0..20]) |b| {
            sum +%= b;
        }
        return sum == 0;
    }

    /// Check if signature is valid
    pub fn hasValidSignature(self: *align(1) const Self) bool {
        return std.mem.eql(u8, &self.signature, &RSDP_SIGNATURE);
    }

    /// Check if this is ACPI 2.0+ (has extended fields)
    pub fn isVersion2(self: *align(1) const Self) bool {
        return self.revision >= 2;
    }

    /// Get RSDT virtual address using HHDM
    pub fn getRsdtVirt(self: *align(1) const Self) *align(1) const SdtHeader {
        const phys: u64 = self.rsdt_address;
        return @ptrCast(paging.physToVirt(phys));
    }

    comptime {
        if (@sizeOf(Rsdp) != 20) @compileError("Rsdp must be 20 bytes (ACPI 1.0 spec)");
    }
};

/// ACPI RSDP v2 structure (ACPI 2.0+)
/// 36 bytes, extends RSDP v1 with 64-bit XSDT address
pub const Rsdp2 = extern struct {
    // First 20 bytes are same as RSDP v1
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32,

    // Extended fields (ACPI 2.0+)
    length: u32,            // Total structure length (36)
    xsdt_address: u64 align(1),      // 64-bit physical address of XSDT
    extended_checksum: u8,  // Checksum of entire structure
    reserved: [3]u8,

    const Self = @This();

    /// Validate extended checksum (sum of all 36 bytes must be 0)
    /// Uses std.mem.asBytes for safe bounded access instead of raw pointer cast
    pub fn validateExtendedChecksum(self: *align(1) const Self) bool {
        const bytes = std.mem.asBytes(self);
        var sum: u8 = 0;
        for (bytes) |b| {
            sum +%= b;
        }
        return sum == 0;
    }

    /// Get XSDT virtual address using HHDM
    pub fn getXsdtVirt(self: *align(1) const Self) *align(1) const SdtHeader {
        return @ptrCast(paging.physToVirt(self.xsdt_address));
    }

    /// Get as base RSDP for v1 compatibility
    pub fn asRsdp(self: *align(1) const Self) *align(1) const Rsdp {
        return @ptrCast(self);
    }

    comptime {
        if (@sizeOf(Rsdp2) != 36) @compileError("Rsdp2 must be 36 bytes (ACPI 2.0 spec)");
    }
};

/// Common ACPI System Description Table header
/// All ACPI tables (RSDT, XSDT, MCFG, etc.) start with this header
pub const SdtHeader = extern struct {
    signature: [4]u8,       // Table signature (e.g., "RSDT", "XSDT", "MCFG")
    length: u32,            // Total table length including header
    revision: u8,           // Table revision
    checksum: u8,           // Checksum of entire table
    oem_id: [6]u8,          // OEM identifier
    oem_table_id: [8]u8,    // OEM table identifier
    oem_revision: u32,      // OEM revision
    creator_id: u32,        // Creator vendor ID
    creator_revision: u32,  // Creator revision

    const Self = @This();

    /// Maximum reasonable ACPI table size (16MB sanity limit)
    pub const MAX_TABLE_SIZE: u32 = 16 * 1024 * 1024;

    /// Validate table checksum (sum of all bytes must be 0)
    /// Returns false if length is invalid or checksum fails
    pub fn validateChecksum(self: *align(1) const Self) bool {
        // Sanity check: table length must be reasonable
        if (self.length < @sizeOf(SdtHeader) or self.length > MAX_TABLE_SIZE) {
            return false;
        }

        // Get table bytes as slice with known bounds
        const table_bytes = self.asBytes() orelse return false;
        var sum: u8 = 0;
        for (table_bytes) |b| {
            sum +%= b;
        }
        return sum == 0;
    }

    /// Check if table has specific signature
    pub fn hasSignature(self: *align(1) const Self, sig: [4]u8) bool {
        return std.mem.eql(u8, &self.signature, &sig);
    }

    /// Get the entire table as a byte slice (header + data)
    /// Returns null if length field is invalid
    pub fn asBytes(self: *align(1) const Self) ?[]const u8 {
        if (self.length < @sizeOf(SdtHeader) or self.length > MAX_TABLE_SIZE) {
            return null;
        }
        const ptr: [*]const u8 = @ptrCast(self);
        return ptr[0..self.length];
    }

    /// Get pointer to table data after header as a bounded slice
    /// Returns empty slice if length is invalid
    pub fn getData(self: *align(1) const Self) []const u8 {
        const data_len = self.getDataLength();
        if (data_len == 0) return &[_]u8{};
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(SdtHeader)..][0..data_len];
    }

    /// Get data length (total length minus header)
    pub fn getDataLength(self: *align(1) const Self) usize {
        if (self.length < @sizeOf(SdtHeader) or self.length > MAX_TABLE_SIZE) return 0;
        return self.length - @sizeOf(SdtHeader);
    }

    comptime {
        if (@sizeOf(SdtHeader) != 36) @compileError("SdtHeader must be 36 bytes (ACPI spec)");
    }
};

/// RSDT (Root System Description Table) - contains 32-bit table pointers
/// Used by ACPI 1.0 systems
pub const Rsdt = extern struct {
    header: SdtHeader,
    // Followed by array of 32-bit physical addresses

    const Self = @This();

    /// Get number of table entries
    pub fn getEntryCount(self: *align(1) const Self) usize {
        const data_len = self.header.getDataLength();
        return data_len / @sizeOf(u32);
    }

    /// Get table entries as bounded slice of u32 addresses
    /// Returns null if data is too small
    fn getEntries(self: *align(1) const Self) ?[]align(1) const u32 {
        const data = self.header.getData();
        const count = self.getEntryCount();
        if (count == 0 or data.len < count * @sizeOf(u32)) return null;

        // Safe reinterpret of bytes as u32 array with alignment 1
        const ptr: [*]align(1) const u32 = @ptrCast(data.ptr);
        return ptr[0..count];
    }

    /// Get table entry at index with bounds checking
    pub fn getEntry(self: *align(1) const Self, index: usize) ?*align(1) const SdtHeader {
        const entries = self.getEntries() orelse return null;
        if (index >= entries.len) return null;

        const phys: u64 = entries[index];
        if (phys == 0) return null; // Null entry
        return @ptrCast(paging.physToVirt(phys));
    }

    /// Find table by signature
    pub fn findTable(self: *align(1) const Self, signature: [4]u8) ?*align(1) const SdtHeader {
        const count = self.getEntryCount();
        for (0..count) |i| {
            if (self.getEntry(i)) |table| {
                if (table.hasSignature(signature)) {
                    return table;
                }
            }
        }
        return null;
    }
};

/// XSDT (Extended System Description Table) - contains 64-bit table pointers
/// Used by ACPI 2.0+ systems, preferred over RSDT when available
pub const Xsdt = extern struct {
    header: SdtHeader,
    // Followed by array of 64-bit physical addresses

    const Self = @This();

    /// Get number of table entries
    pub fn getEntryCount(self: *align(1) const Self) usize {
        const data_len = self.header.getDataLength();
        return data_len / @sizeOf(u64);
    }

    /// Get table entries as bounded slice of u64 addresses
    /// Returns null if data is too small
    fn getEntries(self: *align(1) const Self) ?[]align(1) const u64 {
        const data = self.header.getData();
        const count = self.getEntryCount();
        if (count == 0 or data.len < count * @sizeOf(u64)) return null;

        // Safe reinterpret of bytes as u64 array with alignment 1
        const ptr: [*]align(1) const u64 = @ptrCast(data.ptr);
        return ptr[0..count];
    }

    /// Get table entry at index with bounds checking
    pub fn getEntry(self: *align(1) const Self, index: usize) ?*align(1) const SdtHeader {
        const entries = self.getEntries() orelse return null;
        if (index >= entries.len) return null;

        const phys = entries[index];
        if (phys == 0) return null; // Null entry
        return @ptrCast(paging.physToVirt(phys));
    }

    /// Find table by signature
    pub fn findTable(self: *align(1) const Self, signature: [4]u8) ?*align(1) const SdtHeader {
        const count = self.getEntryCount();
        for (0..count) |i| {
            if (self.getEntry(i)) |table| {
                if (table.hasSignature(signature)) {
                    return table;
                }
            }
        }
        return null;
    }
};

/// Find an ACPI table by signature, searching XSDT first (if available), then RSDT
/// Returns null if table not found or RSDP is invalid
pub fn findTable(rsdp_ptr: *align(1) const Rsdp, signature: [4]u8) ?*align(1) const SdtHeader {
    // 1. Validate Signature (Manual)
    const ptr = @as([*]const u8, @ptrCast(rsdp_ptr));
    if (!std.mem.eql(u8, ptr[0..8], &RSDP_SIGNATURE)) {
        console.warn("ACPI: Invalid RSDP signature", .{});
        return null;
    }

    // 2. Validate Checksum (Manual)
    var sum: u8 = 0;
    for (ptr[0..@sizeOf(Rsdp)]) |b| {
        sum +%= b;
    }
    if (sum != 0) {
        console.warn("ACPI: Invalid RSDP checksum", .{});
        return null;
    }

    // 3. Logic to traverse tables (Rest of logic)
    // If ACPI 2.0+, prefer XSDT (64-bit addresses)
    if (rsdp_ptr.isVersion2()) {
        const rsdp2: *align(1) const Rsdp2 = @ptrCast(rsdp_ptr);
        if (rsdp2.validateExtendedChecksum()) {
            if (rsdp2.xsdt_address != 0) {
                const xsdt: *align(1) const Xsdt = @ptrCast(rsdp2.getXsdtVirt());
                if (xsdt.header.validateChecksum()) {
                    if (xsdt.findTable(signature)) |table| {
                        return table;
                    }
                }
            }
        }
    }

    // Fall back to RSDT
    if (rsdp_ptr.rsdt_address != 0) {
        const rsdt: *align(1) const Rsdt = @ptrCast(rsdp_ptr.getRsdtVirt());
        if (rsdt.header.validateChecksum()) {
            return rsdt.findTable(signature);
        }
    }

    return null;
}

/// Log RSDP information for debugging
pub fn logRsdpInfo(rsdp_ptr: *const Rsdp) void {
    console.info("ACPI: RSDP found", .{});
    console.info("  OEM: {s}", .{rsdp_ptr.oem_id});
    console.info("  Revision: {d} (ACPI {s})", .{
        rsdp_ptr.revision,
        if (rsdp_ptr.revision >= 2) "2.0+" else "1.0",
    });
    console.info("  RSDT: 0x{x:0>8}", .{rsdp_ptr.rsdt_address});

    if (rsdp_ptr.isVersion2()) {
        const rsdp2: *const Rsdp2 = @ptrCast(rsdp_ptr);
        console.info("  XSDT: 0x{x:0>16}", .{rsdp2.xsdt_address});
    }
}

const std = @import("std");
