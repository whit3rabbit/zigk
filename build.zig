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

    // Create config module
    const config_module = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

    // Create local limine module (Zig 0.15.x compatible)
    // Note: Using local bindings because upstream limine-zig uses deprecated usingnamespace
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

    // Create console module (debug output)
    const console_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/debug/console.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    console_module.addImport("hal", hal_module);
    console_module.addImport("config", config_module);

    // Create PMM module (Physical Memory Manager)
    const pmm_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/pmm.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    pmm_module.addImport("hal", hal_module);
    pmm_module.addImport("console", console_module);
    pmm_module.addImport("config", config_module);

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

    // Create Sync module (Spinlock and synchronization primitives)
    // NOTE: Created before heap because heap depends on sync
    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/sync.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    sync_module.addImport("hal", hal_module);

    // Create Heap module (Kernel Heap Allocator)
    const heap_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/heap.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    heap_module.addImport("console", console_module);
    heap_module.addImport("config", config_module);
    heap_module.addImport("sync", sync_module);

    // Create UAPI module (syscall numbers, errno codes)
    const uapi_module = b.createModule(.{
        .root_source_file = b.path("src/uapi/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });

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

    // Create kernel executable using Zig 0.15.x createModule pattern
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            // Kernel code model disables Red Zone (critical for interrupt handling)
            .code_model = .kernel,
        }),
    });

    // Add module imports to kernel
    kernel.root_module.addImport("limine", limine_module);
    kernel.root_module.addImport("hal", hal_module);
    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("console", console_module);
    kernel.root_module.addImport("pmm", pmm_module);
    kernel.root_module.addImport("vmm", vmm_module);
    kernel.root_module.addImport("heap", heap_module);
    kernel.root_module.addImport("sync", sync_module);
    kernel.root_module.addImport("uapi", uapi_module);
    kernel.root_module.addImport("keyboard", keyboard_module);

    // Add assembly helpers for x86_64 (ISR stubs, lgdt, lidt)
    // These cannot be expressed in Zig inline assembly due to operand constraints
    kernel.addAssemblyFile(b.path("src/arch/x86_64/asm_helpers.S"));

    // Set linker script for kernel memory layout
    kernel.setLinkerScript(b.path("src/arch/x86_64/boot/linker.ld"));

    // Install kernel artifact
    b.installArtifact(kernel);

    // Create run step for QEMU
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "128M",
        "-cdrom", "zigk.iso",
        "-serial", "stdio",
        "-no-reboot",
        "-no-shutdown",
        // Apple Silicon requires TCG accelerator for x86_64 emulation
        "-accel", "tcg",
    });
    run_cmd.step.dependOn(&kernel.step);

    const run_step = b.step("run", "Build and run the kernel in QEMU");
    run_step.dependOn(&run_cmd.step);

    // Create ISO build step
    const iso_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        \\mkdir -p iso_root/boot/limine && \
        \\cp zig-out/bin/kernel.elf iso_root/boot/ && \
        \\cp limine.conf iso_root/boot/limine/ && \
        \\xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    --efi-boot boot/limine/limine-uefi-cd.bin \
        \\    -efi-boot-part --efi-boot-image --protective-msdos-label \
        \\    iso_root -o zigk.iso 2>/dev/null || \
        \\xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    iso_root -o zigk.iso
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Host-side unit tests (runs on host, not freestanding)
    // For testing heap, data structures, and other logic
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/main.zig"),
        // Use native target for host-side testing
        .target = b.graph.host,
        .optimize = optimize,
    });

    // Create heap module for host testing (non-freestanding)
    const heap_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/heap.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });

    test_module.addImport("heap", heap_test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests on host");
    test_step.dependOn(&run_unit_tests.step);
}
