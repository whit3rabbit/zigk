//! Physical Memory Manager (PMM)
//!
//! Manages physical page frames using a bitmap allocator.
//! Parses the memory map provided by Limine to identify usable regions.
//!
//! Features:
//! - Bitmap-based allocator: 1 bit per 4KB page.
//! - Reference counting: 16 bits per page (supports CoW/shared memory).
//! - Metadata placement: Dynamically finds a large enough usable region to store its own structures.
//! - HHDM usage: All physical memory access goes through the Higher Half Direct Map.
//!
//! Memory Layout (after init):
//! - Kernel and modules: Reserved by bootloader
//! - Bitmap: Placed in first usable region large enough
//! - Free pages: All usable regions minus bitmap and reserved areas

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const BootInfo = @import("boot_info");
const sync = @import("sync");

const paging = hal.paging;

// Constants
pub const PAGE_SIZE: usize = paging.PAGE_SIZE;

/// PMM internal state
///
/// The bitmap tracks allocation status (1 bit per page).
/// 0 = Free, 1 = Allocated/Reserved.
///
/// Refcounts track shared ownership (e.g., CoW or shared memory).
/// 0 = Free, >0 = Allocated.
var bitmap: []u8 = &[_]u8{};
var bitmap_size: usize = 0; // Size in bytes
var refcounts: []u16 = &[_]u16{}; // Refcount array
var total_pages: usize = 0;
var free_pages: usize = 0;
var allocated_pages: usize = 0;
var pmm_lock: sync.Spinlock = .{};

/// Hint for bitmap search - start searching from this byte index
/// This optimization avoids scanning reserved regions at the start of memory
var search_hint: usize = 0;

// Memory bounds
var memory_start: u64 = 0;
var memory_end: u64 = 0;

// Track if PMM is initialized
var initialized: bool = false;

/// Get refcount for a page (ADVISORY ONLY - unlocked read)
///
/// WARNING: This function reads without holding pmm_lock. The returned value
/// may be stale by the time the caller acts on it. DO NOT use for security
/// decisions like CoW - use getRefcountLocked() instead.
///
/// Safe uses: debugging, statistics, heuristics where stale data is acceptable.
pub fn getRefcount(phys_addr: u64) u16 {
    if (phys_addr >= memory_end) return 0;
    const page = phys_addr / PAGE_SIZE;
    if (page >= refcounts.len) return 0;
    return refcounts[page];
}

/// Get refcount for a page with lock held (for security-critical decisions)
///
/// Use this when the refcount determines security behavior (e.g., CoW decisions).
/// Returns the refcount value that will remain valid while you hold the lock.
///
/// Example: CoW check
///   const held = pmm.acquireLock();
///   defer held.release();
///   if (pmm.getRefcountLocked(page) > 1) { ... copy ... }
pub fn getRefcountLocked(phys_addr: u64) u16 {
    // Caller must already hold pmm_lock
    if (phys_addr >= memory_end) return 0;
    const page = phys_addr / PAGE_SIZE;
    if (page >= refcounts.len) return 0;
    return refcounts[page];
}

/// Acquire the PMM lock for multi-step atomic operations
/// Use with getRefcountLocked() for CoW and other security-critical checks
pub fn acquireLock() sync.Spinlock.Held {
    return pmm_lock.acquire();
}

/// Increment reference count for a page
pub fn refPage(phys_addr: u64) void {
    if (!initialized) return;
    
    // Lock effectively protects the refcount
    const held = pmm_lock.acquire();
    defer held.release();

    const page = phys_addr / PAGE_SIZE;
    if (page >= total_pages) return;

    // Check for overflow
    if (refcounts[page] == std.math.maxInt(u16)) {
        console.panic("PMM: Refcount overflow for page {x}", .{phys_addr});
    }

    refcounts[page] += 1;
}

