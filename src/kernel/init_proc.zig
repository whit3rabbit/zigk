//! Init Process Loading
//!
//! Responsible for identifying, loading, and starting the initial userspace process (PID 1).
//!
//! Functionality:
//! - Scans Limine boot modules for suitable init candidates (test_asm, httpd, shell, doom).
//! - Creates the first process structure and address space.
//! - Uses the ELF loader to load the executable into memory.
//! - Sets up the user stack with arguments (argv) and environment (envp).
//! - Initializes TLS/TCB (Thread Control Block) for the main thread.
//! - Hands the thread over to the scheduler.
//!
//! Also handles the initialization of the Initial RAM Disk (InitRD) if provided.

const std = @import("std");
const limine = @import("limine");
const console = @import("console");
const process = @import("process");
const elf = @import("elf");
const syscall_base = @import("syscall_base");
const fs = @import("fs");
const sched = @import("sched");
const thread = @import("thread");
const pmm = @import("pmm");
const boot = @import("boot.zig");
const capabilities = @import("capabilities");
const heap = @import("heap");
const pci = @import("pci");
const aslr = @import("aslr");
const devfs = @import("devfs");

/// Load the init process (httpd or shell) into a new user address space
///
/// Steps:
/// 1. Find the best candidate module (based on name priority).
/// 2. Create a process struct and set it as current.
/// 3. Load the ELF executable.
/// 4. Setup stack and arguments.
/// 5. Setup TLS.
/// 6. Create the main thread and add to scheduler.
pub fn loadInitProcess() void {
    console.info("Searching for init module...", .{});

    const mod_response = boot.module_request.response orelse {
        console.warn("No modules loaded!", .{});
        return;
    };

    const mods = mod_response.modules();
    
    // Helper to safely get string from Limine pointer
    const get_str = struct {
        fn call(ptr: [*:0]const u8) []const u8 {
            if (@intFromPtr(ptr) == 0) return "";
            return std.mem.span(ptr);
        }
    }.call;

    // 1. Launch Drivers
    // NOTE: Substring matching is used here for flexibility, but exact path matching
    // or cryptographic signature verification would provide stronger guarantees that
    // only intended driver binaries receive hardware capabilities.
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);

        if (matchesDriverName(cmdline, path, "uart_driver")) {
            spawnProcess(mod, "uart_driver");
        }
        if (matchesDriverName(cmdline, path, "ps2_driver")) {
            spawnProcess(mod, "ps2_driver");
        }
        if (matchesDriverName(cmdline, path, "virtio_net_driver")) {
            spawnProcess(mod, "virtio_net_driver");
        }
        if (matchesDriverName(cmdline, path, "virtio_blk_driver")) {
            spawnProcess(mod, "virtio_blk_driver");
        }
        if (matchesDriverName(cmdline, path, "netstack")) {
            spawnProcess(mod, "netstack");
        }
    }

    // 2. Select Main Init Process
    var selected_mod: ?*limine.Module = null;
    var process_name: []const u8 = "init";



    // Priority 0.1: VDSO Test
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
    
            if (std.mem.indexOf(u8, cmdline, "test_vdso") != null or std.mem.indexOf(u8, path, "test_vdso") != null) {
                selected_mod = mod;
                process_name = "test_vdso";
                break;
            }
        }
    }

    // Priority 0.1: Signals FPU Test
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
    
            if (std.mem.indexOf(u8, cmdline, "test_signals_fpu") != null or std.mem.indexOf(u8, path, "test_signals_fpu") != null) {
                selected_mod = mod;
                process_name = "test_signals_fpu";
                break;
            }
        }
    }

    // Priority 0.1: ASM Test (Sanity Check)
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
    
            if (std.mem.indexOf(u8, cmdline, "test_asm") != null or std.mem.indexOf(u8, path, "test_asm") != null) {
                selected_mod = mod;
                process_name = "test_asm";
                break;
            }
        }
    }

    // Priority 0.5: Audio Test
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);

            if (std.mem.indexOf(u8, cmdline, "audio") != null or std.mem.indexOf(u8, path, "audio") != null) {
                selected_mod = mod;
                process_name = "audio_test";
                break;
            }
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

    // Priority 3: Doom
    if (selected_mod == null) {
        for (mods) |mod| {
            const cmdline = get_str(mod.cmdline);
            const path = get_str(mod.path);
            
            if (std.mem.indexOf(u8, cmdline, "doom") != null or std.mem.indexOf(u8, path, "doom") != null) {
                selected_mod = mod;
                process_name = "doom";
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
    spawnProcess(mod, process_name);
}

/// SECURITY: Match driver name with strict boundary checks.
/// Prevents capability spoofing via substring injection (e.g., "my_uart_driver_malware").
/// Only matches:
/// - Exact cmdline match: cmdline == "uart_driver"
/// - Exact path component: path ends with "/uart_driver" or "/uart_driver.elf"
fn matchesDriverName(cmdline: []const u8, path: []const u8, name: []const u8) bool {
    // Exact cmdline match
    if (std.mem.eql(u8, cmdline, name)) return true;

    // Check for exact path component match (must be preceded by '/')
    // This prevents "my_uart_driver" from matching "uart_driver"
    var buf: [65]u8 = undefined;

    // Match "/name" at end of path
    const slash_name = std.fmt.bufPrint(&buf, "/{s}", .{name}) catch return false;
    if (std.mem.endsWith(u8, path, slash_name)) return true;

    // Match "/name.elf" at end of path
    const slash_name_elf = std.fmt.bufPrint(&buf, "/{s}.elf", .{name}) catch return false;
    if (std.mem.endsWith(u8, path, slash_name_elf)) return true;

    return false;
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

fn spawnProcess(mod: *limine.Module, process_name: []const u8) void {
    console.info("Spawning process: {s}", .{process_name});

    // Step 1: Create Process with FD table (stdin/stdout/stderr pre-opened by devfs)
    const proc = process.createProcess(null) catch |err| {
        console.err("Failed to create init process: {}", .{err});
        return;
    };

    // Pre-populate stdin/stdout/stderr (moved from lifecycle.zig)
    devfs.createStdFds(proc.fd_table) catch |err| {
        console.warn("Failed to create std FDs for {s}: {}", .{process_name, err});
    };

    // Step 2: Set as current process so syscall handlers can access FD table
    syscall_base.setCurrentProcess(proc);
    console.info("Created process pid={d} with FD table", .{proc.pid});

    // Grant capabilities if this is the UART driver
    if (std.mem.eql(u8, process_name, "uart_driver")) {
         const alloc = heap.allocator();
         // Grant IRQ 4
         appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 4 } }, process_name);
         // Grant Ports 0x3F8, len 8 (COM1)
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }, process_name);
         console.info("Init: Granted UART capabilities to pid={}", .{proc.pid});
    }

    // Grant capabilities if this is the PS/2 driver
    if (std.mem.eql(u8, process_name, "ps2_driver")) {
         const alloc = heap.allocator();
         // Grant IRQ 1 (Keyboard)
         appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 1 } }, process_name);
         // Grant IRQ 12 (Mouse)
         appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 12 } }, process_name);
         // Grant Ports 0x60, 0x64 (Controller)
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }, process_name);
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }, process_name);
         // Grant input injection capability (send keyboard/mouse events to kernel)
         appendCapabilityOrWarn(proc, alloc, .{ .InputInjection = {} }, process_name);
         console.info("Init: Granted PS/2 capabilities to pid={}", .{proc.pid});
    }

    // Grant capabilities for VirtIO-Net
    if (std.mem.eql(u8, process_name, "virtio_net_driver")) {
         if (grantVirtioCapabilities(proc, .Net)) {
             console.info("Init: Granted VirtIO-Net capabilities to pid={}", .{proc.pid});
         } else {
             console.warn("Init: Failed to find VirtIO-Net device for pid={}", .{proc.pid});
         }
    }

    // Grant capabilities for VirtIO-Blk
    if (std.mem.eql(u8, process_name, "virtio_blk_driver")) {
         if (grantVirtioCapabilities(proc, .Blk)) {
             console.info("Init: Granted VirtIO-Blk capabilities to pid={}", .{proc.pid});
         } else {
             console.warn("Init: Failed to find VirtIO-Blk device for pid={}", .{proc.pid});
         }
    }

    // Grant capabilities if this is Doom
    if (std.mem.eql(u8, process_name, "doom")) {
         const alloc = heap.allocator();
         // Grant IRQ 1 (Keyboard)
         appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 1 } }, process_name);
         // Grant IRQ 12 (Mouse)
         appendCapabilityOrWarn(proc, alloc, .{ .Interrupt = .{ .irq = 12 } }, process_name);
         // Grant Ports 0x60, 0x64 (PC/AT Keyboard/Mouse Controller)
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }, process_name);
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }, process_name);
         // Grant Serial (COM1) for debug output (optional but helpful)
         appendCapabilityOrWarn(proc, alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }, process_name);
         console.info("Init: Granted Doom capabilities to pid={}", .{proc.pid});
    }

    console.info("Init: Loading ELF...", .{});

    // Step 3: Get module data as slice for ELF loader
    // Validation: Ensure valid address and no overflow
    if (mod.address == 0) {
        console.err("Invalid module address (null) for {s}", .{process_name});
        return;
    }
    if (mod.size == 0) {
        console.err("Invalid module size (zero) for {s}", .{process_name});
        return;
    }
    // Check for address overflow
    const end_addr = @addWithOverflow(mod.address, mod.size);
    if (end_addr[1] != 0) {
        console.err("Module address overflow for {s}: addr=0x{x} size={}",
                    .{process_name, mod.address, mod.size});
        return;
    }

    const mod_data = @as([*]const u8, @ptrFromInt(mod.address))[0..mod.size];

    // Step 4: Load ELF into process's address space
    // The ELF loader will parse headers, validate, and map PT_LOAD segments
    // Use ASLR-randomized PIE base from process offsets
    const load_base: u64 = aslr.getPieBase(&proc.aslr_offsets);
    const load_result = elf.load(mod_data, proc.cr3, load_base) catch |err| {
        console.err("ELF load failed: {}", .{err});
        return;
    };
    console.info("ELF: Loaded at {x}-{x}, entry={x} (ASLR)", .{
        load_result.base_addr,
        load_result.end_addr,
        load_result.entry_point,
    });

    // Initialize heap boundaries with ASLR heap gap
    const heap_start = aslr.getHeapStart(load_result.end_addr, &proc.aslr_offsets);
    proc.heap_start = heap_start;
    proc.heap_break = heap_start;
    console.info("Init: Heap initialized at {x} (ASLR gap={})", .{ heap_start, proc.aslr_offsets.heap_gap });

    console.info("Init: Setting up user stack...", .{});
    // Step 5: Allocate and map user stack with arguments
    // We use the ELF helper to set up the stack according to x86_64 ABI
    // (argc, argv, envp, auxv)
    // Use ASLR-randomized stack top from process offsets
    const stack_virt_top: u64 = proc.aslr_offsets.stack_top;
    const stack_size: usize = 1024 * 1024; // 1MB stack

    // Parse arguments from module command line
    // NOTE: Fixed buffer of 16 arguments; excess tokens are silently dropped.
    // Consider dynamic allocation or logging if truncation occurs.
    var argv_buf: [16][]const u8 = undefined;
    var argv_count: usize = 0;

    if (@intFromPtr(mod.cmdline) != 0) {
        const cmd_slice = std.mem.span(mod.cmdline);
        console.debug("Init: Raw Cmdline: '{s}'", .{cmd_slice});
        var it = std.mem.tokenizeAny(u8, cmd_slice, " ");
        while (it.next()) |arg| {
            if (argv_count >= 16) {
                console.warn("Init: Argument buffer full, truncating remaining args for {s}",
                             .{process_name});
                break;
            }
            argv_buf[argv_count] = arg;
            argv_count += 1;
        }
    }

    if (argv_count == 0) {
        argv_buf[0] = process_name;
        argv_count = 1;
    }

    // Workaround: If Limine truncates cmdline, manually add arguments for Doom
    if (argv_count == 1 and std.mem.eql(u8, argv_buf[0], "doom")) {
        console.warn("Init: Detecting Doom with no args, injecting defaults...", .{});
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

    console.info("Creating user stack at {x} (size={d}, ASLR)", .{ stack_virt_top, stack_size });

    // Log ASLR configuration for this process
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

    console.info("User stack created (rsp={x})", .{initial_rsp});
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
    // Musl static binaries may crash if %fs:0 is not accessible or doesn't point to itself.
    // Use randomized TLS base address from ASLR offsets.
    const tls_base_addr = proc.aslr_offsets.tls_base;
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

    console.info("Init: Adding thread to scheduler...", .{});
    sched.addThread(user_thread);
    console.info("Init process started (pid={d}, tid={d})", .{ proc.pid, user_thread.tid });
}

/// Initialize InitRD filesystem from Limine modules
/// Searches for a module with "initrd" in its cmdline or path.
/// If found, passes the data to the global InitRD instance.
pub fn initInitRD(mods: []const *limine.Module) void {
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
            // Net: 0x1000 (Legacy) or 0x1041 (Modern)
            // Blk: 0x1001 (Legacy) or 0x1042 (Modern)
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
                // Net: 1MB (rx/tx pages), Blk: 512KB
                const dma_pages: u32 = switch (driver_type) {
                    .Net => 256,
                    .Blk => 128,
                };
                appendCapabilityOrWarn(proc, alloc, .{
                    .DmaMemory = .{ .max_pages = dma_pages }
                }, "virtio");

                return true;
            }
        }
    }
    return false;
}
