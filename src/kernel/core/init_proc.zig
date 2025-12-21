//! Init Process Loading
//!
//! Responsible for identifying, loading, and starting the initial userspace process (PID 1).
//!
//! Functionality:
//! - Initializes the InitRD filesystem from BootInfo.initrd_addr/size
//! - Scans InitRD for suitable init candidates (test_asm, httpd, shell, doom).
//! - Creates the first process structure and address space.
//! - Uses the ELF loader to load the executable into memory.
//! - Sets up the user stack with arguments (argv) and environment (envp).
//! - Initializes TLS/TCB (Thread Control Block) for the main thread.
//! - Hands the thread over to the scheduler.

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console");
const process = @import("process");
const elf = @import("elf");
const syscall_base = @import("syscall_base");
const fs = @import("fs");
const sched = @import("sched");
const thread = @import("thread");
const pmm = @import("pmm");
const capabilities = @import("capabilities");
const heap = @import("heap");
const pci = @import("pci");
const aslr = @import("aslr");
const devfs = @import("devfs");
const kernel_iommu = @import("kernel_iommu");
const hal = @import("hal");
const BootInfo = @import("boot_info");

/// Module data structure (replaces Limine module)
const ModuleData = struct {
    name: []const u8,
    data: []const u8,
};

/// Maximum reasonable InitRD size (256 MB)
/// Prevents DoS via malicious bootloader setting enormous size
const MAX_INITRD_SIZE: u64 = 256 * 1024 * 1024;

/// Initialize InitRD filesystem from BootInfo
/// This should be called early in kernel boot, before loadInitProcess()
pub fn initInitRDFromBootInfo(boot_info: *const BootInfo.BootInfo) void {
    if (boot_info.initrd_addr == 0 or boot_info.initrd_size == 0) {
        console.info("InitRD: No initrd provided (addr=0 or size=0)", .{});
        return;
    }

    // SECURITY: Validate initrd_size is reasonable
    if (boot_info.initrd_size > MAX_INITRD_SIZE) {
        console.err("InitRD: Size {} exceeds maximum {} bytes - rejecting", .{
            boot_info.initrd_size,
            MAX_INITRD_SIZE,
        });
        return;
    }

    // SECURITY: Check for address overflow (initrd_addr + initrd_size)
    const initrd_end = std.math.add(u64, boot_info.initrd_addr, boot_info.initrd_size) catch {
        console.err("InitRD: Address overflow (addr={x} + size={x})", .{
            boot_info.initrd_addr,
            boot_info.initrd_size,
        });
        return;
    };

    // SECURITY: Validate physical range is within usable memory
    // Check against memory map to ensure initrd is in conventional/loader memory
    if (!isPhysicalRangeUsable(boot_info, boot_info.initrd_addr, initrd_end)) {
        console.err("InitRD: Physical range {x}-{x} not in usable memory", .{
            boot_info.initrd_addr,
            initrd_end,
        });
        return;
    }

    // Convert physical address to virtual using HHDM
    const virt_ptr = hal.paging.physToVirt(boot_info.initrd_addr);
    const data = virt_ptr[0..boot_info.initrd_size];

    // Initialize the global InitRD instance
    fs.initrd.InitRD.init(data);

    console.info("InitRD: Initialized from BootInfo ({d} bytes)", .{boot_info.initrd_size});

    // List files in initrd for debugging
    var iter = fs.initrd.InitRD.instance.listFiles();
    var file_count: usize = 0;
    while (iter.next()) |file| {
        console.debug("  - {s} ({d} bytes)", .{ file.name, file.data.len });
        file_count += 1;
    }
    console.info("InitRD: {d} files found", .{file_count});
}

/// Check if a physical memory range is within usable memory regions
/// Returns true if the range [start, end) is fully contained in a usable memory region
fn isPhysicalRangeUsable(boot_info: *const BootInfo.BootInfo, start: u64, end: u64) bool {
    const descriptors = boot_info.memory_map[0..boot_info.memory_map_count];

    for (descriptors) |desc| {
        // Only consider memory types that are safe for InitRD
        const is_usable = switch (desc.type) {
            .Conventional, .LoaderCode, .LoaderData, .BootServicesCode, .BootServicesData => true,
            else => false,
        };

        if (!is_usable) continue;

        const region_start = desc.phys_start;
        const region_end = desc.phys_start + (desc.num_pages * pmm.PAGE_SIZE);

        // Check if our range is fully contained in this region
        if (start >= region_start and end <= region_end) {
            return true;
        }
    }

    return false;
}

