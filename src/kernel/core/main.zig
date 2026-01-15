//! Kernel Entry Point
//!
//! This module contains the main entry point (`_start`) for the Zscapek microkernel.
//! It is responsible for initializing the hardware, memory management, scheduler,
//! and other core subsystems before launching the initial process.
//!
//! # Entry Conditions
//! The kernel expects to be booted by a UEFI bootloader (e.g., Limine) in 64-bit long mode
//! with the following state:
//! - Paging enabled with identity + HHDM + higher-half mapping.
//! - GDT with flat code/data segments.
//! - Stack already set up.
//! - Interrupts disabled.

const std = @import("std");
const builtin = @import("builtin");
pub const hal = @import("hal");
const syscall_arch = hal.syscall;
const console = @import("console");
const config = @import("config");
const keyboard = @import("keyboard");
const mouse = @import("mouse");
const input = @import("input");
const sched = @import("sched");
const tlb = @import("tlb");
const stack_guard = @import("stack_guard");
const prng = @import("prng");
const framebuffer = @import("framebuffer");
const acpi = @import("acpi");
const serial_driver = @import("serial_driver");
const video_driver = @import("video_driver");
const io = @import("io");
const syscall_base = @import("syscall_base");

// New modules
const panic_lib = @import("panic.zig");
const init_mem = @import("init_mem.zig");
const init_proc = @import("init_proc.zig");
const init_hw = @import("init_hw.zig");
const init_fs = @import("init_fs.zig");
const syscall_ipc = @import("syscall_ipc");
const layout = @import("layout");

// Boot Interface
const BootInfo = @import("boot_info");

/// Global boot info pointer (set during kernel entry)
var boot_info_ptr: ?*BootInfo.BootInfo = null;

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

// Disable error return traces globally to save memory/stack space
pub const os_has_error_return_trace = false;

// =============================================================================
// std.log Integration
// =============================================================================
// Redirect std.log.* calls to kernel console.

pub const std_options: std.Options = .{
    .logFn = kernelLogFn,
    .log_level = .debug,
};

/// Custom log function for `std.log` integration.
/// Redirects log messages to the kernel console with appropriate prefixes.
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
// SECURITY NOTE: These are intentionally `undefined` until properly initialized.
// Framebuffer drivers contain non-nullable pointers that cannot be zero-initialized.
// The init paths (Serial.init(), DirectFramebufferDriver.initDirect(), etc.) fully
// initialize these before any use. If init fails, the kernel panics - partial init
// with leaked data is not possible in practice.
var uart: serial_driver.Serial = undefined;
var fb_driver_direct: video_driver.DirectFramebufferDriver = undefined;
var fb_driver_buffered: video_driver.BufferedFramebufferDriver = undefined;
var fb_is_buffered: bool = false;
var graph_console: video_driver.console.Console = undefined;
var boot_logo_instance: video_driver.boot_logo.BootLogo = undefined;
var boot_logo_active: bool = false;

/// Wrapper for writing to the UART backend.
fn uartWriteWrapper(ctx: ?*anyopaque, str: []const u8) void {
    const s: *serial_driver.Serial = @ptrCast(@alignCast(ctx));
    s.write(str);
}

/// Wrapper for writing to the Video Console backend.
fn videoWriteWrapper(ctx: ?*anyopaque, str: []const u8) void {
    const c: *video_driver.console.Console = @ptrCast(@alignCast(ctx));
    c.write(str);
}

/// Wrapper for scrolling the Video Console backend.
fn videoScrollWrapper(ctx: ?*anyopaque, lines: usize, up: bool) void {
    const c: *video_driver.console.Console = @ptrCast(@alignCast(ctx));
    if (up) {
        c.scrollUp(lines);
    } else {
        c.scrollDown(lines);
    }
}

