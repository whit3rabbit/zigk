// Kernel Memory Layout Module
//
// Provides runtime-initialized memory layout values for KASLR.
// All values are set during boot from BootInfo and remain constant thereafter.
//
// This module centralizes memory region bases so they can be:
// 1. Initialized from bootloader-provided KASLR offsets
// 2. Accessed by other kernel subsystems (VMM, stack allocator, heap)
//
// SECURITY: These values must be treated as sensitive after initialization.
// Leaking them would defeat KASLR protection.

const std = @import("std");
const BootInfo = @import("boot_info");
const console = @import("console");
const hal = @import("hal");

// Default base addresses (before KASLR randomization)
// These are used as fallbacks if KASLR offsets are zero
const DEFAULT_HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;
const DEFAULT_STACK_REGION_BASE: u64 = 0xFFFF_A000_0000_0000;
const DEFAULT_MMIO_REGION_BASE: u64 = 0xFFFF_B000_0000_0000;

// Offsets from HHDM base to region bases (without KASLR)
const STACK_REGION_OFFSET: u64 = DEFAULT_STACK_REGION_BASE - DEFAULT_HHDM_BASE; // 0x2000_0000_0000 = 32TB
const MMIO_REGION_OFFSET: u64 = DEFAULT_MMIO_REGION_BASE - DEFAULT_HHDM_BASE; // 0x3000_0000_0000 = 48TB

// Runtime-initialized layout values
var hhdm_base: u64 = DEFAULT_HHDM_BASE;
var kernel_virt_base: u64 = 0;
var kernel_phys_base: u64 = 0;
var stack_region_base: u64 = DEFAULT_STACK_REGION_BASE;
var mmio_region_base: u64 = DEFAULT_MMIO_REGION_BASE;
var heap_offset: u64 = 0;
var initialized: bool = false;

/// Initialize memory layout from BootInfo
/// Must be called early in kernel initialization, after paging.init()
pub fn init(boot_info: *const BootInfo.BootInfo) void {
    if (initialized) {
        console.warn("Layout: Already initialized, ignoring duplicate init", .{});
        return;
    }

    // Core addresses from bootloader
    hhdm_base = boot_info.hhdm_offset;
    kernel_virt_base = boot_info.kernel_virt_base;
    kernel_phys_base = boot_info.kernel_phys_base;

    // Apply KASLR offsets to derive randomized region bases
    // Stack region: HHDM + fixed offset + random KASLR offset
    stack_region_base = hhdm_base + STACK_REGION_OFFSET + boot_info.stack_region_offset;

    // MMIO region: HHDM + fixed offset + random KASLR offset
    mmio_region_base = hhdm_base + MMIO_REGION_OFFSET + boot_info.mmio_region_offset;

    // Heap offset stored for use during heap initialization
    heap_offset = boot_info.heap_offset;

    initialized = true;

    // Log layout in debug mode (addresses masked in release - see panic.zig)
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) {
        console.info("Layout: HHDM base = 0x{x}", .{hhdm_base});
        console.info("Layout: Stack region = 0x{x} (offset +0x{x})", .{ stack_region_base, boot_info.stack_region_offset });
        console.info("Layout: MMIO region = 0x{x} (offset +0x{x})", .{ mmio_region_base, boot_info.mmio_region_offset });
        console.info("Layout: Heap offset = 0x{x}", .{heap_offset});
    }
}

/// Check if layout has been initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Get the HHDM (Higher Half Direct Map) base address
pub fn getHhdmBase() u64 {
    return hhdm_base;
}

/// Get the kernel virtual base address
pub fn getKernelVirtBase() u64 {
    return kernel_virt_base;
}

/// Get the kernel physical base address
pub fn getKernelPhysBase() u64 {
    return kernel_phys_base;
}

/// Get the kernel stack region base address (randomized with KASLR)
pub fn getStackRegionBase() u64 {
    return stack_region_base;
}

/// Get the MMIO mapping region base address (randomized with KASLR)
pub fn getMmioRegionBase() u64 {
    return mmio_region_base;
}

/// Get the heap offset for randomization
pub fn getHeapOffset() u64 {
    return heap_offset;
}

/// Validate that an address is in kernel space
pub fn isKernelAddress(addr: u64) bool {
    return addr >= hhdm_base;
}

/// Validate that an address is in user space
pub fn isUserAddress(addr: u64) bool {
    return addr < hhdm_base and addr < 0x0000_8000_0000_0000;
}
