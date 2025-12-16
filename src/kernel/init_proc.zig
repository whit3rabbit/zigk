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

/// Load the init process (httpd or shell) into a new user address space
/// Creates a proper Process struct with FD table (stdin/stdout/stderr pre-opened)
/// and uses the ELF loader to parse and load the executable.
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
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);
        
        if (std.mem.indexOf(u8, cmdline, "uart_driver") != null or std.mem.indexOf(u8, path, "uart_driver") != null) {
            spawnProcess(mod, "uart_driver");
        }
        if (std.mem.indexOf(u8, cmdline, "ps2_driver") != null or std.mem.indexOf(u8, path, "ps2_driver") != null) {
            spawnProcess(mod, "ps2_driver");
        }
        if (std.mem.indexOf(u8, cmdline, "virtio_net_driver") != null or std.mem.indexOf(u8, path, "virtio_net_driver") != null) {
            spawnProcess(mod, "virtio_net_driver");
        }
        if (std.mem.indexOf(u8, cmdline, "virtio_blk_driver") != null or std.mem.indexOf(u8, path, "virtio_blk_driver") != null) {
            spawnProcess(mod, "virtio_blk_driver");
        }
    }

    // 2. Select Main Init Process
    var selected_mod: ?*limine.Module = null;
    var process_name: []const u8 = "init";

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

fn spawnProcess(mod: *limine.Module, process_name: []const u8) void {
    console.info("Spawning process: {s}", .{process_name});

    // Step 1: Create Process with FD table (stdin/stdout/stderr pre-opened by devfs)
    const proc = process.createProcess(null) catch |err| {
        console.err("Failed to create init process: {}", .{err});
        return;
    };

    // Step 2: Set as current process so syscall handlers can access FD table
    syscall_base.setCurrentProcess(proc);
    console.info("Created process pid={d} with FD table", .{proc.pid});

    // Grant capabilities if this is the UART driver
    if (std.mem.eql(u8, process_name, "uart_driver")) {
         const alloc = heap.allocator();
         // Grant IRQ 4
         proc.capabilities.append(alloc, .{ .Interrupt = .{ .irq = 4 } }) catch {};
         // Grant Ports 0x3F8, len 8 (COM1)
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }) catch {};
         console.info("Init: Granted UART capabilities to pid={}", .{proc.pid});
    }

    // Grant capabilities if this is the PS/2 driver
    if (std.mem.eql(u8, process_name, "ps2_driver")) {
         const alloc = heap.allocator();
         // Grant IRQ 1 (Keyboard)
         proc.capabilities.append(alloc, .{ .Interrupt = .{ .irq = 1 } }) catch {};
         // Grant IRQ 12 (Mouse)
         proc.capabilities.append(alloc, .{ .Interrupt = .{ .irq = 12 } }) catch {};
         // Grant Ports 0x60, 0x64 (Controller)
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }) catch {};
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }) catch {};
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
         proc.capabilities.append(alloc, .{ .Interrupt = .{ .irq = 1 } }) catch {};
         // Grant IRQ 12 (Mouse)
         proc.capabilities.append(alloc, .{ .Interrupt = .{ .irq = 12 } }) catch {};
         // Grant Ports 0x60, 0x64 (PC/AT Keyboard/Mouse Controller)
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x60, .len = 1 } }) catch {};
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x64, .len = 1 } }) catch {};
         // Grant Serial (COM1) for debug output (optional but helpful)
         proc.capabilities.append(alloc, .{ .IoPort = .{ .port = 0x3F8, .len = 8 } }) catch {};
         console.info("Init: Granted Doom capabilities to pid={}", .{proc.pid});
    }

    console.info("Init: Loading ELF...", .{});

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

    // Initialize heap boundaries
    const heap_start = std.mem.alignForward(u64, load_result.end_addr, pmm.PAGE_SIZE);
    proc.heap_start = heap_start;
    proc.heap_break = heap_start;
    console.info("Init: Heap initialized at {x}", .{heap_start});

    console.info("Init: Setting up user stack...", .{});
    // Step 5: Allocate and map user stack with arguments
    // We use the ELF helper to set up the stack according to x86_64 ABI
    // (argc, argv, envp, auxv)
    const stack_virt_top: u64 = 0xF0000000;
    const stack_size: usize = 1024 * 1024; // 1MB stack

    // Parse arguments from module command line
    var argv_buf: [16][]const u8 = undefined;
    var argv_count: usize = 0;

    if (@intFromPtr(mod.cmdline) != 0) {
        const cmd_slice = std.mem.span(mod.cmdline);
        console.debug("Init: Raw Cmdline: '{s}'", .{cmd_slice});
        var it = std.mem.tokenizeAny(u8, cmd_slice, " ");
        while (it.next()) |arg| {
            if (argv_count >= 16) break;
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
    };

    console.info("Creating user stack at {x} (size={d})", .{ stack_virt_top, stack_size });

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
    const tls_base_addr: u64 = 0xB000_0000; // Preferred address for TCB
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
/// Searches for a module with "initrd" in its cmdline or path
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
                proc.capabilities.append(alloc, .{
                    .PciConfig = .{
                        .bus = dev.bus,
                        .device = @intCast(dev.device),
                        .func = @intCast(dev.func),
                    }
                }) catch {};

                // Grant MMIO Access for BARs
                for (dev.bar) |bar| {
                    if (bar.is_mmio and bar.base != 0 and bar.size != 0) {
                        proc.capabilities.append(alloc, .{
                            .Mmio = .{
                                .phys_addr = bar.base,
                                .size = bar.size,
                            }
                        }) catch {};
                    }
                }
                
                // Grant Interrupt Capability
                proc.capabilities.append(alloc, .{
                    .Interrupt = .{ .irq = dev.irq_line }
                }) catch {};

                // Grant DMA Memory Capability (e.g. 512 pages / 2MB)
                proc.capabilities.append(alloc, .{
                    .DmaMemory = .{ .max_pages = 512 }
                }) catch {};

                return true;
            }
        }
    }
    return false;
}