/// Initialize PMM from generic Memory Map
pub fn init(memmap: []const BootInfo.MemoryDescriptor) !void {
    if (initialized) {
        return error.AlreadyInitialized;
    }

    console.info("PMM: Scanning memory map entries={d}...", .{memmap.len});
    const entries = memmap;

    // First pass: find memory bounds and count usable pages
    var usable_memory: u64 = 0;
    var highest_addr: u64 = 0;
    var lowest_usable: u64 = 0xFFFFFFFFFFFFFFFF;



    for (entries) |entry| {
        // Use checked arithmetic to prevent overflow in multiplication
        const length = std.math.mul(u64, entry.num_pages, PAGE_SIZE) catch continue;
        const end_addr = std.math.add(u64, entry.phys_start, length) catch continue;

        if (end_addr > highest_addr) {
            highest_addr = end_addr;
        }

        if (entry.type == .Conventional) {
            usable_memory += length;
            if (entry.phys_start < lowest_usable) {
                lowest_usable = entry.phys_start;
            }
        }
    }

    memory_start = lowest_usable;

    // Find the highest address of usable memory
    var highest_usable_end: u64 = 0;
    for (entries) |entry| {
        if (entry.type == .Conventional) {
            // Use checked arithmetic to prevent overflow
            const length = std.math.mul(u64, entry.num_pages, PAGE_SIZE) catch continue;
            const end_addr = std.math.add(u64, entry.phys_start, length) catch continue;
            if (end_addr > highest_usable_end) {
                highest_usable_end = end_addr;
            }
        }
    }

    memory_end = highest_usable_end;
    total_pages = @intCast(memory_end / PAGE_SIZE);

    // Sizes for metadata
    bitmap_size = (total_pages + 7) / 8;
    const refcounts_size = total_pages * @sizeOf(u16);
    const refcounts_offset = std.mem.alignForward(usize, bitmap_size, @alignOf(u16));
    const total_metadata = refcounts_offset + refcounts_size;

    console.info("PMM: Tracking {d} pages ({d} MB)", .{
        total_pages,
        (total_pages * PAGE_SIZE) / (1024 * 1024),
    });

    // Second pass: find a usable region for the bitmap AND refcounts
    var metadata_phys: u64 = 0;
    var found_region = false;

    for (entries) |entry| {
        // Need a usable region large enough for all metadata + safety margin
        const region_size = std.math.mul(u64, entry.num_pages, PAGE_SIZE) catch continue;
        const min_size = std.math.add(u64, total_metadata, PAGE_SIZE * 32) catch continue;
        if (entry.type == .Conventional and
            region_size >= min_size and
            entry.phys_start >= 0x100000)
        {
            metadata_phys = paging.pageAlignUp(entry.phys_start) orelse continue;
            found_region = true;
            break;
        }
    }

    if (!found_region) {
        console.err("PMM: No suitable region for metadata!", .{});
        return error.NoMemoryForBitmap;
    }

    // Map metadata arrays using HHDM
    const base_ptr: [*]u8 = paging.physToVirt(metadata_phys);
    bitmap = base_ptr[0..bitmap_size];
    
    // Refcounts follow bitmap with alignment
    const refcount_bytes = base_ptr[refcounts_offset .. refcounts_offset + refcounts_size];
    refcounts = @alignCast(std.mem.bytesAsSlice(u16, refcount_bytes));

    console.info("PMM: Metadata at phys {x}", .{ metadata_phys });

    // Initialize bitmap: mark all used (1)
    hal.mem.fill(bitmap.ptr, 0xFF, bitmap.len);
    
    // Initialize refcounts: default to 1
    for (refcounts) |*entry| {
        entry.* = 1;
    }

    // Third pass: mark usable regions as free
    for (entries) |entry| {
        if (entry.type == .Conventional) {
            // Use checked arithmetic to prevent overflow
            const region_size = std.math.mul(u64, entry.num_pages, PAGE_SIZE) catch continue;
            const region_end = std.math.add(u64, entry.phys_start, region_size) catch continue;
            const start_page = (paging.pageAlignUp(entry.phys_start) orelse continue) / PAGE_SIZE;
            const end_page = paging.pageAlignDown(region_end) / PAGE_SIZE;

            var page = start_page;
            while (page < end_page) : (page += 1) {
                clearBit(page);
                refcounts[page] = 0;
                free_pages += 1;
            }
        }
    }

    // Helper to reserve a range
    const reserveRange = struct {
        fn reserve(start: usize, count: usize) void {
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const p = start + i;
                if (p < total_pages and !isBitSet(p)) {
                    setBit(p);
                    refcounts[p] = 1;
                    if (free_pages > 0) free_pages -= 1;
                } else if (p < total_pages) {
                    refcounts[p] = 1; 
                }
            }
        }
    }.reserve;

    // Reserve page 0
    reserveRange(0, 1);

    // Reserve metadata pages (total_metadata is small, so overflow is impossible)
    const metadata_pages = paging.pagesToCover(total_metadata) orelse unreachable;
    const metadata_start_page = metadata_phys / PAGE_SIZE;
    reserveRange(metadata_start_page, metadata_pages);

    // Reserve kernel/module safety margin (1MB - 4MB)
    reserveRange(0x100000 / PAGE_SIZE, (0x400000 - 0x100000) / PAGE_SIZE);

    // Initialize search hint to skip reserved regions at start of physical memory
    // This dramatically speeds up allocation on platforms where RAM starts at high addresses
    // (e.g., AArch64 QEMU virt where RAM starts at 0x40000000 / 1GB)
    const start_page = memory_start / PAGE_SIZE;
    search_hint = start_page / 8; // Convert page number to byte index in bitmap
    if (search_hint >= bitmap_size) {
        search_hint = 0;
    }
    console.info("PMM: Search hint initialized to byte {d} (page {d})", .{ search_hint, start_page });

    initialized = true;
    
    console.info("PMM: Initialized - {d} MB usable, {d} free pages", .{
        (free_pages * PAGE_SIZE) / (1024 * 1024),
        free_pages,
    });
}




