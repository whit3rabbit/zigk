// Zscapek Kernel Entry Point
//
// This is the main entry point for the Zscapek microkernel.
// It is called by Limine bootloader in 64-bit long mode with paging enabled.
//
// Limine Entry Conditions:
//   - 64-bit long mode
//   - Paging enabled with identity + HHDM + higher-half mapping
//   - GDT with flat code/data segments
//   - Stack already set up
//   - Interrupts disabled (we set up our own IDT)

const std = @import("std");
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
const mouse = @import("mouse");
const sched = @import("sched");
const thread = @import("thread");
const stack_guard = @import("stack_guard");
const prng = @import("prng");
const framebuffer = @import("framebuffer");
const fs = @import("fs");
const elf = @import("elf");
const process_mod = @import("process");
const handlers = @import("syscall_handlers");
const net = @import("net");
const pci = @import("pci");
const e1000e = @import("e1000e");
const usb = @import("usb");
const acpi = @import("acpi");
const ahci = @import("ahci");
const devfs = @import("devfs");

const serial_driver = @import("serial_driver");
const video_driver = @import("video_driver");

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

// =============================================================================
// std.log Integration
// =============================================================================
// Redirect std.log.* calls to kernel console. This allows third-party Zig
// libraries to log correctly and provides a standard logging interface.

pub const std_options: std.Options = .{
    .logFn = kernelLogFn,
    .log_level = .debug,
};

fn kernelLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const prefix = switch (level) {
        .debug => "[DEBUG] ",
        .info => "[INFO]  ",
        .warn => "[WARN]  ",
        .err => "[ERROR] ",
    };
    console.print(prefix);
    console.printf(format, args);
    console.print("\n");
}

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
pub export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};

/// Per-CPU kernel data for syscall entry (GS segment)
/// For SMP, this would be an array indexed by CPU ID
var bsp_gs_data: syscall_arch.KernelGsData = .{
    .kernel_stack = 0,
    .user_stack = 0,
    .current_thread = 0,
    .scratch = 0,
};

// Global driver instances
var uart: serial_driver.Serial = undefined;
var fb_driver_direct: video_driver.DirectFramebufferDriver = undefined;
var fb_driver_buffered: video_driver.BufferedFramebufferDriver = undefined;
var fb_is_buffered: bool = false;
var graph_console: video_driver.console.Console = undefined;

// Wrapper for UART backend
fn uartWriteWrapper(ctx: ?*anyopaque, str: []const u8) void {
    const s: *serial_driver.Serial = @ptrCast(@alignCast(ctx));
    s.write(str);
}

// Wrapper for Video backend
fn videoWriteWrapper(ctx: ?*anyopaque, str: []const u8) void {
    const c: *video_driver.console.Console = @ptrCast(@alignCast(ctx));
    c.write(str);
}

// Wrapper for Scrolling
fn videoScrollWrapper(ctx: ?*anyopaque, lines: usize, up: bool) void {
    const c: *video_driver.console.Console = @ptrCast(@alignCast(ctx));
    if (up) {
        c.scrollUp(lines);
    } else {
        c.scrollDown(lines);
    }
}

