//! Kernel Stack Allocator
//!
//! Manages kernel thread stacks with proper guard page protection.
//! Unlike HHDM-based stacks, this module allocates stacks in a dedicated
//! virtual address range with explicitly unmapped guard pages.
//!
//! Security: HHDM linearly maps all physical memory, so a "guard page"
//! calculated from HHDM is still actually mapped. This module solves that
//! by using a separate VA range where guard pages are truly unmapped.
//!
//! Layout per stack slot:
//!   - x86_64:  9 pages = 36KB (1 guard + 8 stack)
//!   - AArch64: 17 pages = 68KB (1 guard + 16 stack)
//!
//! Stack grows downward (high to low addresses), so overflow writes into
//! the guard page trigger #PF. stack_top is the initial RSP value.
//!
//! This module allocates stacks from a pre-reserved region (stack_region_base).

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console");
const pmm = @import("pmm");
const vmm = @import("vmm");
const hal = @import("hal");
const layout = @import("layout");

const paging = hal.paging;

// Configuration
pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

/// Number of pages per stack (excluding guard page).
/// AArch64 needs more due to larger SyscallFrame (288 bytes vs 128 bytes on x86_64).
/// This compensates for the 2.25x larger exception frames.
pub const STACK_PAGES: usize = switch (builtin.cpu.arch) {
    .aarch64 => 16, // 64 KB - matches x86_64's effective frame depth
    .x86_64 => 8, // 32 KB - sufficient for x86_64
    else => @compileError("Unsupported architecture for kernel stacks"),
};

/// Total size of each stack slot (guard + stack pages)
pub const STACK_SLOT_PAGES: usize = STACK_PAGES + 1;
pub const STACK_SLOT_SIZE: usize = STACK_SLOT_PAGES * PAGE_SIZE;

/// Maximum number of kernel stacks
pub const MAX_STACKS: usize = 256;

/// HHDM size constant (128 GB)
const HHDM_SIZE: u64 = 128 * 1024 * 1024 * 1024;

/// Kernel space base address (canonical high half)
const KERNEL_SPACE_BASE: u64 = 0xFFFF_8000_0000_0000;

/// Default stack region base (before KASLR randomization)
/// Used only for compile-time checks; runtime uses layout.getStackRegionBase()
const DEFAULT_STACK_REGION_BASE: u64 = 0xFFFF_A000_0000_0000;

/// Virtual address base for kernel stacks (runtime, set from layout with KASLR offset)
var stack_region_base: u64 = DEFAULT_STACK_REGION_BASE;

/// Total size of stack region
pub const STACK_REGION_SIZE: u64 = MAX_STACKS * STACK_SLOT_SIZE;

// Compile-time validation of constants
comptime {
    std.debug.assert(STACK_PAGES > 0);
    std.debug.assert(MAX_STACKS > 0);
    std.debug.assert(STACK_SLOT_SIZE == (STACK_PAGES + 1) * PAGE_SIZE);
    // Verify no overflow in worst-case region size
    const max_region: u128 = @as(u128, MAX_STACKS) * STACK_SLOT_SIZE;
    std.debug.assert(max_region <= std.math.maxInt(u64));
}

/// Get the current stack region base (with KASLR offset)
pub fn getStackRegionBase() u64 {
    return stack_region_base;
}

// Bitmap to track allocated stack slots
// Each bit represents one stack slot (1 = allocated, 0 = free)
const BITMAP_SIZE = (MAX_STACKS + 7) / 8;
var stack_bitmap: [BITMAP_SIZE]u8 = [_]u8{0} ** BITMAP_SIZE;

// Spinlock for thread-safe allocation
const sync = @import("sync");
var stack_lock: sync.Spinlock = .{};

// Initialization state (accessed under lock to prevent races)
var initialized: bool = false;

/// Stack allocation result
pub const KernelStack = struct {
    /// Virtual address of guard page (bottom of slot, unmapped).
    /// On stack overflow (RSP moves below stack_base), accesses hit this page -> #PF.
    guard_virt: u64,
    /// Virtual address of stack base (first usable page).
    /// RSP should never go below this address.
    stack_base: u64,
    /// Virtual address of stack top (initial RSP value).
    /// Stack grows downward from this address toward stack_base.
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
    InvalidRegion,
};

