// UEFI Memory Map Handling
// Converts UEFI memory descriptors to kernel BootInfo format

const std = @import("std");
const uefi = std.os.uefi;
const BootInfo = @import("boot_info");

pub const MemoryError = error{
    GetMemoryMapFailed,
    BufferTooSmall,
    InvalidDescriptor,
};

/// UEFI Memory Map state
pub const MemoryMap = struct {
    buffer: [*]align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
    buffer_size: usize,
    map_key: uefi.tables.MemoryMapKey,
    descriptor_size: usize,
    descriptor_version: u32,
    entry_count: usize,

    /// Get iterator over memory descriptors
    pub fn iterator(self: *const MemoryMap) MemoryMapIterator {
        return .{
            .buffer = self.buffer,
            .buffer_size = self.buffer_size,
            .descriptor_size = self.descriptor_size,
            .count = self.entry_count,
            .index = 0,
        };
    }

    /// Calculate total usable memory
    pub fn totalUsableMemory(self: *const MemoryMap) u64 {
        var total: u64 = 0;
        var iter = self.iterator();
        while (iter.next()) |desc| {
            if (isUsableMemory(desc.type)) {
                // Use checked arithmetic to handle malformed descriptors
                const pages_bytes = std.math.mul(u64, desc.number_of_pages, 4096) catch continue;
                total = std.math.add(u64, total, pages_bytes) catch return total;
            }
        }
        return total;
    }
};

pub const MemoryMapIterator = struct {
    buffer: [*]align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
    buffer_size: usize,
    descriptor_size: usize,
    count: usize,
    index: usize,

    pub fn next(self: *MemoryMapIterator) ?*uefi.tables.MemoryDescriptor {
        if (self.index >= self.count) return null;

        // Use checked arithmetic to prevent overflow from malformed descriptor_size
        const offset = std.math.mul(usize, self.index, self.descriptor_size) catch return null;

        // Bounds check against actual buffer size
        if (offset >= self.buffer_size) return null;

        const ptr = self.buffer + offset;
        self.index += 1;
        return @ptrCast(@alignCast(ptr));
    }
};

/// Check if memory type is usable by OS
pub fn isUsableMemory(mem_type: uefi.tables.MemoryType) bool {
    return switch (mem_type) {
        .loader_code,
        .loader_data,
        .boot_services_code,
        .boot_services_data,
        .conventional_memory,
        => true,
        else => false,
    };
}

/// Convert UEFI memory type to BootInfo memory type
pub fn convertMemoryType(uefi_type: uefi.tables.MemoryType) BootInfo.MemoryType {
    return switch (uefi_type) {
        .reserved_memory_type => .Reserved,
        .loader_code => .LoaderCode,
        .loader_data => .LoaderData,
        .boot_services_code => .BootServicesCode,
        .boot_services_data => .BootServicesData,
        .runtime_services_code => .RuntimeServicesCode,
        .runtime_services_data => .RuntimeServicesData,
        .conventional_memory => .Conventional,
        .unusable_memory => .Unusable,
        .acpi_reclaim_memory => .ACPIReclaim,
        .acpi_memory_nvs => .ACPINvs,
        .memory_mapped_io => .MemoryMappedIO,
        .memory_mapped_io_port_space => .MemoryMappedIOPortSpace,
        .pal_code => .PalCode,
        .persistent_memory => .PersistentMemory,
        else => .Reserved,
    };
}

/// Get memory map from UEFI boot services
/// Returns a MemoryMap struct with the map data
/// buffer must be large enough to hold the map
pub fn getMemoryMap(
    bs: *uefi.tables.BootServices,
    buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
) MemoryError!MemoryMap {
    var map_size: usize = buffer.len;
    var map_key: uefi.tables.MemoryMapKey = undefined;
    var desc_size: usize = undefined;
    var desc_version: u32 = undefined;

    const status = bs._getMemoryMap(
        &map_size,
        @ptrCast(buffer.ptr),
        &map_key,
        &desc_size,
        &desc_version,
    );

    if (status != .success) {
        return MemoryError.GetMemoryMapFailed;
    }

    // Validate descriptor size to prevent division by zero and detect malformed firmware data
    if (desc_size == 0 or desc_size < @sizeOf(uefi.tables.MemoryDescriptor)) {
        return MemoryError.InvalidDescriptor;
    }

    // Ensure map_size is a valid multiple of desc_size
    if (map_size % desc_size != 0) {
        return MemoryError.InvalidDescriptor;
    }

    return .{
        .buffer = buffer.ptr,
        .buffer_size = map_size,
        .map_key = map_key,
        .descriptor_size = desc_size,
        .descriptor_version = desc_version,
        .entry_count = map_size / desc_size,
    };
}

/// Convert UEFI memory map to BootInfo format
/// Writes converted descriptors to output buffer
pub fn convertToBootInfo(
    uefi_map: *const MemoryMap,
    output: []BootInfo.MemoryDescriptor,
) usize {
    var iter = uefi_map.iterator();
    var count: usize = 0;

    while (iter.next()) |desc| {
        if (count >= output.len) break;

        output[count] = .{
            .type = convertMemoryType(desc.type),
            .phys_start = desc.physical_start,
            .virt_start = desc.virtual_start,
            .num_pages = desc.number_of_pages,
            .attribute = @bitCast(desc.attribute),
        };
        count += 1;
    }

    return count;
}

/// Find highest usable physical address
pub fn findMaxPhysicalAddress(map: *const MemoryMap) u64 {
    var max_addr: u64 = 0;
    var iter = map.iterator();

    while (iter.next()) |desc| {
        // Use checked arithmetic to prevent overflow from malformed descriptors
        const pages_bytes = std.math.mul(u64, desc.number_of_pages, 4096) catch continue;
        const end = std.math.add(u64, desc.physical_start, pages_bytes) catch continue;
        if (end > max_addr) {
            max_addr = end;
        }
    }

    return max_addr;
}