/// Kernel entry point - called by Limine bootloader
/// Entry point is specified in linker script as _start
export fn _start() noreturn {
    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    // This must be first - serial is needed for any debug output
    hal.init();

    // Initialize Serial Driver (UART)
    uart = serial_driver.Serial.init();
    
    // Register UART as console backend
    console.addBackend(.{
        .context = @ptrCast(&uart),
        .writeFn = uartWriteWrapper,
    });

    // Initialize GS base for syscalls - points to per-CPU data
    // kernel_stack will be updated by scheduler on context switch
    //
    // SWAPGS dance requires:
    //   Kernel mode: GS_BASE = &kernel_data, KERNEL_GS_BASE = user_gs (0)
    //   User mode:   GS_BASE = user_gs (0),  KERNEL_GS_BASE = &kernel_data
    //
    // First SWAPGS (isr_common returning to user) swaps these.
    // So we set GS_BASE here, not KERNEL_GS_BASE.
    // KERNEL_GS_BASE is already 0 from syscall.init().
    hal.cpu.writeMsr(hal.cpu.IA32_GS_BASE, @intFromPtr(&bsp_gs_data));

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
    
    // Initialize Graphical Console if framebuffer is available
    // Initialize Graphical Console if framebuffer is available
    if (framebuffer.getState()) |fb_state| {
        // fb_state.phys_addr is physical. Convert to kernel virtual (HHDM).
        const virt_addr = @intFromPtr(hal.paging.physToVirt(fb_state.phys_addr));
        
        // Initialize Framebuffer Driver (direct mode initially, before PMM is ready)
        const video_mode = video_driver.interface.VideoMode{
            .width = fb_state.width,
            .height = fb_state.height,
            .pitch = fb_state.pitch,
            .bpp = fb_state.bpp,
            .addr = virt_addr,
            .red_mask_size = fb_state.red_mask_size,
            .red_field_position = fb_state.red_shift,
            .green_mask_size = fb_state.green_mask_size,
            .green_field_position = fb_state.green_shift,
            .blue_mask_size = fb_state.blue_mask_size,
            .blue_field_position = fb_state.blue_shift,
        };
        fb_driver_direct = video_driver.DirectFramebufferDriver.initDirect(video_mode);

        // Initialize Graphical Console (will switch to buffered driver after PMM init)
        graph_console = video_driver.console.Console.init(fb_driver_direct.device());
        
        // Register Graphical Console as backend
        console.addBackend(.{
            .context = @ptrCast(&graph_console),
            .writeFn = videoWriteWrapper,
            .scrollFn = videoScrollWrapper,
        });
        
        console.info("Graphics: Initialized {d}x{d}x{d} framebuffer", .{
            fb_state.width, fb_state.height, fb_state.bpp
        });
    }

    // Check for loaded modules (shell, initrd, etc.)
    if (module_request.response) |mod_response| {
        const mods = mod_response.modules();
        console.info("Loaded modules: {d}", .{mods.len});
        for (mods) |mod| {
            console.info("  Module: {s} @ {x} ({d} bytes)", .{
                std.mem.span(mod.cmdline),
                mod.address,
                mod.size,
            });
        }

        // Initialize InitRD if present
        initInitRD(mods);
    }

    // Initialize VFS and mount filesystems
    initVfs();

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

    // Initialize APIC (replaces legacy PIC for interrupt handling)
    // Must be done before keyboard/scheduler to route IRQs correctly
    initApic();

    // Initialize SMP (bring up APs)
    // Must be done after APIC init
    hal.smp.init();

    // Initialize keyboard driver and register with HAL
    keyboard.init();
    hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);

    // Initialize mouse driver and register with HAL
    mouse.init();
    hal.interrupts.setMouseHandler(&mouse.handleIrq);

    hal.interrupts.setCrashHandler(handleCrash);

    // Initialize scheduler (creates idle thread, registers timer handler)
    sched.init();

    // Initialize signal handling subsystem (registers checker hook)
    signal.init();

    // Register GS data with scheduler for syscall stack switching
    sched.setGsData(&bsp_gs_data);

    // Log interrupt infrastructure status
    console.print("\n");
    console.info("Interrupt infrastructure initialized:", .{});
    console.info("  GDT loaded with TSS", .{});
    console.info("  PIC remapped to vectors 32-47", .{});
    console.info("  IDT installed with 48 handlers", .{});
    console.info("  Keyboard driver registered", .{});
    console.info("  Mouse driver registered", .{});
    console.info("  Scheduler initialized", .{});
    console.info("  PRNG seeded, stack canary randomized", .{});

    console.print("\n");
    console.info("Kernel initialization complete", .{});

    // Initialize network (PCI + E1000e + Net Stack)
    initNetwork();

    // Initialize USB (XHCI controllers)
    initUsb();

    // Initialize storage (AHCI controllers)
    initStorage();

    // Initialize Block Filesystem (SFS)
    initBlockFs();

    // Try to initialize VirtIO-GPU (paravirtualized GPU)
    initVirtioGpu();

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
            return std.mem.span(ptr);
        }
    }.call;

    // Priority 0: ASM Test (Sanity Check)
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);
        
        if (std.mem.indexOf(u8, cmdline, "test_asm") != null or std.mem.indexOf(u8, path, "test_asm") != null) {
            selected_mod = mod;
            process_name = "test_asm";
            break;
        }
    }

    // Priority 1: HTTPD
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
            
            if (std.mem.indexOf(u8, cmdline, "httpd") != null or std.mem.indexOf(u8, path, "httpd") != null) {
                selected_mod = mod;
                process_name = "httpd";
                break;
            }
        }
    }

    // Priority 2: Shell
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
            
            if (std.mem.indexOf(u8, cmdline, "shell") != null or std.mem.indexOf(u8, path, "shell") != null) {
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

    // Step 5: Allocate and map user stack with arguments
    // We use the ELF helper to set up the stack according to x86_64 ABI
    // (argc, argv, envp, auxv)
    const stack_virt_top: u64 = 0xF0000000;
    const stack_size: usize = 32 * 1024; // 32KB stack

    const argv = [_][]const u8{process_name};
    const envp = [_][]const u8{};

    // Auxiliary Vector (Required for static binaries to find PHDRs)
    const auxv = [_]elf.AuxEntry{
        .{ .id = 3, .value = load_result.phdr_addr }, // AT_PHDR
        .{ .id = 4, .value = 56 }, // AT_PHENT
        .{ .id = 5, .value = load_result.phnum }, // AT_PHNUM
        .{ .id = 6, .value = 4096 }, // AT_PAGESZ
        .{ .id = 9, .value = load_result.entry_point }, // AT_ENTRY
    };

    console.info("Creating user stack at {x} (size={d})", .{ stack_virt_top, stack_size });

    // setupStack allocates pages, maps them, and pushes args
    const initial_rsp = elf.setupStack(
        proc.cr3,
        stack_virt_top,
        stack_size,
        &argv,
        &envp,
        &auxv,
    ) catch |err| {
        console.err("Failed to setup user stack: {}", .{err});
        return;
    };

    console.info("User stack created (rsp={x})", .{initial_rsp});

    // Step 6: Create user thread with entry point from ELF header
    const user_thread = thread.createUserThread(load_result.entry_point, .{
        .name = process_name,
        .cr3 = proc.cr3,
        .user_stack_top = initial_rsp,
        .process = @ptrCast(proc),
    }) catch |err| {
        console.err("Failed to create user thread: {}", .{err});
        return;
    };

    // Set up TCB/TLS using ELF header information
    // Musl static binaries may crash if %fs:0 is not accessible or doesn't point to itself.
    const tls_base_addr: u64 = 0xB000_0000; // Preferred address for TCB
    var fs_base: u64 = 0;

    if (load_result.tls_phdr) |phdr| {
        // Use TLS segment from ELF
        if (elf.setupTls(proc.cr3, phdr, mod_data, tls_base_addr)) |tp| {
            fs_base = tp;
            console.info("Init: Initialized TLS at {x} (size={d})", .{ tp, phdr.p_memsz });
        } else |err| {
            console.warn("Init: Failed to setup TLS: {}", .{err});
        }
    } else {
        // Fallback for binaries without PT_TLS (but expecting TCB at fs:0)
        // Allocate a minimal TCB
        console.warn("Init: No PT_TLS found, creating minimal TCB", .{});
        const minimal_phdr = elf.Elf64_Phdr{
            .p_type = elf.PT_TLS,
            .p_flags = elf.PF_R | elf.PF_W,
            .p_offset = 0,
            .p_vaddr = 0,
            .p_paddr = 0,
            .p_filesz = 0,
            .p_memsz = 0,
            .p_align = 16, // Default alignment
        };
        if (elf.setupTls(proc.cr3, minimal_phdr, mod_data, tls_base_addr)) |tp| {
            fs_base = tp;
        } else |err| {
            console.warn("Init: Failed to setup minimal TCB: {}", .{err});
        }
    }

    if (fs_base != 0) {
        user_thread.fs_base = fs_base;
    }

    sched.addThread(user_thread);
    console.info("Init process started (pid={d}, tid={d})", .{ proc.pid, user_thread.tid });
}

