// Physical Memory Manager (PMM)
//
// Manages physical page frames using a bitmap allocator.
// Parses memory map to identify usable regions.
// Supports Multiboot2 boot protocol.
//
// Design:
//   - Bitmap-based allocator: 1 bit per 4KB page
//   - Tracks allocated pages count for leak detection
//   - Uses HHDM for all physical memory access
//
// Memory Layout (after init):
//   - Kernel and modules: Reserved by bootloader
//   - Bitmap: Placed in first usable region large enough
//   - Free pages: All usable regions minus bitmap and reserved areas

const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const limine = @import("limine");
const sync = @import("sync");

const paging = hal.paging;

// Constants
pub const PAGE_SIZE: usize = paging.PAGE_SIZE;

// PMM State
// Bitmap as slice enables Zig bounds checking on all accesses.
// Initialized to empty slice; set properly in initFromLimine().
var bitmap: []u8 = &[_]u8{};
var bitmap_size: usize = 0; // Size in bytes (redundant with bitmap.len but kept for clarity)
var total_pages: usize = 0;
var free_pages: usize = 0;
var allocated_pages: usize = 0;
var pmm_lock: sync.Spinlock = .{};

// Memory bounds
var memory_start: u64 = 0;
var memory_end: u64 = 0;

// Track if PMM is initialized
var initialized: bool = false;



/// Initialize PMM from Limine memory map
/// Must be called after paging.init() sets up HHDM
pub fn initFromLimine(memmap: *const limine.MemoryMapResponse) !void {
    if (initialized) {
        return error.AlreadyInitialized;
    }

    console.info("PMM: Scanning Limine memory map...", .{});

    const entries = memmap.entries();

    // First pass: find memory bounds and count usable pages
    var usable_memory: u64 = 0;
    var highest_addr: u64 = 0;
    var lowest_usable: u64 = 0xFFFFFFFFFFFFFFFF;

    for (entries) |entry| {
        const end_addr = entry.base + entry.length;

        if (end_addr > highest_addr) {
            highest_addr = end_addr;
        }

        if (entry.kind == .usable) {
            usable_memory += entry.length;
            if (entry.base < lowest_usable) {
                lowest_usable = entry.base;
            }
        }
    }

    memory_start = lowest_usable;
    memory_end = highest_addr;

    // Calculate total pages in the address space
    total_pages = @intCast(highest_addr / PAGE_SIZE);
    bitmap_size = (total_pages + 7) / 8; // Round up to bytes

    console.info("PMM: {d} entries, Total pages: {d}, Bitmap size: {d} KB", .{
        entries.len,
        total_pages,
        bitmap_size / 1024,
    });

    // Second pass: find a usable region for the bitmap
    var bitmap_phys: u64 = 0;
    var found_region = false;

    for (entries) |entry| {
        // Need a usable region large enough for bitmap + some pages
        // Also ensure we're not in the first 1MB (reserved for legacy)
        if (entry.kind == .usable and
            entry.length >= bitmap_size + PAGE_SIZE * 16 and
            entry.base >= 0x100000)
        {
            // Align bitmap to page boundary
            bitmap_phys = paging.pageAlignUp(entry.base);
            found_region = true;
            break;
        }
    }

    if (!found_region) {
        console.err("PMM: No suitable region for bitmap!", .{});
        return error.NoMemoryForBitmap;
    }

    // Map bitmap using HHDM and create bounded slice
    const bitmap_ptr: [*]u8 = paging.physToVirt(bitmap_phys);
    bitmap = bitmap_ptr[0..bitmap_size];

    console.info("PMM: Bitmap at phys {x}, virt {x}, size {d}", .{ bitmap_phys, @intFromPtr(bitmap.ptr), bitmap.len });

    // Initialize bitmap: mark all pages as used (1 = used, 0 = free)
    @memset(bitmap, 0xFF);

    // Third pass: mark usable regions as free in bitmap
    for (entries) |entry| {
        if (entry.kind == .usable) {
            const start_page = paging.pageAlignUp(entry.base) / PAGE_SIZE;
            const end_page = paging.pageAlignDown(entry.base + entry.length) / PAGE_SIZE;

            var page = start_page;
            while (page < end_page) : (page += 1) {
                clearBit(page);
                free_pages += 1;
            }
        }
    }

    // Reserve first 1MB (legacy BIOS area, bootloader code)
    const first_mb_pages = 0x100000 / PAGE_SIZE;
    var i: usize = 0;
    while (i < first_mb_pages) : (i += 1) {
        if (!isBitSet(i)) {
            setBit(i);
            if (free_pages > 0) free_pages -= 1;
        }
    }

    // Reserve bitmap pages
    const bitmap_pages = paging.pagesToCover(bitmap_size);
    const bitmap_start_page = bitmap_phys / PAGE_SIZE;

    i = 0;
    while (i < bitmap_pages) : (i += 1) {
        if (!isBitSet(bitmap_start_page + i)) {
            setBit(bitmap_start_page + i);
            if (free_pages > 0) free_pages -= 1;
        }
    }

    // Reserve kernel and module pages (Limine marks these as kernel_and_modules)
    // We don't need to manually reserve them as they're not marked usable
    // But we reserve memory up to 4MB for safety margin
    const kernel_end_page = 0x400000 / PAGE_SIZE;
    var page: usize = 0x100000 / PAGE_SIZE;
    while (page < kernel_end_page) : (page += 1) {
        if (!isBitSet(page)) {
            setBit(page);
            if (free_pages > 0) free_pages -= 1;
        }
    }

    initialized = true;

    console.info("PMM: Initialized - {d} MB usable, {d} free pages", .{
        (free_pages * PAGE_SIZE) / (1024 * 1024),
        free_pages,
    });
}