/// Load the init process from InitRD
///
/// Steps:
/// 1. Find drivers and spawn them
/// 2. Find the best candidate init process (based on name priority).
/// 3. Create a process struct and set it as current.
/// 4. Load the ELF executable.
/// 5. Setup stack and arguments.
/// 6. Setup TLS.
/// 7. Create the main thread and add to scheduler.
pub fn loadInitProcess() void {
    console.info("Searching for init in InitRD...", .{});

    // Check if InitRD is initialized
    if (fs.initrd.InitRD.instance.data.len == 0) {
        console.warn("No InitRD loaded - no userspace processes will be spawned", .{});
        return;
    }

    // 1. Launch Drivers (scan InitRD for driver executables)
    const driver_names = [_][]const u8{
        "uart_driver",
        "ps2_driver",
        "virtio_net_driver",
        "virtio_blk_driver",
        "netstack",
    };

    for (driver_names) |driver_name| {
        if (findModuleInInitRD(driver_name)) |mod| {
            spawnProcessFromData(mod, driver_name);
        }
    }

    // 2. Select Main Init Process (priority order)
    const init_candidates = [_][]const u8{
        "test_vdso",
        "test_signals_fpu",
        "test_asm",
        "audio",
        "httpd",
        "shell",
        "doom",
        "init",
    };

    for (init_candidates) |name| {
        if (findModuleInInitRD(name)) |mod| {
            console.info("Found init module: {s} ({d} bytes)", .{ name, mod.data.len });
            spawnProcessFromData(mod, name);
            return;
        }
    }

    // Fallback: Try to find any executable
    var iter = fs.initrd.InitRD.instance.listFiles();
    while (iter.next()) |file| {
        // Skip non-ELF files
        if (file.data.len >= 4 and std.mem.eql(u8, file.data[0..4], "\x7fELF")) {
            console.warn("No matching init found, defaulting to first ELF: {s}", .{file.name});
            spawnProcessFromData(.{ .name = file.name, .data = file.data }, file.name);
            return;
        }
    }

    console.warn("No suitable init process found in InitRD!", .{});
}

/// Find a module in the InitRD by name
/// Searches for exact matches and common variations (.elf suffix, bin/ prefix)
fn findModuleInInitRD(name: []const u8) ?ModuleData {
    // Try exact name match
    if (fs.initrd.InitRD.instance.findFile(name)) |file| {
        return .{ .name = file.name, .data = file.data };
    }

    // Try with .elf suffix
    var buf: [128]u8 = undefined;
    const name_elf = std.fmt.bufPrint(&buf, "{s}.elf", .{name}) catch return null;
    if (fs.initrd.InitRD.instance.findFile(name_elf)) |file| {
        return .{ .name = file.name, .data = file.data };
    }

    // Try with bin/ prefix
    const bin_name = std.fmt.bufPrint(&buf, "bin/{s}", .{name}) catch return null;
    if (fs.initrd.InitRD.instance.findFile(bin_name)) |file| {
        return .{ .name = file.name, .data = file.data };
    }

    // Try with bin/ prefix and .elf suffix
    const bin_name_elf = std.fmt.bufPrint(&buf, "bin/{s}.elf", .{name}) catch return null;
    if (fs.initrd.InitRD.instance.findFile(bin_name_elf)) |file| {
        return .{ .name = file.name, .data = file.data };
    }

    return null;
}

fn appendCapabilityOrWarn(
    proc: *process.Process,
    alloc: std.mem.Allocator,
    cap: capabilities.Capability,
    proc_name: []const u8,
) void {
    proc.capabilities.append(alloc, cap) catch |err| {
        console.warn("Failed to grant capability to {s}: {} (driver may lack hardware access)",
                     .{proc_name, err});
    };
}