/// Initialize InitRD filesystem from Limine modules
/// Searches for a module with "initrd" in its cmdline or path
fn initInitRD(mods: []const *limine.Module) void {
    const get_str = struct {
        fn call(ptr: [*:0]const u8) []const u8 {
            if (@intFromPtr(ptr) == 0) return "";
            return std.mem.span(ptr);
        }
    }.call;

    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);

        // Check if this module is an initrd (by cmdline or path)
        if (std.mem.indexOf(u8, cmdline, "initrd") != null or std.mem.indexOf(u8, path, "initrd") != null or
            std.mem.indexOf(u8, cmdline, ".tar") != null or std.mem.indexOf(u8, path, ".tar") != null)
        {
            // Get module data as slice
            const data = @as([*]const u8, @ptrFromInt(mod.address))[0..mod.size];

            // Initialize the global InitRD instance
            fs.initrd.InitRD.init(data);

            console.info("InitRD: Initialized from module ({d} bytes)", .{mod.size});

            // List files in initrd for debugging
            var iter = fs.initrd.InitRD.instance.listFiles();
            var file_count: usize = 0;
            while (iter.next()) |_| {
                file_count += 1;
            }
            console.info("InitRD: {d} files found", .{file_count});
            return;
        }
    }

    // No initrd found - this is not an error, just informational
    console.info("InitRD: No initrd module found (filesystem empty)", .{});
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
    
    // Now that PMM is ready, try to enable Double Buffering for graphical console
    // Attempt to create a buffered driver using the same video mode
    if (video_driver.BufferedFramebufferDriver.initWithBackBuffer(fb_driver_direct.mode)) |buffered| {
        fb_driver_buffered = buffered;
        fb_is_buffered = true;
        // Reinitialize console with buffered driver
        graph_console = video_driver.console.Console.init(fb_driver_buffered.device());
        console.info("Graphics: Double Buffering enabled", .{});
    }






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