/// Initialize the kernel stack allocator
/// Must be called after layout.init() and VMM is initialized
pub fn init() StackError!void {
    const held = stack_lock.acquire();
    defer held.release();

    // Check initialized state under lock to prevent race conditions
    if (initialized) return;

    // Initialize stack region base from layout (with KASLR offset)
    stack_region_base = layout.getStackRegionBase();

    // SECURITY: Validate stack_region_base is in kernel space
    if (stack_region_base < KERNEL_SPACE_BASE) {
        console.err("KernelStack: stack_region_base {x} not in kernel space!", .{stack_region_base});
        return StackError.InvalidRegion;
    }

    // SECURITY: Check for address space wraparound
    if (stack_region_base > std.math.maxInt(u64) - STACK_REGION_SIZE) {
        console.err("KernelStack: stack region would overflow address space!", .{});
        return StackError.InvalidRegion;
    }

    // Verify the stack region doesn't overlap with HHDM
    const hhdm_start = paging.getHhdmOffset();
    const hhdm_end = std.math.add(u64, hhdm_start, HHDM_SIZE) catch {
        console.err("KernelStack: HHDM range overflow!", .{});
        return StackError.InvalidRegion;
    };
    if (stack_region_base < hhdm_end) {
        console.err("KernelStack: Stack region {x} overlaps HHDM end {x}!", .{ stack_region_base, hhdm_end });
        return StackError.MappingFailed;
    }

    console.info("KernelStack: Initialized at {x}, max {d} stacks ({d}KB each)", .{
        stack_region_base,
        MAX_STACKS,
        STACK_PAGES * PAGE_SIZE / 1024,
    });
    initialized = true;
}

