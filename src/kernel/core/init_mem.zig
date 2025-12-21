//! Memory Initialization
//!
//! Orchestrates the initialization of the memory management subsystems:
//! 1. PMM (Physical Memory Manager) using the Limine memory map.
//! 2. VMM (Virtual Memory Manager) setting up kernel page tables.
//! 3. Kernel Stack Allocator (with guard pages).
//! 4. Kernel Heap (using the standard Zig allocator interface).

const std = @import("std");
const limine = @import("limine");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const kernel_stack = @import("kernel_stack");
const boot = @import("boot.zig");
const panic = @import("panic.zig");

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

/// Log Limine memory map entries
/// Useful for debugging memory layout and availability.
pub fn logMemoryMap(memmap: *const limine.MemoryMapResponse) void {
    var usable_memory: u64 = 0;
    var total_memory: u64 = 0;

    const entries = memmap.entries();
    for (entries) |entry| {
        total_memory += entry.length;

        const type_str = switch (entry.kind) {
            .usable => blk: {
                usable_memory += entry.length;
                break :blk "Usable";
            },
            .reserved => "Reserved",
            .acpi_reclaimable => "ACPI Reclaimable",
            .acpi_nvs => "ACPI NVS",
            .bad_memory => "Bad Memory",
            .bootloader_reclaimable => "Bootloader Reclaimable",
            .kernel_and_modules => "Kernel/Modules",
            .framebuffer => "Framebuffer",
        };

        if (config.debug_memory) {
            console.printf("  {x} - {x} ({s})\n", .{
                entry.base,
                entry.base + entry.length,
                type_str,
            });
        }
    }

    console.info("Memory map entries: {d}", .{entries.len});
    console.info("Total memory: {d} MB", .{total_memory / (1024 * 1024)});
    console.info("Usable memory: {d} MB", .{usable_memory / (1024 * 1024)});
}