/// Handle user process crashes (exceptions in user mode)
fn handleCrash(vector: u8, err_code: u64) noreturn {
    // Map exception vector to POSIX signal
    const signal: i32 = switch (vector) {
        0 => 8,  // #DE -> SIGFPE
        6 => 4,  // #UD -> SIGILL
        13, 14 => 11, // #GP, #PF -> SIGSEGV
        else => 11, // Default to SIGSEGV
    };

    if (config.debug_scheduler) {
        console.warn("Process crashed! Vector={d} Code={x} Signal={d}", .{ vector, err_code, signal });
    }

    // Terminate the process with signal status
    // Signal status is stored in bits 0-6 of exit_status
    process_mod.exit(signal);
}

// ============================================================================
// Network Initialization
// ============================================================================

var net_interface: net.Interface = undefined;
var pci_devices: ?*const pci.DeviceList = null;
var pci_ecam: ?pci.Ecam = null;  // Store by value, not pointer (avoid dangling reference)

fn txWrapper(data: []const u8) bool {
    if (e1000e.getDriver()) |driver| {
        return driver.transmit(data);
    }
    return false;
}

fn multicastUpdate(iface: *net.Interface) void {
    if (e1000e.getDriver()) |driver| {
        driver.applyMulticastFilter(iface);
    }
}