/// Allocate a kernel stack with guard page protection
/// Returns stack information including virtual addresses
pub fn alloc() StackError!KernelStack {
    const held = stack_lock.acquire();
    defer held.release();

    // Check initialized under lock
    if (!initialized) return StackError.NotInitialized;

    // Find free slot in bitmap
    const slot = findFreeSlot() orelse return StackError.OutOfSlots;

    // Calculate virtual addresses for this slot with overflow protection
    const slot_offset = std.math.mul(u64, slot, STACK_SLOT_SIZE) catch {
        console.err("KernelStack: slot {d} offset overflow", .{slot});
        return StackError.MappingFailed;
    };
    const slot_base = std.math.add(u64, stack_region_base, slot_offset) catch {
        console.err("KernelStack: slot_base overflow for slot {d}", .{slot});
        return StackError.MappingFailed;
    };

    const guard_virt = slot_base;
    // These additions are safe: slot_base was validated, and PAGE_SIZE/STACK_SLOT_SIZE are small constants
    const stack_base = slot_base + PAGE_SIZE;
    const stack_top = slot_base + STACK_SLOT_SIZE;

    // Allocate physical pages for the stack (not the guard page)
    const stack_phys = pmm.allocZeroedPages(STACK_PAGES) orelse {
        return StackError.OutOfMemory;
    };
    errdefer pmm.freePages(stack_phys, STACK_PAGES);

    // Validate PMM returned page-aligned address
    std.debug.assert(stack_phys % PAGE_SIZE == 0);

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

    // Explicitly unmap the guard page to ensure no stale mappings exist.
    // SECURITY: If unmap fails (except NotMapped), we cannot guarantee guard protection.
    vmm.unmapPage(kernel_pml4, guard_virt) catch |err| {
        if (err != error.NotMapped) {
            // Guard page may still be mapped - unsafe to use this slot
            console.err("KernelStack: Failed to unmap guard page {x}: {} - slot unusable", .{ guard_virt, err });
            // Cleanup the mapping we just created
            var i: usize = 0;
            while (i < STACK_PAGES) : (i += 1) {
                vmm.unmapPage(kernel_pml4, stack_base + i * PAGE_SIZE) catch {};
            }
            return StackError.MappingFailed;
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
/// Unmaps pages and returns them to PMM. Marks slot as free.
pub fn free(stack: KernelStack) void {
    const held = stack_lock.acquire();
    defer held.release();

    if (stack.slot >= MAX_STACKS) {
        console.warn("KernelStack: Invalid slot {d} in free", .{stack.slot});
        return;
    }

    // SECURITY: Validate that stack_base matches expected address for this slot
    // Prevents attacks where a forged KernelStack struct could free wrong memory
    const expected_offset = std.math.mul(u64, stack.slot, STACK_SLOT_SIZE) catch {
        console.warn("KernelStack: Offset overflow for slot {d}", .{stack.slot});
        return;
    };
    const expected_base = std.math.add(u64, stack_region_base, expected_offset) catch {
        console.warn("KernelStack: Base overflow for slot {d}", .{stack.slot});
        return;
    };
    if (stack.stack_base != expected_base + PAGE_SIZE) {
        if (@import("builtin").mode == .Debug) {
            @panic("KernelStack: Corrupted stack descriptor - stack_base mismatch");
        }
        console.warn("KernelStack: stack_base mismatch for slot {d}: got {x}, expected {x}", .{
            stack.slot,
            stack.stack_base,
            expected_base + PAGE_SIZE,
        });
        return;
    }

    // SECURITY: Check if slot is actually allocated to prevent double-free
    // Without this check, freeing an already-freed slot would:
    // 1. Double-free physical pages (PMM corruption)
    // 2. Potentially free pages now owned by another thread
    if (!getBitmapBit(stack.slot)) {
        // Double-free is a serious bug - panic in Debug mode
        if (@import("builtin").mode == .Debug) {
            @panic("KernelStack: Double-free detected - possible exploit attempt");
        }
        console.warn("KernelStack: Double-free detected for slot {d}", .{stack.slot});
        return;
    }

    // Unmap stack pages from kernel address space
    const kernel_pml4 = vmm.getKernelPml4();
    var i: usize = 0;
    while (i < STACK_PAGES) : (i += 1) {
        const page_addr = stack.stack_base + i * PAGE_SIZE;
        vmm.unmapPage(kernel_pml4, page_addr) catch |err| {
            console.warn("KernelStack: Failed to unmap page {x}: {}", .{ page_addr, err });
        };
    }

    // Free physical pages
    pmm.freePages(stack.stack_phys, STACK_PAGES);

    // Mark slot as free
    setBitmapBit(stack.slot, false);

    console.debug("KernelStack: Freed slot {d}", .{stack.slot});
}

/// Check if an address is within a thread's guard page
/// Used by the page fault handler to detect stack overflows.
pub fn isGuardPage(addr: u64) bool {
    // Check if address is in our stack region with overflow protection
    if (addr < stack_region_base) return false;

    const region_end = std.math.add(u64, stack_region_base, STACK_REGION_SIZE) catch {
        // If this overflows, the address space configuration is invalid
        return false;
    };
    if (addr >= region_end) return false;

    // Calculate which slot this address is in - safe because addr >= stack_region_base
    const offset = addr - stack_region_base;
    const slot_offset = offset % STACK_SLOT_SIZE;

    // Guard page is the first page of each slot
    return slot_offset < PAGE_SIZE;
}

/// Get stack information for a guard page fault address
pub fn getStackInfoForGuardFault(addr: u64) ?struct { slot: usize, stack_base: u64, stack_top: u64 } {
    if (!isGuardPage(addr)) return null;

    const offset = addr - stack_region_base;
    const slot = offset / STACK_SLOT_SIZE;

    if (slot >= MAX_STACKS) return null;

    // Calculate addresses with overflow protection
    const slot_offset = std.math.mul(u64, slot, STACK_SLOT_SIZE) catch return null;
    const slot_base = std.math.add(u64, stack_region_base, slot_offset) catch return null;

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
    std.debug.assert(slot < MAX_STACKS);
    const byte_idx = slot / 8;
    const bit_idx: u3 = @truncate(slot % 8);
    return (stack_bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

fn setBitmapBit(slot: usize, value: bool) void {
    std.debug.assert(slot < MAX_STACKS);
    const byte_idx = slot / 8;
    const bit_idx: u3 = @truncate(slot % 8);
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
