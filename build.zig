const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Freestanding x86_64 target for kernel
    // code_model=kernel disables Red Zone; we keep SSE enabled to avoid
    // soft_float issues, but kernel code must save/restore FPU state in interrupts
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // ============================================================
    // Build-time Configuration Options
    // ============================================================
    const version = b.option([]const u8, "version", "Kernel version string") orelse "0.1.0";
    const kernel_name = b.option([]const u8, "name", "Kernel name") orelse "ZigK";
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
    const qemu_bios = b.option([]const u8, "bios", "Path to BIOS/UEFI firmware (e.g. OVMF.fd) for QEMU");

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

    // Create Limine module (boot protocol parsing)
    const limine_module = b.createModule(.{
        .root_source_file = b.path("src/lib/limine.zig"),
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
        .root_source_file = b.path("src/kernel/sync.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    sync_module.addImport("hal", hal_module);

    // Create console module (debug output)
    const console_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/debug/console.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    console_module.addImport("hal", hal_module);
    console_module.addImport("config", config_module);

    // Create ACPI module (RSDP/MCFG parsing for PCIe ECAM)
    const acpi_module = b.createModule(.{
        .root_source_file = b.path("src/arch/x86_64/acpi/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    acpi_module.addImport("hal", hal_module);
    acpi_module.addImport("console", console_module);

    // Create PMM module (Physical Memory Manager)
    const pmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/pmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    pmm_module.addImport("hal", hal_module);
    pmm_module.addImport("console", console_module);
    pmm_module.addImport("config", config_module);
    pmm_module.addImport("limine", limine_module);
    pmm_module.addImport("sync", sync_module);

    // Create VMM module (Virtual Memory Manager)
    const vmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/vmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    vmm_module.addImport("hal", hal_module);
    vmm_module.addImport("console", console_module);
    vmm_module.addImport("config", config_module);
    vmm_module.addImport("pmm", pmm_module);

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


    // Create E1000e driver module (Intel 82574L NIC)
    const e1000e_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/net/e1000e.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    e1000e_module.addImport("hal", hal_module);
    e1000e_module.addImport("pci", pci_module);
    e1000e_module.addImport("vmm", vmm_module);
    e1000e_module.addImport("pmm", pmm_module);
    e1000e_module.addImport("sync", sync_module);
    e1000e_module.addImport("console", console_module);


    // Create PRNG module (Kernel entropy/random)
    const prng_module = b.createModule(.{
        .root_source_file = b.path("src/lib/prng.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    prng_module.addImport("hal", hal_module);
    prng_module.addImport("sync", sync_module);

    // Create Network Stack module (full stack: core, ethernet, ipv4, transport)
    const net_module = b.createModule(.{
        .root_source_file = b.path("src/net/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    net_module.addImport("hal", hal_module);
    net_module.addImport("uapi", uapi_module);
    net_module.addImport("prng", prng_module);



    // Create Heap module (Kernel Heap Allocator)
    const heap_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/heap.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    heap_module.addImport("console", console_module);
    heap_module.addImport("config", config_module);
    heap_module.addImport("sync", sync_module);

    // Create Thread module (Thread management and creation)
    const thread_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/thread.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    thread_module.addImport("hal", hal_module);
    thread_module.addImport("pmm", pmm_module);
    thread_module.addImport("vmm", vmm_module);
    thread_module.addImport("heap", heap_module);
    thread_module.addImport("console", console_module);
    thread_module.addImport("config", config_module);

    // Create Scheduler module (Thread scheduling)
    const sched_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sched.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    sched_module.addImport("hal", hal_module);
    sched_module.addImport("thread", thread_module);
    sched_module.addImport("sync", sync_module);
    sched_module.addImport("console", console_module);
    sched_module.addImport("config", config_module);

    // Create Stack Guard module (stack canary support)
    const stack_guard_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/stack_guard.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    stack_guard_module.addImport("hal", hal_module);
    stack_guard_module.addImport("console", console_module);
    stack_guard_module.addImport("prng", prng_module);



    // Create FD module (File Descriptor table)
    const fd_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/fd.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    fd_module.addImport("heap", heap_module);
    fd_module.addImport("console", console_module);
    fd_module.addImport("uapi", uapi_module);

    // Create User VMM module (userspace memory management for mmap/munmap)
    const user_vmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/user_vmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    user_vmm_module.addImport("hal", hal_module);
    user_vmm_module.addImport("vmm", vmm_module);
    user_vmm_module.addImport("pmm", pmm_module);
    user_vmm_module.addImport("heap", heap_module);
    user_vmm_module.addImport("console", console_module);
    user_vmm_module.addImport("uapi", uapi_module);

    // Create Ring Buffer module (generic circular buffer)
    const ring_buffer_module = b.createModule(.{
        .root_source_file = b.path("src/lib/ring_buffer.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create Keyboard driver module
    const keyboard_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/keyboard.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    keyboard_module.addImport("hal", hal_module);
    keyboard_module.addImport("sync", sync_module);
    keyboard_module.addImport("ring_buffer", ring_buffer_module);
    keyboard_module.addImport("console", console_module);
    keyboard_module.addImport("uapi", uapi_module);

    // Create DevFS module (device filesystem shim)
    const devfs_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/devfs.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    devfs_module.addImport("fd", fd_module);
    devfs_module.addImport("console", console_module);
    devfs_module.addImport("hal", hal_module);
    devfs_module.addImport("keyboard", keyboard_module);
    devfs_module.addImport("sched", sched_module);
    devfs_module.addImport("uapi", uapi_module);

    // Create Process module (process abstraction for fork/exec/wait)
    const process_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/process.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    process_module.addImport("heap", heap_module);
    process_module.addImport("console", console_module);
    process_module.addImport("fd", fd_module);
    process_module.addImport("devfs", devfs_module);
    process_module.addImport("user_vmm", user_vmm_module);
    process_module.addImport("vmm", vmm_module);
    process_module.addImport("pmm", pmm_module);
    process_module.addImport("hal", hal_module);
    process_module.addImport("uapi", uapi_module);

    // Create ELF loader module (for execve)
    const elf_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/elf.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    elf_module.addImport("hal", hal_module);
    elf_module.addImport("vmm", vmm_module);
    elf_module.addImport("pmm", pmm_module);
    elf_module.addImport("heap", heap_module);
    elf_module.addImport("console", console_module);
    elf_module.addImport("uapi", uapi_module);

    // Create framebuffer module (for fb syscalls)
    const framebuffer_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/framebuffer.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    framebuffer_module.addImport("limine", limine_module);
    framebuffer_module.addImport("console", console_module);

    // Create syscall random module
    const syscall_random_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/random.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_random_module.addImport("uapi", uapi_module);
    syscall_random_module.addImport("prng", prng_module);

    // Create syscall net module (socket syscalls)
    const syscall_net_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/net.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_net_module.addImport("uapi", uapi_module);
    syscall_net_module.addImport("net", net_module);
    syscall_net_module.addImport("sched", sched_module);
    syscall_net_module.addImport("thread", thread_module);
    syscall_net_module.addImport("hal", hal_module);

    // Create syscall handlers module
    const syscall_handlers_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/handlers.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_handlers_module.addImport("uapi", uapi_module);
    syscall_handlers_module.addImport("console", console_module);
    syscall_handlers_module.addImport("hal", hal_module);
    syscall_handlers_module.addImport("sched", sched_module);
    syscall_handlers_module.addImport("keyboard", keyboard_module);
    syscall_handlers_module.addImport("thread", thread_module);
    syscall_handlers_module.addImport("fd", fd_module);
    syscall_handlers_module.addImport("devfs", devfs_module);
    syscall_handlers_module.addImport("user_vmm", user_vmm_module);
    syscall_handlers_module.addImport("process", process_module);
    syscall_handlers_module.addImport("vmm", vmm_module);
    syscall_handlers_module.addImport("pmm", pmm_module);
    syscall_handlers_module.addImport("heap", heap_module);
    syscall_handlers_module.addImport("elf", elf_module);
    syscall_handlers_module.addImport("framebuffer", framebuffer_module);

    // Create syscall dispatch table module
    const syscall_table_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/table.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_table_module.addImport("uapi", uapi_module);
    syscall_table_module.addImport("hal", hal_module);
    syscall_table_module.addImport("console", console_module);
    syscall_table_module.addImport("handlers.zig", syscall_handlers_module);
    syscall_table_module.addImport("random.zig", syscall_random_module);
    syscall_table_module.addImport("net.zig", syscall_net_module);

    // Create kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .kernel,
            .pic = false,
        }),
    });

    // Force non-relocatable executable
    kernel.pie = false;

    // Note: Zig's internal linker ignores some linker script features (virtual addresses).
    // For now, we rely on Limine loading at physical addresses and setting up HHDM.
    // The kernel accesses its own code via identity mapping provided by Limine.

    // Smaller page alignment to reduce ELF file size gaps
    kernel.link_z_max_page_size = 4096;


    // Add module imports to kernel

    kernel.root_module.addImport("limine", limine_module);
    kernel.root_module.addImport("hal", hal_module);
    kernel.root_module.addImport("acpi", acpi_module);
    kernel.root_module.addImport("pci", pci_module);
    kernel.root_module.addImport("e1000e", e1000e_module);
    kernel.root_module.addImport("net", net_module);
    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("console", console_module);
    kernel.root_module.addImport("pmm", pmm_module);
    kernel.root_module.addImport("vmm", vmm_module);
    kernel.root_module.addImport("heap", heap_module);
    kernel.root_module.addImport("sync", sync_module);
    kernel.root_module.addImport("uapi", uapi_module);
    kernel.root_module.addImport("keyboard", keyboard_module);
    kernel.root_module.addImport("thread", thread_module);
    kernel.root_module.addImport("sched", sched_module);
    kernel.root_module.addImport("stack_guard", stack_guard_module);
    kernel.root_module.addImport("prng", prng_module);
    kernel.root_module.addImport("syscall_random", syscall_random_module);
    kernel.root_module.addImport("syscall_table", syscall_table_module);
    kernel.root_module.addImport("framebuffer", framebuffer_module);

    // Add assembly helpers for x86_64 (ISR stubs, lgdt, lidt)
    kernel.addAssemblyFile(b.path("src/arch/x86_64/asm_helpers.S"));

    // Note: boot32.S is no longer needed - Limine handles 64-bit entry directly

    // Set linker script for kernel memory layout
    kernel.setLinkerScript(b.path("src/arch/x86_64/boot/linker.ld"));

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
        .root_source_file = b.path("src/user/lib/syscall.zig"),
        .target = kernel_target,
        .optimize = optimize, 
    });
    // Need to add uapi dependency to syscall lib
    syscall_lib.addImport("uapi", uapi_module);

    const shell_mod = b.createModule(.{
        .root_source_file = b.path("src/user/shell/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small, // User code doesn't need kernel code model
    });
    shell_mod.addImport("syscall", syscall_lib);

    const shell = b.addExecutable(.{
        .name = "shell.elf",
        .root_module = shell_mod,
    });
    shell.setLinkerScript(b.path("src/user/linker.ld"));
    // shell.entry = .disabled; // let Zig find _start

    // Create flat binary for shell
    const shell_bin = b.addObjCopy(shell.getEmittedBin(), .{
        .format = .bin,
    });

    const install_shell = b.addInstallFile(shell_bin.getOutput(), "bin/shell.bin");
    b.getInstallStep().dependOn(&install_shell.step);

    const httpd_mod = b.createModule(.{
        .root_source_file = b.path("src/user/httpd/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
    });
    httpd_mod.addImport("syscall", syscall_lib);

    const httpd = b.addExecutable(.{
        .name = "httpd.elf",
        .root_module = httpd_mod,
    });
    httpd.setLinkerScript(b.path("src/user/linker.ld"));

    const httpd_bin = b.addObjCopy(httpd.getEmittedBin(), .{ .format = .bin });
    const install_httpd = b.addInstallFile(httpd_bin.getOutput(), "bin/httpd.bin");
    b.getInstallStep().dependOn(&install_httpd.step);

    // Create ISO build step using Limine bootloader
    // Use v5.x binary branch which has prebuilt files
    const iso_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e && \
        \\LIMINE_DIR="limine" && \
        \\if [ ! -f "$LIMINE_DIR/limine-bios-cd.bin" ]; then \
        \\    rm -rf "$LIMINE_DIR" && \
        \\    echo "Downloading Limine binary branch..." && \
        \\    git clone --depth 1 --branch v5.x-branch-binary https://github.com/limine-bootloader/limine.git "$LIMINE_DIR" && \
        \\    make -C "$LIMINE_DIR"; \
        \\fi && \
        \\mkdir -p iso_root/boot/modules iso_root/EFI/BOOT && \
        \\cp zig-out/bin/kernel.elf iso_root/boot/ && \
        \\cp zig-out/bin/shell.bin iso_root/boot/modules/ && \
        \\cp zig-out/bin/httpd.bin iso_root/boot/modules/ && \
        \\cp limine.conf iso_root/ && \
        \\cp "$LIMINE_DIR"/limine-bios.sys iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/limine-bios-cd.bin iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/limine-uefi-cd.bin iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/BOOTX64.EFI iso_root/EFI/BOOT/ && \
        \\cp "$LIMINE_DIR"/BOOTIA32.EFI iso_root/EFI/BOOT/ 2>/dev/null || true && \
        \\xorriso -as mkisofs -b boot/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    --efi-boot boot/limine-uefi-cd.bin \
        \\    -efi-boot-part --efi-boot-image --protective-msdos-label \
        \\    iso_root -o zigk.iso && \
        \\"$LIMINE_DIR"/limine bios-install zigk.iso && \
        \\echo "ISO created: zigk.iso"
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Create run step for QEMU
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "128M",
        "-cdrom", "zigk.iso",
        "-serial", "stdio",
        "-no-reboot",
        "-no-shutdown",
        "-accel", "tcg",
    });
    
    // NEW: Inject -bios argument if provided
    if (qemu_bios) |bios_path| {
        if (std.mem.endsWith(u8, bios_path, ".fd") or std.mem.endsWith(u8, bios_path, ".FD")) {
            run_cmd.addArgs(&.{"-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{bios_path})});
        } else {
            run_cmd.addArgs(&.{"-bios", bios_path});
        }
    }
    run_cmd.step.dependOn(&iso_cmd.step);

    const run_step = b.step("run", "Build and run the kernel in QEMU");
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
        .root_source_file = b.path("src/kernel/heap.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    heap_test_module.addImport("config", test_config_module);

    test_module.addImport("heap", heap_test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests on host");
    test_step.dependOn(&run_unit_tests.step);
}
