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
const keyboard = @import("keyboard");
const mouse = @import("mouse");
const input = @import("input");
const sched = @import("sched");
const stack_guard = @import("stack_guard");
const prng = @import("prng");
const framebuffer = @import("framebuffer");
const acpi = @import("acpi");
const serial_driver = @import("serial_driver");
const video_driver = @import("video_driver");
const io = @import("io");

// New modules
const boot = @import("boot.zig");
const panic_lib = @import("panic.zig");
const init_mem = @import("init_mem.zig");
const init_proc = @import("init_proc.zig");
const init_hw = @import("init_hw.zig");
const init_fs = @import("init_fs.zig");
const syscall_ipc = @import("syscall_ipc"); // For console IPC wiring

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

/// Per-CPU kernel data for syscall entry (GS segment)
/// For SMP, this would be an array indexed by CPU ID
var bsp_gs_data: syscall_arch.KernelGsData = .{
    .kernel_stack = 0,
    .user_stack = 0,
    .current_thread = 0,
    .scratch = 0,
    .apic_id = 0, // BSP is APIC ID 0
    .idle_thread = 0,
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
    
    // DISABLE Kernel Serial IRQ Handler to allow userspace driver to take it
    // Phase 3: Transition to userspace capabilities
    hal.interrupts.setSerialHandler(null);

    // Initialize GS base for syscalls - points to per-CPU data
    // kernel_stack will be updated by scheduler on context switch
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
    if (!boot.base_revision.is_supported()) {
        console.err("Limine protocol not supported! Check base revision.", .{});
        panic_lib.halt();
    }
    console.info("Limine protocol verified (revision 3)", .{});

    // Get HHDM offset from Limine response
    if (boot.hhdm_request.response) |hhdm| {
        console.info("HHDM offset: {x}", .{hhdm.offset});
        hal.paging.init(hhdm.offset);
    } else {
        console.warn("HHDM response not available, using default offset", .{});
        hal.paging.init(hal.paging.HHDM_OFFSET);
    }

    // Log kernel address info if available
    if (boot.kernel_address_request.response) |ka| {
        console.info("Kernel physical base: {x}", .{ka.physical_base});
        console.info("Kernel virtual base: {x}", .{ka.virtual_base});
    }

    // Parse and log memory map
    if (boot.memmap_request.response) |memmap| {
        init_mem.logMemoryMap(memmap);
    } else {
        console.err("Memory map not available!", .{});
        panic_lib.halt();
    }

    // Initialize framebuffer from Limine response
    framebuffer.initFromLimine(&boot.framebuffer_request);
    
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
    if (boot.module_request.response) |mod_response| {
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
        init_proc.initInitRD(mods);
    }

    // Initialize memory management subsystems
    init_mem.initMemoryManagement();

    // Now that PMM is ready, try to enable Double Buffering for graphical console
    // Attempt to create a buffered driver using the same video mode
    if (video_driver.BufferedFramebufferDriver.initWithBackBuffer(fb_driver_direct.mode)) |buffered| {
        fb_driver_buffered = buffered;
        fb_is_buffered = true;
        // Reinitialize console with buffered driver
        graph_console = video_driver.console.Console.init(fb_driver_buffered.device());
        console.info("Graphics: Double Buffering enabled", .{});
    }

    // Initialize VFS and mount filesystems
    init_fs.initVfs();

    // Initialize entropy subsystem (RDRAND/RDTSC detection)
    hal.entropy.init();
    console.info("Entropy source: {s}", .{if (hal.entropy.hasRdrand()) "RDRAND" else "RDTSC (fallback)"});

    // Initialize kernel PRNG
    prng.init();

    // Initialize stack guard
    stack_guard.init();

    // Initialize APIC
    initApic();

    // Initialize SMP (bring up APs)
    console.info("About to call hal.smp.init()", .{});
    hal.smp.init();
    console.info("Returned from hal.smp.init()", .{});

    // Initialize keyboard driver and register with HAL
    // Initialize keyboard driver and register with HAL
    // keyboard.init(); // MOVED TO USERSPACE (Phase 5)
    // hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);
    // Explicitly enable keyboard IRQ1 in IOAPIC (ensure unmasked)
    // hal.apic.enableIrq(1); // Userspace driver will enable this via sys_wait_interrupt
    console.info("Keyboard IRQ1 explicitly enabled", .{});

    // Initialize input subsystem
    // mouse.init();    // MOVED TO USERSPACE (Phase 5)
    input.init();
    console.info("Input subsystem initialized", .{});


    // Initialize mouse driver and register with HAL
    // Initialize mouse driver and register with HAL
    // mouse.init(); // MOVED TO USERSPACE (Phase 5)
    // hal.interrupts.setMouseHandler(&mouse.handleIrq);

    // Register Serial (UART) handler
    hal.interrupts.setSerialHandler(&serial_driver.Serial.handleIrq);
    // Register UART input callback
    // serial_driver.Serial.onByteReceived = &uartInputCallback;
    
    // Enable Serial IRQ 4 (legacy COM1)
    hal.apic.enableIrq(4);
    console.info("Serial IRQ4 enabled", .{});

    hal.interrupts.setCrashHandler(panic_lib.handleCrash);

    // Initialize scheduler
    sched.init();

    // Initialize async I/O reactor (Phase 2)
    io.initGlobal();
    console.info("Async I/O reactor initialized", .{});

    // Wire up console IPC backend function pointer
    console.sendKernelMessageFn = syscall_ipc.sendKernelMessage;
    
    // Initialize signal handling subsystem
    const signal = @import("signal");
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
    console.info("\n", .{});
    console.info("Kernel initialization complete", .{});



    // Initialize Hardware Subsystems
    init_hw.initNetwork();
    init_hw.initUsb();
    init_hw.initAudio();
    init_hw.initStorage();

    // Initialize Block Filesystem (SFS)
    init_fs.initBlockFs();

    // Try to initialize VirtIO-GPU
    if (init_hw.initVirtioGpu()) |driver| {
        // Switch console to use VirtIO-GPU
         graph_console = video_driver.console.Console.init(driver.device());
         console.info("VirtIO-GPU: Console switched to paravirtualized GPU", .{});
    }

    // Load Init Process
    console.info("Main: Calling loadInitProcess()...", .{});
    init_proc.loadInitProcess();
    console.info("Main: loadInitProcess() returned.", .{});

    // Start the scheduler
    console.info("Starting scheduler...", .{});
    sched.start();
}

/// Initialize APIC subsystem (replaces legacy PIC)
fn initApic() void {
    console.print("\n");
    console.info("Initializing APIC subsystem...", .{});

    // Get RSDP from Limine via boot module
    const rsdp_response = boot.rsdp_request.response orelse {
        console.warn("RSDP not found, using legacy PIC mode", .{});
        hal.apic.setLegacyPicMode(); // Explicitly set interrupt mode for proper EOI handling
        return;
    };
    const rsdp_ptr: *align(1) const acpi.Rsdp = @ptrFromInt(rsdp_response.address);

    // Parse MADT to get APIC topology
    // MUST be static - ApicInitInfo stores slices that reference this data
    const madt_info = blk: {
        const static = struct {
            var info: acpi.MadtInfo = undefined;
        };
        static.info = acpi.parseMadt(rsdp_ptr) orelse {
            console.warn("MADT not found, using legacy PIC mode", .{});
            hal.apic.setLegacyPicMode();
            return;
        };
        break :blk &static.info;
    };

    acpi.logMadtInfo(madt_info);

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

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) [*]u8 {
    return hal.paging.physToVirt(phys);
}

// Forward panic and handleCrash
pub const panic = panic_lib.panic;