// SECURITY: Maximum memory map entries (must match bootloader)
const MAX_MEMMAP_ENTRIES: usize = 256;
// Kernel space starts at 0xFFFF800000000000 (canonical higher half)
const KERNEL_SPACE_START: u64 = 0xFFFF800000000000;

/// Validate BootInfo fields before use (defense-in-depth)
/// This runs before serial is available, so we halt on failure.
///
/// Checks:
/// - HHDM offset is in kernel space.
/// - Memory map count is within bounds.
/// - Memory map pointer is valid.
/// - Kernel virtual base is in higher half.
fn validateBootInfo(boot_info: *const BootInfo.BootInfo) void {
    // SECURITY: HHDM offset must be in kernel space
    // A malicious/buggy bootloader could set this to userspace, allowing
    // physToVirt() to return user-controllable addresses
    if (boot_info.hhdm_offset < KERNEL_SPACE_START) {
        // Cannot use console here - halt forever
        hal.cpu.halt();
    }

    // SECURITY: Memory map count must be within bounds
    // Out-of-bounds access could read arbitrary memory
    if (boot_info.memory_map_count > MAX_MEMMAP_ENTRIES) {
        hal.cpu.halt();
    }

    // SECURITY: Memory map pointer must be valid (not null)
    if (@intFromPtr(boot_info.memory_map) == 0) {
        hal.cpu.halt();
    }

    // SECURITY: Kernel addresses should be in higher half if set
    if (boot_info.kernel_virt_base != 0 and boot_info.kernel_virt_base < KERNEL_SPACE_START) {
        hal.cpu.halt();
    }
}

/// Early serial write byte - before HAL init.
fn earlySerialWrite(c: u8) void {
    hal.earlyWrite(c);
}

/// Early serial print string - before HAL init.
fn earlySerialPrint(msg: []const u8) void {
    hal.earlyPrint(msg);
}

