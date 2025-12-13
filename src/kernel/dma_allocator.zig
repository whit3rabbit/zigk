// DMA Allocator
//
// Provides a std.mem.Allocator interface backed by PMM for drivers that need
// physically contiguous, DMA-capable memory with known physical addresses.
//
// This abstraction enables:
//   - Unit testing drivers with a mock allocator
//   - Consistent memory management interface across drivers
//   - Easy migration to future memory models
//
// Usage:
//   const dma = @import("dma_allocator");
//
//   // Allocate DMA-capable memory
//   const result = dma.allocDma(4096) orelse return error.OutOfMemory;
//   defer dma.freeDma(result.slice);
//
//   // Use result.slice for virtual access
//   // Use result.phys for DMA programming

const std = @import("std");

const is_freestanding = @import("builtin").os.tag == .freestanding;

const pmm = if (is_freestanding) @import("pmm") else struct {
    pub const PAGE_SIZE: usize = 4096;
    pub fn allocZeroedPages(_: usize) ?u64 {
        return null;
    }
    pub fn freePages(_: u64, _: usize) void {}
};

const hal = if (is_freestanding) @import("hal") else struct {
    pub const paging = struct {
        pub fn physToVirt(phys: u64) [*]u8 {
            return @ptrFromInt(phys);
        }
    };
};

const heap = if (is_freestanding) @import("heap") else struct {
    pub fn allocator() std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

const console = if (is_freestanding) @import("console") else struct {
    pub fn warn(comptime _: []const u8, _: anytype) void {}
};

// Allocation tracking entry
const PhysAlloc = struct {
    phys: u64,
    pages: usize,
};

// Global allocation tracking
// Uses heap allocator for the tracking structure itself
var allocations: ?std.AutoHashMap(usize, PhysAlloc) = null;

fn getTracking() *std.AutoHashMap(usize, PhysAlloc) {
    if (allocations == null) {
        allocations = std.AutoHashMap(usize, PhysAlloc).init(heap.allocator());
    }
    return &allocations.?;
}

// DMA Allocator struct for instance-based usage
pub const DmaAllocator = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {
        // Free all tracked allocations
        if (allocations) |*allocs| {
            var iter = allocs.iterator();
            while (iter.next()) |entry| {
                pmm.freePages(entry.value_ptr.phys, entry.value_ptr.pages);
            }
            allocs.deinit();
            allocations = null;
        }
    }

    // Get the physical address for a virtual address allocated through this allocator
    pub fn getPhysicalAddress(_: *const Self, virt_addr: usize) ?u64 {
        const tracking = getTracking();
        if (tracking.get(virt_addr)) |alloc| {
            return alloc.phys;
        }
        return null;
    }

    // std.mem.Allocator interface
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, _: usize) ?[*]u8 {
        // Calculate pages needed (round up)
        const pages = (len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

        // PMM provides PAGE_SIZE-aligned pages
        const align_bytes = ptr_align.toByteUnits();
        if (align_bytes > pmm.PAGE_SIZE) {
            console.warn("DMA: Cannot satisfy alignment {d} > PAGE_SIZE", .{align_bytes});
            return null;
        }

        // Allocate physical pages
        const phys = pmm.allocZeroedPages(pages) orelse return null;

        // Convert to virtual address
        const virt_ptr = hal.paging.physToVirt(phys);
        const virt_addr = @intFromPtr(virt_ptr);

        // Track allocation for physical address lookup and freeing
        const tracking = getTracking();
        tracking.put(virt_addr, .{ .phys = phys, .pages = pages }) catch {
            pmm.freePages(phys, pages);
            return null;
        };

        return virt_ptr;
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        // DMA allocations cannot be resized (physical contiguity)
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        // DMA allocations cannot be remapped
        return null;
    }

    fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const virt_addr = @intFromPtr(buf.ptr);
        const tracking = getTracking();

        if (tracking.fetchRemove(virt_addr)) |kv| {
            pmm.freePages(kv.value.phys, kv.value.pages);
        }
    }
};

// Global DMA allocator instance (lazily initialized)
var global_dma_allocator: ?DmaAllocator = null;

// Get the global DMA allocator
pub fn getDmaAllocator() *DmaAllocator {
    if (global_dma_allocator == null) {
        global_dma_allocator = DmaAllocator.init();
    }
    return &global_dma_allocator.?;
}

// Result type for allocDma
pub const DmaAllocation = struct {
    slice: []u8,
    phys: u64,
};

// Allocate DMA-capable memory and return both virtual slice and physical address
pub fn allocDma(size: usize) ?DmaAllocation {
    const dma = getDmaAllocator();
    const alloc = dma.allocator();

    const ptr = alloc.alloc(u8, size) catch return null;

    const phys = dma.getPhysicalAddress(@intFromPtr(ptr.ptr)) orelse {
        alloc.free(ptr);
        return null;
    };

    return .{ .slice = ptr, .phys = phys };
}

// Free DMA memory allocated with allocDma
pub fn freeDma(slice: []u8) void {
    const dma = getDmaAllocator();
    dma.allocator().free(slice);
}

// Get physical address for memory allocated through this module
pub fn getPhysicalAddress(virt_ptr: anytype) ?u64 {
    const virt_addr: usize = switch (@typeInfo(@TypeOf(virt_ptr))) {
        .pointer => @intFromPtr(virt_ptr),
        .int => virt_ptr,
        else => @compileError("Expected pointer or integer"),
    };

    const dma = getDmaAllocator();
    return dma.getPhysicalAddress(virt_addr);
}