/// Allocate a specific physical page (if free)
/// Returns true on success, false if already allocated/invalid
pub fn allocSpecificPage(phys_addr: u64) bool {
    if (!initialized) return false;

    const held = pmm_lock.acquire();
    defer held.release();

    if (!paging.isPageAligned(phys_addr)) return false;
    const page = phys_addr / PAGE_SIZE;
    if (page >= total_pages) return false;

    if (isBitSet(page)) return false; // Already allocated

    setBit(page);
    refcounts[page] = 1;
    free_pages -= 1;
    allocated_pages += 1;

    return true;
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
        console.warn("PMM: Out of memory! (free_pages=0, allocated={d})", .{allocated_pages});
        return null;
    }

    // Search bitmap for first free page, starting from search_hint
    // This optimization dramatically speeds up allocation when RAM doesn't start at physical 0
    // (e.g., AArch64 QEMU virt where RAM starts at 0x40000000)

    // Start from the hint, wrapping around if necessary
    var byte_idx = search_hint;
    var wrapped = false;

    while (true) {
        if (bitmap[byte_idx] != 0xFF) {
            // Found a byte with at least one free bit
            var bit: u3 = 0;
            while (bit < 8) : (bit += 1) {
                const page_num = byte_idx * 8 + bit;
                if (page_num >= total_pages) break;

                if (!isBitSet(page_num)) {
                    setBit(page_num);
                    refcounts[page_num] = 1; // Initial refcount
                    free_pages -= 1;
                    allocated_pages += 1;

                    const phys_addr = @as(u64, page_num) * PAGE_SIZE;

                    // Update search hint to this byte for next allocation
                    search_hint = byte_idx;

                    if (config.debug_memory) {
                        console.debug("PMM: Allocated page {x}", .{phys_addr});
                    }

                    return phys_addr;
                }
            }
        }

        // Move to next byte
        byte_idx += 1;

        // Handle wrap-around
        if (byte_idx >= bitmap.len) {
            if (wrapped) {
                // We've searched the entire bitmap
                break;
            }
            byte_idx = 0;
            wrapped = true;
        }

        // If we've wrapped and reached our starting point, we're done
        if (wrapped and byte_idx >= search_hint) {
            break;
        }
    }

    // We've searched the entire bitmap without finding a free page
    // Reset search hint to beginning for next attempt
    search_hint = 0;
    console.warn("PMM: No free pages found! (free_pages={d}, total_pages={d})", .{ free_pages, total_pages });
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
                if (isBitSet(start_page + i)) {
                    @panic("PMM: allocPages found bit set during allocation phase");
                }
                setBit(start_page + i);
                refcounts[start_page + i] = 1;
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

    console.warn("PMM: Could not find {d} contiguous pages! (free_pages={d}, total_pages={d})", .{ count, free_pages, total_pages });
    return null;
}

/// Free a single physical page
/// Decrements refcount; if 0, marks as free.
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
        // Double-free is a serious bug - panic in Debug mode
        if (@import("builtin").mode == .Debug) {
            @panic("PMM: Double-free detected - possible exploit attempt");
        }
        console.warn("PMM: Double-free/Unallocated free detected at {x}!", .{phys_addr});
        return;
    }

    // Decrement refcount
    if (refcounts[page_num] > 0) {
        refcounts[page_num] -= 1;
    } else {
        console.panic("PMM: Refcount underflow for page {x}", .{phys_addr});
    }

    // Only actually free if refcount dropped to 0
    if (refcounts[page_num] == 0) {
        clearBit(page_num);
        free_pages += 1;
        if (allocated_pages > 0) {
            allocated_pages -= 1;
        }
        if (config.debug_memory) {
            console.debug("PMM: Freed page {x} (refcount=0)", .{phys_addr});
        }
    } else {
        if (config.debug_memory) {
            console.debug("PMM: Decremented refcount for {x} to {d}", .{ phys_addr, refcounts[page_num] });
        }
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
    hal.mem.fill(virt, 0, PAGE_SIZE);
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
