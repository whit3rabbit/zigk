// ZigK Kernel Entry Point
//
// This is the main entry point for the ZigK microkernel.
// It is called by the Limine bootloader after initial setup.

const limine = @import("limine");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const keyboard = @import("keyboard");

// Limine Base Revision - required for protocol compatibility
pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

// Limine Requests - bootloader fills responses at load time
pub export var framebuffer_request: limine.FramebufferRequest = .{};
pub export var hhdm_request: limine.HhdmRequest = .{};
pub export var memmap_request: limine.MemoryMapRequest = .{};
pub export var module_request: limine.ModuleRequest = .{};

// Global state initialized from Limine responses
var hhdm_offset: u64 = 0;

/// Kernel entry point - called by Limine bootloader
/// This function must be exported and named _start for the linker
export fn _start() noreturn {
    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    hal.init();

    // Connect console to interrupt handlers for debug output
    hal.interrupts.setConsoleWriter(&console.print);

    // Print boot banner
    console.print("\n");
    console.print("========================================\n");
    console.printf("{s} Microkernel v{s}\n", .{ config.name, config.version });
    console.print("========================================\n");
    console.print("\n");

    // Verify Limine protocol revision
    if (!base_revision.is_supported()) {
        console.err("Limine base revision not supported!", .{});
        halt();
    }
    console.info("Limine protocol revision verified", .{});

    // Initialize HHDM (Higher Half Direct Map)
    if (hhdm_request.response) |hhdm| {
        hhdm_offset = hhdm.offset;
        console.info("HHDM offset: {x}", .{hhdm_offset});
    } else {
        console.err("HHDM not available!", .{});
        halt();
    }

    // Parse memory map
    if (memmap_request.response) |memmap| {
        console.info("Memory map entries: {d}", .{memmap.entry_count});
        logMemoryMap(memmap);
    } else {
        console.err("Memory map not available!", .{});
        halt();
    }

    // Check for framebuffer (optional for serial-only testing)
    if (framebuffer_request.response) |fb_response| {
        if (fb_response.framebuffer_count > 0) {
            const fb = fb_response.framebuffers()[0];
            console.info("Framebuffer: {d}x{d} @ {x}", .{ fb.width, fb.height, fb.address });
        }
    } else {
        console.warn("No framebuffer available (serial-only mode)", .{});
    }

    // Check for InitRD modules
    if (module_request.response) |mod_response| {
        console.info("Loaded modules: {d}", .{mod_response.module_count});
    }

    // Initialize memory management subsystems
    initMemoryManagement();

    // Initialize keyboard driver and register with HAL
    keyboard.init();
    hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);

    // Log interrupt infrastructure status
    console.print("\n");
    console.info("Interrupt infrastructure initialized:", .{});
    console.info("  GDT loaded with TSS", .{});
    console.info("  PIC remapped to vectors 32-47", .{});
    console.info("  IDT installed with 48 handlers", .{});
    console.info("  Keyboard driver registered", .{});

    console.print("\n");
    console.info("Kernel initialization complete", .{});

    // Optional: Test interrupt handling with divide by zero
    // Uncomment to test exception handlers:
    // testDivideByZero();

    console.info("Entering halt loop...", .{});

    // Halt - kernel is not yet fully functional
    halt();
}

/// Test interrupt handling by triggering a divide by zero exception
/// This should print an exception message and halt
fn testDivideByZero() void {
    console.warn("Testing divide by zero exception...", .{});
    // Inline assembly to trigger divide by zero
    // This will cause exception vector 0 to fire
    asm volatile (
        \\xor %%ecx, %%ecx
        \\div %%ecx
        :
        :
        : .{ .eax = true, .ecx = true, .edx = true }
    );
}

/// Initialize PMM, VMM, and Heap
/// Must be called after parsing Limine responses
fn initMemoryManagement() void {
    console.print("\n");
    console.info("Initializing memory management...", .{});

    // Initialize PMM from memory map
    if (memmap_request.response) |memmap| {
        // Cast entries for PMM init
        const entries: []const *anyopaque = @ptrCast(memmap.entries_ptr[0..memmap.entry_count]);

        pmm.init(entries, memmap.entry_count, hhdm_offset) catch |err| {
            console.err("PMM initialization failed: {}", .{err});
            halt();
        };
    } else {
        console.err("Cannot initialize PMM: no memory map!", .{});
        halt();
    }

    // Initialize VMM with kernel page tables
    vmm.init() catch |err| {
        console.err("VMM initialization failed: {}", .{err});
        halt();
    };

    // Initialize kernel heap
    // Allocate heap pages from PMM
    const heap_pages = config.heap_size / pmm.PAGE_SIZE;
    const heap_phys = pmm.allocZeroedPages(heap_pages) orelse {
        console.err("Failed to allocate heap pages!", .{});
        halt();
    };

    // Convert to virtual address via HHDM for heap init
    const heap_virt = hal.paging.physToVirt(heap_phys);
    heap.init(@intFromPtr(heap_virt), config.heap_size);

    console.info("Memory management initialized", .{});
    pmm.printStats();
    heap.printStats();
}

/// Log memory map entries for debugging
fn logMemoryMap(memmap: *limine.MemoryMapResponse) void {
    var usable_memory: u64 = 0;
    var total_memory: u64 = 0;

    for (memmap.entries()) |entry| {
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

    console.info("Total memory: {d} MB", .{total_memory / (1024 * 1024)});
    console.info("Usable memory: {d} MB", .{usable_memory / (1024 * 1024)});
}

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hhdm_offset);
}

/// Convert virtual address to physical using HHDM
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}

/// Halt the kernel (disables interrupts and loops forever)
fn halt() noreturn {
    hal.cpu.haltForever();
}

// Custom panic handler for freestanding environment
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    // Disable interrupts to prevent further issues
    hal.cpu.disableInterrupts();

    console.print("\n!!! KERNEL PANIC !!!\n");
    console.print("Message: ");
    console.print(msg);
    console.print("\n");

    halt();
}
