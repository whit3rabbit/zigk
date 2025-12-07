// ZigK Kernel Entry Point
//
// This is the main entry point for the ZigK microkernel.
// It is called by the boot32.S bootstrap code after switching to 64-bit mode.
// Entry: RDI contains the physical address of the Multiboot2 boot information.

const multiboot2 = @import("multiboot2");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const vmm = @import("vmm");
const heap = @import("heap");
const keyboard = @import("keyboard");
const sched = @import("sched");
const thread = @import("thread");
const stack_guard = @import("stack_guard");
const prng = @import("prng");

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

// External symbols from boot32.S
extern fn multiboot2_info_ptr() u32;
extern fn multiboot2_magic() u32;

/// Kernel entry point - called by boot32.S after mode switch
/// This function must be exported and named _start for the linker
export fn _start() noreturn {
    // Initialize HAL (serial port, GDT, PIC, IDT, interrupts)
    hal.init();

    // Connect console to interrupt handlers for debug output
    hal.interrupts.setConsoleWriter(&console.print);

    // Print boot banner
    console.print("\n");
    console.print("========================================\n");
    console.printf("{s} Microkernel v{s}\n", .{ config.name, config.version });
    console.print("========================================\n");
    console.print("\n");

    // Get Multiboot2 info from saved pointer in boot32.S
    // The physical address needs to be converted to virtual via HHDM
    const mb2_info_phys = @as(*const u32, @ptrFromInt(@intFromPtr(&multiboot2_info_ptr))).*;
    const mb2_magic = @as(*const u32, @ptrFromInt(@intFromPtr(&multiboot2_magic))).*;

    // Verify Multiboot2 magic
    if (mb2_magic != multiboot2.BOOTLOADER_MAGIC) {
        console.err("Invalid Multiboot2 magic: {x} (expected {x})", .{ mb2_magic, multiboot2.BOOTLOADER_MAGIC });
        halt();
    }
    console.info("Multiboot2 magic verified", .{});

    // Convert Multiboot2 info address to virtual (using HHDM)
    const mb2_info_virt = hal.paging.HHDM_OFFSET + mb2_info_phys;
    const boot_info: *const multiboot2.BootInfo = @ptrFromInt(mb2_info_virt);

    console.info("Multiboot2 info at phys={x} virt={x} size={d}", .{
        mb2_info_phys,
        mb2_info_virt,
        boot_info.total_size,
    });

    // Log bootloader name if available
    if (multiboot2.findBootLoaderNameTag(boot_info)) |name_tag| {
        const name = name_tag.name();
        console.info("Bootloader: {s}", .{name});
    }

    // Parse memory map
    if (multiboot2.findMmapTag(boot_info)) |mmap| {
        logMemoryMap(mmap);
    } else {
        console.err("Memory map not available!", .{});
        halt();
    }

    // Check for framebuffer (optional for serial-only testing)
    if (multiboot2.findFramebufferTag(boot_info)) |fb| {
        console.info("Framebuffer: {d}x{d} @ {x}", .{
            fb.framebuffer_width,
            fb.framebuffer_height,
            fb.framebuffer_addr,
        });
    } else {
        console.warn("No framebuffer available (serial-only mode)", .{});
    }

    // Check for loaded modules
    var mod_count: u32 = 0;
    var mod_iter = multiboot2.modules(boot_info);
    while (mod_iter.next()) |mod| {
        console.info("Module: {s} @ {x}-{x} ({d} bytes)", .{
            mod.cmdline(),
            mod.mod_start,
            mod.mod_end,
            mod.size(),
        });
        mod_count += 1;
    }
    if (mod_count > 0) {
        console.info("Loaded modules: {d}", .{mod_count});
    }

    // Initialize memory management subsystems
    initMemoryManagement(boot_info);

    // Initialize entropy subsystem (RDRAND/RDTSC detection)
    // Must be done before PRNG which depends on hardware entropy
    hal.entropy.init();
    console.info("Entropy source: {s}", .{if (hal.entropy.hasRdrand()) "RDRAND" else "RDTSC (fallback)"});

    // Initialize kernel PRNG (seeds from hardware entropy)
    // Must be done before stack_guard which uses PRNG for canary
    prng.init();

    // Initialize stack guard canary with randomized value
    // Must be done BEFORE scheduler creates any threads
    stack_guard.init();

    // Initialize keyboard driver and register with HAL
    keyboard.init();
    hal.interrupts.setKeyboardHandler(&keyboard.handleIrq);

    // Initialize scheduler (creates idle thread, registers timer handler)
    sched.init();

    // Log interrupt infrastructure status
    console.print("\n");
    console.info("Interrupt infrastructure initialized:", .{});
    console.info("  GDT loaded with TSS", .{});
    console.info("  PIC remapped to vectors 32-47", .{});
    console.info("  IDT installed with 48 handlers", .{});
    console.info("  Keyboard driver registered", .{});
    console.info("  Scheduler initialized", .{});
    console.info("  PRNG seeded, stack canary randomized", .{});

    console.print("\n");
    console.info("Kernel initialization complete", .{});

    // Create test threads to verify scheduler
    createTestThreads();

    // Start the scheduler - this does not return
    // The boot thread becomes part of the idle loop
    console.info("Starting scheduler...", .{});
    sched.start();
}

