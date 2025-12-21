//! Memory Initialization
//!
//! Orchestrates the initialization of the memory management subsystems:
//! 1. PMM (Physical Memory Manager) using the BootInfo memory map.
//! 2. VMM (Virtual Memory Manager) setting up kernel page tables.
//! 3. Kernel Stack Allocator (with guard pages).
//! 4. Kernel Heap (using the standard Zig allocator interface).

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const kernel_stack = @import("kernel_stack");
const panic = @import("panic.zig");
const BootInfo = @import("boot_info");

/// Initialize PMM, VMM, and Heap using generic BootInfo
///
/// Steps:
/// 1. Initialize PMM with memory map from bootloader.
/// 2. Initialize VMM (kernel page tables).
/// 3. Initialize Kernel Stack Allocator (allows creating threads with guard pages).
/// 4. Allocate and initialize the Kernel Heap (free-list allocator).
pub fn initMemoryManagement(boot_info: *const @import("boot_info").BootInfo) void {
    console.print("\n");
    console.info("Initializing memory management...", .{});

    // PMM initialization from BootInfo
    const descriptors = boot_info.memory_map[0..boot_info.memory_map_count];
    
    pmm.init(descriptors) catch |err| {
        console.err("PMM initialization failed: {}", .{err});
        panic.halt();
    };

    // Initialize VMM with kernel page tables
    vmm.init() catch |err| {
        console.err("VMM initialization failed: {}", .{err});
        panic.halt();
    };

    // Initialize kernel stack allocator (for proper guard page protection)
    // This must be done after VMM is ready since it uses VMM for page mapping
    kernel_stack.init() catch |err| {
        console.err("Kernel stack allocator initialization failed: {}", .{err});
        panic.halt();
    };

    // Initialize kernel heap
    // Allocate heap pages from PMM
    const heap_pages = config.heap_size / pmm.PAGE_SIZE;
    const heap_phys = pmm.allocZeroedPages(heap_pages) orelse {
        console.err("Failed to allocate heap pages!", .{});
        panic.halt();
    };

    // Convert to virtual address via HHDM for heap init
    const heap_virt = hal.paging.physToVirt(heap_phys);
    heap.init(@intFromPtr(heap_virt), config.heap_size);

    console.info("Memory management initialized", .{});

    heap.printStats();
}

/// Log memory map entries from BootInfo
/// Useful for debugging memory layout and availability.
pub fn logMemoryMap(boot_info: *const BootInfo.BootInfo) void {
    var usable_memory: u64 = 0;
    var total_memory: u64 = 0;

    const entries = boot_info.memory_map[0..boot_info.memory_map_count];
    for (entries) |entry| {
        const length = entry.num_pages * pmm.PAGE_SIZE;
        total_memory += length;

        const type_str = switch (entry.type) {
            .Conventional => blk: {
                usable_memory += length;
                break :blk "Usable";
            },
            .Reserved => "Reserved",
            .ACPIReclaim => "ACPI Reclaimable",
            .ACPINvs => "ACPI NVS",
            .Unusable => "Unusable",
            .BootServicesCode, .BootServicesData => "Bootloader Reclaimable",
            .KernelCode, .KernelData => "Kernel/Modules",
            .Framebuffer => "Framebuffer",
            else => "Other",
        };

        if (config.debug_memory) {
            console.printf("  {x} - {x} ({s})\n", .{
                entry.phys_start,
                entry.phys_start + length,
                type_str,
            });
        }
    }

    console.info("Memory map entries: {d}", .{entries.len});
    console.info("Total memory: {d} MB", .{total_memory / (1024 * 1024)});
    console.info("Usable memory: {d} MB", .{usable_memory / (1024 * 1024)});
}
