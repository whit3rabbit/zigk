const std = @import("std");

const OvmfPaths = struct {
    code: ?[]const u8,
    vars: ?[]const u8,
};

fn fileExists(path: [:0]const u8) bool {
    // Use std.c.access for Zig 0.16.x compatibility (std.fs.cwd() was deprecated)
    return std.c.access(path.ptr, std.c.F_OK) == 0;
}

fn detectHostOvmf(host_os: std.Target.Os.Tag, target_arch: std.Target.Cpu.Arch) OvmfPaths {
    var code: ?[]const u8 = null;
    var vars: ?[]const u8 = null;

    if (host_os == .macos) {
        if (target_arch == .aarch64) {
            // AArch64 UEFI firmware paths on macOS
            if (fileExists("/opt/homebrew/share/qemu/edk2-aarch64-code.fd")) {
                code = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd";
            }
            if (fileExists("/opt/homebrew/share/qemu/edk2-arm-vars.fd")) {
                vars = "/opt/homebrew/share/qemu/edk2-arm-vars.fd";
            }
            if (code == null and fileExists("/usr/local/share/qemu/edk2-aarch64-code.fd")) {
                code = "/usr/local/share/qemu/edk2-aarch64-code.fd";
            }
        } else {
            // x86_64 UEFI firmware paths on macOS
            if (fileExists("/opt/homebrew/share/qemu/edk2-x86_64-code.fd")) {
                code = "/opt/homebrew/share/qemu/edk2-x86_64-code.fd";
            }
            if (fileExists("/opt/homebrew/share/qemu/edk2-x86_64-vars.fd")) {
                vars = "/opt/homebrew/share/qemu/edk2-x86_64-vars.fd";
            }
            if (code == null and fileExists("/usr/local/share/qemu/edk2-x86_64-code.fd")) {
                code = "/usr/local/share/qemu/edk2-x86_64-code.fd";
            }
            if (vars == null and fileExists("/usr/local/share/qemu/edk2-x86_64-vars.fd")) {
                vars = "/usr/local/share/qemu/edk2-x86_64-vars.fd";
            }
        }

        return .{ .code = code, .vars = vars };
    }

    if (host_os == .linux) {
        if (target_arch == .aarch64) {
            // AArch64 UEFI firmware paths on Linux
            const aarch64_paths = [_]struct { code: [:0]const u8, vars: [:0]const u8 }{
                .{ .code = "/usr/share/AAVMF/AAVMF_CODE.fd", .vars = "/usr/share/AAVMF/AAVMF_VARS.fd" },
                .{ .code = "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd", .vars = "/usr/share/qemu-efi-aarch64/vars-template-pflash.raw" },
                .{ .code = "/usr/share/edk2/aarch64/QEMU_EFI.fd", .vars = "/usr/share/edk2/aarch64/vars-template-pflash.raw" },
                .{ .code = "/usr/share/qemu/edk2-aarch64-code.fd", .vars = "/usr/share/qemu/edk2-arm-vars.fd" },
            };

            for (aarch64_paths) |pair| {
                if (fileExists(pair.code) and fileExists(pair.vars)) {
                    return .{ .code = pair.code, .vars = pair.vars };
                }
            }

            for (aarch64_paths) |pair| {
                if (code == null and fileExists(pair.code)) code = pair.code;
                if (vars == null and fileExists(pair.vars)) vars = pair.vars;
            }
        } else {
            // x86_64 UEFI firmware paths on Linux
            const pair_paths = [_]struct { code: [:0]const u8, vars: [:0]const u8 }{
                .{ .code = "/usr/share/OVMF/OVMF_CODE.fd", .vars = "/usr/share/OVMF/OVMF_VARS.fd" },
                .{ .code = "/usr/share/OVMF/OVMF_CODE.secboot.fd", .vars = "/usr/share/OVMF/OVMF_VARS.secboot.fd" },
                .{ .code = "/usr/share/edk2/ovmf/OVMF_CODE.fd", .vars = "/usr/share/edk2/ovmf/OVMF_VARS.fd" },
                .{ .code = "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd", .vars = "/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd" },
                .{ .code = "/usr/share/qemu/edk2-x86_64-code.fd", .vars = "/usr/share/qemu/edk2-x86_64-vars.fd" },
            };

            for (pair_paths) |pair| {
                if (fileExists(pair.code) and fileExists(pair.vars)) {
                    return .{ .code = pair.code, .vars = pair.vars };
                }
            }

            for (pair_paths) |pair| {
                if (code == null and fileExists(pair.code)) code = pair.code;
                if (vars == null and fileExists(pair.vars)) vars = pair.vars;
            }
        }
    }

    return .{ .code = code, .vars = vars };
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    const target_arch = b.option(std.Target.Cpu.Arch, "arch", "Target architecture") orelse .x86_64;

    // Freestanding target for kernel
    // Kernel target (No SSE/MMX/AVX for x86 to prevent FPU register clobbering)
    var kernel_target_query = std.Target.Query{
        .cpu_arch = target_arch,
        .os_tag = .freestanding,
        .abi = .none,
    };

    if (target_arch == .x86_64) {
        kernel_target_query.cpu_features_sub = std.Target.x86.featureSet(&.{
            .mmx, .sse, .sse2, .avx, .avx2,
        });
        kernel_target_query.cpu_features_add = std.Target.x86.featureSet(&.{
            .soft_float,
        });
    }

    const kernel_target = b.resolveTargetQuery(kernel_target_query);

    // User target
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = target_arch,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // UEFI target
    const uefi_target = b.resolveTargetQuery(.{
        .cpu_arch = target_arch,
        .os_tag = .uefi,
        .abi = if (target_arch == .x86_64) .msvc else .none,
    });

    // ============================================================
    // UEFI Bootloader
    // ============================================================
    // Architecture-specific EFI naming
    const efi_loader_name = if (target_arch == .aarch64) "bootaa64" else "bootx64";
    const efi_boot_file = if (target_arch == .aarch64) "BOOTAA64.EFI" else "BOOTX64.EFI";
    const kernel_elf_name = if (target_arch == .aarch64) "kernel-aarch64.elf" else "kernel-x86_64.elf";

    // Bootloader config options (parsed before other options for early use)
    const default_boot_early = b.option([]const u8, "default-boot", "Default boot target (shell, doom)") orelse "shell";
    const boot_config = b.addOptions();
    boot_config.addOption([]const u8, "default_boot", default_boot_early);

    const bootloader = b.addExecutable(.{
        .name = efi_loader_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot/uefi/main.zig"),
            .target = uefi_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "boot_info", .module = b.createModule(.{
                    .root_source_file = b.path("src/boot/common/boot_info.zig"),
                    .target = uefi_target,
                    .optimize = optimize,
                }) },
                .{ .name = "boot_config", .module = boot_config.createModule() },
            },
        }),
    });
    b.installArtifact(bootloader);

    // ============================================================
    // Build Steps & Runnersfiguration Options
    // ============================================================
    const version = b.option([]const u8, "version", "Kernel version string") orelse "0.1.0";
    const kernel_name = b.option([]const u8, "name", "Kernel name") orelse "ZK";
    const stack_size = b.option(usize, "stack-size", "Default thread stack size in bytes") orelse 16 * 1024;
    const heap_size_opt = b.option(usize, "heap-size", "Kernel heap size in bytes") orelse 2 * 1024 * 1024;
    const max_threads = b.option(usize, "max-threads", "Maximum number of threads") orelse 64;
    const timer_hz = b.option(u32, "timer-hz", "Timer frequency in Hz") orelse 100;
    const serial_baud = b.option(u32, "serial-baud", "Serial port baud rate") orelse 115200;
    const debug_enabled = b.option(bool, "debug", "Enable debug output") orelse true;
    const debug_memory = b.option(bool, "debug-memory", "Enable verbose memory allocation logging") orelse false;
    const debug_scheduler = b.option(bool, "debug-scheduler", "Enable verbose scheduler logging") orelse false;
    const debug_network = b.option(bool, "debug-network", "Enable verbose network logging") orelse false;
    // NEW: Option to pass BIOS/UEFI firmware path
    const qemu_bios_opt = b.option([]const u8, "bios", "Path to BIOS/UEFI firmware (e.g. OVMF.fd) for QEMU");
    const qemu_vars_opt = b.option([]const u8, "vars", "Path to UEFI vars (e.g. OVMF_VARS.fd) for QEMU");
    const run_iso = b.option(bool, "run-iso", "Boot QEMU from ISO instead of FAT directory") orelse false;
    const host_os = b.graph.host.result.os.tag;
    const homebrew_ovmf = detectHostOvmf(host_os, target_arch);
    const qemu_bios = qemu_bios_opt orelse homebrew_ovmf.code;
    const qemu_vars = if (qemu_bios_opt == null) (qemu_vars_opt orelse homebrew_ovmf.vars) else qemu_vars_opt;
    // Display option: "default" (auto), "sdl", "gtk", "cocoa" (macOS), "none" (headless)
    const qemu_display = b.option([]const u8, "display", "QEMU display backend (default, sdl, gtk, cocoa, none)") orelse "default";
    const qemu_usb_hub = b.option(bool, "usb-hub", "Attach usb-hub to XHCI and connect storage to it") orelse false;
    const qemu_nvme = b.option(bool, "nvme", "Add NVMe storage device for testing") orelse false;
    const qemu_virtfs = b.option([]const u8, "virtfs", "Share host directory via VirtIO-9P (e.g. /tmp/share)") orelse null;
    const default_audio: []const u8 = switch (host_os) {
        .macos => "coreaudio",
        .linux => "pa",
        else => "none",
    };
    const qemu_audio = b.option([]const u8, "audio", "QEMU audio backend (none, coreaudio, pa, file)") orelse default_audio;
    const qemu_extra_args = b.option([]const u8, "qemu-args", "Extra QEMU arguments (e.g. -nographic for serial console mode)");
    // Check if -nographic is requested (implies -serial stdio, so we must not add it explicitly)
    const qemu_nographic = if (qemu_extra_args) |args| std.mem.indexOf(u8, args, "-nographic") != null else false;
    const boot_logo_enabled = b.option(bool, "boot-logo", "Show animated boot logo during init (disable for debugging)") orelse true;
    const allow_weak_entropy = b.option(bool, "allow-weak-entropy", "Allow weak entropy for ASLR (TESTING ONLY - insecure!)") orelse false;

    // Create kernel config options module
    const config_options = b.addOptions();
    config_options.addOption([]const u8, "version", version);
    config_options.addOption([]const u8, "name", kernel_name);
    config_options.addOption(usize, "default_stack_size", stack_size);
    config_options.addOption(usize, "heap_size", heap_size_opt);
    config_options.addOption(usize, "max_threads", max_threads);
    config_options.addOption(u32, "timer_hz", timer_hz);
    config_options.addOption(u32, "serial_baud", serial_baud);
    config_options.addOption(bool, "debug_enabled", debug_enabled);
    config_options.addOption(bool, "debug_memory", debug_memory);
    config_options.addOption(bool, "debug_scheduler", debug_scheduler);
    config_options.addOption(bool, "debug_network", debug_network);
    config_options.addOption(bool, "boot_logo_enabled", boot_logo_enabled);
    config_options.addOption(bool, "allow_weak_entropy", allow_weak_entropy);

    // Create config module from build options
    const config_module = b.createModule(.{
        .root_source_file = config_options.getOutput(),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create UAPI module (syscall numbers, errno codes)
    const uapi_module = b.createModule(.{
        .root_source_file = b.path("src/uapi/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create User UAPI module (for user apps with SSE)
    const user_uapi_module = b.createModule(.{
        .root_source_file = b.path("src/uapi/root.zig"),
        .target = user_target,
        .optimize = optimize,
    });

    // Create Boot Info module (Shared Contract)
    const boot_info_module = b.createModule(.{
        .root_source_file = b.path("src/boot/common/boot_info.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create HAL module
    const hal_module = b.createModule(.{
        .root_source_file = b.path("src/arch/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });


    // Create Sync module (Spinlock and synchronization primitives)
    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/core/sync.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    sync_module.addImport("hal", hal_module);

    // Create Serial module (Architecture-specific)
    const serial_source = switch (kernel_target.result.cpu.arch) {
        .aarch64 => b.path("src/drivers/serial/pl011.zig"),
        else => b.path("src/drivers/serial/uart_16550.zig"),
    };
    const serial_module = b.createModule(.{
        .root_source_file = serial_source,
        .target = kernel_target,
        .optimize = optimize,
    });
    serial_module.addImport("hal", hal_module);
    serial_module.addImport("sync", sync_module);

    // Create TLB module (TLB shootdown for SMP)
    const tlb_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/tlb.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    tlb_module.addImport("hal", hal_module);
    tlb_module.addImport("sync", sync_module);

    // Create console module (debug output)
    const console_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/core/debug/console.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    console_module.addImport("hal", hal_module);
    console_module.addImport("config", config_module);
    console_module.addImport("sync", sync_module);

    // HAL needs console for APIC debug output (circular but Zig handles it)
    hal_module.addImport("console", console_module);
    hal_module.addImport("sync", sync_module);
    hal_module.addImport("serial", serial_module);

    // Create ACPI module (RSDP/MCFG parsing for PCIe ECAM)
    const acpi_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/acpi/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    acpi_module.addImport("hal", hal_module);
    acpi_module.addImport("console", console_module);

    // HAL needs acpi for VT-d initialization (DrhdInfo type)
    hal_module.addImport("acpi", acpi_module);

    // Create PMM module (Physical Memory Manager)
    const pmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/pmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    pmm_module.addImport("hal", hal_module);
    pmm_module.addImport("console", console_module);
    pmm_module.addImport("config", config_module);
    pmm_module.addImport("sync", sync_module);
    pmm_module.addImport("boot_info", boot_info_module);

    // Create VMM module (Virtual Memory Manager)
    const vmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/vmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    vmm_module.addImport("hal", hal_module);
    vmm_module.addImport("console", console_module);
    vmm_module.addImport("config", config_module);
    vmm_module.addImport("pmm", pmm_module);
    vmm_module.addImport("sync", sync_module);
    vmm_module.addImport("tlb", tlb_module);

    // Create Layout module (KASLR memory layout)
    const layout_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/layout.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    layout_module.addImport("boot_info", boot_info_module);
    layout_module.addImport("console", console_module);
    layout_module.addImport("hal", hal_module);

    // Add layout to vmm_module
    vmm_module.addImport("layout", layout_module);

    // Create PCI module (PCIe ECAM enumeration)
    const pci_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/pci/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    pci_module.addImport("hal", hal_module);
    pci_module.addImport("vmm", vmm_module);
    pci_module.addImport("console", console_module);
    pci_module.addImport("acpi", acpi_module);
    pci_module.addImport("sync", sync_module);

    // Create PRNG module (Kernel entropy/random)
    const prng_module = b.createModule(.{
        .root_source_file = b.path("src/lib/prng.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    prng_module.addImport("hal", hal_module);
    prng_module.addImport("sync", sync_module);
    prng_module.addImport("console", console_module);
    
    // Create Random module (Generic CSPRNG)
    const random_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/core/random.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    random_module.addImport("hal", hal_module);
    random_module.addImport("sync", sync_module);
    random_module.addImport("console", console_module);

    // Create ASLR module (Address Space Layout Randomization)
    const aslr_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/aslr.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    aslr_module.addImport("prng", prng_module);
    aslr_module.addImport("random", random_module);
    aslr_module.addImport("pmm", pmm_module);
    aslr_module.addImport("console", console_module);
    aslr_module.addImport("config", config_module);
    aslr_module.addImport("hal", hal_module);

    // Create Slab module (Kernel Slab Allocator)
    const slab_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/slab.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    slab_module.addImport("console", console_module);
    slab_module.addImport("config", config_module);
    slab_module.addImport("sync", sync_module);
    slab_module.addImport("pmm", pmm_module);
    slab_module.addImport("hal", hal_module);

    // Create Heap module (Kernel Heap Allocator)
    const heap_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/heap.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    heap_module.addImport("console", console_module);
    heap_module.addImport("config", config_module);
    heap_module.addImport("sync", sync_module);
    heap_module.addImport("hal", hal_module); // For TSC-based canary randomization
    heap_module.addImport("slab", slab_module);

    // Create Network Stack module (full stack: core, ethernet, ipv4, transport)
    const net_module = b.createModule(.{
        .root_source_file = b.path("src/net/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    net_module.addImport("hal", hal_module);
    net_module.addImport("uapi", uapi_module);
    net_module.addImport("prng", prng_module);
    net_module.addImport("random", random_module);
    net_module.addImport("console", console_module);
    net_module.addImport("sync", sync_module);
    net_module.addImport("heap", heap_module);
    // Note: io module added later after sched_module is defined

    // heap_module moved up

    // Create DMA Allocator module (Physical memory allocator with std.mem.Allocator interface)
    const dma_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/dma_allocator.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    dma_allocator_module.addImport("pmm", pmm_module);
    dma_allocator_module.addImport("hal", hal_module);
    dma_allocator_module.addImport("heap", heap_module);
    dma_allocator_module.addImport("console", console_module);

    // Create List module (generic intrusive list)
    const list_module = b.createModule(.{
        .root_source_file = b.path("src/lib/list.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create Kernel Stack module (dedicated stack allocator with guard pages)
    const kernel_stack_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/kernel_stack.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_stack_module.addImport("hal", hal_module);
    kernel_stack_module.addImport("pmm", pmm_module);
    kernel_stack_module.addImport("vmm", vmm_module);
    kernel_stack_module.addImport("console", console_module);
    kernel_stack_module.addImport("sync", sync_module);
    kernel_stack_module.addImport("layout", layout_module);

    // Create VDSO module
    const vdso_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/vdso.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    // Add dependencies for VDSO module
    vdso_module.addImport("pmm", pmm_module);
    vdso_module.addImport("vmm", vmm_module);
    vdso_module.addImport("hal", hal_module);
    vdso_module.addImport("console", console_module);
    vdso_module.addImport("prng", prng_module);
    // UserVmm not defined yet - will do after definition
    // Process not defined yet - will do after definition

    // Create Thread module (Thread management and creation)
    const thread_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/thread.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    thread_module.addImport("hal", hal_module);
    thread_module.addImport("pmm", pmm_module);
    thread_module.addImport("vmm", vmm_module);
    thread_module.addImport("heap", heap_module);
    thread_module.addImport("console", console_module);
    thread_module.addImport("config", config_module);
    thread_module.addImport("kernel_stack", kernel_stack_module);
    thread_module.addImport("uapi", uapi_module);

    // Create Scheduler module (Thread scheduling)
    const sched_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/sched/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    sched_module.addImport("hal", hal_module);
    sched_module.addImport("thread", thread_module);
    sched_module.addImport("sync", sync_module);
    sched_module.addImport("console", console_module);
    sched_module.addImport("config", config_module);
    sched_module.addImport("list", list_module);
    sched_module.addImport("kernel_stack", kernel_stack_module);
    sched_module.addImport("vdso", vdso_module);
    sched_module.addImport("uapi", uapi_module);

    // Break circular dependency shim
    sync_module.addImport("sched", sched_module);
    hal_module.addImport("sched", sched_module);
    hal_module.addImport("pmm", pmm_module);
    hal_module.addImport("vmm", vmm_module);

    // Create Kernel Async I/O module (reactor, request pool, futures)
    const kernel_io_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/io/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_io_module.addImport("sync", sync_module);
    kernel_io_module.addImport("uapi", uapi_module);
    kernel_io_module.addImport("sched", sched_module);
    kernel_io_module.addImport("thread", thread_module);

    // Wire io module into net and serial (deferred from earlier due to dependency order)
    net_module.addImport("io", kernel_io_module);
    serial_module.addImport("io", kernel_io_module);

    // Create Stack Guard module (stack canary support)
    const stack_guard_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/core/stack_guard.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    stack_guard_module.addImport("hal", hal_module);
    stack_guard_module.addImport("console", console_module);
    stack_guard_module.addImport("prng", prng_module);
    stack_guard_module.addImport("random", random_module);

    // Create FD module (File Descriptor table)
    const fd_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/fs/fd.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    fd_module.addImport("heap", heap_module);
    fd_module.addImport("console", console_module);
    fd_module.addImport("uapi", uapi_module);
    fd_module.addImport("sync", sync_module);

    // Create flock module (advisory file locking manager)
    const flock_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/fs/flock.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    flock_module.addImport("sync", sync_module);
    flock_module.addImport("sched", sched_module);
    flock_module.addImport("uapi", uapi_module);
    flock_module.addImport("console", console_module);

    // fd needs flock for cleanup
    fd_module.addImport("flock", flock_module);

    // Create kernel IOMMU module (domain management) - before drivers that need it
    const kernel_iommu_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/iommu/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_iommu_module.addImport("console", console_module);
    kernel_iommu_module.addImport("pmm", pmm_module);
    kernel_iommu_module.addImport("hal", hal_module);
    kernel_iommu_module.addImport("acpi", acpi_module);

    // Create DMA module (IOMMU-aware DMA buffer allocation for drivers)
    const dma_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/dma.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    dma_module.addImport("console", console_module);
    dma_module.addImport("pmm", pmm_module);
    dma_module.addImport("hal", hal_module);
    dma_module.addImport("iommu", kernel_iommu_module);

    // Create E1000e driver module (Intel 82574L NIC)
    const e1000e_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/net/e1000e/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    e1000e_module.addImport("hal", hal_module);
    e1000e_module.addImport("pci", pci_module);
    e1000e_module.addImport("vmm", vmm_module);
    e1000e_module.addImport("pmm", pmm_module);
    e1000e_module.addImport("sync", sync_module);
    e1000e_module.addImport("console", console_module);
    e1000e_module.addImport("thread", thread_module);
    e1000e_module.addImport("sched", sched_module);
    e1000e_module.addImport("heap", heap_module);
    e1000e_module.addImport("net", net_module);
    e1000e_module.addImport("dma", dma_module);
    e1000e_module.addImport("iommu", kernel_iommu_module);
    e1000e_module.addImport("io", kernel_io_module);

    // Create AHCI driver module (SATA storage controller)
    const ahci_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/storage/ahci/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ahci_module.addImport("pci", pci_module);
    ahci_module.addImport("vmm", vmm_module);
    ahci_module.addImport("pmm", pmm_module);
    ahci_module.addImport("console", console_module);
    ahci_module.addImport("hal", hal_module);
    ahci_module.addImport("fd", fd_module);
    ahci_module.addImport("uapi", uapi_module);
    ahci_module.addImport("heap", heap_module);
    ahci_module.addImport("io", kernel_io_module);
    ahci_module.addImport("sync", sync_module);
    ahci_module.addImport("dma", dma_module);
    ahci_module.addImport("iommu", kernel_iommu_module);

    // Create IDE driver module (Legacy IDE/PATA storage controller - x86_64 only)
    const ide_module = if (target_arch == .x86_64) b.createModule(.{
        .root_source_file = b.path("src/drivers/storage/ide/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    }) else null;
    if (ide_module) |mod| {
        mod.addImport("pci", pci_module);
        mod.addImport("console", console_module);
        mod.addImport("hal", hal_module);
        mod.addImport("fd", fd_module);
        mod.addImport("uapi", uapi_module);
        mod.addImport("heap", heap_module);
    }

    // Create NVMe driver module (NVM Express storage controller)
    const nvme_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/storage/nvme/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    nvme_module.addImport("pci", pci_module);
    nvme_module.addImport("vmm", vmm_module);
    nvme_module.addImport("pmm", pmm_module);
    nvme_module.addImport("console", console_module);
    nvme_module.addImport("hal", hal_module);
    nvme_module.addImport("fd", fd_module);
    nvme_module.addImport("uapi", uapi_module);
    nvme_module.addImport("heap", heap_module);
    nvme_module.addImport("io", kernel_io_module);
    nvme_module.addImport("sync", sync_module);
    nvme_module.addImport("dma", dma_module);
    nvme_module.addImport("iommu", kernel_iommu_module);

    // Create VirtIO-SCSI driver module (VirtIO SCSI storage controller)
    const virtio_scsi_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/scsi/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_scsi_module.addImport("pci", pci_module);
    virtio_scsi_module.addImport("vmm", vmm_module);
    virtio_scsi_module.addImport("pmm", pmm_module);
    virtio_scsi_module.addImport("console", console_module);
    virtio_scsi_module.addImport("hal", hal_module);
    virtio_scsi_module.addImport("fd", fd_module);
    virtio_scsi_module.addImport("uapi", uapi_module);
    virtio_scsi_module.addImport("heap", heap_module);
    virtio_scsi_module.addImport("io", kernel_io_module);
    virtio_scsi_module.addImport("sync", sync_module);
    virtio_scsi_module.addImport("dma", dma_module);
    virtio_scsi_module.addImport("iommu", kernel_iommu_module);

    // Create USB driver module (XHCI/EHCI host controllers)
    const usb_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/usb/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    usb_module.addImport("hal", hal_module);
    usb_module.addImport("pci", pci_module);
    usb_module.addImport("vmm", vmm_module);
    usb_module.addImport("pmm", pmm_module);
    usb_module.addImport("console", console_module);
    usb_module.addImport("sync", sync_module);
    usb_module.addImport("io", kernel_io_module);
    usb_module.addImport("dma", dma_module);
    usb_module.addImport("iommu", kernel_iommu_module);

    // Add USB to scheduler for XHCI polling on aarch64
    sched_module.addImport("usb", usb_module);

    // fd_module moved up

    // Create User VMM module (userspace memory management for mmap/munmap)
    const user_vmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/user_vmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    user_vmm_module.addImport("hal", hal_module);
    user_vmm_module.addImport("vmm", vmm_module);
    user_vmm_module.addImport("pmm", pmm_module);
    user_vmm_module.addImport("heap", heap_module);
    user_vmm_module.addImport("console", console_module);
    user_vmm_module.addImport("uapi", uapi_module);
    user_vmm_module.addImport("sync", sync_module);

    // Create Ring Buffer module (generic circular buffer)
    const ring_buffer_module = b.createModule(.{
        .root_source_file = b.path("src/lib/ring_buffer.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create FS module
    const fs_module = b.createModule(.{
        .root_source_file = b.path("src/fs/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    fs_module.addImport("fd", fd_module);
    fs_module.addImport("heap", heap_module);
    fs_module.addImport("uapi", uapi_module);
    fs_module.addImport("console", console_module);
    fs_module.addImport("ahci", ahci_module);
    if (ide_module) |mod| {
        fs_module.addImport("ide", mod);
    }
    fs_module.addImport("nvme", nvme_module);
    fs_module.addImport("virtio_scsi", virtio_scsi_module);

    fs_module.addImport("sync", sync_module);

    fs_module.addImport("io", kernel_io_module);
    fs_module.addImport("pmm", pmm_module);
    fs_module.addImport("hal", hal_module);


    // Create PS/2 controller module (shared between keyboard and mouse)
    const ps2_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/input/ps2/controller.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ps2_module.addImport("hal", hal_module);

    // Create Keyboard driver module
    const keyboard_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/input/keyboard.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    keyboard_module.addImport("hal", hal_module);
    keyboard_module.addImport("sync", sync_module);
    keyboard_module.addImport("ring_buffer", ring_buffer_module);
    keyboard_module.addImport("console", console_module);
    keyboard_module.addImport("uapi", uapi_module);
    keyboard_module.addImport("sched", sched_module);
    keyboard_module.addImport("thread", thread_module);
    keyboard_module.addImport("io", kernel_io_module);
    keyboard_module.addImport("ps2", ps2_module);
    // Note: user_mem import added after user_mem_module is defined below


    // Create VirtIO common module
    const virtio_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_module.addImport("pmm", pmm_module);
    virtio_module.addImport("hal", hal_module);
    virtio_module.addImport("pci", pci_module);
    virtio_module.addImport("vmm", vmm_module);
    virtio_module.addImport("console", console_module);
    virtio_module.addImport("prng", prng_module);

    // Add virtio import to virtio_scsi_module (defined earlier but virtio_module wasn't ready yet)
    virtio_scsi_module.addImport("virtio", virtio_module);

    // Create Video driver module
    const video_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/video/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    video_module.addImport("sync", sync_module);
    video_module.addImport("pmm", pmm_module);
    video_module.addImport("vmm", vmm_module);
    video_module.addImport("hal", hal_module);
    video_module.addImport("virtio", virtio_module);
    video_module.addImport("pci", pci_module);
    video_module.addImport("console", console_module);
    video_module.addImport("heap", heap_module);

    // Create Audio driver module
    const audio_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/audio/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    audio_module.addImport("hal", hal_module);
    audio_module.addImport("pci", pci_module);
    audio_module.addImport("pmm", pmm_module);
    audio_module.addImport("vmm", vmm_module);
    audio_module.addImport("console", console_module);
    audio_module.addImport("uapi", uapi_module);
    audio_module.addImport("fd", fd_module);
    audio_module.addImport("sync", sync_module);
    audio_module.addImport("heap", heap_module);
    audio_module.addImport("sched", sched_module);
    audio_module.addImport("thread", thread_module);
    audio_module.addImport("io", kernel_io_module);

    // Create Virtual PCI driver module (pciem framework port)
    const virt_pci_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virt_pci/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virt_pci_module.addImport("uapi", uapi_module);
    virt_pci_module.addImport("sync", sync_module);
    virt_pci_module.addImport("pmm", pmm_module);
    virt_pci_module.addImport("console", console_module);
    virt_pci_module.addImport("hal", hal_module);
    virt_pci_module.addImport("sched", sched_module);

    // Create Input subsystem module
    const input_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/input/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    input_module.addImport("sync", sync_module);
    input_module.addImport("ring_buffer", ring_buffer_module);
    input_module.addImport("uapi", uapi_module);
    input_module.addImport("hal", hal_module);
    input_module.addImport("console", console_module);

    // Create Mouse driver module
    const mouse_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/input/mouse.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    mouse_module.addImport("hal", hal_module);
    mouse_module.addImport("sync", sync_module);
    mouse_module.addImport("ring_buffer", ring_buffer_module);
    mouse_module.addImport("console", console_module);
    mouse_module.addImport("input", input_module);
    mouse_module.addImport("uapi", uapi_module);
    mouse_module.addImport("ps2", ps2_module);

    // Add mouse module to input for vmmouse driver
    input_module.addImport("mouse", mouse_module);

    // Add dependencies to USB module (after keyboard/mouse are defined)
    usb_module.addImport("keyboard", keyboard_module);
    usb_module.addImport("mouse", mouse_module);

    // Create VirtIO-Input driver module (keyboard/mouse/tablet via VirtIO)
    const virtio_input_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/input/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_input_module.addImport("pci", pci_module);
    virtio_input_module.addImport("vmm", vmm_module);
    virtio_input_module.addImport("pmm", pmm_module);
    virtio_input_module.addImport("console", console_module);
    virtio_input_module.addImport("hal", hal_module);
    virtio_input_module.addImport("heap", heap_module);
    virtio_input_module.addImport("sync", sync_module);
    virtio_input_module.addImport("virtio", virtio_module);
    virtio_input_module.addImport("input", input_module);
    virtio_input_module.addImport("keyboard", keyboard_module);
    virtio_input_module.addImport("uapi", uapi_module);

    // Create VirtIO-Sound driver module (audio playback/capture via VirtIO)
    const virtio_sound_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/sound/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_sound_module.addImport("pci", pci_module);
    virtio_sound_module.addImport("vmm", vmm_module);
    virtio_sound_module.addImport("pmm", pmm_module);
    virtio_sound_module.addImport("console", console_module);
    virtio_sound_module.addImport("hal", hal_module);
    virtio_sound_module.addImport("heap", heap_module);
    virtio_sound_module.addImport("sync", sync_module);
    virtio_sound_module.addImport("virtio", virtio_module);
    virtio_sound_module.addImport("uapi", uapi_module);
    virtio_sound_module.addImport("fd", fd_module);
    // user_mem added later (after user_mem_module is defined)

    // Create VirtIO-9P driver module (shared folders via 9P protocol)
    const virtio_9p_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/9p/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_9p_module.addImport("pci", pci_module);
    virtio_9p_module.addImport("vmm", vmm_module);
    virtio_9p_module.addImport("pmm", pmm_module);
    virtio_9p_module.addImport("console", console_module);
    virtio_9p_module.addImport("hal", hal_module);
    virtio_9p_module.addImport("heap", heap_module);
    virtio_9p_module.addImport("sync", sync_module);
    virtio_9p_module.addImport("virtio", virtio_module);
    virtio_9p_module.addImport("dma", dma_module);
    virtio_9p_module.addImport("iommu", kernel_iommu_module);

    // Add virtio_9p to fs module for VFS integration
    fs_module.addImport("virtio_9p", virtio_9p_module);

    // Create VirtIO-FS driver module (shared folders via FUSE protocol)
    const virtio_fs_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/fs/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_fs_module.addImport("pci", pci_module);
    virtio_fs_module.addImport("vmm", vmm_module);
    virtio_fs_module.addImport("pmm", pmm_module);
    virtio_fs_module.addImport("console", console_module);
    virtio_fs_module.addImport("hal", hal_module);
    virtio_fs_module.addImport("heap", heap_module);
    virtio_fs_module.addImport("sync", sync_module);
    virtio_fs_module.addImport("virtio", virtio_module);
    virtio_fs_module.addImport("dma", dma_module);
    virtio_fs_module.addImport("iommu", kernel_iommu_module);

    // Add virtio_fs to fs module for VFS integration
    fs_module.addImport("virtio_fs", virtio_fs_module);

    // Create VirtualBox VMMDev driver module (Guest Additions communication)
    const vmmdev_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/vbox/vmmdev/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    vmmdev_module.addImport("pci", pci_module);
    vmmdev_module.addImport("vmm", vmm_module);
    vmmdev_module.addImport("pmm", pmm_module);
    vmmdev_module.addImport("console", console_module);
    vmmdev_module.addImport("hal", hal_module);
    vmmdev_module.addImport("heap", heap_module);
    vmmdev_module.addImport("sync", sync_module);
    vmmdev_module.addImport("dma", dma_module);
    vmmdev_module.addImport("iommu", kernel_iommu_module);

    // Create VirtualBox Shared Folders (VBoxSF) driver module
    const vboxsf_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/vbox/sf/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    vboxsf_module.addImport("hal", hal_module);
    vboxsf_module.addImport("console", console_module);
    vboxsf_module.addImport("heap", heap_module);
    vboxsf_module.addImport("sync", sync_module);
    vboxsf_module.addImport("dma", dma_module);
    vboxsf_module.addImport("iommu", kernel_iommu_module);
    vboxsf_module.addImport("vmmdev", vmmdev_module);

    // Create VirtualBox facade module (re-exports vmmdev, vboxsf)
    const vbox_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/vbox/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    vbox_module.addImport("hal", hal_module);
    // vmmdev and vboxsf are imported via relative paths in root.zig

    // Add vboxsf to fs module for VFS integration
    fs_module.addImport("vboxsf", vboxsf_module);

    // Create VMware HGFS driver module (Host-Guest File System over RPCI - x86_64 only)
    const hgfs_module = if (target_arch == .x86_64) b.createModule(.{
        .root_source_file = b.path("src/drivers/vmware/hgfs/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    }) else null;
    if (hgfs_module) |mod| {
        mod.addImport("hal", hal_module);
        mod.addImport("console", console_module);
        mod.addImport("heap", heap_module);
        mod.addImport("sync", sync_module);
    }

    // Create VMware facade module (re-exports hgfs - x86_64 only)
    const vmware_module = if (target_arch == .x86_64) b.createModule(.{
        .root_source_file = b.path("src/drivers/vmware/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    }) else null;
    if (vmware_module) |mod| {
        mod.addImport("hal", hal_module);
    }

    // Add hgfs to fs module for VFS integration (x86_64 only)
    if (hgfs_module) |mod| {
        fs_module.addImport("hgfs", mod);
    }

    // Create DevFS module (device filesystem shim)
    const devfs_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/fs/devfs.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    devfs_module.addImport("fd", fd_module);
    devfs_module.addImport("console", console_module);
    devfs_module.addImport("hal", hal_module);
    devfs_module.addImport("keyboard", keyboard_module);
    devfs_module.addImport("sched", sched_module);
    devfs_module.addImport("uapi", uapi_module);
    devfs_module.addImport("ahci", ahci_module);
    if (ide_module) |mod| {
        devfs_module.addImport("ide", mod);
    }
    devfs_module.addImport("nvme", nvme_module);
    devfs_module.addImport("virtio_scsi", virtio_scsi_module);
    devfs_module.addImport("heap", heap_module);
    devfs_module.addImport("fs", fs_module);
    devfs_module.addImport("sync", sync_module);

    // Add devfs to VirtIO-Sound (for /dev/dsp registration)
    virtio_sound_module.addImport("devfs", devfs_module);

    // Add devfs to audio module (AC97 /dev/dsp registration)
    audio_module.addImport("devfs", devfs_module);

    // Add devfs to IDE module (for /dev/hda registration - x86_64 only)
    if (ide_module) |mod| {
        mod.addImport("devfs", devfs_module);
    }

    // Create Partitions module
    const partitions_module = b.createModule(.{
        .root_source_file = b.path("src/fs/partitions/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    partitions_module.addImport("ahci", ahci_module);
    if (ide_module) |mod| {
        partitions_module.addImport("ide", mod);
    }
    partitions_module.addImport("nvme", nvme_module);
    partitions_module.addImport("virtio_scsi", virtio_scsi_module);
    partitions_module.addImport("devfs", devfs_module);
    partitions_module.addImport("heap", heap_module);
    partitions_module.addImport("fd", fd_module);
    partitions_module.addImport("uapi", uapi_module);
    partitions_module.addImport("console", console_module);

    // Create Capabilities module
    const capabilities_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/capabilities/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    capabilities_module.addImport("console", console_module);

    // Create atomic module for IPC/Locking (needed by process)
    const ipc_msg_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/ipc/message.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ipc_msg_module.addImport("uapi", uapi_module);

    // Create Process module (process abstraction for fork/exec/wait)
    const process_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/process/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    process_module.addImport("heap", heap_module);
    process_module.addImport("console", console_module);
    process_module.addImport("fd", fd_module);
    // Removed devfs dependency to break cycle
    process_module.addImport("user_vmm", user_vmm_module);

    process_module.addImport("vmm", vmm_module);
    process_module.addImport("pmm", pmm_module);
    process_module.addImport("hal", hal_module);
    process_module.addImport("uapi", uapi_module);
    process_module.addImport("sched", sched_module);
    process_module.addImport("ipc_msg", ipc_msg_module);
    process_module.addImport("list", list_module);
    process_module.addImport("capabilities", capabilities_module);
    process_module.addImport("vdso", vdso_module);
    process_module.addImport("aslr", aslr_module);

    // Defer fs->process import due to definition order
    fs_module.addImport("process", process_module);



    // Create ELF loader module (for execve)
    const elf_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/core/elf/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    elf_module.addImport("hal", hal_module);
    elf_module.addImport("vmm", vmm_module);
    elf_module.addImport("pmm", pmm_module);
    elf_module.addImport("heap", heap_module);
    elf_module.addImport("console", console_module);
    elf_module.addImport("uapi", uapi_module);
    elf_module.addImport("user_vmm", user_vmm_module);

    // Create framebuffer module (for fb syscalls)
    const framebuffer_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/framebuffer.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    framebuffer_module.addImport("console", console_module);
    framebuffer_module.addImport("hal", hal_module);
    framebuffer_module.addImport("boot_info", boot_info_module);

    // Add framebuffer to process_module (deferred due to definition order)
    process_module.addImport("framebuffer", framebuffer_module);

    // Add virt_pci for process exit cleanup
    process_module.addImport("virt_pci", virt_pci_module);

    // Create user memory validation module (shared by all syscall modules)
    const user_mem_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/core/user_mem.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    user_mem_module.addImport("console", console_module);
    user_mem_module.addImport("vmm", vmm_module);
    user_mem_module.addImport("sched", sched_module);

    // Add user_mem to sched (circular dependency allowed in Zig modules)
    sched_module.addImport("user_mem", user_mem_module);

    // Add user_mem to audio for ioctl validation
    audio_module.addImport("user_mem", user_mem_module);

    // Add user_mem to keyboard for getCharAsync io_uring integration
    keyboard_module.addImport("user_mem", user_mem_module);

    // Add user_mem to VirtIO-Sound for ioctl validation
    virtio_sound_module.addImport("user_mem", user_mem_module);

    // Create Pipe module (IPC)
    const pipe_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/fs/pipe.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    pipe_module.addImport("heap", heap_module);
    pipe_module.addImport("fd", fd_module);
    pipe_module.addImport("sched", sched_module);
    pipe_module.addImport("sync", sync_module);
    pipe_module.addImport("uapi", uapi_module);
    pipe_module.addImport("console", console_module);
    pipe_module.addImport("hal", hal_module);
    pipe_module.addImport("io", kernel_io_module);

    // Create Signal module
    const signal_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/signal.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    // Add deferred dependencies for VDSO module
    vdso_module.addImport("user_vmm", user_vmm_module);
    vdso_module.addImport("process", process_module);
    signal_module.addImport("sched", sched_module);
    signal_module.addImport("thread", thread_module);
    signal_module.addImport("uapi", uapi_module);
    signal_module.addImport("hal", hal_module);
    signal_module.addImport("user_mem", user_mem_module);
    signal_module.addImport("console", console_module);

    // Create generic FS metadata module (structs only, no deps)
    const fs_meta_module = b.createModule(.{
        .root_source_file = b.path("src/fs/meta.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create permissions logic module
    const perms_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/perms.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    perms_module.addImport("process", process_module);
    perms_module.addImport("fs_meta", fs_meta_module); // Use standalone meta module
    perms_module.addImport("capabilities", capabilities_module);
    perms_module.addImport("fd", fd_module);

    // Add imports to fs module (safe here as fs_meta and perms are defined)
    fs_module.addImport("fs_meta", fs_meta_module);
    fs_module.addImport("perms", perms_module);

    // Create syscall base module (shared state for all handlers)
    const syscall_base_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/core/base.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_base_module.addImport("uapi", uapi_module);
    syscall_base_module.addImport("console", console_module);
    syscall_base_module.addImport("sched", sched_module);
    syscall_base_module.addImport("fd", fd_module);
    syscall_base_module.addImport("user_vmm", user_vmm_module);
    syscall_base_module.addImport("process", process_module);
    syscall_base_module.addImport("user_mem", user_mem_module);

    // Create syscall process module (exit, wait4, getpid, etc.)
    const syscall_process_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/process/process.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_process_module.addImport("base.zig", syscall_base_module);
    syscall_process_module.addImport("uapi", uapi_module);
    syscall_process_module.addImport("console", console_module);
    syscall_process_module.addImport("hal", hal_module);
    syscall_process_module.addImport("sched", sched_module);
    syscall_process_module.addImport("process", process_module);
    syscall_process_module.addImport("config", config_module);

    // Add syscall_base and user_mem to devfs (required for TTY ioctl job control)
    devfs_module.addImport("syscall_base", syscall_base_module);
    devfs_module.addImport("user_mem", user_mem_module);

    // Create syscall signals module (rt_sigprocmask, rt_sigaction, etc.)
    const syscall_signals_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/process/signals.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_signals_module.addImport("base.zig", syscall_base_module);
    syscall_signals_module.addImport("uapi", uapi_module);
    syscall_signals_module.addImport("console", console_module);
    syscall_signals_module.addImport("hal", hal_module);
    syscall_signals_module.addImport("sched", sched_module);
    syscall_signals_module.addImport("process", process_module);
    // Add signals module to devfs for SIGTTOU/SIGTTIN job control
    devfs_module.addImport("signals", syscall_signals_module);
    // Add signals module to process for orphaned process group detection
    process_module.addImport("signals", syscall_signals_module);

    // Create Futex module
    const futex_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/futex.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    futex_module.addImport("sched", sched_module);
    futex_module.addImport("sync", sync_module);
    futex_module.addImport("heap", heap_module);
    futex_module.addImport("hal", hal_module);
    futex_module.addImport("vmm", vmm_module);
    futex_module.addImport("console", console_module);
    futex_module.addImport("pmm", pmm_module); // For page pinning to prevent UAF

    // Break circular dependency: sched needs futex for timeout handling in wakeSleepingThreads
    sched_module.addImport("futex", futex_module);
    // sched needs base.zig for CLONE_CHILD_CLEARTID handling
    sched_module.addImport("base.zig", syscall_base_module);
    // sched needs process for alarm list (Process.alarm_deadline/alarm_next/alarm_prev fields)
    sched_module.addImport("process", process_module);
    // sched needs signal for alarm expiration (deliverSignalToThread, SIGALRM)
    sched_module.addImport("signal", signal_module);

    // Create kernel IPC module (SysV IPC: shared memory, semaphores, message queues)
    const kernel_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/ipc/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_ipc_module.addImport("process", process_module);
    kernel_ipc_module.addImport("pmm", pmm_module);
    kernel_ipc_module.addImport("hal", hal_module);
    kernel_ipc_module.addImport("uapi", uapi_module);
    kernel_ipc_module.addImport("user_mem", user_mem_module);
    kernel_ipc_module.addImport("vmm", vmm_module);
    kernel_ipc_module.addImport("sync", sync_module);
    kernel_ipc_module.addImport("console", console_module);

    // Create syscall scheduling module (sched_yield, nanosleep, etc.)
    const syscall_scheduling_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/process/scheduling.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_scheduling_module.addImport("base.zig", syscall_base_module);
    syscall_scheduling_module.addImport("uapi", uapi_module);
    syscall_scheduling_module.addImport("hal", hal_module);
    syscall_scheduling_module.addImport("sched", sched_module);
    syscall_scheduling_module.addImport("futex", futex_module);
    syscall_scheduling_module.addImport("heap", heap_module);
    syscall_scheduling_module.addImport("fd", fd_module);
    syscall_scheduling_module.addImport("sync", sync_module);
    syscall_scheduling_module.addImport("user_mem", user_mem_module);
    syscall_scheduling_module.addImport("process", process_module);

    // Create syscall io module (read, write, stat, etc.)
    const syscall_io_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/io/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_io_module.addImport("base.zig", syscall_base_module);
    syscall_io_module.addImport("uapi", uapi_module);
    syscall_io_module.addImport("console", console_module);
    syscall_io_module.addImport("fs", fs_module);
    syscall_io_module.addImport("heap", heap_module);
    syscall_io_module.addImport("fd", fd_module);
    syscall_io_module.addImport("user_mem", user_mem_module);
    syscall_io_module.addImport("hal", hal_module);
    syscall_io_module.addImport("devfs", devfs_module);
    syscall_io_module.addImport("sched", sched_module);
    syscall_io_module.addImport("sync", sync_module);

    // Create syscall fd module (open, close, dup, pipe, lseek)
    const syscall_fd_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/fs/fd.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_fd_module.addImport("base.zig", syscall_base_module);
    syscall_fd_module.addImport("uapi", uapi_module);
    syscall_fd_module.addImport("console", console_module);
    syscall_fd_module.addImport("fs", fs_module);
    syscall_fd_module.addImport("heap", heap_module);
    syscall_fd_module.addImport("pipe", pipe_module);
    syscall_fd_module.addImport("fd", fd_module);
    syscall_fd_module.addImport("user_mem", user_mem_module);
    syscall_fd_module.addImport("perms", perms_module);

    // Now that syscall_fd_module is defined, add it to syscall_io_module
    syscall_io_module.addImport("syscall_fd", syscall_fd_module);

    // Create syscall memory module (mmap, mprotect, munmap, brk)
    const syscall_memory_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/memory/memory.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_memory_module.addImport("base.zig", syscall_base_module);
    syscall_memory_module.addImport("uapi", uapi_module);
    syscall_memory_module.addImport("pmm", pmm_module);
    syscall_memory_module.addImport("vmm", vmm_module);
    syscall_memory_module.addImport("user_mem", user_mem_module);
    syscall_memory_module.addImport("user_vmm", user_vmm_module);
    syscall_memory_module.addImport("console", console_module);

    // Create syscall execution module (fork, execve, arch_prctl, fb syscalls)
    const syscall_execution_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/core/execution.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_execution_module.addImport("base.zig", syscall_base_module);
    syscall_execution_module.addImport("uapi", uapi_module);
    syscall_execution_module.addImport("console", console_module);
    syscall_execution_module.addImport("hal", hal_module);
    syscall_execution_module.addImport("sched", sched_module);
    syscall_execution_module.addImport("process", process_module);
    syscall_execution_module.addImport("thread", thread_module);
    syscall_execution_module.addImport("vmm", vmm_module);
    syscall_execution_module.addImport("pmm", pmm_module);
    syscall_execution_module.addImport("heap", heap_module);
    syscall_execution_module.addImport("elf", elf_module);
    syscall_execution_module.addImport("framebuffer", framebuffer_module);
    syscall_execution_module.addImport("fs", fs_module);
    syscall_execution_module.addImport("user_mem", user_mem_module);
    syscall_execution_module.addImport("user_vmm", user_vmm_module);
    syscall_execution_module.addImport("vdso", vdso_module);
    syscall_execution_module.addImport("aslr", aslr_module);
    syscall_execution_module.addImport("video_driver", video_module);

    // Create syscall custom module (debug_log, putchar, getchar, etc.)
    const syscall_custom_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/custom.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_custom_module.addImport("base.zig", syscall_base_module);

    // Create syscall library for USER applications (SSE enabled)
    // Moved up for dependency resolution
    const user_syscall_lib = b.createModule(.{
        .root_source_file = b.path("src/user/lib/syscall/root.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    user_syscall_lib.addImport("uapi", user_uapi_module);

    // Create ring buffer IPC library for USER applications
    const user_ring_lib = b.createModule(.{
        .root_source_file = b.path("src/user/lib/ring.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    user_ring_lib.addImport("syscall", user_syscall_lib);

    const user_libc_module = b.createModule(.{
        .root_source_file = b.path("src/user/lib/libc/root.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    user_libc_module.addImport("syscall", user_syscall_lib);
    // Create User Sync module (stub)
    const user_sync_module = b.createModule(.{
        .root_source_file = b.path("src/user/lib/sync_stub.zig"),
        .target = user_target,
        .optimize = optimize,
    });

    // Create User Console module (stub)
    const user_console_module = b.createModule(.{
        .root_source_file = b.path("src/user/lib/console_stub.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    user_console_module.addImport("uapi", user_uapi_module);

    // Create User Network Stack module (for userspace netstack)
    const user_net_module = b.createModule(.{
        .root_source_file = b.path("src/net/root.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    // Do NOT import hal for user_net_module
    user_net_module.addImport("uapi", user_uapi_module);
    user_net_module.addImport("console", user_console_module);
    user_net_module.addImport("sync", user_sync_module);
    user_net_module.addImport("prng", prng_module); // See note below, ideally unused or stubbed
    user_net_module.addImport("io", b.createModule(.{
        .root_source_file = b.path("src/user/netstack/io_stub.zig"),
        .target = user_target,
        .optimize = optimize,
    }));

    // Create Netstack Process (Userspace Networking)
    const netstack_mod = b.createModule(.{
        .root_source_file = b.path("src/user/netstack/main.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    // Note: syscall import added after netstack_syscall_mod is created below
    // Note: src/user/lib/syscall/root.zig needs uapi.
    // I should add uapi to the syscall module as well?
    // The syscall module created above needs imports?
    // Yes. It's better if I define netstack loop later or just duplicate logic.
    // Or I can move user_syscall_lib definition up?
    // Replacing a large chunk to move it up is risky.
    // I will just define netstack_mod imports manually.

    // Actually, I can fix the build error first.
    // netstack_mod.addImport("syscall", ...);
    // But that syscall module needs imports.
    // Let's use b.createModule for syscall and add uapi import.
    const netstack_syscall_mod = b.createModule(.{
        .root_source_file = b.path("src/user/lib/syscall/root.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    netstack_syscall_mod.addImport("uapi", user_uapi_module);

    // Create netstack-specific ring module to avoid module conflicts
    const netstack_ring_mod = b.createModule(.{
        .root_source_file = b.path("src/user/lib/ring.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    netstack_ring_mod.addImport("syscall", netstack_syscall_mod);

    netstack_mod.addImport("syscall", netstack_syscall_mod);
    netstack_mod.addImport("net", user_net_module);
    netstack_mod.addImport("uapi", user_uapi_module);
    netstack_mod.addImport("libc", user_libc_module);
    netstack_mod.addImport("ring", netstack_ring_mod);

    const netstack_exe = b.addExecutable(.{
        .name = "netstack",
        .root_module = netstack_mod,
    });
    netstack_exe.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        netstack_exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const netstack_cmd = b.addInstallArtifact(netstack_exe, .{});
    b.getInstallStep().dependOn(&netstack_cmd.step);

    // Add explicit step for building netstack
    const netstack_step = b.step("netstack", "Build userspace netstack");
    netstack_step.dependOn(&netstack_cmd.step);
    syscall_custom_module.addImport("console", console_module);
    syscall_custom_module.addImport("hal", hal_module);
    syscall_custom_module.addImport("keyboard", keyboard_module);
    syscall_custom_module.addImport("heap", heap_module);
    syscall_custom_module.addImport("sched", sched_module);
    syscall_custom_module.addImport("usb", usb_module);
    syscall_custom_module.addImport("virtio_input", virtio_input_module);

    // Create syscall random module
    const syscall_random_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/random.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_random_module.addImport("uapi", uapi_module);
    syscall_random_module.addImport("prng", prng_module);
    syscall_random_module.addImport("user_mem", user_mem_module);

    // Create syscall alarm module
    const syscall_alarm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/alarm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_alarm_module.addImport("base.zig", syscall_base_module);
    syscall_alarm_module.addImport("sched", sched_module);

    // Create syscall sysinfo module
    const syscall_sysinfo_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/sysinfo.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_sysinfo_module.addImport("uapi", uapi_module);
    syscall_sysinfo_module.addImport("user_mem", user_mem_module);
    syscall_sysinfo_module.addImport("sched", sched_module);
    syscall_sysinfo_module.addImport("pmm", pmm_module);
    syscall_sysinfo_module.addImport("process", process_module);
    syscall_sysinfo_module.addImport("base.zig", syscall_base_module);

    // Create syscall times module
    const syscall_times_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/times.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_times_module.addImport("uapi", uapi_module);
    syscall_times_module.addImport("user_mem", user_mem_module);
    syscall_times_module.addImport("sched", sched_module);
    syscall_times_module.addImport("base.zig", syscall_base_module);
    syscall_times_module.addImport("process", process_module);

    // Create syscall itimer module
    const syscall_itimer_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/itimer.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_itimer_module.addImport("uapi", uapi_module);
    syscall_itimer_module.addImport("user_mem", user_mem_module);
    syscall_itimer_module.addImport("base.zig", syscall_base_module);

    // Create syscall input module (mouse/input syscalls)
    const syscall_input_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/input.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_input_module.addImport("base.zig", syscall_base_module);
    syscall_input_module.addImport("uapi", uapi_module);
    syscall_input_module.addImport("input", input_module);
    syscall_input_module.addImport("usb", usb_module);

    // Create syscall net module (socket syscalls)
    const syscall_net_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/net/net.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_net_module.addImport("uapi", uapi_module);
    syscall_net_module.addImport("net", net_module);
    syscall_net_module.addImport("sched", sched_module);
    syscall_net_module.addImport("thread", thread_module);
    syscall_net_module.addImport("hal", hal_module);
    syscall_net_module.addImport("user_mem", user_mem_module);
    syscall_net_module.addImport("base.zig", syscall_base_module);
    syscall_net_module.addImport("heap", heap_module);
    syscall_net_module.addImport("fd", fd_module);
    syscall_net_module.addImport("capabilities", capabilities_module);
    syscall_net_module.addImport("console", console_module);

    // Create syscall io_uring module (async I/O syscalls)
    const syscall_io_uring_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/io_uring/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_io_uring_module.addImport("uapi", uapi_module);
    syscall_io_uring_module.addImport("io", kernel_io_module);
    syscall_io_uring_module.addImport("syscall_io", syscall_io_module);
    syscall_io_uring_module.addImport("user_mem", user_mem_module);
    syscall_io_uring_module.addImport("fd", fd_module);
    syscall_io_uring_module.addImport("sched", sched_module);
    syscall_io_uring_module.addImport("hal", hal_module);
    syscall_io_uring_module.addImport("heap", heap_module);
    syscall_io_uring_module.addImport("base.zig", syscall_base_module);
    syscall_io_uring_module.addImport("net", net_module);
    syscall_io_uring_module.addImport("pipe", pipe_module);
    syscall_io_uring_module.addImport("keyboard", keyboard_module);
    syscall_io_uring_module.addImport("thread", thread_module);
    syscall_io_uring_module.addImport("pmm", pmm_module);
    syscall_io_uring_module.addImport("syscall_fd", syscall_fd_module);

    // Create IPC Service Registry module
    const ipc_service_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/ipc/service.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ipc_service_module.addImport("heap", heap_module);
    ipc_service_module.addImport("sync", sync_module);
    ipc_service_module.addImport("process", process_module);
    ipc_service_module.addImport("console", console_module);
    ipc_service_module.addImport("hal", hal_module);

    // Create syscall ipc module (microkernel IPC)
    const syscall_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/misc/ipc.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_ipc_module.addImport("uapi", uapi_module);
    syscall_ipc_module.addImport("user_mem", user_mem_module);
    syscall_ipc_module.addImport("ipc_msg", ipc_msg_module);
    syscall_ipc_module.addImport("process", process_module);
    syscall_ipc_module.addImport("heap", heap_module);
    syscall_ipc_module.addImport("sched", sched_module);
    syscall_ipc_module.addImport("sched", sched_module);
    syscall_ipc_module.addImport("console", console_module);
    syscall_ipc_module.addImport("hal", hal_module);
    syscall_ipc_module.addImport("keyboard", keyboard_module);
    syscall_ipc_module.addImport("mouse", mouse_module);
    syscall_ipc_module.addImport("ipc_service", ipc_service_module);

    // Create syscall SysV IPC module (shared memory, semaphores, message queues)
    const syscall_sysv_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/ipc/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_sysv_ipc_module.addImport("uapi", uapi_module);
    syscall_sysv_ipc_module.addImport("user_mem", user_mem_module);
    syscall_sysv_ipc_module.addImport("sched", sched_module);
    syscall_sysv_ipc_module.addImport("process", process_module);
    syscall_sysv_ipc_module.addImport("kernel_ipc", kernel_ipc_module);

    // Create syscall interrupt module
    const syscall_interrupt_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/interrupt.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_interrupt_module.addImport("uapi", uapi_module);
    syscall_interrupt_module.addImport("hal", hal_module);
    syscall_interrupt_module.addImport("sched", sched_module);
    syscall_interrupt_module.addImport("capabilities", capabilities_module);
    syscall_interrupt_module.addImport("process", process_module);

    // Create syscall port_io module
    const syscall_port_io_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/port_io.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_port_io_module.addImport("uapi", uapi_module);
    syscall_port_io_module.addImport("hal", hal_module);
    syscall_port_io_module.addImport("sched", sched_module);
    syscall_port_io_module.addImport("process", process_module);

    // Create syscall mmio module (MMIO/DMA for userspace drivers)
    const syscall_mmio_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/memory/mmio.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_mmio_module.addImport("base.zig", syscall_base_module);
    syscall_mmio_module.addImport("uapi", uapi_module);
    syscall_mmio_module.addImport("console", console_module);
    syscall_mmio_module.addImport("hal", hal_module);
    syscall_mmio_module.addImport("vmm", vmm_module);
    syscall_mmio_module.addImport("pmm", pmm_module);
    syscall_mmio_module.addImport("heap", heap_module);
    syscall_mmio_module.addImport("user_vmm", user_vmm_module);
    syscall_mmio_module.addImport("kernel_iommu", kernel_iommu_module);

    // Create syscall pci module (PCI enumeration and config access)
    const syscall_pci_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/net/pci_syscall.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_pci_module.addImport("base.zig", syscall_base_module);
    syscall_pci_module.addImport("uapi", uapi_module);
    syscall_pci_module.addImport("console", console_module);
    syscall_pci_module.addImport("pci", pci_module);
    syscall_pci_module.addImport("virt_pci", virt_pci_module);

    // Create ring buffer manager module (kernel/ring.zig)
    const ring_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/proc/ring.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ring_module.addImport("uapi", uapi_module);
    ring_module.addImport("sync", sync_module);
    ring_module.addImport("pmm", pmm_module);
    ring_module.addImport("vmm", vmm_module);
    ring_module.addImport("hal", hal_module);
    ring_module.addImport("futex", futex_module);
    ring_module.addImport("sched", sched_module);
    ring_module.addImport("console", console_module);
    ring_module.addImport("ipc_service", ipc_service_module);

    // Create syscall ring module (ring buffer IPC syscalls)
    const syscall_ring_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/ring.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_ring_module.addImport("uapi", uapi_module);
    syscall_ring_module.addImport("user_mem", user_mem_module);
    syscall_ring_module.addImport("process", process_module);
    syscall_ring_module.addImport("sched", sched_module);
    syscall_ring_module.addImport("ring", ring_module);
    syscall_ring_module.addImport("ipc_service", ipc_service_module);
    syscall_ring_module.addImport("pmm", pmm_module);
    syscall_ring_module.addImport("vmm", vmm_module);
    syscall_ring_module.addImport("hal", hal_module);
    syscall_ring_module.addImport("user_vmm", user_vmm_module);

    // Create syscall hypervisor module (VMware hypercall, hypervisor detection)
    const syscall_hypervisor_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/hypervisor.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_hypervisor_module.addImport("uapi", uapi_module);
    syscall_hypervisor_module.addImport("hal", hal_module);
    syscall_hypervisor_module.addImport("sched", sched_module);
    syscall_hypervisor_module.addImport("process", process_module);
    syscall_hypervisor_module.addImport("user_mem", user_mem_module);

    // Create syscall display module (display mode changes)
    const syscall_display_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/display.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_display_module.addImport("uapi", uapi_module);
    syscall_display_module.addImport("sched", sched_module);
    syscall_display_module.addImport("process", process_module);
    syscall_display_module.addImport("console", console_module);
    syscall_display_module.addImport("video_driver", video_module);

    // Create syscall virt_pci module (virtual PCI device emulation)
    const syscall_virt_pci_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/hw/virt_pci.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_virt_pci_module.addImport("uapi", uapi_module);
    syscall_virt_pci_module.addImport("sched", sched_module);
    syscall_virt_pci_module.addImport("process", process_module);
    syscall_virt_pci_module.addImport("user_mem", user_mem_module);
    syscall_virt_pci_module.addImport("console", console_module);
    syscall_virt_pci_module.addImport("virt_pci", virt_pci_module);
    syscall_virt_pci_module.addImport("caps", capabilities_module);
    syscall_virt_pci_module.addImport("hal", hal_module);
    syscall_virt_pci_module.addImport("pci", pci_module);

    // Create syscall fs_handlers module (mount, umount, unlink)
    const syscall_fs_handlers_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/fs/fs_handlers.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_fs_handlers_module.addImport("base.zig", syscall_base_module);
    syscall_fs_handlers_module.addImport("uapi", uapi_module);
    syscall_fs_handlers_module.addImport("console", console_module);
    syscall_fs_handlers_module.addImport("fs", fs_module);
    syscall_fs_handlers_module.addImport("heap", heap_module);
    syscall_fs_handlers_module.addImport("user_mem", user_mem_module);
    syscall_fs_handlers_module.addImport("capabilities", capabilities_module);
    syscall_fs_handlers_module.addImport("process", process_module);
    syscall_fs_handlers_module.addImport("devfs", devfs_module);
    syscall_fs_handlers_module.addImport("perms", perms_module);
    syscall_fs_handlers_module.addImport("vmm", vmm_module);
    syscall_fs_handlers_module.addImport("syscall_fd", syscall_fd_module);
    syscall_fs_handlers_module.addImport("hal", hal_module);
    syscall_fs_handlers_module.addImport("sched", sched_module);

    // Create syscall flock module (advisory file locking)
    const syscall_flock_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/fs/flock.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_flock_module.addImport("base.zig", syscall_base_module);
    syscall_flock_module.addImport("uapi", uapi_module);
    syscall_flock_module.addImport("fd", fd_module);
    syscall_flock_module.addImport("flock", flock_module);

    // Create syscall dispatch table module
    const syscall_table_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/core/table.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_table_module.addImport("uapi", uapi_module);
    syscall_table_module.addImport("hal", hal_module);
    syscall_table_module.addImport("console", console_module);
    syscall_table_module.addImport("signal", signal_module);
    // Handler modules
    syscall_table_module.addImport("process", syscall_process_module);
    syscall_table_module.addImport("signals", syscall_signals_module);
    syscall_table_module.addImport("scheduling", syscall_scheduling_module);
    syscall_table_module.addImport("io", syscall_io_module);
    syscall_table_module.addImport("fd", syscall_fd_module);
    syscall_table_module.addImport("memory", syscall_memory_module);
    syscall_table_module.addImport("execution", syscall_execution_module);
    syscall_table_module.addImport("custom", syscall_custom_module);
    syscall_table_module.addImport("net", syscall_net_module);
    syscall_table_module.addImport("random", syscall_random_module);
    syscall_table_module.addImport("alarm", syscall_alarm_module);
    syscall_table_module.addImport("sysinfo", syscall_sysinfo_module);
    syscall_table_module.addImport("times", syscall_times_module);
    syscall_table_module.addImport("itimer", syscall_itimer_module);
    syscall_table_module.addImport("input", syscall_input_module);
    syscall_table_module.addImport("io_uring", syscall_io_uring_module);
    syscall_table_module.addImport("ipc", syscall_ipc_module);
    syscall_table_module.addImport("sysv_ipc", syscall_sysv_ipc_module);
    syscall_table_module.addImport("interrupt", syscall_interrupt_module);
    syscall_table_module.addImport("port_io", syscall_port_io_module);
    syscall_table_module.addImport("mmio", syscall_mmio_module);
    syscall_table_module.addImport("pci_syscall", syscall_pci_module);
    syscall_table_module.addImport("ring", syscall_ring_module);
    syscall_table_module.addImport("fs_handlers", syscall_fs_handlers_module);
    syscall_table_module.addImport("flock_syscall", syscall_flock_module);
    syscall_table_module.addImport("hypervisor", syscall_hypervisor_module);
    syscall_table_module.addImport("display", syscall_display_module);
    syscall_table_module.addImport("virt_pci", syscall_virt_pci_module);

    // Create kernel executable
    // NOTE: red_zone must be disabled for kernel code to prevent stack corruption
    // from interrupts. code_model=kernel enables top-2GB addressing.
    const kernel = b.addExecutable(.{
        .name = kernel_elf_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/core/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = if (target_arch == .x86_64) .kernel else .small,
            .pic = false,
            .red_zone = false,
        }),
        // WORKAROUND: Zig 0.16.x has a regression (#25069) where the self-hosted backend
        // doesn't properly use linker scripts. Force LLVM backend to fix higher-half linking.
        .use_llvm = true,
    });

    // Force non-relocatable executable
    kernel.pie = false;

    // Smaller page alignment to reduce ELF file size gaps
    kernel.link_z_max_page_size = 4096;

    // Add module imports to kernel

    kernel.root_module.addImport("boot_info", boot_info_module);
    kernel.root_module.addImport("hal", hal_module);
    kernel.root_module.addImport("acpi", acpi_module);
    kernel.root_module.addImport("pci", pci_module);
    kernel.root_module.addImport("tlb", tlb_module);
    kernel.root_module.addImport("e1000e", e1000e_module);
    kernel.root_module.addImport("ahci", ahci_module);
    if (ide_module) |mod| {
        kernel.root_module.addImport("ide", mod);
    }
    kernel.root_module.addImport("nvme", nvme_module);
    kernel.root_module.addImport("virtio_scsi", virtio_scsi_module);
    kernel.root_module.addImport("usb", usb_module);
    kernel.root_module.addImport("net", net_module);
    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("console", console_module);
    kernel.root_module.addImport("pmm", pmm_module);
    kernel.root_module.addImport("vmm", vmm_module);
    kernel.root_module.addImport("layout", layout_module);
    kernel.root_module.addImport("heap", heap_module);
    kernel.root_module.addImport("sync", sync_module);
    kernel.root_module.addImport("uapi", uapi_module);
    kernel.root_module.addImport("keyboard", keyboard_module);
    kernel.root_module.addImport("serial_driver", serial_module);
    kernel.root_module.addImport("video_driver", video_module);
    kernel.root_module.addImport("mouse", mouse_module);
    kernel.root_module.addImport("partitions", partitions_module);
    kernel.root_module.addImport("input", input_module);
    kernel.root_module.addImport("audio", audio_module);
    kernel.root_module.addImport("thread", thread_module);
    kernel.root_module.addImport("sched", sched_module);
    kernel.root_module.addImport("kernel_stack", kernel_stack_module);
    kernel.root_module.addImport("stack_guard", stack_guard_module);
    kernel.root_module.addImport("prng", prng_module);
    kernel.root_module.addImport("aslr", aslr_module);
    kernel.root_module.addImport("syscall_random", syscall_random_module);
    kernel.root_module.addImport("syscall_table", syscall_table_module);
    kernel.root_module.addImport("framebuffer", framebuffer_module);
    kernel.root_module.addImport("fs", fs_module);
    kernel.root_module.addImport("elf", elf_module);
    kernel.root_module.addImport("process", process_module);
    kernel.root_module.addImport("syscall_base", syscall_base_module);
    kernel.root_module.addImport("signal", signal_module);
    kernel.root_module.addImport("devfs", devfs_module);
    kernel.root_module.addImport("fd", fd_module);
    kernel.root_module.addImport("flock", flock_module);
    kernel.root_module.addImport("io", kernel_io_module);
    kernel.root_module.addImport("capabilities", capabilities_module);
    kernel.root_module.addImport("syscall_ipc", syscall_ipc_module);
    kernel.root_module.addImport("futex", futex_module);
    kernel.root_module.addImport("vdso", vdso_module);
    kernel.root_module.addImport("kernel_iommu", kernel_iommu_module);
    kernel.root_module.addImport("dma", dma_module);
    kernel.root_module.addImport("virtio", virtio_module);
    kernel.root_module.addImport("virtio_input", virtio_input_module);
    kernel.root_module.addImport("virtio_sound", virtio_sound_module);
    kernel.root_module.addImport("virtio_9p", virtio_9p_module);
    kernel.root_module.addImport("virtio_fs", virtio_fs_module);
    kernel.root_module.addImport("vmmdev", vmmdev_module);
    kernel.root_module.addImport("vboxsf", vboxsf_module);
    kernel.root_module.addImport("vbox", vbox_module);
    if (vmware_module) |mod| {
        kernel.root_module.addImport("vmware", mod);
    }
    if (hgfs_module) |mod| {
        kernel.root_module.addImport("hgfs", mod);
    }
    kernel.root_module.addImport("virt_pci", virt_pci_module);

    // Add architecture-specific assembly and linker script
    switch (target_arch) {
        .x86_64 => {
            kernel.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/asm_helpers.S"));
            kernel.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
            kernel.root_module.addAssemblyFile(b.path("src/arch/x86_64/boot/smp_trampoline.S"));
            kernel.setLinkerScript(b.path("src/arch/x86_64/boot/linker.ld"));
        },
        .aarch64 => {
            kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/boot/entry.S"));
            kernel.root_module.addAssemblyFile(b.path("src/arch/aarch64/lib/asm_helpers.S"));
            kernel.setLinkerScript(b.path("src/arch/aarch64/boot/linker.ld"));
        },
        else => {},
    }

    // Install kernel artifact
    b.installArtifact(kernel);

    // Create flat binary using objcopy
    const kernel_bin = b.addObjCopy(kernel.getEmittedBin(), .{
        .format = .bin,
    });

    // Install the binary
    const install_bin = b.addInstallFile(kernel_bin.getOutput(), "bin/kernel.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    // Create user modules
    // Create syscall library module for user access
    const syscall_lib = b.createModule(.{
        .root_source_file = b.path("src/user/lib/syscall/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    // Need to add uapi dependency to syscall lib
    syscall_lib.addImport("uapi", uapi_module);

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/user/shell/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small, // User code doesn't need kernel code model
    });
    shell_mod.addImport("syscall", user_syscall_lib);
    shell_mod.addImport("libc", user_libc_module);

    const shell = b.addExecutable(.{
        .name = "shell.elf",
        .root_module = shell_mod,
    });
    shell.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        shell.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }
    // shell.entry = .disabled; // let Zig find _start

    // Install shell as ELF (required for proper ELF loading in kernel)
    const install_shell = b.addInstallArtifact(shell, .{});
    b.getInstallStep().dependOn(&install_shell.step);

    const httpd_mod = b.createModule(.{
        .root_source_file = b.path("src/user/httpd/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    httpd_mod.addImport("syscall", user_syscall_lib);
    httpd_mod.addImport("libc", user_libc_module);

    const httpd = b.addExecutable(.{
        .name = "httpd.elf",
        .root_module = httpd_mod,
    });
    httpd.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        httpd.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    // Install httpd as ELF (required for proper ELF loading in kernel)
    const install_httpd = b.addInstallArtifact(httpd, .{});
    b.getInstallStep().dependOn(&install_httpd.step);

    // Build VMware Tools Service (x86_64 only)
    if (target_arch == .x86_64) {
        const vmware_tools_mod = b.createModule(.{
            .root_source_file = b.path("src/user/services/vmware_tools/main.zig"),
            .target = user_target,
            .optimize = optimize,
            .code_model = .small,
        });
        vmware_tools_mod.addImport("syscall", user_syscall_lib);
        vmware_tools_mod.addImport("libc", user_libc_module);

        const vmware_tools = b.addExecutable(.{
            .name = "vmware_tools.elf",
            .root_module = vmware_tools_mod,
        });
        vmware_tools.setLinkerScript(b.path("src/user/linker.ld"));
        vmware_tools.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));

        const install_vmware_tools = b.addInstallArtifact(vmware_tools, .{});
        b.getInstallStep().dependOn(&install_vmware_tools.step);
    }

    // Build QEMU Guest Agent Service
    const qemu_ga_mod = b.createModule(.{
        .root_source_file = b.path("src/user/services/qemu_ga/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    qemu_ga_mod.addImport("syscall", user_syscall_lib);
    qemu_ga_mod.addImport("libc", user_libc_module);

    const qemu_ga = b.addExecutable(.{
        .name = "qemu_ga.elf",
        .root_module = qemu_ga_mod,
    });
    qemu_ga.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        qemu_ga.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const install_qemu_ga = b.addInstallArtifact(qemu_ga, .{});
    b.getInstallStep().dependOn(&install_qemu_ga.step);

    // Build netcfgd (Network Configuration Daemon)
    const netcfgd_mod = b.createModule(.{
        .root_source_file = b.path("src/user/services/netcfgd/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    netcfgd_mod.addImport("syscall", user_syscall_lib);
    netcfgd_mod.addImport("libc", user_libc_module);

    const netcfgd = b.addExecutable(.{
        .name = "netcfgd.elf",
        .root_module = netcfgd_mod,
    });
    netcfgd.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        netcfgd.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const install_netcfgd = b.addInstallArtifact(netcfgd, .{});
    b.getInstallStep().dependOn(&install_netcfgd.step);

    // Build VirtIO-Balloon Driver
    const virtio_balloon_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/virtio_balloon/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    virtio_balloon_mod.addImport("syscall", user_syscall_lib);
    virtio_balloon_mod.addImport("libc", user_libc_module);

    const virtio_balloon = b.addExecutable(.{
        .name = "virtio_balloon.elf",
        .root_module = virtio_balloon_mod,
    });
    virtio_balloon.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        virtio_balloon.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const install_virtio_balloon = b.addInstallArtifact(virtio_balloon, .{});
    b.getInstallStep().dependOn(&install_virtio_balloon.step);

    // Build VirtIO-Console Driver
    const virtio_console_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/virtio_console/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    virtio_console_mod.addImport("syscall", user_syscall_lib);
    virtio_console_mod.addImport("libc", user_libc_module);

    const virtio_console = b.addExecutable(.{
        .name = "virtio_console.elf",
        .root_module = virtio_console_mod,
    });
    virtio_console.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        virtio_console.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const install_virtio_console = b.addInstallArtifact(virtio_console, .{});
    b.getInstallStep().dependOn(&install_virtio_console.step);

    // Build Doom
    // NOTE: Doom uses libc printf/sscanf. On aarch64, we use C shims to work around
    // LLVM's @cVaArg limitation (see https://github.com/ziglang/zig/issues/14096)
    // Create platform hooks module
    const doom_platform_module = b.createModule(.{
        .root_source_file = b.path("src/user/doom/doomgeneric_zk.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    doom_platform_module.addImport("syscall", user_syscall_lib);

    // Create sound module
    const doom_sound_module = b.createModule(.{
        .root_source_file = b.path("src/user/doom/i_sound.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    doom_sound_module.addImport("syscall", user_syscall_lib);
    doom_sound_module.addImport("uapi", user_uapi_module);

    const doom_mod = b.createModule(.{
        .root_source_file = b.path("src/user/doom/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    doom_mod.addImport("syscall", user_syscall_lib);
    doom_mod.addImport("libc", user_libc_module);
    doom_mod.addImport("doomgeneric_zk.zig", doom_platform_module);
    doom_mod.addImport("i_sound.zig", doom_sound_module);

    const doom = b.addExecutable(.{
        .name = "doom.elf",
        .root_module = doom_mod,
    });
    if (target_arch == .x86_64) {
        doom.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
        doom.root_module.addAssemblyFile(b.path("src/user/lib/libc/setjmp.S"));
    }

    // NOTE: uart_driver and ps2_driver removed - source files not yet implemented
    // TODO: Add userspace UART driver (src/user/drivers/uart/main.zig)
    // TODO: Add userspace PS/2 driver (src/user/drivers/ps2/main.zig)

    // NOTE: VirtIO userspace drivers temporarily disabled - need pci_config_read API update
    // The userspace drivers use pci_config_read with (bus, device, func, offset) but the
    // syscall expects u5 for device and u3 for func. Need to add @truncate casts in drivers.
    // TODO: Fix src/user/drivers/virtio_net/main.zig and virtio_blk/main.zig
    //
    // // Create VirtIO-Net Driver module (userspace VirtIO network driver)
    // const virtio_net_driver_mod = b.createModule(.{
    //     .root_source_file = b.path("src/user/drivers/virtio_net/main.zig"),
    //     .target = user_target,
    //     .optimize = optimize,
    //     .code_model = .small,
    // });
    // virtio_net_driver_mod.addImport("syscall", user_syscall_lib);
    // virtio_net_driver_mod.addImport("libc", user_libc_module);
    // virtio_net_driver_mod.addImport("ring", user_ring_lib);
    //
    // const virtio_net_driver = b.addExecutable(.{
    //     .name = "virtio_net_driver.elf",
    //     .root_module = virtio_net_driver_mod,
    // });
    // virtio_net_driver.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    // virtio_net_driver.setLinkerScript(b.path("src/user/linker.ld"));
    // const install_virtio_net_driver = b.addInstallArtifact(virtio_net_driver, .{});
    // b.getInstallStep().dependOn(&install_virtio_net_driver.step);
    //
    // // Create VirtIO-Blk Driver module (userspace VirtIO block driver)
    // const virtio_blk_driver_mod = b.createModule(.{
    //     .root_source_file = b.path("src/user/drivers/virtio_blk/main.zig"),
    //     .target = user_target,
    //     .optimize = optimize,
    //     .code_model = .small,
    // });
    // virtio_blk_driver_mod.addImport("syscall", user_syscall_lib);
    // virtio_blk_driver_mod.addImport("libc", user_libc_module);
    //
    // const virtio_blk_driver = b.addExecutable(.{
    //     .name = "virtio_blk_driver.elf",
    //     .root_module = virtio_blk_driver_mod,
    // });
    // virtio_blk_driver.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    // virtio_blk_driver.setLinkerScript(b.path("src/user/linker.ld"));
    // const install_virtio_blk_driver = b.addInstallArtifact(virtio_blk_driver, .{});
    // b.getInstallStep().dependOn(&install_virtio_blk_driver.step);

    // Add doomgeneric C source files
    doom.root_module.addCSourceFiles(.{
        .root = b.path("src/user/doom/doomgeneric"),
        .files = &.{
            "am_map.c",   "d_event.c",  "d_items.c",    "d_iwad.c",   "d_loop.c",
            "d_main.c",   "d_mode.c",   "d_net.c",      "doomdef.c",  "doomgeneric.c",
            "doomstat.c", "dstrings.c", "dummy.c",      "f_finale.c", "f_wipe.c",
            "g_game.c",   "gusconf.c",  "hu_lib.c",     "hu_stuff.c", "i_cdmus.c",
            "i_endoom.c", "i_input.c",  "i_joystick.c", "i_scale.c",
            "i_system.c",    "i_timer.c",    "i_video.c",  "icon.c", // i_sound.c excluded - using Zig stubs
            "info.c",        "m_argv.c",     "m_bbox.c",   "m_cheat.c",
            "m_config.c",    "m_controls.c", "m_fixed.c",  "m_menu.c",
            "m_misc.c",      "m_random.c",   "memio.c",    "mus2mid.c",
            "p_ceilng.c",    "p_doors.c",    "p_enemy.c",  "p_floor.c",
            "p_inter.c",     "p_lights.c",   "p_map.c",    "p_maputl.c",
            "p_mobj.c",      "p_plats.c",    "p_pspr.c",   "p_saveg.c",
            "p_setup.c",     "p_sight.c",    "p_spec.c",   "p_switch.c",
            "p_telept.c",    "p_tick.c",     "p_user.c",   "r_bsp.c",
            "r_data.c",      "r_draw.c",     "r_main.c",   "r_plane.c",
            "r_segs.c",      "r_sky.c",      "r_things.c", "s_sound.c",
            "sha1.c",        "sounds.c",     "st_lib.c",   "st_stuff.c",
            "statdump.c",    "tables.c",     "v_video.c",  "w_checksum.c",
            "w_file_stdc.c", "w_file.c",     "w_main.c",   "w_wad.c",
            "wi_stuff.c",    "z_zone.c",
        },
        .flags = if (target_arch == .x86_64) &.{
            "-DDOOMGENERIC_RESX=640",
            "-DDOOMGENERIC_RESY=400",
            "-ffreestanding",
            "-nostdlib",
            "-fno-stack-protector",
            "-fno-builtin",
            "-mno-sse",
            "-mno-sse2",
            "-mno-mmx",
            "-mno-red-zone",
            "-fno-sanitize=undefined",
            "-fno-sanitize=alignment",
        } else &.{
            "-DDOOMGENERIC_RESX=640",
            "-DDOOMGENERIC_RESY=400",
            "-ffreestanding",
            "-nostdlib",
            "-fno-stack-protector",
            "-fno-builtin",
            "-fno-sanitize=undefined",
            "-fno-sanitize=alignment",
        },
    });
    doom.root_module.addIncludePath(b.path("src/user/doom/include"));
    doom.root_module.addIncludePath(b.path("src/user/doom/doomgeneric"));

    doom.setLinkerScript(b.path("src/user/linker.ld"));

    // Add C shim for varargs functions on aarch64
    if (target_arch == .aarch64) {
        doom.root_module.addCSourceFile(.{
            .file = b.path("src/user/lib/libc/stdio/shim/printf_shim.c"),
            .flags = &.{
                "-ffreestanding",
                "-nostdlib",
                "-fno-stack-protector",
                "-fno-builtin",
            },
        });
    }

    // Install doom.elf
    const install_doom = b.addInstallArtifact(doom, .{});
    b.getInstallStep().dependOn(&install_doom.step);

    // ============================================================
    // SPICE Agent Service
    // ============================================================
    // Userspace service for SPICE/Proxmox display resolution sync
    const spice_agent_mod = b.createModule(.{
        .root_source_file = b.path("src/user/services/spice_agent/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    spice_agent_mod.addImport("syscall", user_syscall_lib);
    spice_agent_mod.addImport("libc", user_libc_module);

    const spice_agent = b.addExecutable(.{
        .name = "spice_agent.elf",
        .root_module = spice_agent_mod,
    });
    spice_agent.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        spice_agent.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }

    const install_spice_agent = b.addInstallArtifact(spice_agent, .{});
    b.getInstallStep().dependOn(&install_spice_agent.step);

    // Compile C integration tests
    const c_tests = [_][]const u8{
        "test_stdio",
        "test_devnull",
        "test_wait4",
        "test_clock",
        "test_random",
        "test_threads",
        "test_signals_fpu",
        "test_vdso",
        "test_statfs",
        "test_vfs_ops",
        "test_job_control",
    };

    const test_step_build = b.step("build-tests", "Build C integration tests");

    // Select target based on architecture
    const c_test_target = if (target_arch == .aarch64) "aarch64-linux-musl" else "x86_64-linux-musl";

    inline for (c_tests) |test_name| {
        const test_exe = b.addSystemCommand(&.{
            "zig",                       "cc",
            "-target",                   c_test_target,
            "-static",                   "-o",
            "zig-out/bin/" ++ test_name ++ ".elf", "tests/userland/" ++ test_name ++ ".c",
        });
        test_step_build.dependOn(&test_exe.step);
    }

    // Create libc test runner module (Zig wrapper for C test)
    // NOTE: test_libc_fixes uses snprintf. On aarch64, we use C shims to work around
    // LLVM's @cVaArg limitation (see https://github.com/ziglang/zig/issues/14096)
    const test_libc_runner_mod = b.createModule(.{
        .root_source_file = b.path("tests/userland/test_libc_runner.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_libc_runner_mod.addImport("libc", user_libc_module);

    const test_libc_exe = b.addExecutable(.{
        .name = "test_libc_fixes.elf",
        .root_module = test_libc_runner_mod,
    });
    test_libc_exe.root_module.addCSourceFile(.{
        .file = b.path("tests/userland/test_libc_fixes.c"),
        .flags = &.{
            "-ffreestanding",
            "-nostdlib",
            "-mno-red-zone",
            "-fno-stack-protector",
            "-fno-builtin", // Use our libc functions, not compiler builtins
        },
    });
    test_libc_exe.root_module.addIncludePath(b.path("src/user/doom/include"));
    test_libc_exe.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_libc_exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
        test_libc_exe.root_module.addAssemblyFile(b.path("src/user/lib/libc/setjmp.S"));
    }

    // Add C shim for varargs functions on aarch64
    if (target_arch == .aarch64) {
        test_libc_exe.root_module.addCSourceFile(.{
            .file = b.path("src/user/lib/libc/stdio/shim/printf_shim.c"),
            .flags = &.{
                "-ffreestanding",
                "-nostdlib",
                "-fno-stack-protector",
                "-fno-builtin",
            },
        });
    }

    const install_test_libc = b.addInstallArtifact(test_libc_exe, .{});
    b.getInstallStep().dependOn(&install_test_libc.step);

    // TEMP: Commented out due to zig cc cache issues
    // b.getInstallStep().dependOn(test_step_build);

    // ASM Test (Minimal userland sanity check)
    // ASM Test (Minimal userland sanity check)
    const test_asm = b.addExecutable(.{
        .name = "test_asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/tests/test_asm.zig"),
            .target = user_target,
            .optimize = optimize,
        }),
    });
    test_asm.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_asm.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }
    const install_test_asm = b.addInstallArtifact(test_asm, .{});
    b.getInstallStep().dependOn(&install_test_asm.step);

    // writev Test (Zig userland test for writev syscall)
    const test_writev_mod = b.createModule(.{
        .root_source_file = b.path("tests/userland/test_writev.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_writev_mod.addImport("syscall", user_syscall_lib);
    test_writev_mod.addImport("libc", user_libc_module);

    const test_writev = b.addExecutable(.{
        .name = "test_writev",
        .root_module = test_writev_mod,
    });
    test_writev.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_writev.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }
    const install_test_writev = b.addInstallArtifact(test_writev, .{});
    b.getInstallStep().dependOn(&install_test_writev.step);

    // Audio Test
    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/user/tests/audio_test.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    audio_test_mod.addImport("syscall", user_syscall_lib);
    audio_test_mod.addImport("libc", user_libc_module);

    const audio_test = b.addExecutable(.{
        .name = "audio_test",
        .root_module = audio_test_mod,
    });
    audio_test.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        audio_test.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }
    const install_audio_test = b.addInstallArtifact(audio_test, .{});
    b.getInstallStep().dependOn(&install_audio_test.step);

    // Sound Test
    const sound_test_mod = b.createModule(.{
        .root_source_file = b.path("src/user/tests/sound_test.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    sound_test_mod.addImport("syscall", user_syscall_lib);
    sound_test_mod.addImport("libc", user_libc_module);
    sound_test_mod.addImport("uapi", user_uapi_module);

    const sound_test = b.addExecutable(.{
        .name = "sound_test",
        .root_module = sound_test_mod,
    });
    sound_test.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        sound_test.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
    }
    const install_sound_test = b.addInstallArtifact(sound_test, .{});
    b.getInstallStep().dependOn(&install_sound_test.step);

    // Test Runner (Integration Tests)
    const test_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/user/test_runner/main.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_runner_mod.addImport("syscall", user_syscall_lib);

    const test_runner = b.addExecutable(.{
        .name = "test_runner.elf",
        .root_module = test_runner_mod,
    });
    test_runner.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_runner.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
        test_runner.root_module.addAssemblyFile(b.path("src/user/crt0.S"));
    } else if (target_arch == .aarch64) {
        test_runner.root_module.addAssemblyFile(b.path("src/arch/aarch64/lib/crt0.S"));
    }
    const install_test_runner = b.addInstallArtifact(test_runner, .{});
    b.getInstallStep().dependOn(&install_test_runner.step);

    // Test Binary (Simple exec target for integration tests)
    const test_binary_mod = b.createModule(.{
        .root_source_file = b.path("src/user/test_binary/main.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_binary_mod.addImport("syscall", user_syscall_lib);

    const test_binary = b.addExecutable(.{
        .name = "test_binary.elf",
        .root_module = test_binary_mod,
    });
    test_binary.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_binary.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
        test_binary.root_module.addAssemblyFile(b.path("src/user/crt0.S"));
    } else if (target_arch == .aarch64) {
        test_binary.root_module.addAssemblyFile(b.path("src/arch/aarch64/lib/crt0.S"));
    }
    const install_test_binary = b.addInstallArtifact(test_binary, .{});
    b.getInstallStep().dependOn(&install_test_binary.step);

    // Libc Fix Verification Test (Native C with Custom Libc)
    // Uses C shim for aarch64 va_list bootstrap
    // Wrapper and C source definition below

    // Create a wrapper to link against libc and crt0
    // Create a dummy entry file if needed, or better:
    // Actually, create module with just the C file?
    // b.createModule doesn't take C files easily as root.
    // Use a small Zig wrapper "src/user/test_libc_fix_entry.zig" that imports libc and exports nothing, relying on C main.

    // Waiting for file creation in next step, assuming path "src/user/tests/test_libc_fix_wrapper.zig"
    // Let's create the wrapper content inline if possible or use write_to_file next.
    // For now I define the build step, pointing to a wrapper I will create.
    const test_libc_fix_mod = b.createModule(.{
        .root_source_file = b.path("src/user/tests/test_libc_fix_wrapper.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_libc_fix_mod.addImport("libc", user_libc_module);
    test_libc_fix_mod.addImport("syscall", user_syscall_lib);

    const test_libc_fix_exe = b.addExecutable(.{
        .name = "test_libc_fix",
        .root_module = test_libc_fix_mod,
    });
    test_libc_fix_exe.root_module.addCSourceFile(.{
        .file = b.path("tests/userland/test_libc_fix.c"),
        .flags = &.{ "-nostdlib", "-ffreestanding", "-I", "src/user/doom/include" },
    });
    test_libc_fix_exe.setLinkerScript(b.path("src/user/linker.ld"));
    if (target_arch == .x86_64) {
        test_libc_fix_exe.root_module.addAssemblyFile(b.path("src/arch/x86_64/lib/memcpy.S"));
        test_libc_fix_exe.root_module.addAssemblyFile(b.path("src/user/crt0.S"));
        test_libc_fix_exe.root_module.addAssemblyFile(b.path("src/user/lib/libc/setjmp.S"));
    } else if (target_arch == .aarch64) {
        test_libc_fix_exe.root_module.addAssemblyFile(b.path("src/arch/aarch64/lib/crt0.S"));
        // aarch64: Use C shim for va_list bootstrap
        test_libc_fix_exe.root_module.addCSourceFile(.{
            .file = b.path("src/user/lib/libc/stdio/shim/printf_shim.c"),
            .flags = &.{ "-nostdlib", "-ffreestanding" },
        });
    }
    const install_test_libc_fix = b.addInstallArtifact(test_libc_fix_exe, .{});
    // TEMP: Commented out due to errno.h issue
    _ = install_test_libc_fix;
    // b.getInstallStep().dependOn(&install_test_libc_fix.step);

    // Create UEFI-only ISO build step
    // Uses custom UEFI bootloader (no Limine dependency)
    // Creates a proper UEFI-bootable ISO with embedded EFI System Partition
    const efi_loader_ext = b.fmt("{s}.efi", .{efi_loader_name});
    const iso_script = b.fmt(
        \\set -e && \
        \\rm -rf iso_root efi.img && \
        \\mkdir -p iso_root/EFI/BOOT && \
        \\cp zig-out/bin/{s} iso_root/EFI/BOOT/{s} && \
        \\cp zig-out/bin/{s} iso_root/ && \
        \\mkdir -p .zig-cache && \
        \\tmp_initrd=".zig-cache/esp_initrd.tar" && \
        \\rm -rf .zig-cache/initrd_root && \
        \\mkdir -p .zig-cache/initrd_root && \
        \\if [ -d initrd_contents ] && [ "$(ls -A initrd_contents 2>/dev/null)" ]; then \
        \\    cp -R initrd_contents/. .zig-cache/initrd_root/; \
        \\fi && \
        \\if [ -d zig-out/bin ] && [ "$(ls -A zig-out/bin 2>/dev/null)" ]; then \
        \\    for f in zig-out/bin/*; do \
        \\        base="$(basename "$f")"; \
        \\        case "$base" in \
        \\            {s}|{s}.pdb|kernel-*.elf|kernel.bin|disk_image) continue ;; \
        \\        esac; \
        \\        cp "$f" .zig-cache/initrd_root/; \
        \\    done; \
        \\fi && \
        \\if [ "$(ls -A .zig-cache/initrd_root 2>/dev/null)" ]; then \
        \\    echo "Creating initrd.tar..." && \
        \\    tar --format=ustar -cvf "$tmp_initrd" -C .zig-cache/initrd_root .; \
        \\fi && \
        \\echo "Creating EFI boot image..." && \
        \\dd if=/dev/zero of=efi.img bs=1M count=128 2>/dev/null && \
        \\mformat -i efi.img -F :: && \
        \\mmd -i efi.img ::/EFI && \
        \\mmd -i efi.img ::/EFI/BOOT && \
        \\mcopy -i efi.img zig-out/bin/{s} ::/EFI/BOOT/{s} && \
        \\mcopy -i efi.img zig-out/bin/{s} :: && \
        \\if [ -f "$tmp_initrd" ]; then \
        \\    mcopy -i efi.img "$tmp_initrd" ::/initrd.tar; \
        \\fi && \
        \\rm -f "$tmp_initrd" && \
        \\rm -rf .zig-cache/initrd_root && \
        \\cp efi.img iso_root/ && \
        \\xorriso -as mkisofs \
        \\    -r -V "ZK" \
        \\    -e efi.img \
        \\    -no-emul-boot \
        \\    -isohybrid-gpt-basdat \
        \\    iso_root -o zk.iso && \
        \\rm -f efi.img && \
        \\echo "UEFI ISO created: zk.iso"
    , .{ efi_loader_ext, efi_boot_file, kernel_elf_name, efi_loader_ext, efi_loader_name, efi_loader_ext, efi_boot_file, kernel_elf_name });
    const iso_cmd = b.addSystemCommand(&.{ "sh", "-c", iso_script });
    // TEMP: Commented out due to zig cc cache issues
    // iso_cmd.step.dependOn(test_step_build);
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable UEFI ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Create run step for QEMU (UEFI boot via ISO or FAT directory)
    const qemu_cmd = if (target_arch == .aarch64) "qemu-system-aarch64" else "qemu-system-x86_64";
    const qemu_machine = if (target_arch == .aarch64) "virt,gic-version=2" else "q35";

    const run_cmd = b.addSystemCommand(&.{qemu_cmd});

    if (target_arch == .aarch64) {
        // AArch64-specific QEMU options
        run_cmd.addArgs(&.{
            "-machine", qemu_machine,
            "-cpu", "max",
            "-m", "512M",
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
        });
        // Configure display and serial for console I/O
        if (qemu_nographic) {
            // For -nographic mode on macOS, use explicit chardev for proper stdin handling
            // signal=off prevents QEMU from intercepting Ctrl+C on macOS
            run_cmd.addArgs(&.{
                "-display", "none",
                "-chardev", "stdio,id=char0,mux=on,signal=off",
                "-serial", "chardev:char0",
                "-mon", "chardev=char0",
            });
        } else {
            run_cmd.addArgs(&.{
                "-device", "ramfb", // Simple framebuffer for UEFI GOP (no driver needed)
                "-serial", "stdio",
            });
        }
        run_cmd.addArgs(&.{
            "-smp", "1", // Single-core for initial bring-up
            "-no-reboot",
            "-no-shutdown",
            "-accel", "hvf", // Use Hypervisor.framework on Apple Silicon
        });
    } else {
        // x86_64-specific QEMU options
        // Note: We don't use USB keyboard on x86_64 because QEMU TCG has USB transfer
        // timeout issues. Instead, keyboard input goes to the built-in i8042 PS/2 controller.
        // USB tablet is still used for mouse input (absolute positioning).
        run_cmd.addArgs(&.{
            "-machine", qemu_machine,
            "-m", "512M",
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-tablet",
            "-device", "virtio-keyboard-pci", // VirtIO keyboard for reliable input on macOS TCG
        });
        // Only add VGA if not using -nographic
        if (!qemu_nographic) {
            run_cmd.addArgs(&.{ "-vga", "std" });
        }
        run_cmd.addArgs(&.{ "-audiodev", b.fmt("{s},id=audio0", .{qemu_audio}) });
        run_cmd.addArgs(&.{
            "-device", "AC97,audiodev=audio0",
        });
        // Configure serial port for console I/O
        if (qemu_nographic) {
            // For -nographic mode on macOS, use explicit chardev for proper stdin handling
            // signal=off prevents QEMU from intercepting Ctrl+C on macOS
            // We also add -display none since we'll filter out -nographic from extra args
            run_cmd.addArgs(&.{
                "-display", "none",
                "-chardev", "stdio,id=char0,mux=on,signal=off",
                "-serial", "chardev:char0",
                "-mon", "chardev=char0",
            });
        } else {
            run_cmd.addArgs(&.{ "-serial", "stdio" });
        }
        run_cmd.addArgs(&.{
            "-smp", "1",
            "-no-reboot",
            "-no-shutdown",
            "-accel", "tcg,thread=multi",
            // USB Mass Storage (optional)
            "-drive", "if=none,id=usbdisk,format=raw,file=usb_disk.img",
        });
    }

    if (run_iso) {
        // Boot hybrid ISO as hard disk - bypasses EDK2 El Torito bug
        // The -isohybrid-gpt-basdat xorriso option creates a GPT on the ISO
        if (target_arch == .aarch64) {
            run_cmd.addArgs(&.{
                "-drive", "file=zk.iso,format=raw,if=none,id=bootdisk",
                "-device", "virtio-blk-pci,drive=bootdisk,bootindex=1",
            });
        } else {
            run_cmd.addArgs(&.{
                "-drive", "file=zk.iso,format=raw,if=none,id=bootdisk",
                "-device", "ide-hd,drive=bootdisk,bus=ide.0,bootindex=1",
            });
        }
    } else {
        // Use a real FAT disk image for UEFI boot (fat:rw: doesn't work with UEFI)
        // The disk.img is created by the pre-build step
        if (target_arch == .aarch64) {
            run_cmd.addArgs(&.{
                "-drive", "if=none,format=raw,id=esp,file=disk.img",
                "-device", "virtio-blk-pci,drive=esp,bootindex=1",
            });
        } else {
            run_cmd.addArgs(&.{
                "-drive", "if=none,format=raw,id=esp,file=disk.img",
                "-device", "ide-hd,drive=esp,bus=ide.0,bootindex=1",
            });
        }
    }

    // SFS storage disk (aarch64 uses VirtIO-SCSI, x86_64 uses AHCI on boot disk)
    if (target_arch == .aarch64) {
        run_cmd.addArgs(&.{
            "-device", "virtio-scsi-pci,id=scsi0",
            "-drive", "file=sfs.img,format=raw,if=none,id=sfsdisk",
            "-device", "scsi-hd,drive=sfsdisk,bus=scsi0.0",
        });
    }

    // USB hub and storage (x86_64 only for now)
    if (target_arch == .x86_64) {
        if (qemu_usb_hub) {
            run_cmd.addArgs(&.{
                "-device", "usb-hub,bus=xhci.0,id=hub0",
                "-device", "usb-storage,drive=usbdisk,bus=hub0.0",
            });
        } else {
            run_cmd.addArgs(&.{
                "-device", "usb-storage,drive=usbdisk",
            });
        }
    }

    // NVMe storage device (for testing NVMe driver)
    if (qemu_nvme) {
        run_cmd.addArgs(&.{
            "-drive", "file=nvme_test.img,format=raw,if=none,id=nvmedisk",
            "-device", "nvme,serial=ZKNVME01,drive=nvmedisk",
        });
    }

    // VirtIO-9P shared folder (for host-guest file sharing)
    if (qemu_virtfs) |virtfs_path| {
        run_cmd.addArgs(&.{
            "-virtfs",
            b.fmt("local,path={s},mount_tag=hostshare,security_model=passthrough", .{virtfs_path}),
        });
    }

    // Add display option (default = let QEMU auto-detect)
    if (!std.mem.eql(u8, qemu_display, "default")) {
        run_cmd.addArgs(&.{ "-display", qemu_display });
    }

    // UEFI firmware (required for UEFI boot)
    if (qemu_bios) |bios_path| {
        if (std.mem.endsWith(u8, bios_path, ".fd") or std.mem.endsWith(u8, bios_path, ".FD")) {
            run_cmd.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{bios_path}) });
            if (qemu_vars) |vars_path| {
                run_cmd.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,file={s}", .{vars_path}) });
            }
        } else {
            run_cmd.addArgs(&.{ "-bios", bios_path });
        }
    }

    // Add extra QEMU arguments (for workarounds like -nographic on macOS TCG)
    if (qemu_extra_args) |extra| {
        // Split space-separated args and add them
        var iter = std.mem.splitScalar(u8, extra, ' ');
        while (iter.next()) |arg| {
            if (arg.len > 0) {
                // Skip -nographic since we handle it explicitly with chardev above
                // (explicit chardev with signal=off is required for stdin on macOS)
                if (qemu_nographic and std.mem.eql(u8, arg, "-nographic")) continue;
                run_cmd.addArg(arg);
            }
        }
    }

    // Install UEFI bootloader and kernel to efi_root directory
    const install_uefi = b.addInstallFile(bootloader.getEmittedBin(), b.fmt("efi_root/EFI/BOOT/{s}", .{efi_boot_file}));
    const install_kernel_uefi = b.addInstallFile(kernel.getEmittedBin(), b.fmt("efi_root/{s}", .{kernel_elf_name}));
    const startup_nsh_source = if (target_arch == .aarch64) "src/boot/uefi/startup-aarch64.nsh" else "src/boot/uefi/startup-x86_64.nsh";
    const install_startup_nsh = b.addInstallFile(b.path(startup_nsh_source), "efi_root/startup.nsh");
    b.getInstallStep().dependOn(&install_uefi.step);
    b.getInstallStep().dependOn(&install_kernel_uefi.step);
    b.getInstallStep().dependOn(&install_startup_nsh.step);

    // Create esp_part.img (Raw FAT filesystem)
    const esp_script = b.fmt(
        \\set -e && \
        \\dd if=/dev/zero of=esp_part.img bs=1M count=128 2>/dev/null && \
        \\mformat -i esp_part.img -H 2048 :: && \
        \\mmd -i esp_part.img ::/EFI && \
        \\mmd -i esp_part.img ::/EFI/BOOT && \
        \\mcopy -i esp_part.img zig-out/bin/{s} ::/EFI/BOOT/{s} && \
        \\mcopy -i esp_part.img zig-out/bin/{s} :: && \
        \\mcopy -i esp_part.img {s} :: && \
        \\mkdir -p .zig-cache && \
        \\tmp_initrd=".zig-cache/esp_initrd.tar" && \
        \\rm -rf .zig-cache/initrd_root && \
        \\mkdir -p .zig-cache/initrd_root && \
        \\if [ -d initrd_contents ] && [ "$(ls -A initrd_contents 2>/dev/null)" ]; then \
        \\    cp -R initrd_contents/. .zig-cache/initrd_root/; \
        \\fi && \
        \\if [ -d zig-out/bin ] && [ "$(ls -A zig-out/bin 2>/dev/null)" ]; then \
        \\    for f in zig-out/bin/*; do \
        \\        base="$(basename "$f")"; \
        \\        case "$base" in \
        \\            {s}|{s}.pdb|kernel-*.elf|kernel.bin|disk_image) continue ;; \
        \\        esac; \
        \\        cp "$f" .zig-cache/initrd_root/; \
        \\    done; \
        \\fi && \
        \\if [ "$(ls -A .zig-cache/initrd_root 2>/dev/null)" ]; then \
        \\    echo "Creating initrd.tar..." && \
        \\    tar --format=ustar -cvf "$tmp_initrd" -C .zig-cache/initrd_root .; \
        \\fi && \
        \\if [ -f "$tmp_initrd" ]; then \
        \\    mcopy -i esp_part.img "$tmp_initrd" ::/initrd.tar; \
        \\fi && \
        \\rm -f "$tmp_initrd" && \
        \\rm -rf .zig-cache/initrd_root
    , .{ efi_loader_ext, efi_boot_file, kernel_elf_name, startup_nsh_source, efi_loader_ext, efi_loader_name });
    const create_esp_cmd = b.addSystemCommand(&.{ "sh", "-c", esp_script });
    create_esp_cmd.step.dependOn(&install_uefi.step);
    create_esp_cmd.step.dependOn(&install_kernel_uefi.step);
    create_esp_cmd.step.dependOn(b.getInstallStep()); // Ensure bootloader is installed to zig-out/bin/

    // Build disk_image tool
    const disk_image_tool = b.addExecutable(.{
        .name = "disk_image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/disk_image.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const install_disk_image_tool = b.addInstallArtifact(disk_image_tool, .{});

    // Run disk_image tool to create disk.img
    const create_disk_img = b.addRunArtifact(disk_image_tool);
    create_disk_img.addFileArg(b.path("esp_part.img")); // Input FAT FS
    create_disk_img.addArg("disk.img");      // Output GPT disk path
    create_disk_img.step.dependOn(&create_esp_cmd.step);
    create_disk_img.step.dependOn(&install_disk_image_tool.step);

    if (run_iso) {
        run_cmd.step.dependOn(&iso_cmd.step);
    } else {
        run_cmd.step.dependOn(&create_disk_img.step);
    }

    const run_step = b.step("run", "Build and run the kernel in QEMU (UEFI)");
    run_step.dependOn(&run_cmd.step);

    // Host-side unit tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    const test_config_options = b.addOptions();
    test_config_options.addOption([]const u8, "version", version);
    test_config_options.addOption([]const u8, "name", kernel_name);
    test_config_options.addOption(usize, "max_threads", max_threads);
    test_config_options.addOption(u32, "timer_hz", timer_hz);
    test_config_options.addOption(u32, "serial_baud", serial_baud);
    test_config_options.addOption(bool, "debug_memory", debug_memory);
    test_config_options.addOption(usize, "heap_size", heap_size_opt);
    test_config_options.addOption(usize, "default_stack_size", stack_size);
    test_config_options.addOption(bool, "debug_enabled", debug_enabled);
    test_config_options.addOption(bool, "debug_scheduler", debug_scheduler);
    test_config_options.addOption(bool, "debug_network", debug_network);

    const test_config_module = test_config_options.createModule();

    const heap_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/heap.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    heap_test_module.addImport("config", test_config_module);

    test_module.addImport("heap", heap_test_module);
    const slab_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/mm/slab.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    slab_test_module.addImport("config", test_config_module);

    heap_test_module.addImport("slab", slab_test_module);
    test_module.addImport("slab", slab_test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    // Syscall unit tests (isolated, no kernel dependencies)
    const syscall_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sys/syscall/tests/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    // Add minimal dependencies for syscall tests
    syscall_test_module.addImport("fs", fs_module);
    syscall_test_module.addImport("uapi", uapi_module);

    const syscall_unit_tests = b.addTest(.{
        .root_module = syscall_test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_syscall_unit_tests = b.addRunArtifact(syscall_unit_tests);

    const test_step = b.step("test", "Run unit tests on host");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_syscall_unit_tests.step);

    // =========================================================================
    // Architecture-specific convenience steps (aliases)
    // =========================================================================

    // iso-x86_64: Build x86_64 ISO
    const iso_x86_64_cmd = b.addSystemCommand(&.{
        "sh", "-c", "zig build iso -Darch=x86_64",
    });
    const iso_x86_64_step = b.step("iso-x86_64", "Build bootable x86_64 UEFI ISO");
    iso_x86_64_step.dependOn(&iso_x86_64_cmd.step);

    // iso-aarch64: Build aarch64 ISO
    const iso_aarch64_cmd = b.addSystemCommand(&.{
        "sh", "-c", "zig build iso -Darch=aarch64",
    });
    const iso_aarch64_step = b.step("iso-aarch64", "Build bootable aarch64 UEFI ISO");
    iso_aarch64_step.dependOn(&iso_aarch64_cmd.step);

    // run-x86_64: Build and run x86_64 in QEMU
    const run_x86_64_cmd = b.addSystemCommand(&.{
        "sh", "-c", "zig build run -Darch=x86_64",
    });
    const run_x86_64_step = b.step("run-x86_64", "Build and run x86_64 kernel in QEMU");
    run_x86_64_step.dependOn(&run_x86_64_cmd.step);

    // run-aarch64: Build and run aarch64 in QEMU
    const run_aarch64_cmd = b.addSystemCommand(&.{
        "sh", "-c", "zig build run -Darch=aarch64",
    });
    const run_aarch64_step = b.step("run-aarch64", "Build and run aarch64 kernel in QEMU");
    run_aarch64_step.dependOn(&run_aarch64_cmd.step);

    // Kernel test runner target (integration tests in QEMU)
    const test_kernel_cmd = b.addSystemCommand(&.{
        "bash",
        "-c",
        "scripts/run_tests.sh",
    });
    test_kernel_cmd.step.dependOn(b.getInstallStep());

    const test_kernel_step = b.step("test-kernel", "Run integration tests in QEMU");
    test_kernel_step.dependOn(&test_kernel_cmd.step);
}