fn spawnProcessFromData(mod: ModuleData, process_name: []const u8) void {
    console.info("Spawning process: {s}", .{process_name});

    // Step 1: Create Process with FD table (stdin/stdout/stderr pre-opened by devfs)
    const proc = process.createProcess(null) catch |err| {
        console.err("Failed to create init process: {}", .{err});
        return;
    };

    // Pre-populate stdin/stdout/stderr
    devfs.createStdFds(proc.fd_table) catch |err| {
        console.warn("Failed to create std FDs for {s}: {}", .{process_name, err});
    };

    // Step 2: Set as current process so syscall handlers can access FD table
    syscall_base.setCurrentProcess(proc);
    console.info("Created process pid={d} with FD table", .{proc.pid});

    // Grant capabilities based on process name
    grantProcessCapabilities(proc, process_name);

    console.info("Init: Loading ELF...", .{});

    // Step 3: Validate module data
    if (mod.data.len == 0) {
        console.err("Invalid module size (zero) for {s}", .{process_name});
        return;
    }

    // Step 4: Load ELF into process's address space
    const load_base: u64 = aslr.getPieBase(&proc.aslr_offsets);

    // SECURITY: Use actual ASLR stack bounds for ELF segment overlap validation
    const stack_size: usize = 1024 * 1024; // 1MB stack
    const stack_bounds = elf.StackBounds{
        .stack_top = proc.aslr_offsets.stack_top,
        .stack_size = stack_size,
    };

    const load_result = elf.load(mod.data, proc.cr3, load_base, stack_bounds) catch |err| {
        console.err("ELF load failed: {}", .{err});
        return;
    };
    // SECURITY: Only log addresses in debug builds to prevent ASLR info leak
    if (builtin.mode == .Debug) {
        console.info("ELF: Loaded at {x}-{x}, entry={x} (ASLR)", .{
            load_result.base_addr,
            load_result.end_addr,
            load_result.entry_point,
        });
    } else {
        console.info("ELF: Loaded successfully", .{});
    }

    // Initialize heap boundaries with ASLR heap gap
    const heap_start = aslr.getHeapStart(load_result.end_addr, &proc.aslr_offsets);
    proc.heap_start = heap_start;
    proc.heap_break = heap_start;
    // SECURITY: Only log heap address in debug builds
    if (builtin.mode == .Debug) {
        console.info("Init: Heap initialized at {x} (ASLR gap={})", .{ heap_start, proc.aslr_offsets.heap_gap });
    }

    console.info("Init: Setting up user stack...", .{});

    // Step 5: Allocate and map user stack with arguments
    const stack_virt_top: u64 = proc.aslr_offsets.stack_top;
    // stack_size defined above for ELF loading

    // Parse arguments (just use process name for now)
    var argv_buf: [16][]const u8 = undefined;
    argv_buf[0] = process_name;
    var argv_count: usize = 1;

    // Workaround: If this is Doom, inject default arguments
    if (std.mem.eql(u8, process_name, "doom")) {
        console.warn("Init: Detecting Doom, injecting defaults...", .{});
        argv_buf[1] = "-iwad";
        argv_buf[2] = "/doom1.wad";
        argv_count = 3;
    }

    const argv = argv_buf[0..argv_count];
    const envp = [_][]const u8{};

    for (argv, 0..) |arg, i| {
        console.debug("Init: Arg {d}: '{s}'", .{i, arg});
    }

    // Auxiliary Vector (Required for static binaries to find PHDRs)
    const auxv = [_]elf.AuxEntry{
        .{ .id = 3, .value = load_result.phdr_addr }, // AT_PHDR
        .{ .id = 4, .value = 56 }, // AT_PHENT
        .{ .id = 5, .value = load_result.phnum }, // AT_PHNUM
        .{ .id = 6, .value = 4096 }, // AT_PAGESZ
        .{ .id = 9, .value = load_result.entry_point }, // AT_ENTRY
        .{ .id = 33, .value = proc.vdso_base }, // AT_SYSINFO_EHDR
    };

    // SECURITY: Only log stack address in debug builds
    if (builtin.mode == .Debug) {
        console.info("Creating user stack at {x} (size={d}, ASLR)", .{ stack_virt_top, stack_size });
    }

    // Log ASLR configuration for this process (already guarded in aslr.zig)
    aslr.logOffsets(&proc.aslr_offsets, proc.pid);

    // setupStack allocates pages, maps them, and pushes args
    const initial_rsp = elf.setupStack(
        proc.cr3,
        stack_virt_top,
        stack_size,
        argv,
        &envp,
        &auxv,
    ) catch |err| {
        console.err("Failed to setup user stack: {}", .{err});
        return;
    };

    // SECURITY: Only log rsp in debug builds
    if (builtin.mode == .Debug) {
        console.info("User stack created (rsp={x})", .{initial_rsp});
    }
    console.info("Init: Creating user thread...", .{});

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
    const tls_base_addr = proc.aslr_offsets.tls_base;
    var fs_base: u64 = 0;

    if (load_result.tls_phdr) |phdr| {
        // Use TLS segment from ELF
        // SECURITY: Pass actual ASLR stack bounds for TLS overlap validation
        if (elf.setupTls(proc.cr3, phdr, mod.data, tls_base_addr, stack_bounds)) |tp| {
            fs_base = tp;
            // SECURITY: Only log TLS address in debug builds
            if (builtin.mode == .Debug) {
                console.info("Init: Initialized TLS at {x} (size={d})", .{ tp, phdr.p_memsz });
            }
        } else |err| {
            console.warn("Init: Failed to setup TLS: {}", .{err});
        }
    } else {
        // Fallback for binaries without PT_TLS (but expecting TCB at fs:0)
        console.warn("Init: No PT_TLS found, creating minimal TCB", .{});
        const minimal_phdr = elf.Elf64_Phdr{
            .p_type = elf.PT_TLS,
            .p_flags = elf.PF_R | elf.PF_W,
            .p_offset = 0,
            .p_vaddr = 0,
            .p_paddr = 0,
            .p_filesz = 0,
            .p_memsz = 0,
            .p_align = 16,
        };
        // SECURITY: Pass actual ASLR stack bounds for TLS overlap validation
        if (elf.setupTls(proc.cr3, minimal_phdr, mod.data, tls_base_addr, stack_bounds)) |tp| {
            fs_base = tp;
        } else |err| {
            console.warn("Init: Failed to setup minimal TCB: {}", .{err});
        }
    }

    if (fs_base != 0) {
        user_thread.fs_base = fs_base;
    }

    console.info("Init: Adding thread to scheduler...", .{});
    sched.addThread(user_thread);
    console.info("Init process started (pid={d}, tid={d})", .{ proc.pid, user_thread.tid });
}

