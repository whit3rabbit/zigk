const std = @import("std");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const console = @import("console");
const types = @import("types.zig");

const ElfError = types.ElfError;
const paging = hal.paging;

/// Cleanup helper for partial segment loads
pub fn cleanupMappedSegment(pml4_phys: u64, start_vaddr: u64, page_size: usize, pages: []const u64) void {
    for (pages, 0..) |phys, idx| {
        const virt = start_vaddr + @as(u64, idx) * @as(u64, page_size);
        vmm.unmapPage(pml4_phys, virt) catch {};
        pmm.freePage(phys);
    }
}

/// Copy data to userspace virtual address
/// Handles page boundaries by looking up each page's physical address
/// Returns error if address translation fails (indicates mapping bug)
pub fn copyToUserspace(pml4_phys: u64, vaddr: u64, data: []const u8) ElfError!void {
    const page_size = pmm.PAGE_SIZE;
    var offset: usize = 0;
    var current_vaddr = vaddr;

    while (offset < data.len) {
        // Calculate how much to copy to this page
        const page_offset = current_vaddr & (page_size - 1);
        const bytes_in_page = @min(page_size - page_offset, data.len - offset);

        // Look up physical address
        if (vmm.translate(pml4_phys, current_vaddr)) |phys| {
            // Get kernel-accessible pointer via HHDM
            // Note: phys already includes page offset from translate()
            const dest_ptr: [*]u8 = paging.physToVirt(phys);
            const dest = dest_ptr[0..bytes_in_page];

            // Copy data
            hal.mem.copy(dest.ptr, data[offset..][0..bytes_in_page].ptr, bytes_in_page);
        } else {
            // CRITICAL: Translation failed for a page we should have just mapped
            console.err("ELF: copyToUserspace failed - vaddr={x} not mapped (pml4={x})", .{ current_vaddr, pml4_phys });
            return ElfError.MappingFailed;
        }

        offset += bytes_in_page;
        current_vaddr += bytes_in_page;
    }
}

/// Check that stack pointer is within bounds
pub inline fn checkStackBounds(sp: u64, stack_base: u64) !void {
    if (sp < stack_base) {
        console.err("ELF: Stack overflow - sp={x} below stack_base={x}", .{ sp, stack_base });
        return error.StackOverflow;
    }
}

/// Write bytes to userspace (stack setup - propagate errors)
pub fn writeToUserspace(pml4_phys: u64, vaddr: u64, data: []const u8) !void {
    // Stack pages are mapped immediately before this call, so translation
    // failures indicate a severe bug.
    copyToUserspace(pml4_phys, vaddr, data) catch |err| {
        console.err("ELF: writeToUserspace failed at {x}: {}", .{ vaddr, err });
        return err;
    };
}

/// Write a u64 to userspace (stack setup - propagate errors)
pub fn writeU64ToUserspace(pml4_phys: u64, vaddr: u64, value: u64) !void {
    const bytes = std.mem.toBytes(value);
    try writeToUserspace(pml4_phys, vaddr, &bytes);
}
