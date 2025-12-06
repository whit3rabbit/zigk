// ZigK Kernel Entry Point
//
// This is the main entry point for the ZigK microkernel.
// It is called by the Limine bootloader after initial setup.

const limine = @import("limine");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");

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
    // Initialize HAL (serial port first for debug output)
    hal.init();

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

    console.print("\n");
    console.info("Kernel initialization complete", .{});
    console.info("Entering halt loop...", .{});

    // Halt - kernel is not yet fully functional
    halt();
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
