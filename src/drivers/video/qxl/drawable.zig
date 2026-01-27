//! QXL Drawable Pool
//!
//! Manages a pool of pre-allocated QXL drawable structures for 2D acceleration.
//! Drawables are used to submit fill, copy, and blit operations to the QXL device.

const std = @import("std");
const hal = @import("hal");
const pmm = @import("pmm");
const sync = @import("sync");
const hw = @import("hardware.zig");

/// CopyBits command data
pub const CopyBits = extern struct {
    src_pos: hw.QxlPoint,
};

/// QXL Drawable structure for 2D commands
/// This structure is placed in guest RAM and referenced by command ring entries
pub const QxlDrawable = extern struct {
    /// Release info for tracking command completion
    release_info: hw.QxlReleaseInfo,
    /// Surface ID (0 = primary surface)
    surface_id: u32,
    /// Effect type (unused, set to 0)
    effect: u8,
    /// Draw type (fill, copy_bits, etc.)
    type: u8,
    /// Padding for alignment
    _pad: [2]u8 = .{0} ** 2,
    /// Bounding box for the operation
    bbox: hw.QxlRect,
    /// Clip region descriptor
    clip: hw.QxlClip,
    /// Command-specific data union
    u: extern union {
        fill: hw.QxlFill,
        copy_bits: CopyBits,
    },
};

/// Pool of pre-allocated drawable structures
/// Uses a bitmap allocator for O(n) allocation with n = POOL_SIZE / 8
pub const DrawablePool = struct {
    /// Number of drawables in the pool
    pub const POOL_SIZE: usize = 64;
    /// Number of bytes in the allocation bitmap
    const BITMAP_SIZE: usize = POOL_SIZE / 8;

    /// Physical base address of the drawable pool
    phys_base: u64,
    /// Virtual base address of the drawable array
    virt_base: [*]QxlDrawable,
    /// Allocation bitmap (1 = allocated, 0 = free)
    alloc_bitmap: [BITMAP_SIZE]u8,
    /// Count of free slots
    free_count: usize,
    /// Spinlock for thread-safe allocation
    lock: sync.Spinlock,

    const Self = @This();

    /// Initialize the drawable pool
    /// Allocates 2 pages of physical memory for the pool
    pub fn init() ?Self {
        // Calculate pages needed: 64 drawables * sizeof(QxlDrawable)
        // QxlDrawable is ~128 bytes, so 64 * 128 = 8KB = 2 pages
        const pool_size_bytes = std.math.mul(usize, POOL_SIZE, @sizeOf(QxlDrawable)) catch return null;
        const pages_needed = (pool_size_bytes + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

        // Allocate zeroed physical pages for DMA access
        const phys = pmm.allocZeroedPages(pages_needed) orelse return null;
        const virt = hal.paging.physToVirt(phys);
        const virt_ptr: [*]QxlDrawable = @ptrCast(@alignCast(virt));

        return Self{
            .phys_base = phys,
            .virt_base = virt_ptr,
            .alloc_bitmap = .{0} ** BITMAP_SIZE,
            .free_count = POOL_SIZE,
            .lock = .{},
        };
    }

    /// Allocate a drawable from the pool
    /// Returns null if pool is exhausted
    pub fn alloc(self: *Self) ?*QxlDrawable {
        const held = self.lock.acquire();
        defer held.release();

        if (self.free_count == 0) return null;

        // Scan bitmap for a free slot
        for (0..BITMAP_SIZE) |byte_idx| {
            if (self.alloc_bitmap[byte_idx] != 0xFF) {
                // Found a byte with at least one free bit
                var bit: u3 = 0;
                while (bit < 8) : (bit += 1) {
                    const mask: u8 = @as(u8, 1) << bit;
                    if ((self.alloc_bitmap[byte_idx] & mask) == 0) {
                        // Found free slot, mark as allocated
                        self.alloc_bitmap[byte_idx] |= mask;
                        self.free_count -= 1;

                        // Calculate index with overflow protection
                        const index = std.math.mul(usize, byte_idx, 8) catch return null;
                        const slot_index = std.math.add(usize, index, bit) catch return null;

                        // Return pointer to the drawable
                        const drawable = &self.virt_base[slot_index];
                        // Zero-initialize for security
                        const drawable_bytes: [*]u8 = @ptrCast(drawable);
                        @memset(drawable_bytes[0..@sizeOf(QxlDrawable)], 0);
                        return drawable;
                    }
                }
            }
        }

        return null;
    }

    /// Free a drawable back to the pool
    pub fn free(self: *Self, drawable: *QxlDrawable) void {
        const held = self.lock.acquire();
        defer held.release();

        // Calculate index from pointer difference
        const drawable_addr = @intFromPtr(drawable);
        const base_addr = @intFromPtr(self.virt_base);

        if (drawable_addr < base_addr) return; // Invalid pointer

        const offset = drawable_addr - base_addr;
        const index = offset / @sizeOf(QxlDrawable);

        if (index >= POOL_SIZE) return; // Out of bounds

        // Calculate bitmap position
        const byte_idx = index / 8;
        const bit_idx: u3 = @intCast(index % 8);
        const mask: u8 = @as(u8, 1) << bit_idx;

        // Only free if currently allocated
        if ((self.alloc_bitmap[byte_idx] & mask) != 0) {
            self.alloc_bitmap[byte_idx] &= ~mask;
            self.free_count += 1;
        }
    }

    /// Convert a drawable virtual address to its physical address
    /// Returns null if the drawable is not from this pool
    pub fn toPhysical(self: *const Self, drawable: *const QxlDrawable) ?u64 {
        const drawable_addr = @intFromPtr(drawable);
        const base_addr = @intFromPtr(self.virt_base);

        if (drawable_addr < base_addr) return null;

        const offset = drawable_addr - base_addr;
        const index = offset / @sizeOf(QxlDrawable);

        if (index >= POOL_SIZE) return null;

        // Calculate physical address with overflow protection
        const drawable_offset = std.math.mul(u64, index, @sizeOf(QxlDrawable)) catch return null;
        return std.math.add(u64, self.phys_base, drawable_offset) catch null;
    }

    /// Get the number of free drawables
    pub fn getFreeCount(self: *const Self) usize {
        return self.free_count;
    }

    /// Check if a drawable belongs to this pool
    pub fn contains(self: *const Self, drawable: *const QxlDrawable) bool {
        const drawable_addr = @intFromPtr(drawable);
        const base_addr = @intFromPtr(self.virt_base);

        if (drawable_addr < base_addr) return false;

        const offset = drawable_addr - base_addr;
        const index = offset / @sizeOf(QxlDrawable);

        return index < POOL_SIZE;
    }
};
