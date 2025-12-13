// Kernel Stack Allocator
//
// Manages kernel thread stacks with proper guard page protection.
// Unlike HHDM-based stacks, this module allocates stacks in a dedicated
// virtual address range with explicitly unmapped guard pages.
//
// Security: HHDM linearly maps all physical memory, so a "guard page"
// calculated from HHDM is still actually mapped. This module solves that
// by using a separate VA range where guard pages are truly unmapped.
//
// Layout per stack slot (5 pages = 20KB):
//   [Guard Page (unmapped)] [Stack pages (4 pages)] [Stack Top]
//
// Stack grows downward, so overflow writes into the guard page trigger #PF.

const std = @import("std");
const console = @import("console");
const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");

const paging = hal.paging;

// Configuration
pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

/// Number of pages per stack (excluding guard page)
pub const STACK_PAGES: usize = 4;

/// Total size of each stack slot (guard + stack pages)
pub const STACK_SLOT_PAGES: usize = STACK_PAGES + 1;
pub const STACK_SLOT_SIZE: usize = STACK_SLOT_PAGES * PAGE_SIZE;

/// Maximum number of kernel stacks
pub const MAX_STACKS: usize = 256;

/// Virtual address base for kernel stacks
/// This is in kernel space but separate from HHDM (0xFFFF_8000...)
/// Using 0xFFFF_A000_0000_0000 for stack region
pub const STACK_REGION_BASE: u64 = 0xFFFF_A000_0000_0000;

/// Total size of stack region
pub const STACK_REGION_SIZE: u64 = MAX_STACKS * STACK_SLOT_SIZE;

// Bitmap to track allocated stack slots
// Each bit represents one stack slot (1 = allocated, 0 = free)
const BITMAP_SIZE = (MAX_STACKS + 7) / 8;
var stack_bitmap: [BITMAP_SIZE]u8 = [_]u8{0} ** BITMAP_SIZE;

// Spinlock for thread-safe allocation
const sync = @import("sync");
var stack_lock: sync.Spinlock = .{};

// Initialization state
var initialized: bool = false;

/// Stack allocation result
pub const KernelStack = struct {
    /// Virtual address of guard page (bottom of slot, unmapped)
    guard_virt: u64,
    /// Virtual address of stack base (first usable page)
    stack_base: u64,
    /// Virtual address of stack top (where RSP starts)
    stack_top: u64,
    /// Physical address of stack pages
    stack_phys: u64,
    /// Slot index (for deallocation)
    slot: usize,
};

/// Errors that can occur during stack operations
pub const StackError = error{
    NotInitialized,
    OutOfSlots,
    OutOfMemory,
    MappingFailed,
    InvalidSlot,
};

/// Initialize the kernel stack allocator
/// Must be called after VMM is initialized
pub fn init() StackError!void {
    if (initialized) return;

    const held = stack_lock.acquire();
    defer held.release();

    // Verify the stack region doesn't overlap with HHDM
    // HHDM is at 0xFFFF_8000_0000_0000, our region at 0xFFFF_A000_0000_0000
    if (STACK_REGION_BASE < paging.HHDM_OFFSET + (4 * 1024 * 1024 * 1024)) {
        console.err("KernelStack: Stack region overlaps HHDM!", .{});
        return StackError.MappingFailed;
    }

    console.info("KernelStack: Initialized at {x}, max {d} stacks", .{ STACK_REGION_BASE, MAX_STACKS });
    initialized = true;
}