/// Kernel entry point - called by UEFI bootloader with BootInfo.
/// This is the C-calling-convention entry point that receives control
/// from the bootloader stub.
export fn _start(boot_info: *BootInfo.BootInfo) callconv(.c) noreturn {
    // CRITICAL: First thing - prove we got here
    earlySerialPrint("KERNEL: Entry point reached!\r\n");

    // SECURITY: Validate boot info before using any fields
    // This must be first - a malicious bootloader could provide invalid data
    earlySerialPrint("KERNEL: Validating BootInfo...\r\n");
    validateBootInfo(boot_info);
    earlySerialPrint("KERNEL: BootInfo valid\r\n");

    // Store the boot info globally
    boot_info_ptr = boot_info;

    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    // This must be first - serial is needed for any debug output
    earlySerialPrint("KERNEL: Calling hal.init()...\r\n");
    hal.init(boot_info.hhdm_offset);
    earlySerialPrint("KERNEL: HAL initialized\r\n");

    // Initialize Serial Driver (UART)
    uart = serial_driver.Serial.init(serial_driver.COM1);

    // Register UART as console backend
    console.addBackend(.{
        .context = @ptrCast(&uart),
        .writeFn = uartWriteWrapper,
    });

    // DISABLE Kernel Serial IRQ Handler to allow userspace driver to take it
    hal.interrupts.setSerialHandler(null);

    // Initialize GS base for syscalls
    hal.cpu.writeMsr(hal.cpu.IA32_GS_BASE, @intFromPtr(&bsp_gs_data));

    // Connect console to interrupt handlers
    hal.interrupts.setConsoleWriter(&console.print);

    // Print boot banner
    console.print("\n");
    console.print("========================================\n");
    console.printf("{s} Microkernel v{s}\n", .{ config.name, config.version });
    console.print("========================================\n");
    console.print("\n");

    // Initialize paging with HHDM offset from BootInfo
    hal.paging.init(boot_info.hhdm_offset);

    // Initialize memory layout with KASLR offsets from BootInfo
    // Must be called after paging.init() but before VMM/stack/heap init
    layout.init(boot_info);

    // SECURITY: Only log kernel addresses in debug mode to prevent KASLR bypass
    if (builtin.mode == .Debug) {
        console.info("HHDM offset: {x}", .{boot_info.hhdm_offset});
        if (boot_info.kernel_phys_base != 0) {
            console.info("Kernel physical base: {x}", .{boot_info.kernel_phys_base});
            console.info("Kernel virtual base: {x}", .{boot_info.kernel_virt_base});
        }
    }

    console.info("Kernel Exception Handling initialized", .{});

    // Initialize Memory Management (PMM, VMM, Heap)
    init_mem.initMemoryManagement(boot_info);

    // Initialize Framebuffer
    if (boot_info.framebuffer) |fb| {
        framebuffer.initFromInfo(fb, boot_info.hhdm_offset);
    } else {
        console.warn("No framebuffer (BootInfo), serial only", .{});
    }

    // Initialize InitRD from BootInfo
    init_proc.initInitRDFromBootInfo(boot_info);

    // Initialize video console if framebuffer available
    if (framebuffer.getState()) |fb_state| {
        const virt_addr = @intFromPtr(hal.paging.physToVirt(fb_state.phys_addr));

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

        console.info("Graphics: Initialized {d}x{d}x{d} framebuffer", .{
            fb_state.width, fb_state.height, fb_state.bpp
        });
    }

    // Try double buffering
    if (video_driver.BufferedFramebufferDriver.initWithBackBuffer(fb_driver_direct.mode)) |buffered| {
        fb_driver_buffered = buffered;
        fb_is_buffered = true;
        console.info("Graphics: Double Buffering enabled", .{});
    }

    // Show boot logo or enable console immediately based on config
    if (config.boot_logo_enabled) {
        const device = if (fb_is_buffered) fb_driver_buffered.device() else fb_driver_direct.device();
        boot_logo_instance = video_driver.boot_logo.BootLogo.init(device);
        video_driver.boot_logo.g_boot_logo = &boot_logo_instance;
        boot_logo_instance.show();
        boot_logo_active = true;
        console.info("Boot logo displayed", .{});
    } else {
        // No boot logo - enable graphics console immediately for debugging
        const device = if (fb_is_buffered) fb_driver_buffered.device() else fb_driver_direct.device();
        graph_console = video_driver.console.Console.init(device);
        console.addBackend(.{
            .context = @ptrCast(&graph_console),
            .writeFn = videoWriteWrapper,
            .scrollFn = videoScrollWrapper,
        });
        console.info("Graphics console enabled (boot logo disabled)", .{});
    }

    // Initialize VFS
    init_fs.initVfs();

    // Initialize entropy subsystem
    hal.entropy.init();
    prng.init();
    stack_guard.init();

    // Initialize APIC
    initApic(boot_info);
    stack_guard.reseed();

    // Initialize TLB Shootdown
    tlb.init();

    // Initialize SMP
    console.info("About to call hal.smp.init()", .{});
    hal.smp.init();
    console.info("Returned from hal.smp.init()", .{});

    input.init();
    console.info("Input subsystem initialized", .{});

    // Initialize PS/2 keyboard and mouse (x86_64 only - uses APIC and PS/2 controller)
    if (builtin.cpu.arch == .x86_64) {
        keyboard.init();
        hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);
        // Route IRQ1 to vector 33 (KEYBOARD) before enabling
        hal.apic.routeIrq(1, hal.apic.Vectors.KEYBOARD, 0);
        hal.apic.enableIrq(1);
        console.info("PS/2 keyboard initialized, IRQ1 routed to vector {d}", .{hal.apic.Vectors.KEYBOARD});

        mouse.init();
        hal.interrupts.setMouseHandler(&mouse.handleIrq);
        // Route IRQ12 to vector 44 (MOUSE) before enabling
        hal.apic.routeIrq(12, hal.apic.Vectors.MOUSE, 0);
        hal.apic.enableIrq(12);
        console.info("PS/2 mouse initialized, IRQ12 routed to vector {d}", .{hal.apic.Vectors.MOUSE});

        hal.interrupts.setSerialHandler(&serial_driver.Serial.handleIrq);
        // Route IRQ4 to vector 36 (COM1) before enabling
        hal.apic.routeIrq(4, hal.apic.Vectors.COM1, 0);
        hal.apic.enableIrq(4);
        console.info("Serial IRQ4 routed to vector {d}", .{hal.apic.Vectors.COM1});
    }

    hal.interrupts.setCrashHandler(panic_lib.handleCrash);

    // Initialize scheduler
    sched.init();
    hal.interrupts.setPageFaultHandler(pageFaultHandler);
    console.info("Demand paging enabled", .{});

    io.initGlobal();
    console.info("Async I/O reactor initialized", .{});

    console.sendKernelMessageFn = syscall_ipc.sendKernelMessage;

    const signal = @import("signal");
    signal.init();

    sched.setGsData(&bsp_gs_data);

    console.print("\n");
    console.info("Interrupt infrastructure initialized:", .{});
    console.info("  GDT loaded with TSS", .{});
    console.info("  PIC remapped to vectors 32-47", .{});
    console.info("  IDT installed with 48 handlers", .{});
    console.info("  Scheduler initialized", .{});
    console.info("  PRNG seeded, stack canary randomized", .{});
    console.info("\n", .{});
    console.info("Kernel initialization complete", .{});

    // Set RSDP address for hardware subsystems
    init_hw.setRsdpAddress(boot_info.rsdp);

    // Detect hypervisor early to enable platform-specific optimizations
    init_hw.initHypervisor();

    // Initialize IOMMU before device drivers for DMA isolation
    init_hw.initIommu();

    // Initialize Hardware (with boot logo animation ticks)
    init_hw.initNetwork();
    if (boot_logo_active) boot_logo_instance.tick();

    // Initialize VirtIO-RNG for hardware entropy (after PCI is available)
    init_hw.initVirtioRng();
    if (boot_logo_active) boot_logo_instance.tick();

    init_hw.initUsb();
    if (boot_logo_active) boot_logo_instance.tick();

    init_hw.initAudio();
    if (boot_logo_active) boot_logo_instance.tick();

    init_hw.initStorage();
    if (boot_logo_active) boot_logo_instance.tick();

    init_fs.initBlockFs();
    if (boot_logo_active) boot_logo_instance.tick();

    // Fade out boot logo and enable graphics console
    if (boot_logo_active) {
        boot_logo_instance.fadeOut();
        video_driver.boot_logo.g_boot_logo = null;
        boot_logo_active = false;

        // Now set up the graphics console
        const device = if (fb_is_buffered) fb_driver_buffered.device() else fb_driver_direct.device();
        graph_console = video_driver.console.Console.init(device);
        console.addBackend(.{
            .context = @ptrCast(&graph_console),
            .writeFn = videoWriteWrapper,
            .scrollFn = videoScrollWrapper,
        });
        console.info("Graphics console enabled", .{});
    }

    // Initialize Video subsystem (VirtIO-GPU, SVGA, or fallback to boot framebuffer)
    init_hw.initVideo();
    if (init_hw.virtio_gpu_driver) |driver| {
        graph_console = video_driver.console.Console.init(driver.device());
        console.info("VirtIO-GPU: Console switched to paravirtualized GPU", .{});
    } else if (builtin.cpu.arch == .x86_64) {
        // SVGA is x86_64 only (VMware-specific, uses port I/O)
        if (init_hw.svga_driver) |driver| {
            driver.setMode(1024, 768, 32);
            graph_console = video_driver.console.Console.init(driver.device());
            console.info("SVGA: Console switched to VMware graphics", .{});
        }
    }

    // Initialize Input subsystem (VMMouse probe, etc.)
    init_hw.initInput();

    // Load Init Process from InitRD
    console.info("Main: Calling loadInitProcess()...", .{});
    init_proc.loadInitProcess();

    // Initialize Futex subsystem
    {
        const futex = @import("futex");
        futex.init();
    }

    console.info("Starting scheduler...", .{});
    sched.start();
}