fn rxCallbackAdapter(data: []u8) void {
    // Wrap data in PacketBuffer and pass to network stack
    var pkt = net.PacketBuffer.init(data, data.len);
    _ = net.processFrame(&net_interface, &pkt);

    // Free the buffer allocated by the driver
    // This was allocated in drivers/net/e1000e.zig:processRxLimited via heap.allocator().alloc
    heap.allocator().free(data);
}

fn initNetwork() void {
    console.print("\n");
    console.info("Initializing network subsystem...", .{});

    // 1. Get RSDP for PCI ECAM
    if (rsdp_request.response) |resp| {
        console.info("Debug: RSDP response at 0x{x}", .{resp.address});
    }
    const rsdp_response = rsdp_request.response orelse {
        console.warn("RSDP not found (BIOS boot without ACPI?), network disabled.", .{});
        return;
    };
    const rsdp_addr = rsdp_response.address;
    console.info("Debug: Calling pci.initFromAcpi with 0x{x}", .{rsdp_addr});

    // 2. Initialize PCI
    const pci_res = pci.initFromAcpi(heap.allocator(), rsdp_addr) catch |err| {
        console.err("PCI init failed: {}", .{err});
        return;
    };

    // Save PCI state for other subsystems (USB, VirtIO)
    pci_devices = pci_res.devices;
    pci_ecam = pci_res.ecam;  // Copy by value to avoid dangling reference

    // 3. Initialize E1000e
    const nic_driver = e1000e.initFromPci(pci_res.devices, &pci_res.ecam) catch |err| {
        console.warn("E1000e init failed (no supported NIC?): {}", .{err});
        return;
    };

    // 4. Setup Interface
    const mac = nic_driver.getMacAddress();
    net_interface = net.Interface.init("eth0", mac);
    net_interface.setTransmitFn(txWrapper);
    net_interface.setMulticastUpdateFn(multicastUpdate);

    // 5. Initialize Network Stack
    net.init(&net_interface, heap.allocator(), 100);

    // Program initial multicast filter (defaults to all-multicast until IGMP joins)
    multicastUpdate(&net_interface);

    // 6. Register Callbacks
    nic_driver.setRxCallback(rxCallbackAdapter);
    sched.setTickCallback(net.transport.tcpProcessTimers);

    console.info("Network initialized (MAC={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2})", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });

    // Initialize loopback interface for local (127.x.x.x) traffic
    const lo = net.loopback.init();
    lo.up();
    console.info("Loopback interface initialized (127.0.0.1)", .{});
}

// ============================================================================
// USB Initialization
// ============================================================================

fn initUsb() void {
    console.print("\n");
    console.info("Initializing USB subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("USB: PCI not initialized, skipping USB", .{});
        return;
    };

    var ecam = pci_ecam orelse {
        console.warn("USB: PCI ECAM not available, skipping USB", .{});
        return;
    };

    usb.initFromPci(devices, &ecam);
}

// ============================================================================
// VFS Initialization
// ============================================================================

fn initVfs() void {
    console.print("\n");
    console.info("Initializing VFS...", .{});

    fs.vfs.Vfs.init();

    // Mount InitRD at /
    fs.vfs.Vfs.mount("/", fs.vfs.initrd_fs) catch |err| {
        console.err("Failed to mount InitRD at /: {}", .{err});
    };

    // Mount DevFS at /dev
    fs.vfs.Vfs.mount("/dev", devfs.dev_fs) catch |err| {
        console.err("Failed to mount DevFS at /dev: {}", .{err});
    };

    console.info("VFS initialized (mounted / and /dev)", .{});
}

// ============================================================================
// Storage Initialization (AHCI)
// ============================================================================

