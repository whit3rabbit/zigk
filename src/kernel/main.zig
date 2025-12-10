// ZigK Kernel Entry Point
//
// This is the main entry point for the ZigK microkernel.
// It is called by Limine bootloader in 64-bit long mode with paging enabled.
//
// Limine Entry Conditions:
//   - 64-bit long mode
//   - Paging enabled with identity + HHDM + higher-half mapping
//   - GDT with flat code/data segments
//   - Stack already set up
//   - Interrupts disabled (we set up our own IDT)

const limine = @import("limine");
const hal = @import("hal");
const syscall_arch = hal.syscall;
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const kernel_stack = @import("kernel_stack");
const keyboard = @import("keyboard");
const sched = @import("sched");
const thread = @import("thread");
const stack_guard = @import("stack_guard");
const prng = @import("prng");
const framebuffer = @import("framebuffer");
const fs = @import("fs");
const elf = @import("elf");
const process_mod = @import("process");
const handlers = @import("syscall_handlers");

// Syscall dispatch table - must be imported to compile dispatch_syscall symbol
// called from asm_helpers.S _syscall_entry
const syscall_table = @import("syscall_table");

// Force linking of symbols used by external code (assembly or compiler-inserted)
comptime {
    // Stack canary symbols used by compiler-inserted stack protection
    _ = &stack_guard.__stack_chk_guard;
    _ = &stack_guard.__stack_chk_fail;
    // Syscall dispatcher called from _syscall_entry in asm_helpers.S
    _ = &syscall_table.dispatch_syscall;
}

// Disable error return traces globally to safe memory/stack space
pub const os_has_error_return_trace = false;

// ============================================================================
// Limine Request Structures
// These are placed in .limine_requests section for bootloader discovery.
// Limine scans for magic IDs and patches response pointers at boot time.
// ============================================================================

pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 1 };
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};
pub export var module_request linksection(".limine_requests") = limine.ModuleRequest{};
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};
pub export var kernel_address_request linksection(".limine_requests") = limine.KernelAddressRequest{};

/// Per-CPU kernel data for syscall entry (GS segment)
/// For SMP, this would be an array indexed by CPU ID
var bsp_gs_data: syscall_arch.KernelGsData = .{
    .kernel_stack = 0,
    .user_stack = 0,
    .current_thread = 0,
    .scratch = 0,
};