/// Allocate a single physical page
/// Returns physical address of allocated page, or null if OOM
pub fn allocPage() ?u64 {
    if (!initialized) {
        console.err("PMM: Not initialized!", .{});
        return null;
    }

    const held = pmm_lock.acquire();
    defer held.release();

    if (free_pages == 0) {
        console.warn("PMM: Out of memory!", .{});
        return null;
    }

    // Search bitmap for first free page
    // Using bitmap.len for bounds - slice provides automatic bounds checking
    var byte_idx: usize = 0;
    while (byte_idx < bitmap.len) : (byte_idx += 1) {
        if (bitmap[byte_idx] != 0xFF) {
            // Found a byte with at least one free bit
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                const page_num = byte_idx * 8 + bit;
                if (page_num >= total_pages) break;

                if (!isBitSet(page_num)) {
                    setBit(page_num);
                    free_pages -= 1;
                    allocated_pages += 1;

                    const phys_addr = @as(u64, page_num) * PAGE_SIZE;

                    if (config.debug_memory) {
                        console.debug("PMM: Allocated page {x}", .{phys_addr});
                    }

                    return phys_addr;
                }
            }
        }
    }

    console.warn("PMM: No free pages found!", .{});
    return null;
}

/// Allocate contiguous physical pages
/// Returns physical address of first page, or null if OOM
pub fn allocPages(count: usize) ?u64 {
    if (!initialized or count == 0) return null;

    const held = pmm_lock.acquire();
    defer held.release();

    if (free_pages < count) {
        console.warn("PMM: Not enough free pages ({d} requested, {d} available)", .{ count, free_pages });
        return null;
    }

    // Search for contiguous free pages
    var start_page: usize = 0;
    while (start_page + count <= total_pages) {
        var found = true;
        var i: usize = 0;

        while (i < count) : (i += 1) {
            if (isBitSet(start_page + i)) {
                found = false;
                start_page += i + 1;
                break;
            }
        }

        if (found) {
            // Mark all pages as allocated
            i = 0;
            while (i < count) : (i += 1) {
                setBit(start_page + i);
            }
            free_pages -= count;
            allocated_pages += count;

            const phys_addr = @as(u64, start_page) * PAGE_SIZE;

            if (config.debug_memory) {
                console.debug("PMM: Allocated {d} pages at {x}", .{ count, phys_addr });
            }

            return phys_addr;
        }
    }

    console.warn("PMM: Could not find {d} contiguous pages!", .{count});
    return null;
}

