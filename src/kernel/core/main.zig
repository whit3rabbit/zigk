// Zscapek Kernel Entry Point
//
// This is the main entry point for the Zscapek microkernel.
// It is called by the UEFI bootloader in 64-bit long mode with paging enabled.
//
// Entry Conditions:
//   - 64-bit long mode
//   - Paging enabled with identity + HHDM + higher-half mapping
//   - GDT with flat code/data segments
//   - Stack already set up
//   - Interrupts disabled (we set up our own IDT)

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
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

// Global boot info pointer (set during kernel entry)
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

// SECURITY: Maximum memory map entries (must match bootloader)
const MAX_MEMMAP_ENTRIES: usize = 256;
// Kernel space starts at 0xFFFF800000000000 (canonical higher half)
const KERNEL_SPACE_START: u64 = 0xFFFF800000000000;

/// Validate BootInfo fields before use (defense-in-depth)
/// This runs before serial is available, so we halt on failure
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

/// Kernel entry point - called by UEFI bootloader with BootInfo
export fn _start(boot_info: *BootInfo.BootInfo) callconv(.c) noreturn {
    // SECURITY: Validate boot info before using any fields
    // This must be first - a malicious bootloader could provide invalid data
    validateBootInfo(boot_info);

    // Store the boot info globally
    boot_info_ptr = boot_info;

    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    // This must be first - serial is needed for any debug output
    hal.init(boot_info.hhdm_offset);

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
        graph_console = video_driver.console.Console.init(fb_driver_direct.device());

        console.addBackend(.{
            .context = @ptrCast(&graph_console),
            .writeFn = videoWriteWrapper,
            .scrollFn = videoScrollWrapper,
        });

        console.info("Graphics: Initialized {d}x{d}x{d} framebuffer", .{
            fb_state.width, fb_state.height, fb_state.bpp
        });
    }

    // Try double buffering
    if (video_driver.BufferedFramebufferDriver.initWithBackBuffer(fb_driver_direct.mode)) |buffered| {
        fb_driver_buffered = buffered;
        fb_is_buffered = true;
        graph_console = video_driver.console.Console.init(fb_driver_buffered.device());
        console.info("Graphics: Double Buffering enabled", .{});
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

    console.info("Keyboard IRQ1 explicitly enabled", .{});
    input.init();
    console.info("Input subsystem initialized", .{});

    hal.interrupts.setSerialHandler(&serial_driver.Serial.handleIrq);
    hal.apic.enableIrq(4);
    console.info("Serial IRQ4 enabled", .{});

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

    // Initialize Hardware
    init_hw.initNetwork();
    init_hw.initUsb();
    init_hw.initAudio();
    init_hw.initStorage();

    init_fs.initBlockFs();

    if (init_hw.initVirtioGpu()) |driver| {
        graph_console = video_driver.console.Console.init(driver.device());
        console.info("VirtIO-GPU: Console switched to paravirtualized GPU", .{});
    }

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

// Initialize APIC subsystem (replaces legacy PIC)
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

/// Page fault handler for demand paging
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

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) [*]u8 {
    return hal.paging.physToVirt(phys);
}

// Forward panic and handleCrash
pub const panic = panic_lib.panic;