fn initStorage() void {
    console.print("\n");
    console.info("Initializing storage subsystem...", .{});

    const devices = pci_devices orelse {
        console.warn("Storage: PCI not initialized, skipping AHCI", .{});
        return;
    };

    const ecam = pci_ecam orelse {
        console.warn("Storage: PCI ECAM not available, skipping AHCI", .{});
        return;
    };

    // Search for AHCI controller (Class 0x01 Mass Storage, Subclass 0x06 SATA)
    var found_ahci = false;
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.class_code == 0x01 and dev.subclass == 0x06) {
            console.info("Storage: Found AHCI controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            if (ahci.initFromPci(dev, &ecam)) |controller| {
                // Report detected drives
                var port_num: u5 = 0;
                while (port_num < ahci.MAX_PORTS) : (port_num += 1) {
                    if (controller.getPort(port_num)) |port| {
                        const dev_type_str = switch (port.device_type) {
                            .ata => "ATA",
                            .atapi => "ATAPI",
                            .semb => "SEMB",
                            .port_multiplier => "Port Multiplier",
                            else => "None",
                        };
                        console.info("  Port {d}: {s} device", .{ port_num, dev_type_str });
                    }
                }
                found_ahci = true;
                break; // Only initialize first controller
            } else |err| {
                console.warn("Storage: AHCI init failed: {}", .{err});
            }
        }
    }

    if (!found_ahci) {
        console.info("Storage: No AHCI controllers found", .{});
    }
}

// ============================================================================
// Block Filesystem Initialization (SFS)
// ============================================================================

fn initBlockFs() void {
    console.print("\n");
    console.info("Initializing Block Filesystem...", .{});

    // Check if /dev/sda exists (created by initStorage via DevFS check)
    // SFS.init will attempt to open it using VFS

    const sfs_instance = fs.sfs.SFS.init("/dev/sda") catch |err| {
        console.warn("SFS: Failed to initialize on /dev/sda: {}", .{err});
        return;
    };

    // Mount at /mnt
    fs.vfs.Vfs.mount("/mnt", sfs_instance) catch |err| {
        console.err("SFS: Failed to mount at /mnt: {}", .{err});
        return;
    };

    console.info("SFS: Mounted at /mnt", .{});

    // Run simple filesystem test
    testBlockFs();
}

fn testBlockFs() void {
    console.info("SFS: Running read/write test...", .{});

    const fd_mod = @import("fd");

    // Open/Create file
    const path = "/mnt/hello.txt";
    const flags = fd_mod.O_CREAT | fd_mod.O_RDWR;

    const fd = fs.vfs.Vfs.open(path, flags) catch |err| {
        console.err("SFS Test: Failed to open {s}: {}", .{ path, err });
        return;
    };
    defer {
        if (fd.ops.close) |close_fn| _ = close_fn(fd);
        // heap.allocator().destroy(fd); // Vfs.open doesn't use heap? It does. But who owns fd?
        // sys_close destroys it. We should manually destroy if not using sys_close.
        // Actually, Vfs.open returns a pointer allocated on heap.
        // And FileDescriptor.unref calls destroy.
        // So we should simulate unref/close.
        const alloc = @import("heap").allocator();
        alloc.destroy(fd); // fd.close is not enough, need to free struct. But unref does it.
        // We haven't ref-ed it, createFd sets ref=1.
        // So calling ops.close is part of it, but we need to free the memory too.
        // Correct usage:
        // if (fd.unref()) { if (fd.ops.close) |c| _ = c(fd); alloc.destroy(fd); }
    }

    // Write data
    const message = "Hello, Block World!";
    if (fd.ops.write) |write_fn| {
        const written = write_fn(fd, message);
        console.info("SFS Test: Wrote {d} bytes", .{written});
    }

    // Seek to beginning
    if (fd.ops.seek) |seek_fn| {
        _ = seek_fn(fd, 0, 0); // SEEK_SET
    }

    // Read back
    var buf: [64]u8 = undefined;
    if (fd.ops.read) |read_fn| {
        const read = read_fn(fd, &buf);
        if (read > 0) {
            const content = buf[0..@intCast(read)];
            console.info("SFS Test: Read back: '{s}'", .{content});

            if (std.mem.eql(u8, content, message)) {
                console.info("SFS Test: PASSED", .{});
            } else {
                console.err("SFS Test: FAILED (content mismatch)", .{});
            }
        } else {
            console.err("SFS Test: FAILED (read 0 bytes)", .{});
        }
    }
}

