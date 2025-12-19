const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    // Freestanding x86_64 target for kernel
    // Kernel target (No SSE/MMX/AVX) to prevent FPU register clobbering
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .mmx, .sse, .sse2, .avx, .avx2,
        }),
        .cpu_features_add = std.Target.x86.featureSet(&.{
            .soft_float,
        }),
    });

    // User target (SSE enabled) for userspace applications
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // ============================================================
    // Build-time Configuration Options
    // ============================================================
    const version = b.option([]const u8, "version", "Kernel version string") orelse "0.1.0";
    const kernel_name = b.option([]const u8, "name", "Kernel name") orelse "Zscapek";
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
    // Display option: "default" (auto), "sdl", "gtk", "cocoa" (macOS), "none" (headless)
    const qemu_display = b.option([]const u8, "display", "QEMU display backend (default, sdl, gtk, cocoa, none)") orelse "default";
    const qemu_usb_hub = b.option(bool, "usb-hub", "Attach usb-hub to XHCI and connect storage to it") orelse false;

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

    // Create User UAPI module (for user apps with SSE)
    const user_uapi_module = b.createModule(.{
        .root_source_file = b.path("src/uapi/root.zig"),
        .target = user_target,
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

    // Create TLB module (TLB shootdown for SMP)
    const tlb_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/tlb.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    tlb_module.addImport("hal", hal_module);
    tlb_module.addImport("sync", sync_module);

    // Create console module (debug output)
    const console_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/debug/console.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    console_module.addImport("hal", hal_module);
    console_module.addImport("config", config_module);
    console_module.addImport("sync", sync_module);

    // HAL needs console for APIC debug output (circular but Zig handles it)
    hal_module.addImport("console", console_module);
    hal_module.addImport("sync", sync_module);

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
    vmm_module.addImport("sync", sync_module);
    vmm_module.addImport("tlb", tlb_module);

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

    // Create ASLR module (Address Space Layout Randomization)
    const aslr_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/aslr.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    aslr_module.addImport("prng", prng_module);
    aslr_module.addImport("pmm", pmm_module);
    aslr_module.addImport("console", console_module);

    // Create Slab module (Kernel Slab Allocator)
    const slab_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/slab.zig"),
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
        .root_source_file = b.path("src/kernel/heap.zig"),
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
    net_module.addImport("console", console_module);
    net_module.addImport("sync", sync_module);
    net_module.addImport("heap", heap_module);
    // Note: io module added later after sched_module is defined

    // heap_module moved up

    // Create DMA Allocator module (Physical memory allocator with std.mem.Allocator interface)
    const dma_allocator_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/dma_allocator.zig"),
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
        .root_source_file = b.path("src/kernel/kernel_stack.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_stack_module.addImport("hal", hal_module);
    kernel_stack_module.addImport("pmm", pmm_module);
    kernel_stack_module.addImport("vmm", vmm_module);
    kernel_stack_module.addImport("console", console_module);
    kernel_stack_module.addImport("sync", sync_module);

    // Create VDSO module
    const vdso_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/vdso.zig"),
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
    thread_module.addImport("kernel_stack", kernel_stack_module);
    thread_module.addImport("uapi", uapi_module);

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
    sched_module.addImport("list", list_module);
    sched_module.addImport("kernel_stack", kernel_stack_module);
    sched_module.addImport("vdso", vdso_module);

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

    // Wire io module into net (deferred from earlier due to dependency order)
    net_module.addImport("io", kernel_io_module);

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
    fd_module.addImport("sync", sync_module);

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

    // fd_module moved up

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
    fs_module.addImport("sync", sync_module);
    fs_module.addImport("io", kernel_io_module);
    fs_module.addImport("pmm", pmm_module);

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
    keyboard_module.addImport("sched", sched_module);
    keyboard_module.addImport("thread", thread_module);
    keyboard_module.addImport("io", kernel_io_module);

    // Create Serial driver module
    const serial_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/serial/uart.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    serial_module.addImport("hal", hal_module);
    serial_module.addImport("sync", sync_module);

    // Create VirtIO common module
    const virtio_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/virtio/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    virtio_module.addImport("pmm", pmm_module);
    virtio_module.addImport("hal", hal_module);

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

    // Create Input subsystem module
    const input_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/input/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    input_module.addImport("sync", sync_module);
    input_module.addImport("ring_buffer", ring_buffer_module);
    input_module.addImport("uapi", uapi_module);

    // Create Mouse driver module
    const mouse_module = b.createModule(.{
        .root_source_file = b.path("src/drivers/mouse.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    mouse_module.addImport("hal", hal_module);
    mouse_module.addImport("sync", sync_module);
    mouse_module.addImport("ring_buffer", ring_buffer_module);
    mouse_module.addImport("console", console_module);
    mouse_module.addImport("input", input_module);
    mouse_module.addImport("uapi", uapi_module);

    // Add dependencies to USB module (after keyboard/mouse are defined)
    usb_module.addImport("keyboard", keyboard_module);
    usb_module.addImport("mouse", mouse_module);

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
    devfs_module.addImport("ahci", ahci_module);
    devfs_module.addImport("heap", heap_module);
    devfs_module.addImport("audio", audio_module);
    devfs_module.addImport("fs", fs_module);
    devfs_module.addImport("sync", sync_module);

    // Create Partitions module
    const partitions_module = b.createModule(.{
        .root_source_file = b.path("src/fs/partitions/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    partitions_module.addImport("ahci", ahci_module);
    partitions_module.addImport("devfs", devfs_module);
    partitions_module.addImport("heap", heap_module);
    partitions_module.addImport("fd", fd_module);
    partitions_module.addImport("uapi", uapi_module);
    partitions_module.addImport("console", console_module);

    // Create Capabilities module
    const capabilities_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/capabilities/root.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    capabilities_module.addImport("console", console_module);

    // Create atomic module for IPC/Locking (needed by process)
    const ipc_msg_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/ipc/message.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    ipc_msg_module.addImport("uapi", uapi_module);

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
    process_module.addImport("sched", sched_module);
    process_module.addImport("ipc_msg", ipc_msg_module);
    process_module.addImport("list", list_module);
    process_module.addImport("capabilities", capabilities_module);
    process_module.addImport("vdso", vdso_module);
    process_module.addImport("aslr", aslr_module);

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
    framebuffer_module.addImport("hal", hal_module);

    // Create user memory validation module (shared by all syscall modules)
    const user_mem_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/user_mem.zig"),
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

    // Create Pipe module (IPC)
    const pipe_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/pipe.zig"),
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
        .root_source_file = b.path("src/kernel/signal.zig"),
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

    // Create syscall base module (shared state for all handlers)
    const syscall_base_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/base.zig"),
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
        .root_source_file = b.path("src/kernel/syscall/process.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_process_module.addImport("base.zig", syscall_base_module);
    syscall_process_module.addImport("uapi", uapi_module);
    syscall_process_module.addImport("console", console_module);
    syscall_process_module.addImport("hal", hal_module);
    syscall_process_module.addImport("sched", sched_module);
    syscall_process_module.addImport("process", process_module);

    // Create syscall signals module (rt_sigprocmask, rt_sigaction, etc.)
    const syscall_signals_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/signals.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_signals_module.addImport("base.zig", syscall_base_module);
    syscall_signals_module.addImport("uapi", uapi_module);
    syscall_signals_module.addImport("console", console_module);
    syscall_signals_module.addImport("hal", hal_module);
    syscall_signals_module.addImport("sched", sched_module);

    // Create Futex module
    const futex_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/futex.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    futex_module.addImport("sched", sched_module);
    futex_module.addImport("sync", sync_module);
    futex_module.addImport("heap", heap_module);
    futex_module.addImport("hal", hal_module);
    futex_module.addImport("vmm", vmm_module);
    futex_module.addImport("console", console_module);

    // Break circular dependency: sched needs futex for timeout handling in wakeSleepingThreads
    sched_module.addImport("futex", futex_module);
    // sched needs base.zig for CLONE_CHILD_CLEARTID handling
    sched_module.addImport("base.zig", syscall_base_module);

    // Create syscall scheduling module (sched_yield, nanosleep, etc.)
    const syscall_scheduling_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/scheduling.zig"),
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

    // Create syscall io module (read, write, stat, etc.)
    const syscall_io_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/io.zig"),
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

    // Create syscall fd module (open, close, dup, pipe, lseek)
    const syscall_fd_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/fd.zig"),
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

    // Create syscall memory module (mmap, mprotect, munmap, brk)
    const syscall_memory_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/memory.zig"),
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
        .root_source_file = b.path("src/kernel/syscall/execution.zig"),
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

    // Create syscall custom module (debug_log, putchar, getchar, etc.)
    const syscall_custom_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/custom.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_custom_module.addImport("base.zig", syscall_base_module);

    // Create syscall library for USER applications (SSE enabled)
    // Moved up for dependency resolution
    const user_syscall_lib = b.createModule(.{
        .root_source_file = b.path("src/user/lib/syscall.zig"),
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
    user_libc_module.addImport("syscall.zig", user_syscall_lib);
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
    // Note: src/user/lib/syscall.zig needs uapi.
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
        .root_source_file = b.path("src/user/lib/syscall.zig"),
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
    netstack_exe.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));

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

    // Create syscall random module
    const syscall_random_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/random.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_random_module.addImport("uapi", uapi_module);
    syscall_random_module.addImport("prng", prng_module);
    syscall_random_module.addImport("user_mem", user_mem_module);

    // Create syscall fs_handlers module (mount/umount/unlink)
    const syscall_fs_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/fs_handlers.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_fs_module.addImport("base.zig", syscall_base_module);
    syscall_fs_module.addImport("uapi", uapi_module);
    syscall_fs_module.addImport("console", console_module);
    syscall_fs_module.addImport("fs", fs_module);
    syscall_fs_module.addImport("heap", heap_module);
    syscall_fs_module.addImport("user_mem", user_mem_module);
    syscall_fs_module.addImport("capabilities", capabilities_module);

    // Create syscall input module (mouse/input syscalls)
    const syscall_input_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/input.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_input_module.addImport("base.zig", syscall_base_module);
    syscall_input_module.addImport("uapi", uapi_module);
    syscall_input_module.addImport("input", input_module);

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
    syscall_net_module.addImport("user_mem", user_mem_module);
    syscall_net_module.addImport("base.zig", syscall_base_module);
    syscall_net_module.addImport("heap", heap_module);
    syscall_net_module.addImport("fd", fd_module);

    // Create syscall io_uring module (async I/O syscalls)
    const syscall_io_uring_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/io_uring.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_io_uring_module.addImport("uapi", uapi_module);
    syscall_io_uring_module.addImport("io", kernel_io_module);
    syscall_io_uring_module.addImport("user_mem", user_mem_module);
    syscall_io_uring_module.addImport("fd", fd_module);
    syscall_io_uring_module.addImport("sched", sched_module);
    syscall_io_uring_module.addImport("hal", hal_module);
    syscall_io_uring_module.addImport("heap", heap_module);
    syscall_io_uring_module.addImport("base.zig", syscall_base_module);
    syscall_io_uring_module.addImport("net", net_module);
    syscall_io_uring_module.addImport("pipe", pipe_module);
    syscall_io_uring_module.addImport("keyboard", keyboard_module);

    // Create IPC Service Registry module
    const ipc_service_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/ipc/service.zig"),
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
        .root_source_file = b.path("src/kernel/syscall/ipc.zig"),
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

    // Create syscall interrupt module
    const syscall_interrupt_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/interrupt.zig"),
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
        .root_source_file = b.path("src/kernel/syscall/port_io.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_port_io_module.addImport("uapi", uapi_module);
    syscall_port_io_module.addImport("hal", hal_module);
    syscall_port_io_module.addImport("sched", sched_module);
    syscall_port_io_module.addImport("process", process_module);

    // Create syscall mmio module (MMIO/DMA for userspace drivers)
    const syscall_mmio_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/mmio.zig"),
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

    // Create syscall pci module (PCI enumeration and config access)
    const syscall_pci_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/pci_syscall.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    syscall_pci_module.addImport("base.zig", syscall_base_module);
    syscall_pci_module.addImport("uapi", uapi_module);
    syscall_pci_module.addImport("console", console_module);
    syscall_pci_module.addImport("pci", pci_module);

    // Create ring buffer manager module (kernel/ring.zig)
    const ring_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/ring.zig"),
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
        .root_source_file = b.path("src/kernel/syscall/ring.zig"),
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

    // Create syscall fs_handlers module (mount, umount, unlink)
    const syscall_fs_handlers_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/fs_handlers.zig"),
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

    // Create syscall dispatch table module
    const syscall_table_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/syscall/table.zig"),
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
    syscall_table_module.addImport("input", syscall_input_module);
    syscall_table_module.addImport("io_uring", syscall_io_uring_module);
    syscall_table_module.addImport("ipc", syscall_ipc_module);
    syscall_table_module.addImport("interrupt", syscall_interrupt_module);
    syscall_table_module.addImport("port_io", syscall_port_io_module);
    syscall_table_module.addImport("mmio", syscall_mmio_module);
    syscall_table_module.addImport("pci_syscall", syscall_pci_module);
    syscall_table_module.addImport("ring", syscall_ring_module);
    syscall_table_module.addImport("fs_handlers", syscall_fs_handlers_module);

    // Create kernel executable
    // NOTE: red_zone must be disabled for kernel code to prevent stack corruption
    // from interrupts. code_model=kernel enables top-2GB addressing.
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .kernel,
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

    kernel.root_module.addImport("limine", limine_module);
    kernel.root_module.addImport("hal", hal_module);
    kernel.root_module.addImport("acpi", acpi_module);
    kernel.root_module.addImport("pci", pci_module);
    kernel.root_module.addImport("tlb", tlb_module);
    kernel.root_module.addImport("e1000e", e1000e_module);
    kernel.root_module.addImport("ahci", ahci_module);
    kernel.root_module.addImport("usb", usb_module);
    kernel.root_module.addImport("net", net_module);
    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("console", console_module);
    kernel.root_module.addImport("pmm", pmm_module);
    kernel.root_module.addImport("vmm", vmm_module);
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
    kernel.root_module.addImport("io", kernel_io_module);
    kernel.root_module.addImport("capabilities", capabilities_module);
    kernel.root_module.addImport("syscall_ipc", syscall_ipc_module);
    kernel.root_module.addImport("futex", futex_module);
    kernel.root_module.addImport("vdso", vdso_module);

    // Add assembly helpers for x86_64 (ISR stubs, lgdt, lidt)
    kernel.addAssemblyFile(b.path("src/arch/x86_64/asm_helpers.S"));
    kernel.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));

    // Add SMP trampoline code
    kernel.addAssemblyFile(b.path("src/arch/x86_64/smp_trampoline.S"));

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
    shell.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
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
    httpd.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));

    // Install httpd as ELF (required for proper ELF loading in kernel)
    const install_httpd = b.addInstallArtifact(httpd, .{});
    b.getInstallStep().dependOn(&install_httpd.step);

    // Build Doom
    // Create platform hooks module
    const doom_platform_module = b.createModule(.{
        .root_source_file = b.path("src/user/doom/doomgeneric_zscapek.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    doom_platform_module.addImport("syscall", user_syscall_lib);

    // Create sound stubs module
    const doom_sound_module = b.createModule(.{
        .root_source_file = b.path("src/user/doom/i_sound_stub.zig"),
        .target = user_target,
        .optimize = optimize,
    });

    const doom_mod = b.createModule(.{
        .root_source_file = b.path("src/user/doom/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    doom_mod.addImport("syscall", user_syscall_lib);
    doom_mod.addImport("libc", user_libc_module);
    doom_mod.addImport("doomgeneric_zscapek.zig", doom_platform_module);
    doom_mod.addImport("i_sound_stub.zig", doom_sound_module);

    const doom = b.addExecutable(.{
        .name = "doom.elf",
        .root_module = doom_mod,
    });
    doom.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));

    // Create UART Driver module
    const uart_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/uart/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    uart_driver_mod.addImport("syscall", user_syscall_lib);
    uart_driver_mod.addImport("libc", user_libc_module);

    const uart_driver = b.addExecutable(.{
        .name = "uart_driver.elf",
        .root_module = uart_driver_mod,
    });
    uart_driver.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    uart_driver.setLinkerScript(b.path("src/user/linker.ld"));

    const install_uart_driver = b.addInstallArtifact(uart_driver, .{});
    b.getInstallStep().dependOn(&install_uart_driver.step);

    // Create PS/2 driver executable (userspace driver)
    const ps2_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/ps2/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    ps2_driver_mod.addImport("syscall", user_syscall_lib);
    ps2_driver_mod.addImport("libc", user_libc_module);

    const ps2_driver = b.addExecutable(.{
        .name = "ps2_driver.elf",
        .root_module = ps2_driver_mod,
    });
    ps2_driver.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    // Use user linker script
    ps2_driver.setLinkerScript(b.path("src/user/linker.ld"));
    // Install
    const install_ps2_driver = b.addInstallArtifact(ps2_driver, .{});
    b.getInstallStep().dependOn(&install_ps2_driver.step);

    // Create VirtIO-Net Driver module (userspace VirtIO network driver)
    const virtio_net_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/virtio_net/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    virtio_net_driver_mod.addImport("syscall", user_syscall_lib);
    virtio_net_driver_mod.addImport("libc", user_libc_module);
    virtio_net_driver_mod.addImport("ring", user_ring_lib);

    const virtio_net_driver = b.addExecutable(.{
        .name = "virtio_net_driver.elf",
        .root_module = virtio_net_driver_mod,
    });
    virtio_net_driver.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    virtio_net_driver.setLinkerScript(b.path("src/user/linker.ld"));

    const install_virtio_net_driver = b.addInstallArtifact(virtio_net_driver, .{});
    b.getInstallStep().dependOn(&install_virtio_net_driver.step);

    // Create VirtIO-Blk Driver module (userspace VirtIO block driver)
    const virtio_blk_driver_mod = b.createModule(.{
        .root_source_file = b.path("src/user/drivers/virtio_blk/main.zig"),
        .target = user_target,
        .optimize = optimize,
        .code_model = .small,
    });
    virtio_blk_driver_mod.addImport("syscall", user_syscall_lib);
    virtio_blk_driver_mod.addImport("libc", user_libc_module);

    const virtio_blk_driver = b.addExecutable(.{
        .name = "virtio_blk_driver.elf",
        .root_module = virtio_blk_driver_mod,
    });
    virtio_blk_driver.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    virtio_blk_driver.setLinkerScript(b.path("src/user/linker.ld"));

    const install_virtio_blk_driver = b.addInstallArtifact(virtio_blk_driver, .{});
    b.getInstallStep().dependOn(&install_virtio_blk_driver.step);

    // Add doomgeneric C source files
    doom.addCSourceFiles(.{
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
        .flags = &.{
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
        },
    });
    doom.addIncludePath(b.path("src/user/doom/include"));
    doom.addIncludePath(b.path("src/user/doom/doomgeneric"));

    doom.setLinkerScript(b.path("src/user/linker.ld"));

    // Install doom.elf
    const install_doom = b.addInstallArtifact(doom, .{});
    b.getInstallStep().dependOn(&install_doom.step);

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
    };

    const test_step_build = b.step("build-tests", "Build C integration tests");

    inline for (c_tests) |test_name| {
        const test_exe = b.addSystemCommand(&.{
            "zig",                       "cc",
            "-target",                   "x86_64-linux-musl",
            "-static",                   "-o",
            "zig-out/bin/" ++ test_name, "tests/userland/" ++ test_name ++ ".c",
        });
        test_step_build.dependOn(&test_exe.step);
    }

    // Create libc test runner module (Zig wrapper for C test)
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
    test_libc_exe.addCSourceFile(.{
        .file = b.path("tests/userland/test_libc_fixes.c"),
        .flags = &.{
            "-ffreestanding",
            "-nostdlib",
            "-mno-red-zone",
            "-fno-stack-protector",
            "-fno-builtin", // Use our libc functions, not compiler builtins
        },
    });
    test_libc_exe.addIncludePath(b.path("src/user/doom/include"));
    test_libc_exe.setLinkerScript(b.path("src/user/linker.ld"));
    test_libc_exe.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));

    const install_test_libc = b.addInstallArtifact(test_libc_exe, .{});
    b.getInstallStep().dependOn(&install_test_libc.step);

    // Copy to ISO modules
    const copy_test_libc = b.addSystemCommand(&.{
        "cp", "zig-out/bin/test_libc_fixes.elf", "iso_root/boot/modules/"
    });
    copy_test_libc.step.dependOn(&install_test_libc.step);
    b.getInstallStep().dependOn(&copy_test_libc.step);

    // Ensure tests are built before ISO is created
    b.getInstallStep().dependOn(test_step_build);

    // ASM Test (Minimal userland sanity check)
    // ASM Test (Minimal userland sanity check)
    const test_asm = b.addExecutable(.{
        .name = "test_asm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/test_asm.zig"),
            .target = user_target,
            .optimize = optimize,
        }),
    });
    test_asm.setLinkerScript(b.path("src/user/linker.ld"));
    test_asm.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
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
    test_writev.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    const install_test_writev = b.addInstallArtifact(test_writev, .{});
    b.getInstallStep().dependOn(&install_test_writev.step);

    // Audio Test
    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/user/audio_test.zig"),
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
    audio_test.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    const install_audio_test = b.addInstallArtifact(audio_test, .{});
    b.getInstallStep().dependOn(&install_audio_test.step);

    // Libc Fix Verification Test (Native C with Custom Libc)
    // Wrapper and C source definition below
    
    // Create a wrapper to link against libc and crt0
    // Create a dummy entry file if needed, or better:
    // Actually, create module with just the C file?
    // b.createModule doesn't take C files easily as root.
    // Use a small Zig wrapper "src/user/test_libc_fix_entry.zig" that imports libc and exports nothing, relying on C main.
    
    // Waiting for file creation in next step, assuming path "src/user/test_libc_fix_wrapper.zig"
    // Let's create the wrapper content inline if possible or use write_to_file next.
    // For now I define the build step, pointing to a wrapper I will create.
    const test_libc_fix_mod = b.createModule(.{
        .root_source_file = b.path("src/user/test_libc_fix_wrapper.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    test_libc_fix_mod.addImport("libc", user_libc_module);
    test_libc_fix_mod.addImport("syscall", user_syscall_lib);
    
    const test_libc_fix_exe = b.addExecutable(.{
        .name = "test_libc_fix",
        .root_module = test_libc_fix_mod,
    });
    test_libc_fix_exe.addCSourceFile(.{
        .file = b.path("tests/userland/test_libc_fix.c"),
        .flags = &.{ "-nostdlib", "-ffreestanding", "-I", "src/user/doom/include" },
    });
    test_libc_fix_exe.setLinkerScript(b.path("src/user/linker.ld"));
    test_libc_fix_exe.addAssemblyFile(b.path("src/arch/x86_64/memcpy.S"));
    test_libc_fix_exe.addAssemblyFile(b.path("src/user/crt0.S"));
    const install_test_libc_fix = b.addInstallArtifact(test_libc_fix_exe, .{});
    b.getInstallStep().dependOn(&install_test_libc_fix.step);

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
        \\cp zig-out/bin/shell.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/httpd.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_stdio iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_devnull iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_wait4 iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_clock iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_random iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_asm iso_root/boot/modules/ && \
        \\cp zig-out/bin/netstack iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_threads iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_signals_fpu iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_vdso iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_writev iso_root/boot/modules/ && \
        \\cp zig-out/bin/audio_test iso_root/boot/modules/ && \
        \\cp zig-out/bin/test_libc_fix iso_root/boot/modules/ && \
        \\cp zig-out/bin/doom.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/uart_driver.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/ps2_driver.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/virtio_net_driver.elf iso_root/boot/modules/ && \
        \\cp zig-out/bin/virtio_blk_driver.elf iso_root/boot/modules/ && \
        \\if [ -d initrd_contents ] && [ "$(ls -A initrd_contents 2>/dev/null)" ]; then \
        \\    echo "Creating initrd.tar..." && \
        \\    tar --format=ustar -cvf iso_root/boot/initrd.tar -C initrd_contents .; \
        \\fi && \
        \\cp limine.cfg iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/limine-bios.sys iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/limine-bios-cd.bin iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/limine-uefi-cd.bin iso_root/boot/ && \
        \\cp "$LIMINE_DIR"/BOOTX64.EFI iso_root/EFI/BOOT/ && \
        \\cp "$LIMINE_DIR"/BOOTIA32.EFI iso_root/EFI/BOOT/ 2>/dev/null || true && \
        \\xorriso -as mkisofs -b boot/limine-bios-cd.bin \
        \\    -no-emul-boot -boot-load-size 4 -boot-info-table \
        \\    --efi-boot boot/limine-uefi-cd.bin \
        \\    -efi-boot-part --efi-boot-image --protective-msdos-label \
        \\    iso_root -o zscapek.iso && \
        \\"$LIMINE_DIR"/limine bios-install zscapek.iso && \
        \\echo "ISO created: zscapek.iso"
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Create run step for QEMU
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M",
        "q35",
        "-m",
        "512M",
        "-cdrom",
        "zscapek.iso",
        "-device",
        "qemu-xhci,id=xhci",
        "-device",
        "usb-kbd",
        "-vga",
        "std",
        "-device",
        "AC97",
        "-serial",
        "stdio",
        "-smp",
        "4",
        "-no-reboot",
        "-no-shutdown",
        "-accel",
        "tcg",
        "-drive", "if=none,id=usbdisk,format=raw,file=usb_disk.img", // USB Mass Storage
    });

    if (qemu_usb_hub) {
        run_cmd.addArgs(&.{
            // Attach USB Hub to XHCI and let QEMU pick the port
            "-device", "usb-hub,bus=xhci.0,id=hub0",
            // Attach USB Storage to hub port 1 (auto-assigned)
            "-device", "usb-storage,drive=usbdisk,bus=hub0.0",
        });
    } else {
        run_cmd.addArgs(&.{
            // Attach USB Storage to XHCI root hub (auto-assigned port)
            "-device", "usb-storage,drive=usbdisk",
        });
    }

    // Add display option (default = let QEMU auto-detect)
    if (!std.mem.eql(u8, qemu_display, "default")) {
        run_cmd.addArgs(&.{ "-display", qemu_display });
    }

    // NEW: Inject -bios argument if provided
    if (qemu_bios) |bios_path| {
        if (std.mem.endsWith(u8, bios_path, ".fd") or std.mem.endsWith(u8, bios_path, ".FD")) {
            run_cmd.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{bios_path}) });
        } else {
            run_cmd.addArgs(&.{ "-bios", bios_path });
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
    const slab_test_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/slab.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    slab_test_module.addImport("config", test_config_module);

    heap_test_module.addImport("slab", slab_test_module);
    test_module.addImport("slab", slab_test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests on host");
    test_step.dependOn(&run_unit_tests.step);
}