/// Grant capabilities based on process name
///
/// SECURITY WARNING: This function grants hardware capabilities based solely on
/// the process name, which is derived from the filename in InitRD. This is a
/// PRIVILEGE ESCALATION RISK:
///
/// - Any binary named "doom", "virtio_net_driver", etc. will receive powerful
///   hardware access capabilities (IRQs, I/O ports, MMIO, DMA, PCI config)
/// - A compromised InitRD or bootloader can plant malicious binaries with
///   privileged names to gain full hardware access
///
/// RECOMMENDED MITIGATIONS:
/// 1. Cryptographically sign InitRD contents and verify signatures before granting caps
/// 2. Use a separate capability manifest file that is also signed
/// 3. Implement a TPM-based measured boot to detect InitRD tampering
/// 4. Move to a capability token system where processes request caps at runtime
///
/// FIXME(security-high): Replace name-based capability granting with signed capability manifests
/// Tracked as: Privilege escalation via malicious InitRD binaries
fn grantProcessCapabilities(proc: *process.Process, process_name: []const u8) void {
    // Track whether we've logged the security warning (static var persists across calls)
    const S = struct {
        var warned: bool = false;
    };
    if (!S.warned) {
        console.warn("SECURITY: Capabilities granted by process name only. See grantProcessCapabilities() for risks.", .{});
        S.warned = true;
    }

    const alloc = heap.allocator();

    // UART driver capabilities
    if (std.mem.eql(u8, process_name, "uart_driver")) {
        appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 4 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }, process_name);
        console.info("Init: Granted UART capabilities to pid={}", .{proc.pid});
    }

    // PS/2 driver capabilities
    if (std.mem.eql(u8, process_name, "ps2_driver")) {
        appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 12 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .InputInjection = {} }, process_name);
        console.info("Init: Granted PS/2 capabilities to pid={}", .{proc.pid});
    }

    // VirtIO-Net capabilities
    if (std.mem.eql(u8, process_name, "virtio_net_driver")) {
        if (grantVirtioCapabilities(proc, .Net)) {
            console.info("Init: Granted VirtIO-Net capabilities to pid={}", .{proc.pid});
        } else {
            console.warn("Init: Failed to find VirtIO-Net device for pid={}", .{proc.pid});
        }
    }

    // VirtIO-Blk capabilities
    if (std.mem.eql(u8, process_name, "virtio_blk_driver")) {
        if (grantVirtioCapabilities(proc, .Blk)) {
            console.info("Init: Granted VirtIO-Blk capabilities to pid={}", .{proc.pid});
        } else {
            console.warn("Init: Failed to find VirtIO-Blk device for pid={}", .{proc.pid});
        }
    }

    // Doom capabilities
    if (std.mem.eql(u8, process_name, "doom")) {
        appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 12 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }, process_name);
        appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }, process_name);
        console.info("Init: Granted Doom capabilities to pid={}", .{proc.pid});
    }
}