/// Kernel entry point - called by Limine bootloader
/// Entry point is specified in linker script as _start
export fn _start() noreturn {
    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    // This must be first - serial is needed for any debug output
    hal.init();

    // Initialize GS base for syscalls - points to per-CPU data
    // kernel_stack will be updated by scheduler on context switch
    syscall_arch.setKernelGsBase(@intFromPtr(&bsp_gs_data));

    // Connect console to interrupt handlers for debug output
    hal.interrupts.setConsoleWriter(&console.print);

    // Print boot banner
    console.print("\n");
    console.print("========================================\n");
    console.printf("{s} Microkernel v{s}\n", .{ config.name, config.version });
    console.print("========================================\n");
    console.print("\n");

    // Verify Limine protocol is supported
    // Limine sets magic[0] to 0 if it processed our base revision
    if (!base_revision.is_supported()) {
        console.err("Limine protocol not supported! Check base revision.", .{});
        halt();
    }
    console.info("Limine protocol verified (revision 3)", .{});

    // Get HHDM offset from Limine response
    // This is critical - paging module needs the correct HHDM offset
    if (hhdm_request.response) |hhdm| {
        console.info("HHDM offset: {x}", .{hhdm.offset});
        hal.paging.init(hhdm.offset);
    } else {
        // Fallback to default HHDM (should not happen with Limine)
        console.warn("HHDM response not available, using default offset", .{});
        hal.paging.init(hal.paging.HHDM_OFFSET);
    }

    // Log kernel address info if available
    if (kernel_address_request.response) |ka| {
        console.info("Kernel physical base: {x}", .{ka.physical_base});
        console.info("Kernel virtual base: {x}", .{ka.virtual_base});
    }

    // Parse and log memory map
    if (memmap_request.response) |memmap| {
        logMemoryMap(memmap);
    } else {
        console.err("Memory map not available!", .{});
        halt();
    }

    // Initialize framebuffer from Limine response
    // Optional - serial-only mode works without framebuffer
    framebuffer.initFromLimine(&framebuffer_request);

    // Check for loaded modules (shell, etc.)
    if (module_request.response) |mod_response| {
        const mods = mod_response.modules();
        console.info("Loaded modules: {d}", .{mods.len});
        for (mods) |mod| {
            console.info("  Module: {s} @ {x} ({d} bytes)", .{
                mod.cmdline[0..strlen(mod.cmdline)],
                mod.address,
                mod.size,
            });
        }
    }

    // Initialize memory management subsystems
    initMemoryManagement();

    // Initialize entropy subsystem (RDRAND/RDTSC detection)
    // Must be done before PRNG which depends on hardware entropy
    hal.entropy.init();
    console.info("Entropy source: {s}", .{if (hal.entropy.hasRdrand()) "RDRAND" else "RDTSC (fallback)"});

    // Initialize kernel PRNG (seeds from hardware entropy)
    // Must be done before stack_guard which uses PRNG for canary
    prng.init();

    // Initialize stack guard canary with randomized value
    // Must be done BEFORE scheduler creates any threads
    stack_guard.init();

    // Initialize keyboard driver and register with HAL
    keyboard.init();
    hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);

    // Initialize scheduler (creates idle thread, registers timer handler)
    sched.init();

    // Register GS data with scheduler for syscall stack switching
    sched.setGsData(&bsp_gs_data);

    // Log interrupt infrastructure status
    console.print("\n");
    console.info("Interrupt infrastructure initialized:", .{});
    console.info("  GDT loaded with TSS", .{});
    console.info("  PIC remapped to vectors 32-47", .{});
    console.info("  IDT installed with 48 handlers", .{});
    console.info("  Keyboard driver registered", .{});
    console.info("  Scheduler initialized", .{});
    console.info("  PRNG seeded, stack canary randomized", .{});

    console.print("\n");
    console.info("Kernel initialization complete", .{});

    // Load Init Process (httpd or shell) from modules
    loadInitProcess();

    // Start the scheduler - this does not return
    // The boot thread becomes part of the idle loop
    console.info("Starting scheduler...", .{});
    sched.start();
}

