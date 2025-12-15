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
    var selected_mod: ?*limine.Module = null;
    var process_name: []const u8 = "init";

    // Helper to safely get string from Limine pointer
    const get_str = struct {
        fn call(ptr: [*:0]const u8) []const u8 {
            if (@intFromPtr(ptr) == 0) return "";
            return std.mem.span(ptr);
        }
    }.call;

    // Priority 0: ASM Test (Sanity Check)
    for (mods) |mod| {
        const cmdline = get_str(mod.cmdline);
        const path = get_str(mod.path);

        if (std.mem.indexOf(u8, cmdline, "test_asm") != null or std.mem.indexOf(u8, path, "test_asm") != null) {
            selected_mod = mod;
            process_name = "test_asm";
            break;
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

    // Debug: List VFS root
    {
        // Try to open root to verify filesystem is up
        if (fs.vfs.Vfs.open("/", 0)) |root| {
             if (root.ops.close) |close_fn| {
                 _ = close_fn(root);
             }
        } else |err| {
            console.err("Failed to open root /: {}", .{err});
        }
    }
    
    // Debug: Check for WAD
    // Mode 0 = O_RDONLY
    if (fs.vfs.Vfs.open("/doom1.wad", 0)) |f| {
        console.info("KERNEL: Successfully opened /doom1.wad", .{});
        if (f.ops.close) |c| _ = c(f);
    } else |err| {
        console.warn("KERNEL: Failed to open /doom1.wad: {}", .{err});
    }

    // Step 1: Create Process with FD table (stdin/stdout/stderr pre-opened by devfs)
    const proc = process.createProcess(null) catch |err| {
        console.err("Failed to create init process: {}", .{err});
        return;
    };

    // Step 2: Set as current process so syscall handlers can access FD table
    syscall_base.setCurrentProcess(proc);
    console.info("Created process pid={d} with FD table", .{proc.pid});

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