// ============================================================================
// VirtIO-GPU Initialization
// ============================================================================

var virtio_gpu_driver: ?*video_driver.VirtioGpuDriver = null;

fn initVirtioGpu() void {
    console.print("\n");
    console.info("Checking for VirtIO-GPU...", .{});

    const devices = pci_devices orelse {
        console.info("VirtIO-GPU: PCI not initialized, skipping", .{});
        return;
    };

    var ecam = pci_ecam orelse {
        console.info("VirtIO-GPU: PCI ECAM not available, skipping", .{});
        return;
    };

    // Scan for VirtIO-GPU device
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.isVirtioGpu()) {
            console.info("VirtIO-GPU: Found device at {d}:{d}.{d}", .{ dev.bus, dev.device, dev.func });

            // Try to initialize the driver
            if (video_driver.VirtioGpuDriver.init(dev, &ecam)) |driver| {
                virtio_gpu_driver = driver;

                // Switch console to use VirtIO-GPU
                graph_console = video_driver.console.Console.init(driver.device());
                console.info("VirtIO-GPU: Console switched to paravirtualized GPU", .{});
                return;
            } else {
                console.warn("VirtIO-GPU: Driver initialization failed", .{});
            }
        }
    }

    console.info("VirtIO-GPU: No device found, using framebuffer", .{});
}

/// Initialize APIC subsystem (replaces legacy PIC)
fn initApic() void {
    console.print("\n");
    console.info("Initializing APIC subsystem...", .{});

    // Get RSDP from Limine
    const rsdp_response = rsdp_request.response orelse {
        console.warn("RSDP not found, using legacy PIC mode", .{});
        hal.apic.setLegacyPicMode(); // Explicitly set interrupt mode for proper EOI handling
        return;
    };
    const rsdp_ptr: *align(1) const acpi.Rsdp = @ptrFromInt(rsdp_response.address);

    // Parse MADT to get APIC topology
    const madt_info = acpi.parseMadt(rsdp_ptr) orelse {
        console.warn("MADT not found, using legacy PIC mode", .{});
        hal.apic.setLegacyPicMode(); // Explicitly set interrupt mode for proper EOI handling
        return;
    };

    acpi.logMadtInfo(&madt_info);

    // Convert MADT info to APIC init info
    // We need to convert the ioapic array to the local IoApicInfo type
    var io_apics: [hal.apic.ioapic.MAX_IOAPICS]hal.apic.IoApicInfo = undefined;
    for (madt_info.io_apics[0..madt_info.io_apic_count], 0..) |ioapic, i| {
        io_apics[i] = .{
            .id = ioapic.id,
            .addr = ioapic.addr,
            .gsi_base = ioapic.gsi_base,
        };
    }

    // Convert overrides
    var overrides: [16]?hal.apic.InterruptOverride = [_]?hal.apic.InterruptOverride{null} ** 16;
    for (madt_info.overrides, 0..) |maybe_ovr, i| {
        if (maybe_ovr) |ovr| {
            overrides[i] = .{
                .source_irq = ovr.source_irq,
                .gsi = ovr.gsi,
                .polarity = @enumFromInt(@intFromEnum(ovr.polarity)),
                .trigger_mode = @enumFromInt(@intFromEnum(ovr.trigger_mode)),
            };
        }
    }

    const apic_init_info = hal.apic.ApicInitInfo{
        .local_apic_addr = madt_info.local_apic_addr,
        .io_apics = io_apics[0..madt_info.io_apic_count],
        .overrides = &overrides,
        .pcat_compat = madt_info.pcat_compat,
        .lapic_ids = madt_info.lapic_ids[0..madt_info.lapic_count],
    };

    // Initialize APIC
    hal.apic.init(&apic_init_info);

    console.info("APIC subsystem initialized", .{});
}