/// Create test threads to verify scheduler operation
fn createTestThreads() void {
    console.info("Creating test threads...", .{});

    // Create thread A - prints 'A' periodically
    const thread_a = thread.createKernelThread(testThreadA, .{
        .name = "test-A",
    }) catch |err| {
        console.err("Failed to create thread A: {}", .{err});
        return;
    };
    sched.addThread(thread_a);
    console.info("Created thread A (tid={d})", .{thread_a.tid});

    // Create thread B - prints 'B' periodically
    const thread_b = thread.createKernelThread(testThreadB, .{
        .name = "test-B",
    }) catch |err| {
        console.err("Failed to create thread B: {}", .{err});
        return;
    };
    sched.addThread(thread_b);
    console.info("Created thread B (tid={d})", .{thread_b.tid});
}

/// Test thread A - prints 'A' and yields
fn testThreadA() void {
    var count: u32 = 0;
    while (count < 10) : (count += 1) {
        console.print("A");
        // Busy wait a bit (no sleep syscall yet)
        busyWait(100000);
    }
    console.info("\nThread A completed", .{});
    sched.exit();
}

/// Test thread B - prints 'B' and yields
fn testThreadB() void {
    var count: u32 = 0;
    while (count < 10) : (count += 1) {
        console.print("B");
        // Busy wait a bit (no sleep syscall yet)
        busyWait(100000);
    }
    console.info("\nThread B completed", .{});
    sched.exit();
}

/// Simple busy wait loop
fn busyWait(iterations: u32) void {
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        asm volatile ("pause");
    }
}

/// Test interrupt handling by triggering a divide by zero exception
/// This should print an exception message and halt
fn testDivideByZero() void {
    console.warn("Testing divide by zero exception...", .{});
    // Inline assembly to trigger divide by zero
    // This will cause exception vector 0 to fire
    asm volatile (
        \\xor %%ecx, %%ecx
        \\div %%ecx
        :
        :
        : .{ .eax = true, .ecx = true, .edx = true }
    );
}

/// Test stack overflow detection by triggering a guard page fault
/// This function recurses until it overflows the stack, triggering
/// the guard page fault handler which should print stack overflow info.
/// WARNING: This will halt the kernel - only use for testing!
fn testStackOverflow() void {
    console.warn("Testing stack overflow detection...", .{});
    // Create a thread that will overflow its stack
    const overflow_thread = thread.createKernelThread(stackOverflowThread, .{
        .name = "overflow-test",
        .stack_size = 4096, // Small stack to overflow quickly
    }) catch |err| {
        console.err("Failed to create overflow test thread: {}", .{err});
        return;
    };
    sched.addThread(overflow_thread);
    console.info("Created stack overflow test thread (tid={d})", .{overflow_thread.tid});
}

/// Thread entry point that deliberately overflows its stack
/// Uses recursion with a large local buffer to quickly overflow
fn stackOverflowThread() void {
    console.info("Stack overflow test thread started, recursing...", .{});
    recursiveStackConsumer(0);
}

/// Recursive function that consumes stack space until overflow
/// Uses noinline to prevent tail-call optimization
fn recursiveStackConsumer(depth: u32) void {
    // Large buffer to consume stack quickly
    var buffer: [256]u8 = undefined;

    // Prevent buffer from being optimized away
    buffer[0] = @truncate(depth);

    // Touch the buffer to ensure it's actually on the stack
    for (buffer, 0..) |*b, i| {
        b.* = @truncate(i ^ depth);
    }

    // Print progress occasionally
    if (depth % 10 == 0) {
        console.printf("  Recursion depth: {d}\n", .{depth});
    }

    // Recurse until stack overflow - no escape condition
    // The guard page will catch this
    @call(.never_inline, recursiveStackConsumer, .{depth + 1});
}

