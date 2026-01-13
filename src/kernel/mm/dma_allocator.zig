//! DMA Allocator
//!
//! Provides a `std.mem.Allocator` interface backed by the Physical Memory Manager (PMM)
//! for drivers that require physically contiguous, DMA-capable memory with known
//! physical addresses.
//!
//! Features:
//! - Tracks virtual-to-physical mappings for its allocations.
//! - Ensures physical contiguity (required for simple DMA).
//! - Integrates with `std.mem.Allocator` for ease of use.
//!
//! This abstraction enables:
//! - Unit testing drivers with a mock allocator
//! - Consistent memory management interface across drivers
//! - Easy migration to future memory models
//!
//! Usage:
//! ```zig
//! const dma = @import("dma_allocator");
//!
//! // Allocate DMA-capable memory
//! const result = dma.allocDma(4096) orelse return error.OutOfMemory;
//! defer dma.freeDma(result.slice);
//!
//! // Use result.slice for virtual access
//! // Use result.phys for DMA programming
//! ```

const std = @import("std");

const is_freestanding = @import("builtin").os.tag == .freestanding;

// Mock implementations for testing on host
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

/// Allocation tracking entry
/// Stores the physical address and page count for a given allocation
const PhysAlloc = struct {
    phys: u64,
    pages: usize,
};

/// Global allocation tracking map
/// Maps virtual address -> PhysAlloc
/// Uses heap allocator for the tracking structure itself
var allocations: ?std.AutoHashMap(usize, PhysAlloc) = null;

/// Lock protecting the allocations hashmap
/// Required for thread-safety when multiple drivers allocate DMA buffers concurrently
var dma_lock: sync.Spinlock = .{};

const sync = if (is_freestanding) @import("sync") else struct {
    pub const Spinlock = struct {
        pub const Held = struct {
            pub fn release(_: Held) void {}
        };
        pub fn acquire(_: *Spinlock) Held {
            return .{};
        }
    };
};

/// Initialize the tracking hashmap.
/// Called during kernel init to catch allocation failures early.
pub fn initTracking() void {
    const held = dma_lock.acquire();
    defer held.release();

    if (allocations == null) {
        allocations = std.AutoHashMap(usize, PhysAlloc).init(heap.allocator());
    }
}

fn getTracking() ?*std.AutoHashMap(usize, PhysAlloc) {
    if (allocations == null) {
        allocations = std.AutoHashMap(usize, PhysAlloc).init(heap.allocator());
    }
    return if (allocations != null) &allocations.? else null;
}

/// DMA Allocator struct for instance-based usage
pub const DmaAllocator = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {
        const held = dma_lock.acquire();
        defer held.release();

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

    /// Get the physical address for a virtual address allocated through this allocator
    pub fn getPhysicalAddress(_: *const Self, virt_addr: usize) ?u64 {
        const held = dma_lock.acquire();
        defer held.release();

        const tracking = getTracking() orelse return null;
        if (tracking.get(virt_addr)) |alloc| {
            return alloc.phys;
        }
        return null;
    }

    /// Get the std.mem.Allocator interface
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

        // Allocate physical pages (outside lock - PMM has its own locking)
        const phys = pmm.allocZeroedPages(pages) orelse return null;

        // Convert to virtual address
        const virt_ptr = hal.paging.physToVirt(phys);
        const virt_addr = @intFromPtr(virt_ptr);

        // Track allocation for physical address lookup and freeing
        // Use block scope for lock to allow cleanup outside lock on failure
        const success = blk: {
            const held = dma_lock.acquire();
            defer held.release();

            const tracking = getTracking() orelse break :blk false;
            tracking.put(virt_addr, .{ .phys = phys, .pages = pages }) catch {
                break :blk false;
            };
            break :blk true;
        };

        if (!success) {
            pmm.freePages(phys, pages);
            return null;
        }

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

        // Lookup and remove under lock, then free pages outside lock
        const maybe_alloc = blk: {
            const held = dma_lock.acquire();
            defer held.release();

            const tracking = getTracking() orelse break :blk null;
            break :blk tracking.fetchRemove(virt_addr);
        };

        if (maybe_alloc) |kv| {
            pmm.freePages(kv.value.phys, kv.value.pages);
        }
    }
};

// Global DMA allocator instance (lazily initialized)
var global_dma_allocator: ?DmaAllocator = null;

/// Get the global DMA allocator instance
pub fn getDmaAllocator() *DmaAllocator {
    if (global_dma_allocator == null) {
        global_dma_allocator = DmaAllocator.init();
    }
    return &global_dma_allocator.?;
}

/// Result type for allocDma, containing both virtual and physical addresses
pub const DmaAllocation = struct {
    slice: []u8,
    phys: u64,
};

/// Allocate DMA-capable memory and return both virtual slice and physical address
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

/// Free DMA memory allocated with allocDma
pub fn freeDma(slice: []u8) void {
    const dma = getDmaAllocator();
    dma.allocator().free(slice);
}

/// Get physical address for memory allocated through this module
pub fn getPhysicalAddress(virt_ptr: anytype) ?u64 {
    const virt_addr: usize = switch (@typeInfo(@TypeOf(virt_ptr))) {
        .pointer => @intFromPtr(virt_ptr),
        .int => virt_ptr,
        else => @compileError("Expected pointer or integer"),
    };

    const dma = getDmaAllocator();
    return dma.getPhysicalAddress(virt_addr);
}