/// Initialize APIC subsystem (replaces legacy PIC).
/// Parses MADT ACPI table to configure Local APIC and I/O APICs.
fn initApic(boot_info: *const BootInfo.BootInfo) void {
    console.print("\n");
    console.info("Initializing APIC subsystem...", .{});

    // Get RSDP address from BootInfo
    const rsdp_addr = boot_info.rsdp;

    if (rsdp_addr == 0) {
        console.warn("RSDP not found, using legacy PIC mode", .{});
        hal.apic.setLegacyPicMode();
        return;
    }
    const rsdp_ptr: *align(1) const acpi.Rsdp = @ptrFromInt(rsdp_addr);

    // Parse MADT to get APIC topology
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
    // IMPORTANT: These must be static to outlive initApic() since hal.apic caches the pointers.
    // Otherwise we get use-after-free when routeIrq() is called later.
    const io_apics_static = struct {
        var data: [hal.apic.ioapic.MAX_IOAPICS]hal.apic.IoApicInfo = undefined;
    };
    for (madt_info.io_apics[0..madt_info.io_apic_count], 0..) |ioapic, i| {
        io_apics_static.data[i] = .{
            .id = ioapic.id,
            .addr = ioapic.addr,
            .gsi_base = ioapic.gsi_base,
        };
    }

    // Convert overrides - also must be static for same reason
    const overrides_static = struct {
        var data: [16]?hal.apic.InterruptOverride = [_]?hal.apic.InterruptOverride{null} ** 16;
    };
    for (madt_info.overrides, 0..) |maybe_ovr, i| {
        if (maybe_ovr) |ovr| {
            overrides_static.data[i] = .{
                .source_irq = ovr.source_irq,
                .gsi = ovr.gsi,
                .polarity = if (builtin.cpu.arch == .x86_64)
                    @enumFromInt(@intFromEnum(ovr.polarity))
                else
                    @intFromEnum(ovr.polarity),
                .trigger_mode = if (builtin.cpu.arch == .x86_64)
                    @enumFromInt(@intFromEnum(ovr.trigger_mode))
                else
                    @intFromEnum(ovr.trigger_mode),
            };
        }
    }

    const apic_init_info = hal.apic.ApicInitInfo{
        .local_apic_addr = madt_info.local_apic_addr,
        .io_apics = io_apics_static.data[0..madt_info.io_apic_count],
        .overrides = &overrides_static.data,
        .pcat_compat = madt_info.pcat_compat,
        .lapic_ids = madt_info.lapic_ids[0..madt_info.lapic_count],
    };

    // Initialize APIC
    hal.apic.init(&apic_init_info);

    console.info("APIC subsystem initialized", .{});
}

/// Page fault handler for demand paging.
/// Returns true if the fault was handled (e.g., loaded a page), false otherwise.
/// Updates process RSS statistics on success.
fn pageFaultHandler(addr: u64, err_code: u64) bool {
    const proc = syscall_base.getCurrentProcessOrNull() orelse {
        console.warn("PageFault: No current process for addr {x}", .{addr});
        return false;
    };

    const handled = proc.user_vmm.handlePageFault(addr, err_code);

    if (handled) {
        proc.rss_current +|= 4096;
    }

    return handled;
}

/// Convert physical address to virtual using HHDM.
/// This is a convenience wrapper around `hal.paging.physToVirt`.
pub fn physToVirt(phys: u64) [*]u8 {
    return hal.paging.physToVirt(phys);
}

// Forward panic and handleCrash
pub const panic = panic_lib.panic;
