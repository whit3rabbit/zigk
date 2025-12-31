//! Slab Allocator for Small Object Allocation
//!
//! Provides O(1) allocation for fixed-size objects by pre-dividing memory
//! into size classes. Each size class maintains slabs (4KB pages) subdivided
//! into equal-sized slots tracked by a bitmap.
//!
//! Size Classes: 16, 32, 64, 128, 256, 512, 1024, 2048 bytes
//!
//! Design:
//!   - Each slab is a 4KB page containing fixed-size objects
//!   - Bitmap at start of slab tracks free/allocated slots
//!   - Partial slabs (some free slots) are preferred for allocation
//!   - Full slabs are moved to full list (no searching)
//!   - Empty slabs can be returned to heap (memory reclamation)
//!
//! Performance:
//!   - Allocation: O(1) - bitmap scan for free slot
//!   - Deallocation: O(1) - compute slot index from pointer
//!   - No fragmentation within size class

const std = @import("std");

const is_freestanding = @import("builtin").os.tag == .freestanding;

// PMM and HAL for direct page allocation (freestanding only)
const pmm = if (is_freestanding) @import("pmm") else @compileError("PMM not available outside freestanding");
const hal = if (is_freestanding) @import("hal") else @compileError("HAL not available outside freestanding");

const console = if (is_freestanding) @import("console") else struct {
    pub fn info(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn warn(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn err(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
    pub fn debug(comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
    }
};

const sync = if (is_freestanding)
    @import("sync")
else
    struct {
        pub const Spinlock = struct {
            pub const Held = struct {
                pub fn release(_: Held) void {}
            };
            pub fn acquire(_: *Spinlock) Held {
                return .{};
            }
        };
    };

const config = @import("config");

// Backing allocator callbacks (set by heap during init)
var backing_alloc: ?*const fn (usize) ?[]u8 = null;
var backing_free: ?*const fn ([]u8) void = null;

/// Set the backing allocator functions (called by heap during init)
pub fn setBackingAllocator(
    alloc_fn: *const fn (usize) ?[]u8,
    free_fn: *const fn ([]u8) void,
) void {
    backing_alloc = alloc_fn;
    backing_free = free_fn;
}

// Constants
pub const SLAB_SIZE: usize = 4096; // 4KB per slab (one page)
pub const MIN_OBJECT_SIZE: usize = 16;
pub const MAX_OBJECT_SIZE: usize = 2048;
pub const NUM_SIZE_CLASSES: usize = 8;

// Size classes: 16, 32, 64, 128, 256, 512, 1024, 2048
pub const SIZE_CLASSES = [NUM_SIZE_CLASSES]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

/// Find the size class index for a given allocation size
pub fn getSizeClassIndex(size: usize) ?usize {
    inline for (SIZE_CLASSES, 0..) |class_size, i| {
        if (size <= class_size) {
            return i;
        }
    }
    return null; // Size too large for slab allocator
}

/// Magic value for slab header validation
/// Used to detect fake slab injection attacks
const SLAB_MAGIC: u32 = 0xDEAD51AB; // "DEADSLAB"

/// Slab header stored at the beginning of each slab
/// Uses a bitmap to track free/allocated slots
pub const SlabHeader = struct {
    /// Magic canary for validation (prevents fake slab injection)
    magic: u32 = SLAB_MAGIC,
    /// Number of allocated objects in this slab
    allocated_count: u16,
    /// Total number of objects that fit in this slab
    total_objects: u16,
    /// Pointer to the cache this slab belongs to
    cache: *SlabCache,
    /// Next slab in the list (partial/full/empty)
    next: ?*SlabHeader,
    /// Previous slab in the list
    prev: ?*SlabHeader,
    /// Object size for this slab
    object_size: u16,
    /// Padding to align to 8 bytes
    _reserved: u16 = 0,
    /// Bitmap tracking allocated slots (1 = allocated, 0 = free)
    /// Sized to fit maximum objects per slab (4096/16 = 256 objects = 4 u64s)
    bitmap: [4]u64,

    const Self = @This();

    /// Get the start address of object storage (after header)
    pub fn getObjectBase(self: *Self) usize {
        const header_size = @sizeOf(SlabHeader);
        const aligned_header = std.mem.alignForward(usize, header_size, 16);
        return @intFromPtr(self) + aligned_header;
    }

    /// Calculate total objects that fit in this slab
    pub fn calculateObjectCount(object_size: usize) u16 {
        const header_size = @sizeOf(SlabHeader);
        const aligned_header = std.mem.alignForward(usize, header_size, 16);
        const usable_space = SLAB_SIZE - aligned_header;
        return @truncate(usable_space / object_size);
    }

    /// Initialize a new slab for a given object size
    pub fn init(self: *Self, cache: *SlabCache, object_size: u16) void {
        self.magic = SLAB_MAGIC;
        self.cache = cache;
        self.next = null;
        self.prev = null;
        self.allocated_count = 0;
        self.object_size = object_size;
        self._reserved = 0;
        self.total_objects = calculateObjectCount(object_size);

        // Clear bitmap (all slots free)
        self.bitmap = [4]u64{ 0, 0, 0, 0 };
    }

    /// Allocate an object from this slab
    /// Returns pointer to allocated memory or null if slab is full
    pub fn allocObject(self: *Self) ?[*]u8 {
        if (self.allocated_count >= self.total_objects) {
            return null;
        }

        // Find first free slot in bitmap
        for (&self.bitmap, 0..) |*word, word_idx| {
            if (word.* != ~@as(u64, 0)) {
                // Found a word with at least one free bit
                const bit_idx = @ctz(~word.*);
                if (word_idx * 64 + bit_idx >= self.total_objects) {
                    return null; // Beyond valid object range
                }

                // Mark slot as allocated
                word.* |= (@as(u64, 1) << @truncate(bit_idx));
                self.allocated_count += 1;

                // Calculate object address
                const slot_index = word_idx * 64 + bit_idx;
                const obj_addr = self.getObjectBase() + slot_index * self.object_size;
                return @ptrFromInt(obj_addr);
            }
        }

        return null;
    }

    /// Free an object back to this slab
    /// Returns true if the free was valid
    pub fn freeObject(self: *Self, ptr: [*]u8) bool {
        const ptr_addr = @intFromPtr(ptr);
        const base = self.getObjectBase();

        // Validate pointer is within this slab's object area
        if (ptr_addr < base) {
            return false;
        }

        const offset = ptr_addr - base;
        if (offset % self.object_size != 0) {
            // Misaligned pointer
            if (is_freestanding) {
                console.warn("Slab: Misaligned free at {x}", .{ptr_addr});
            }
            return false;
        }

        const slot_index = offset / self.object_size;
        if (slot_index >= self.total_objects) {
            return false;
        }

        // Check if slot was actually allocated
        const word_idx = slot_index / 64;
        const bit_idx: u6 = @truncate(slot_index % 64);
        const mask = @as(u64, 1) << bit_idx;

        if ((self.bitmap[word_idx] & mask) == 0) {
            // Double free detected - possible exploit attempt
            if (@import("builtin").mode == .Debug) {
                @panic("Slab: Double-free detected - possible exploit attempt");
            }
            if (is_freestanding) {
                console.warn("Slab: Double free at {x}", .{ptr_addr});
            }
            return false;
        }

        // Mark slot as free
        self.bitmap[word_idx] &= ~mask;
        self.allocated_count -= 1;

        return true;
    }

    /// Check if slab is empty (no allocated objects)
    pub fn isEmpty(self: *const Self) bool {
        return self.allocated_count == 0;
    }

    /// Check if slab is full (all objects allocated)
    pub fn isFull(self: *const Self) bool {
        return self.allocated_count >= self.total_objects;
    }
};

/// Slab cache for a specific size class
/// Maintains lists of partial, full, and empty slabs
pub const SlabCache = struct {
    /// Size of objects in this cache
    object_size: usize,
    /// List of slabs with some free objects (preferred for allocation)
    partial_list: ?*SlabHeader,
    /// List of completely full slabs
    full_list: ?*SlabHeader,
    /// Number of partial slabs
    partial_count: usize,
    /// Number of full slabs
    full_count: usize,
    /// Total objects allocated from this cache
    total_allocated: usize,
    /// Lock protecting this cache
    lock: sync.Spinlock,

    const Self = @This();

    /// Initialize a cache for a specific object size
    pub fn init(self: *Self, object_size: usize) void {
        self.object_size = object_size;
        self.partial_list = null;
        self.full_list = null;
        self.partial_count = 0;
        self.full_count = 0;
        self.total_allocated = 0;
        self.lock = .{};
    }

    /// Allocate an object from this cache
    pub fn alloc(self: *Self) ?[*]u8 {
        const held = self.lock.acquire();
        defer held.release();

        // Try to allocate from a partial slab first
        if (self.partial_list) |slab| {
            if (slab.allocObject()) |ptr| {
                self.total_allocated += 1;

                // If slab became full, move to full list
                if (slab.isFull()) {
                    self.moveToFullList(slab);
                }

                return ptr;
            }
        }

        // Need a new slab
        const new_slab = self.allocateSlab() orelse return null;
        const ptr = new_slab.allocObject() orelse {
            // Should not happen with a fresh slab
            self.deallocateSlab(new_slab);
            return null;
        };

        self.total_allocated += 1;

        // Add to partial list (or full if only one object fits)
        if (new_slab.isFull()) {
            self.addToFullList(new_slab);
        } else {
            self.addToPartialList(new_slab);
        }

        return ptr;
    }

    /// Free an object back to this cache
    pub fn free(self: *Self, slab: *SlabHeader, ptr: [*]u8) void {
        const held = self.lock.acquire();
        defer held.release();

        const was_full = slab.isFull();

        if (!slab.freeObject(ptr)) {
            return; // Invalid free, already logged
        }

        self.total_allocated -= 1;

        // Handle list transitions
        if (was_full) {
            // Move from full to partial
            self.removeFromFullList(slab);
            self.addToPartialList(slab);
        } else if (slab.isEmpty()) {
            // Slab is now empty, optionally return to heap
            // For now, keep one empty slab per cache for hysteresis
            if (self.partial_count > 1) {
                self.removeFromPartialList(slab);
                self.deallocateSlab(slab);
            }
        }
    }

    // List management helpers

    fn addToPartialList(self: *Self, slab: *SlabHeader) void {
        slab.next = self.partial_list;
        slab.prev = null;
        if (self.partial_list) |head| {
            head.prev = slab;
        }
        self.partial_list = slab;
        self.partial_count += 1;
    }

    fn removeFromPartialList(self: *Self, slab: *SlabHeader) void {
        if (slab.prev) |prev| {
            prev.next = slab.next;
        } else {
            self.partial_list = slab.next;
        }
        if (slab.next) |next| {
            next.prev = slab.prev;
        }
        slab.prev = null;
        slab.next = null;
        if (self.partial_count > 0) {
            self.partial_count -= 1;
        }
    }

    fn addToFullList(self: *Self, slab: *SlabHeader) void {
        slab.next = self.full_list;
        slab.prev = null;
        if (self.full_list) |head| {
            head.prev = slab;
        }
        self.full_list = slab;
        self.full_count += 1;
    }

    fn removeFromFullList(self: *Self, slab: *SlabHeader) void {
        if (slab.prev) |prev| {
            prev.next = slab.next;
        } else {
            self.full_list = slab.next;
        }
        if (slab.next) |next| {
            next.prev = slab.prev;
        }
        slab.prev = null;
        slab.next = null;
        if (self.full_count > 0) {
            self.full_count -= 1;
        }
    }

    fn moveToFullList(self: *Self, slab: *SlabHeader) void {
        self.removeFromPartialList(slab);
        self.addToFullList(slab);
    }

    /// Allocate a new slab directly from PMM (page-aligned)
    fn allocateSlab(self: *Self) ?*SlabHeader {
        if (!is_freestanding) {
            // For testing, fall back to backing allocator
            const alloc_fn = backing_alloc orelse return null;
            const mem = alloc_fn(SLAB_SIZE) orelse return null;
            const slab: *SlabHeader = @ptrCast(@alignCast(mem.ptr));
            slab.init(self, @truncate(self.object_size));
            return slab;
        }

        // Allocate one physical page (4KB, page-aligned by definition)
        const phys_addr = pmm.allocZeroedPage() orelse return null;

        // Convert to virtual address via HHDM
        const virt_ptr = hal.paging.physToVirt(phys_addr);
        const slab: *SlabHeader = @ptrCast(@alignCast(virt_ptr));
        slab.init(self, @truncate(self.object_size));
        return slab;
    }

    /// Return a slab to PMM
    fn deallocateSlab(_: *Self, slab: *SlabHeader) void {
        if (!is_freestanding) {
            // For testing, fall back to backing allocator
            const free_fn = backing_free orelse return;
            const ptr: [*]u8 = @ptrCast(slab);
            free_fn(ptr[0..SLAB_SIZE]);
            return;
        }

        // Convert virtual address back to physical via HHDM
        const virt_addr = @intFromPtr(slab);
        const phys_addr = hal.paging.virtToPhys(virt_addr);

        // Free the page back to PMM
        pmm.freePage(phys_addr);
    }
};

// Global slab caches (one per size class)
var slab_caches: [NUM_SIZE_CLASSES]SlabCache = undefined;
var slab_initialized: bool = false;

/// Initialize the slab allocator
pub fn init() void {
    if (slab_initialized) return;

    for (&slab_caches, SIZE_CLASSES) |*cache, size| {
        cache.init(size);
    }

    slab_initialized = true;

    if (is_freestanding) {
        console.info("Slab: Initialized {d} size classes (16B-2KB)", .{NUM_SIZE_CLASSES});
    }
}

/// Allocate memory using slab allocator
/// Returns null if size > MAX_OBJECT_SIZE or allocation fails
pub fn alloc(size: usize) ?[]u8 {
    if (!slab_initialized or size == 0) {
        return null;
    }

    const class_idx = getSizeClassIndex(size) orelse return null;
    const cache = &slab_caches[class_idx];

    const ptr = cache.alloc() orelse return null;
    return ptr[0..SIZE_CLASSES[class_idx]];
}

/// Free memory allocated by slab allocator
/// Returns false if the pointer was not from a slab
pub fn free(ptr: []u8) bool {
    if (!slab_initialized or ptr.len == 0) {
        return false;
    }

    // Find which slab this pointer belongs to by aligning down to slab boundary
    const ptr_addr = @intFromPtr(ptr.ptr);
    const slab_addr = ptr_addr & ~@as(usize, SLAB_SIZE - 1);
    const slab: *SlabHeader = @ptrFromInt(slab_addr);

    // SECURITY: First validate magic canary to detect fake slab injection
    // An attacker who controls memory at a page boundary could craft a fake
    // SlabHeader. The magic check prevents this attack.
    if (slab.magic != SLAB_MAGIC) {
        if (is_freestanding) {
            console.warn("Slab: Invalid magic at {x} (expected {x}, got {x})", .{
                slab_addr,
                SLAB_MAGIC,
                slab.magic,
            });
        }
        return false; // Not a valid slab - possible attack or corruption
    }

    // Validate this looks like a slab header by checking cache pointer
    // The cache pointer should point into our slab_caches array
    const caches_start = @intFromPtr(&slab_caches[0]);
    const caches_end = caches_start + @sizeOf(@TypeOf(slab_caches));
    const cache_addr = @intFromPtr(slab.cache);

    if (cache_addr < caches_start or cache_addr >= caches_end) {
        if (is_freestanding) {
            console.warn("Slab: Invalid cache pointer at {x}", .{slab_addr});
        }
        return false; // Not a slab allocation
    }

    // Additional validation: object_size should match cache's object_size
    if (slab.object_size != slab.cache.object_size) {
        if (is_freestanding) {
            console.warn("Slab: Object size mismatch at {x}", .{slab_addr});
        }
        return false; // Corrupted or fake slab
    }

    slab.cache.free(slab, ptr.ptr);
    return true;
}

/// Check if a size would be handled by the slab allocator
pub fn isSizeSlabbed(size: usize) bool {
    return size > 0 and size <= MAX_OBJECT_SIZE;
}

/// Get statistics for a size class
pub fn getCacheStats(class_idx: usize) struct {
    object_size: usize,
    partial_slabs: usize,
    full_slabs: usize,
    total_allocated: usize,
} {
    if (class_idx >= NUM_SIZE_CLASSES) {
        return .{ .object_size = 0, .partial_slabs = 0, .full_slabs = 0, .total_allocated = 0 };
    }

    const cache = &slab_caches[class_idx];
    return .{
        .object_size = cache.object_size,
        .partial_slabs = cache.partial_count,
        .full_slabs = cache.full_count,
        .total_allocated = cache.total_allocated,
    };
}

/// Print slab allocator statistics
pub fn printStats() void {
    if (is_freestanding) {
        console.info("Slab Allocator Stats:", .{});
        for (0..NUM_SIZE_CLASSES) |i| {
            const stats = getCacheStats(i);
            if (stats.total_allocated > 0 or stats.partial_slabs > 0) {
                console.info("  {d}B: {d} alloc, {d} partial, {d} full slabs", .{
                    stats.object_size,
                    stats.total_allocated,
                    stats.partial_slabs,
                    stats.full_slabs,
                });
            }
        }
    }
}
