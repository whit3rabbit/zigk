// Minimal Device Tree Blob (DTB/FDT) Parser
//
// Provides just enough functionality to extract GIC configuration
// from the Device Tree. This is NOT a full DTB parser.
//
// Reference: https://devicetree-specification.readthedocs.io/
//
// SECURITY AUDIT (2025-12-27): VERIFIED SECURE (after fix)
// - Header validation: Thorough bounds checking with checked arithmetic (lines 97-109)
// - MAX_DTB_SIZE: 64MB limit prevents DoS from malicious totalsize claims
// - Node name limit: 256 byte scan limit prevents unbounded reads
// - Property bounds: Validated before slice creation (lines 216-234)
// - Reg property: Checked arithmetic for address_cells calculations (lines 280-287, 304)
// - Trust model: DTB from firmware; validation limits damage from malformed input

const std = @import("std");

/// FDT Header (big-endian on-disk format)
pub const FdtHeader = extern struct {
    magic: u32, // 0xd00dfeed (big-endian)
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

const FDT_MAGIC: u32 = 0xd00dfeed;

// FDT structure tokens
const FDT_BEGIN_NODE: u32 = 0x00000001;
const FDT_END_NODE: u32 = 0x00000002;
const FDT_PROP: u32 = 0x00000003;
const FDT_NOP: u32 = 0x00000004;
const FDT_END: u32 = 0x00000009;

/// GIC information extracted from DTB
pub const GicInfo = struct {
    dist_base: u64, // GICD base address
    cpu_base: u64, // GICC (v2) or GICR (v3) base address
    version: u8, // 2 or 3
};

/// Read a big-endian u32 from memory
fn readBe32(ptr: [*]const u8) u32 {
    return @as(u32, ptr[0]) << 24 |
        @as(u32, ptr[1]) << 16 |
        @as(u32, ptr[2]) << 8 |
        @as(u32, ptr[3]);
}

/// Read a big-endian u64 from memory (for 64-bit reg properties)
fn readBe64(ptr: [*]const u8) u64 {
    return @as(u64, readBe32(ptr)) << 32 | @as(u64, readBe32(ptr + 4));
}

/// Validated header information returned by validateHeader
pub const ValidatedHeader = struct {
    header: *const FdtHeader,
    totalsize: u32,
    struct_off: u32,
    struct_size: u32,
    strings_off: u32,
    strings_size: u32,
};

// SECURITY: Maximum allowed DTB size (64 MB)
// This prevents DoS from malicious DTBs claiming enormous sizes that would
// cause the parser to read far beyond the actual DTB region.
// 64 MB is generous - typical DTBs are 10-100 KB.
const MAX_DTB_SIZE: u32 = 64 * 1024 * 1024;

/// Validate FDT header and all critical fields
/// SECURITY: Validates that all offsets and sizes are within totalsize bounds.
/// A malicious DTB with out-of-bounds offsets would cause the parser to read
/// arbitrary kernel memory.
///
/// TRUST MODEL: The DTB is provided by firmware/bootloader. If the bootloader
/// is compromised, many other attacks are possible. This validation prevents
/// accidental parsing of corrupted DTBs and limits damage from malformed input.
pub fn validateHeader(dtb_addr: u64) ?ValidatedHeader {
    if (dtb_addr == 0) return null;

    const ptr: [*]const u8 = @ptrFromInt(dtb_addr);
    const magic = readBe32(ptr);

    if (magic != FDT_MAGIC) return null;

    const header: *const FdtHeader = @ptrFromInt(dtb_addr);

    // Read and validate totalsize
    const totalsize = readBe32(@ptrCast(&header.totalsize));
    if (totalsize < @sizeOf(FdtHeader)) return null; // Too small for header

    // SECURITY: Reject unreasonably large DTBs to prevent unbounded memory reads.
    // A compromised bootloader could claim totalsize = 4GB, causing us to read
    // far beyond mapped memory. This bounds check limits the blast radius.
    if (totalsize > MAX_DTB_SIZE) return null;

    // Read and validate struct block bounds
    const struct_off = readBe32(@ptrCast(&header.off_dt_struct));
    const struct_size = readBe32(@ptrCast(&header.size_dt_struct));
    if (struct_off > totalsize) return null;
    // SECURITY: Use checked subtraction to prevent underflow
    const struct_remaining = std.math.sub(u32, totalsize, struct_off) catch return null;
    if (struct_size > struct_remaining) return null;

    // Read and validate strings block bounds
    const strings_off = readBe32(@ptrCast(&header.off_dt_strings));
    const strings_size = readBe32(@ptrCast(&header.size_dt_strings));
    if (strings_off > totalsize) return null;
    const strings_remaining = std.math.sub(u32, totalsize, strings_off) catch return null;
    if (strings_size > strings_remaining) return null;

    return ValidatedHeader{
        .header = header,
        .totalsize = totalsize,
        .struct_off = struct_off,
        .struct_size = struct_size,
        .strings_off = strings_off,
        .strings_size = strings_size,
    };
}

/// Check if a string matches a compatible pattern
fn matchesCompatible(compat_data: []const u8, target: []const u8) bool {
    // Compatible is a null-separated list of strings
    var i: usize = 0;
    while (i < compat_data.len) {
        const start = i;
        while (i < compat_data.len and compat_data[i] != 0) : (i += 1) {}
        const compat_str = compat_data[start..i];
        if (std.mem.eql(u8, compat_str, target)) return true;
        i += 1; // Skip null terminator
    }
    return false;
}

/// Parse DTB and extract GIC information
/// Returns null if DTB is invalid or GIC node not found
pub fn parseGicInfo(dtb_addr: u64) ?GicInfo {
    const validated = validateHeader(dtb_addr) orelse return null;
    const base: [*]const u8 = @ptrFromInt(dtb_addr);

    // SECURITY: Use validated header fields (bounds already checked)
    const struct_off = validated.struct_off;
    const struct_size = validated.struct_size;
    const strings_off = validated.strings_off;
    const strings_size = validated.strings_size;

    // SECURITY: Create bounded slices instead of raw pointer arithmetic.
    // This prevents out-of-bounds access even if offset calculations overflow.
    const struct_block = base[struct_off..][0..struct_size];
    const strings_block = base[strings_off..][0..strings_size];

    // State for parsing
    var offset: usize = 0;
    var in_intc_node = false;
    var gic_version: u8 = 0;
    var reg_data: ?[]const u8 = null;
    var address_cells: u32 = 2; // Default for root
    var size_cells: u32 = 1; // Default

    // Simple state machine to find GIC node and extract reg property
    while (offset + 4 <= struct_size) {
        const token = readBe32(struct_block[offset..].ptr);
        offset += 4;

        switch (token) {
            FDT_BEGIN_NODE => {
                // Node name follows (null-terminated, aligned to 4 bytes)
                // SECURITY: Limit node name scan to prevent unbounded reads on malformed DTB
                const MAX_NODE_NAME_LEN: usize = 256;

                // Calculate maximum scan distance (limited by both struct bounds and max name length)
                if (offset >= struct_size) break;
                const remaining = struct_size - offset;
                const max_scan = @min(remaining, MAX_NODE_NAME_LEN);

                // Scan for null terminator within bounds
                const name_region = struct_block[offset..][0..max_scan];
                const name = std.mem.sliceTo(name_region, 0);

                // SECURITY: Simplified bounds check - reject if no null found within scan region
                // sliceTo returns the entire slice if no sentinel found, so check length
                if (name.len >= max_scan) {
                    break; // Malformed: no null terminator within bounds or name too long
                }

                offset += name.len;

                // Skip null and align to 4 bytes
                offset += 1;
                offset = (offset + 3) & ~@as(usize, 3);

                // Check if this looks like an interrupt controller node
                if (std.mem.startsWith(u8, name, "intc") or
                    std.mem.startsWith(u8, name, "interrupt-controller") or
                    std.mem.startsWith(u8, name, "gic"))
                {
                    in_intc_node = true;
                }
            },
            FDT_END_NODE => {
                if (in_intc_node and gic_version != 0 and reg_data != null) {
                    // We found what we need, parse reg property
                    return parseRegProperty(reg_data.?, address_cells, gic_version);
                }
                in_intc_node = false;
                gic_version = 0;
                reg_data = null;
            },
            FDT_PROP => {
                if (offset + 8 > struct_size) break;

                const prop_len = readBe32(struct_block[offset..].ptr);
                const name_off = readBe32(struct_block[offset + 4 ..].ptr);
                offset += 8;

                // SECURITY: Validate property data bounds before creating slice.
                // A malicious DTB can specify prop_len extending beyond struct_block,
                // which would allow reading arbitrary kernel memory.
                if (prop_len > struct_size - offset) break;

                // SECURITY: Validate name_off is within strings block bounds.
                // A malicious DTB can specify name_off pointing outside the DTB,
                // allowing arbitrary kernel memory reads via the property name.
                if (name_off >= strings_size) break;

                // SECURITY: Use bounded sliceTo to prevent reading past strings block.
                // Create a slice from name_off to end of strings block, then search
                // for null within that bounded region only.
                const name_remaining = strings_size - name_off;
                const name_region = strings_block[name_off..][0..name_remaining];
                const prop_name = std.mem.sliceTo(name_region, 0);

                // Get property data (now safe - bounds validated above)
                const data = struct_block[offset..][0..prop_len];

                // Update address/size cells if at root level
                if (std.mem.eql(u8, prop_name, "#address-cells") and prop_len >= 4) {
                    address_cells = readBe32(struct_block[offset..].ptr);
                } else if (std.mem.eql(u8, prop_name, "#size-cells") and prop_len >= 4) {
                    size_cells = readBe32(struct_block[offset..].ptr);
                }

                if (in_intc_node) {
                    if (std.mem.eql(u8, prop_name, "compatible")) {
                        // Check for GIC compatible strings
                        if (matchesCompatible(data, "arm,gic-v3") or
                            matchesCompatible(data, "arm,gic-v3-its"))
                        {
                            gic_version = 3;
                        } else if (matchesCompatible(data, "arm,cortex-a15-gic") or
                            matchesCompatible(data, "arm,gic-400") or
                            matchesCompatible(data, "arm,cortex-a9-gic"))
                        {
                            gic_version = 2;
                        }
                    } else if (std.mem.eql(u8, prop_name, "reg")) {
                        reg_data = data;
                    }
                }

                // Align to 4 bytes
                offset += prop_len;
                offset = (offset + 3) & ~@as(usize, 3);
            },
            FDT_NOP => {},
            FDT_END => break,
            else => break, // Unknown token, stop parsing
        }
    }

    return null;
}

/// Parse reg property to extract GIC addresses
fn parseRegProperty(data: []const u8, address_cells: u32, gic_version: u8) ?GicInfo {
    // reg property format: <addr size addr size ...>
    // For GICv2: GICD, GICC (2 regions)
    // For GICv3: GICD, GICR (and possibly more)

    // SECURITY: Use checked arithmetic to prevent integer overflow from malicious DTB.
    // A crafted DTB with address_cells = 0x40000001 would overflow addr_size to 4.
    const addr_size = std.math.mul(usize, address_cells, 4) catch return null;
    const entry_size = std.math.add(usize, addr_size, 4) catch return null; // addr + size (assume 1 size cell for now)

    // SECURITY: Validate we have enough data for at least 2 entries (GICD + GICC/GICR)
    const min_required = std.math.mul(usize, entry_size, 2) catch return null;
    if (data.len < min_required) return null;

    var dist_base: u64 = 0;
    var cpu_base: u64 = 0;

    // Read first region (GICD)
    if (address_cells == 2) {
        dist_base = readBe64(data.ptr);
    } else {
        dist_base = readBe32(data.ptr);
    }

    // Read second region (GICC for v2, GICR for v3)
    const second_offset = entry_size;
    // SECURITY FIX: Use checked arithmetic for bounds check to prevent overflow.
    // A malicious DTB with large address_cells could cause second_offset + addr_size
    // to wrap, bypassing the bounds check and causing out-of-bounds reads.
    const read_end = std.math.add(usize, second_offset, addr_size) catch return null;
    if (read_end <= data.len) {
        if (address_cells == 2) {
            cpu_base = readBe64(data.ptr + second_offset);
        } else {
            cpu_base = readBe32(data.ptr + second_offset);
        }
    }

    if (dist_base == 0) return null;

    return GicInfo{
        .dist_base = dist_base,
        .cpu_base = cpu_base,
        .version = gic_version,
    };
}

/// Populate BootInfo with GIC configuration from DTB
/// This is the main entry point called during kernel init
pub fn populateGicFromDtb(boot_info: anytype) void {
    if (boot_info.dtb_addr == 0) return;

    if (parseGicInfo(boot_info.dtb_addr)) |gic| {
        boot_info.gic_dist_base = gic.dist_base;
        boot_info.gic_cpu_base = gic.cpu_base;
        boot_info.gic_version = gic.version;
    }
}