/// Free a single physical page
pub fn freePage(phys_addr: u64) void {
    if (!initialized) return;

    const held = pmm_lock.acquire();
    defer held.release();

    if (!paging.isPageAligned(phys_addr)) {
        console.err("PMM: Attempt to free non-aligned address {x}!", .{phys_addr});
        return;
    }

    const page_num = phys_addr / PAGE_SIZE;
    if (page_num >= total_pages) {
        console.err("PMM: Attempt to free invalid page {x}!", .{phys_addr});
        return;
    }

    if (!isBitSet(page_num)) {
        console.warn("PMM: Double-free detected at {x}!", .{phys_addr});
        return;
    }

    clearBit(page_num);
    free_pages += 1;

    if (allocated_pages > 0) {
        allocated_pages -= 1;
    }

    if (config.debug_memory) {
        console.debug("PMM: Freed page {x}", .{phys_addr});
    }
}

/// Free contiguous physical pages
pub fn freePages(phys_addr: u64, count: usize) void {
    if (!initialized or count == 0) return;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        freePage(phys_addr + i * PAGE_SIZE);
    }
}

/// Get count of free pages
pub fn getFreePages() usize {
    return free_pages;
}

/// Get count of allocated pages
pub fn getAllocatedPages() usize {
    return allocated_pages;
}

/// Get total pages in system
pub fn getTotalPages() usize {
    return total_pages;
}

/// Zero out a physical page (via HHDM)
pub fn zeroPage(phys_addr: u64) void {
    const virt = paging.physToVirt(phys_addr);
    @memset(virt[0..PAGE_SIZE], 0);
}

/// Allocate a zeroed physical page
pub fn allocZeroedPage() ?u64 {
    const phys = allocPage() orelse return null;
    zeroPage(phys);
    return phys;
}

/// Allocate zeroed contiguous pages
pub fn allocZeroedPages(count: usize) ?u64 {
    const phys = allocPages(count) orelse return null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        zeroPage(phys + i * PAGE_SIZE);
    }
    return phys;
}

// Bitmap helper functions
// These now include explicit bounds checks that panic on overflow.
// The slice access would also bounds-check, but explicit checks give better error messages.

fn setBit(page_num: usize) void {
    const byte_idx = page_num / 8;
    if (byte_idx >= bitmap.len) {
        console.err("PMM: setBit overflow - page {d}, byte_idx {d}, bitmap.len {d}", .{ page_num, byte_idx, bitmap.len });
        @panic("PMM: bitmap overflow in setBit");
    }
    const bit_idx: u3 = @intCast(page_num % 8);
    bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
}

fn clearBit(page_num: usize) void {
    const byte_idx = page_num / 8;
    if (byte_idx >= bitmap.len) {
        console.err("PMM: clearBit overflow - page {d}, byte_idx {d}, bitmap.len {d}", .{ page_num, byte_idx, bitmap.len });
        @panic("PMM: bitmap overflow in clearBit");
    }
    const bit_idx: u3 = @intCast(page_num % 8);
    bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
}

fn isBitSet(page_num: usize) bool {
    const byte_idx = page_num / 8;
    if (byte_idx >= bitmap.len) {
        console.err("PMM: isBitSet overflow - page {d}, byte_idx {d}, bitmap.len {d}", .{ page_num, byte_idx, bitmap.len });
        @panic("PMM: bitmap overflow in isBitSet");
    }
    const bit_idx: u3 = @intCast(page_num % 8);
    return (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

/// Debug: Print PMM statistics
pub fn printStats() void {
    console.info("PMM Stats:", .{});
    console.info("  Total pages:     {d}", .{total_pages});
    console.info("  Free pages:      {d}", .{free_pages});
    console.info("  Allocated pages: {d}", .{allocated_pages});
    console.info("  Free memory:     {d} MB", .{(free_pages * PAGE_SIZE) / (1024 * 1024)});
}