/// Initialize PMM, VMM, and Heap
/// Uses Multiboot2 memory map
fn initMemoryManagement(boot_info: *const multiboot2.BootInfo) void {
    console.print("\n");
    console.info("Initializing memory management...", .{});

    // Initialize paging with HHDM offset (fixed for Multiboot2)
    hal.paging.init(hal.paging.HHDM_OFFSET);

    // Initialize PMM from Multiboot2 memory map
    if (multiboot2.findMmapTag(boot_info)) |mmap| {
        pmm.init(mmap) catch |err| {
            console.err("PMM initialization failed: {}", .{err});
            halt();
        };
    } else {
        console.err("Cannot initialize PMM: no memory map!", .{});
        halt();
    }

    // Initialize VMM with kernel page tables
    vmm.init() catch |err| {
        console.err("VMM initialization failed: {}", .{err});
        halt();
    };

    // Initialize kernel heap
    // Allocate heap pages from PMM
    const heap_pages = config.heap_size / pmm.PAGE_SIZE;
    const heap_phys = pmm.allocZeroedPages(heap_pages) orelse {
        console.err("Failed to allocate heap pages!", .{});
        halt();
    };

    // Convert to virtual address via HHDM for heap init
    const heap_virt = hal.paging.physToVirt(heap_phys);
    heap.init(@intFromPtr(heap_virt), config.heap_size);

    console.info("Memory management initialized", .{});
    pmm.printStats();
    heap.printStats();
}

/// Log memory map entries for debugging
fn logMemoryMap(mmap: *const multiboot2.MmapTag) void {
    var usable_memory: u64 = 0;
    var total_memory: u64 = 0;
    var entry_count: u32 = 0;

    var iter = mmap.entries();
    while (iter.next()) |entry| {
        entry_count += 1;
        total_memory += entry.length;

        const type_str = switch (entry.mem_type) {
            .available => blk: {
                usable_memory += entry.length;
                break :blk "Available";
            },
            .reserved => "Reserved",
            .acpi_reclaimable => "ACPI Reclaimable",
            .acpi_nvs => "ACPI NVS",
            .bad_memory => "Bad Memory",
            else => "Unknown",
        };

        if (config.debug_memory) {
            console.printf("  {x} - {x} ({s})\n", .{
                entry.base_addr,
                entry.base_addr + entry.length,
                type_str,
            });
        }
    }

    console.info("Memory map entries: {d}", .{entry_count});
    console.info("Total memory: {d} MB", .{total_memory / (1024 * 1024)});
    console.info("Usable memory: {d} MB", .{usable_memory / (1024 * 1024)});
}

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) [*]u8 {
    return @ptrFromInt(phys + hal.paging.HHDM_OFFSET);
}

/// Convert virtual address to physical using HHDM
pub fn virtToPhys(virt: u64) u64 {
    return virt - hal.paging.HHDM_OFFSET;
}

/// Halt the kernel (disables interrupts and loops forever)
fn halt() noreturn {
    hal.cpu.haltForever();
}

// Custom panic handler for freestanding environment
//
// SMP Panic Requirements (for future multi-core support):
// When SMP is implemented, this handler must be updated to:
// 1. Set an atomic global panic flag before any output
// 2. Send NMI IPI to all Application Processors (APs)
// 3. APs should check panic flag in their main loops and halt
// 4. BSP (Bootstrap Processor) waits briefly for APs before final halt
//
// Without this, other cores continue executing potentially corrupted state.
// Reference: Intel SDM Vol 3A, Chapter 10 (APIC) for IPI mechanisms.
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    // Disable interrupts to prevent further issues on this core
    hal.cpu.disableInterrupts();

    // TODO(SMP): When multi-core is implemented:
    // 1. @atomicStore(&global_panic_flag, true, .seq_cst);
    // 2. lapic.sendBroadcastNmi(); // Send NMI to all other cores
    // 3. Brief spin waiting for APs to acknowledge (with timeout)

    console.print("\n!!! KERNEL PANIC !!!\n");
    console.print("Message: ");
    console.print(msg);
    console.print("\n");

    halt();
}