const VirtioDriverType = enum {
    Net,
    Blk,
};

fn grantVirtioCapabilities(proc: *process.Process, driver_type: VirtioDriverType) bool {
    const devices = pci.getDevices() orelse return false;
    const alloc = heap.allocator();

    var i: usize = 0;
    while (i < devices.count) : (i += 1) {
        if (devices.get(i)) |dev| {
            // Check Vendor ID (VirtIO = 0x1AF4)
            if (dev.vendor_id != 0x1AF4) continue;

            // Check Device ID
            const is_net = (dev.device_id == 0x1000 or dev.device_id == 0x1041);
            const is_blk = (dev.device_id == 0x1001 or dev.device_id == 0x1042);

            if ((driver_type == .Net and is_net) or (driver_type == .Blk and is_blk)) {
                // Grant PciConfig Access
                appendCapabilityOrWarn(proc, alloc, .{
                    .PciConfig = .{
                        .bus = dev.bus,
                        .device = @intCast(dev.device),
                        .func = @intCast(dev.func),
                    }
                }, "virtio");

                // Grant MMIO Access for BARs
                for (dev.bar) |bar| {
                    if (bar.is_mmio and bar.base != 0 and bar.size != 0) {
                        appendCapabilityOrWarn(proc, alloc, .{
                            .Mmio = .{
                                .phys_addr = bar.base,
                                .size = bar.size,
                            }
                        }, "virtio");
                    }
                }

                // Grant Interrupt Capability
                appendCapabilityOrWarn(proc, alloc, .{
                    .Interrupt = .{ .irq = dev.irq_line }
                }, "virtio");

                // Grant DMA Memory Capability
                const dma_pages: u32 = switch (driver_type) {
                    .Net => 256,
                    .Blk => 128,
                };
                appendCapabilityOrWarn(proc, alloc, .{
                    .DmaMemory = .{ .max_pages = dma_pages }
                }, "virtio");

                if (kernel_iommu.isAvailable()) {
                    const max_size = std.math.mul(
                        u64,
                        @as(u64, dma_pages),
                        @as(u64, pmm.PAGE_SIZE),
                    ) catch {
                        console.err("virtio: IOMMU max_size overflow for dma_pages={d}", .{dma_pages});
                        return false;
                    };
                    appendCapabilityOrWarn(proc, alloc, .{
                        .IommuDma = .{
                            .bus = dev.bus,
                            .device = @intCast(dev.device),
                            .func = @intCast(dev.func),
                            .max_size = max_size,
                            .domain_id = 0,
                            .iommu_required = true,
                        }
                    }, "virtio");
                }

                return true;
            }
        }
    }
    return false;
}