/// Load the init process (httpd or shell) into a new user address space
/// Creates a proper Process struct with FD table (stdin/stdout/stderr pre-opened)
/// and uses the ELF loader to parse and load the executable.
fn loadInitProcess() void {
    console.info("Searching for init module...", .{});

    const mod_response = module_request.response orelse {
        console.warn("No modules loaded!", .{});
        return;
    };

    const mods = mod_response.modules();
    var selected_mod: ?*limine.Module = null;
    var process_name: []const u8 = "init";

    // Helper to safely get string from Limine pointer
    const get_str = struct {
        fn call(ptr: [*:0]const u8) []const u8 {
            if (@intFromPtr(ptr) == 0) return "";
            return ptr[0..strlen(ptr)];
        }
    }.call;

    // Priority 1: HTTPD
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);
        
        if (containsStr(cmdline, "httpd") or containsStr(path, "httpd")) {
            selected_mod = mod;
            process_name = "httpd";
            break;
        }
    }

    // Priority 2: Shell
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
            
            if (containsStr(cmdline, "shell") or containsStr(path, "shell")) {
                selected_mod = mod;
                process_name = "shell";
                break;
            }
        }
    }

    // Fallback: If only one module exists, use it regardless of name
    if (selected_mod == null and mods.len == 1) {
        selected_mod = mods[0];
        console.warn("No matching cmdline found, defaulting to first module", .{});
    }

    const mod = selected_mod orelse {
        console.warn("No suitable init module (httpd/shell) found!", .{});
        return;
    };

    console.info("Found init module: {s} ({d} bytes)", .{ process_name, mod.size });

    // Step 1: Create Process with FD table (stdin/stdout/stderr pre-opened by devfs)
    const proc = process_mod.createProcess(null) catch |err| {
        console.err("Failed to create init process: {}", .{err});
        return;
    };

    // Step 2: Set as current process so syscall handlers can access FD table
    handlers.setCurrentProcess(proc);
    console.info("Created process pid={d} with FD table", .{proc.pid});

    // Step 3: Get module data as slice for ELF loader
    const mod_data = @as([*]const u8, @ptrFromInt(mod.address))[0..mod.size];

    // Step 4: Load ELF into process's address space
    // The ELF loader will parse headers, validate, and map PT_LOAD segments
    const load_base: u64 = 0x400000; // Default load base for non-PIE executables
    const load_result = elf.load(mod_data, proc.cr3, load_base) catch |err| {
        console.err("ELF load failed: {}", .{err});
        return;
    };
    console.info("ELF: Loaded at {x}-{x}, entry={x}", .{
        load_result.base_addr,
        load_result.end_addr,
        load_result.entry_point,
    });

    // Step 5: Allocate and map user stack in process's address space
    const stack_virt_top: u64 = 0xF0000000;
    const stack_size: usize = 32 * 1024; // 32KB stack
    const stack_virt_base = stack_virt_top - stack_size;

    console.info("Creating user stack at {x}-{x}", .{ stack_virt_base, stack_virt_top });

    const stack_flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
    };

    // Allocate and map stack pages
    var addr = stack_virt_base;
    while (addr < stack_virt_top) : (addr += pmm.PAGE_SIZE) {
        vmm.allocAndMapPage(proc.cr3, addr, stack_flags) catch |err| {
            console.err("Failed to map stack page: {}", .{err});
            return;
        };
    }

    // Step 6: Create user thread with entry point from ELF header
    const user_thread = thread.createUserThread(load_result.entry_point, .{
        .name = process_name,
        .cr3 = proc.cr3,
        .user_stack_top = stack_virt_top,
    }) catch |err| {
        console.err("Failed to create user thread: {}", .{err});
        return;
    };

    sched.addThread(user_thread);
    console.info("Init process started (pid={d}, tid={d})", .{ proc.pid, user_thread.tid });
}

/// Initialize PMM, VMM, and Heap using Limine memory map
fn initMemoryManagement() void {
    console.print("\n");
    console.info("Initializing memory management...", .{});

    // PMM initialization from Limine memory map
    const memmap_response = memmap_request.response orelse {
        console.err("Cannot initialize PMM: no memory map!", .{});
        halt();
    };

    pmm.initFromLimine(memmap_response) catch |err| {
        console.err("PMM initialization failed: {}", .{err});
        halt();
    };

    // Initialize VMM with kernel page tables
    vmm.init() catch |err| {
        console.err("VMM initialization failed: {}", .{err});
        halt();
    };

    // Initialize kernel stack allocator (for proper guard page protection)
    // This must be done after VMM is ready since it uses VMM for page mapping
    kernel_stack.init() catch |err| {
        console.err("Kernel stack allocator initialization failed: {}", .{err});
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

/// Log Limine memory map entries
fn logMemoryMap(memmap: *const limine.MemoryMapResponse) void {
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

/// Calculate string length (null-terminated)
fn strlen(s: [*:0]const u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

/// Check if haystack contains needle
fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (haystack[i + j] != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) [*]u8 {
    return hal.paging.physToVirt(phys);
}

/// Halt the kernel (disables interrupts and loops forever)
fn halt() noreturn {
    hal.cpu.haltForever();
}

// Custom panic handler for freestanding environment
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    // Disable interrupts to prevent further issues on this core
    hal.cpu.disableInterrupts();

    console.printUnsafe("\n!!! KERNEL PANIC !!!\n");
    console.printUnsafe("Message: ");
    console.printUnsafe(msg);
    console.printUnsafe("\n");

    halt();
}
