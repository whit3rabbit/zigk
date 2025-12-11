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
const net = @import("net");
const pci = @import("pci");
const e1000e = @import("e1000e");

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
pub export var rsdp_request linksection(".limine_requests") = limine.RsdpRequest{};

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

    // Check for loaded modules (shell, initrd, etc.)
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

        // Initialize InitRD if present
        initInitRD(mods);
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
    hal.interrupts.setCrashHandler(handleCrash);

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

    // Initialize network (PCI + E1000e + Net Stack)
    initNetwork();

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

    // Priority 0: ASM Test (Sanity Check)
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);
        
        if (containsStr(cmdline, "test_asm") or containsStr(path, "test_asm")) {
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
            
            if (containsStr(cmdline, "httpd") or containsStr(path, "httpd")) {
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

    // Hack: Manually set up TCB/TLS for Musl
    // Musl static binaries may crash if %fs:0 is not accessible or doesn't point to itself
    // We allocate a page, map it, write self-pointer, and set fs_base.
    if (pmm.allocZeroedPage()) |tcb_page| {
        const tcb_virt: u64 = 0xB000_0000; // Arbitrary user address
        if (vmm.mapPage(proc.cr3, tcb_virt, tcb_page, .{ .writable = true, .user = true })) |_| {
            // Write self-pointer to TCB (first 8 bytes)
            const tcb_ptr: [*]u64 = @ptrCast(@alignCast(hal.paging.physToVirt(tcb_page)));
            tcb_ptr[0] = tcb_virt;
            user_thread.fs_base = tcb_virt;
            console.debug("Init: Manually initialized TLS/TCB at {x}", .{tcb_virt});
        } else |_| {
             pmm.freePage(tcb_page);
        }
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
            return ptr[0..strlen(ptr)];
        }
    }.call;

    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);

        // Check if this module is an initrd (by cmdline or path)
        if (containsStr(cmdline, "initrd") or containsStr(path, "initrd") or
            containsStr(cmdline, ".tar") or containsStr(path, ".tar"))
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

fn txWrapper(data: []const u8) bool {
    if (e1000e.getDriver()) |driver| {
        return driver.transmit(data);
    }
    return false;
}

fn rxCallbackAdapter(data: []u8) void {
    // Wrap data in PacketBuffer and pass to network stack
    var pkt = net.PacketBuffer.init(data, data.len);
    _ = net.processFrame(&net_interface, &pkt);
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
    
    // 3. Initialize E1000e
    const nic_driver = e1000e.initFromPci(pci_res.devices, &pci_res.ecam) catch |err| {
        console.warn("E1000e init failed (no supported NIC?): {}", .{err});
        return;
    };

    // 4. Setup Interface
    const mac = nic_driver.getMacAddress();
    net_interface = net.Interface.init("eth0", mac);
    net_interface.setTransmitFn(txWrapper);

    // 5. Initialize Network Stack
    net.init(&net_interface, heap.allocator());

    // 6. Register Callbacks
    nic_driver.setRxCallback(rxCallbackAdapter);
    sched.setTickCallback(net.transport.tcpProcessTimers);

    console.info("Network initialized (MAC={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2})", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]
    });
}