/// Allocate a kernel stack with guard page protection
/// Returns stack information including virtual addresses
pub fn alloc() StackError!KernelStack {
    if (!initialized) return StackError.NotInitialized;

    const held = stack_lock.acquire();
    defer held.release();

    // Find free slot in bitmap
    const slot = findFreeSlot() orelse return StackError.OutOfSlots;

    // Calculate virtual addresses for this slot
    const slot_base = STACK_REGION_BASE + slot * STACK_SLOT_SIZE;
    const guard_virt = slot_base;
    const stack_base = slot_base + PAGE_SIZE; // Skip guard page
    const stack_top = slot_base + STACK_SLOT_SIZE;

    // Allocate physical pages for the stack (not the guard page)
    const stack_phys = pmm.allocZeroedPages(STACK_PAGES) orelse {
        return StackError.OutOfMemory;
    };
    errdefer pmm.freePages(stack_phys, STACK_PAGES);

    // Map stack pages into the kernel address space
    // The guard page is intentionally NOT mapped - it stays unmapped
    const kernel_pml4 = vmm.getKernelPml4();
    const flags = vmm.PageFlags{
        .writable = true,
        .user = false, // Kernel stack, not user accessible
        .no_execute = true, // Stack should not be executable
    };

    vmm.mapRange(kernel_pml4, stack_base, stack_phys, STACK_PAGES * PAGE_SIZE, flags) catch {
        return StackError.MappingFailed;
    };

    // Explicitly unmap the guard page to ensure no stale mappings exist
    // from previous uses of this slot. This enforces the "guard" property.
    vmm.unmapPage(kernel_pml4, guard_virt) catch |err| {
        // If it's already unmapped (error.PageNotPresent), that's fine.
        // Any other error is concerning but likely recoverable/ignorable for a guard page.
        if (err != error.PageNotPresent) {
            console.warn("KernelStack: Failed to unmap guard page {x}: {}", .{ guard_virt, err });
        }
    };
    errdefer {
        // Unmap on error - note we only mapped stack_base, not guard
        var i: usize = 0;
        while (i < STACK_PAGES) : (i += 1) {
            vmm.unmapPage(kernel_pml4, stack_base + i * PAGE_SIZE) catch {};
        }
    }

    // Mark slot as allocated
    setBitmapBit(slot, true);

    console.debug("KernelStack: Allocated slot {d}, guard={x} stack={x}-{x}", .{
        slot,
        guard_virt,
        stack_base,
        stack_top,
    });

    return KernelStack{
        .guard_virt = guard_virt,
        .stack_base = stack_base,
        .stack_top = stack_top,
        .stack_phys = stack_phys,
        .slot = slot,
    };
}

/// Free a kernel stack
pub fn free(stack: KernelStack) void {
    const held = stack_lock.acquire();
    defer held.release();

    if (stack.slot >= MAX_STACKS) {
        console.warn("KernelStack: Invalid slot {d} in free", .{stack.slot});
        return;
    }

    // Unmap stack pages from kernel address space
    const kernel_pml4 = vmm.getKernelPml4();
    var i: usize = 0;
    while (i < STACK_PAGES) : (i += 1) {
        vmm.unmapPage(kernel_pml4, stack.stack_base + i * PAGE_SIZE) catch |err| {
            console.warn("KernelStack: Failed to unmap page: {}", .{err});
        };
    }

    // Free physical pages
    pmm.freePages(stack.stack_phys, STACK_PAGES);

    // Mark slot as free
    setBitmapBit(stack.slot, false);

    console.debug("KernelStack: Freed slot {d}", .{stack.slot});
}

/// Check if an address is within a stack's guard page
pub fn isGuardPage(addr: u64) bool {
    // Check if address is in our stack region
    if (addr < STACK_REGION_BASE or addr >= STACK_REGION_BASE + STACK_REGION_SIZE) {
        return false;
    }

    // Calculate which slot this address is in
    const offset = addr - STACK_REGION_BASE;
    const slot_offset = offset % STACK_SLOT_SIZE;

    // Guard page is the first page of each slot
    return slot_offset < PAGE_SIZE;
}

/// Get stack information for a guard page fault address
pub fn getStackInfoForGuardFault(addr: u64) ?struct { slot: usize, stack_base: u64, stack_top: u64 } {
    if (!isGuardPage(addr)) return null;

    const offset = addr - STACK_REGION_BASE;
    const slot = offset / STACK_SLOT_SIZE;

    if (slot >= MAX_STACKS) return null;

    const slot_base = STACK_REGION_BASE + slot * STACK_SLOT_SIZE;
    return .{
        .slot = slot,
        .stack_base = slot_base + PAGE_SIZE,
        .stack_top = slot_base + STACK_SLOT_SIZE,
    };
}

// Internal helpers

fn findFreeSlot() ?usize {
    var i: usize = 0;
    while (i < MAX_STACKS) : (i += 1) {
        if (!getBitmapBit(i)) {
            return i;
        }
    }
    return null;
}

fn getBitmapBit(slot: usize) bool {
    const byte_idx = slot / 8;
    const bit_idx: u3 = @intCast(slot % 8);
    return (stack_bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

fn setBitmapBit(slot: usize, value: bool) void {
    const byte_idx = slot / 8;
    const bit_idx: u3 = @intCast(slot % 8);
    if (value) {
        stack_bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
    } else {
        stack_bitmap[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }
}

/// Check if the kernel stack allocator is initialized
pub fn isInitialized() bool {
    return initialized;
}
