// Zscapek UEFI Bootloader
// Phase 3: Full boot implementation
//
// Boot sequence:
// 1. Initialize serial for debug output
// 2. Load kernel ELF and parse segments
// 3. Get memory map from UEFI
// 4. Initialize GOP for framebuffer
// 5. Find RSDP (ACPI)
// 6. Build page tables (Identity + HHDM + Kernel)
// 7. Call ExitBootServices
// 8. Switch to new page tables
// 9. Jump to kernel entry point

const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const BootInfo = @import("boot_info");
const loader = @import("loader.zig");
const memory = @import("memory.zig");
const graphics = @import("graphics.zig");
const paging = @import("paging.zig");
const menu = @import("menu.zig");
const entropy = @import("entropy.zig");

// Constants
const HHDM_OFFSET: u64 = 0xFFFF_8000_0000_0000;

// KASLR configuration
const KASLR_STACK_ENTROPY_BITS: u5 = 12; // 4096 units * 4KB = 16MB range
const KASLR_MMIO_ENTROPY_BITS: u5 = 12; // 4096 units * 4KB = 16MB range
const KASLR_HEAP_ENTROPY_BITS: u5 = 8; // 256 units * 4KB = 1MB range
const KASLR_PAGE_SIZE: u64 = 4096;
const MAX_SEGMENTS: usize = 32;
const MAX_MEMMAP_ENTRIES: usize = 256;
const MEMMAP_BUFFER_SIZE: usize = MAX_MEMMAP_ENTRIES * @sizeOf(uefi.tables.MemoryDescriptor);

// Static buffers
var kernel_segments: [MAX_SEGMENTS]loader.LoadedSegment = std.mem.zeroes([MAX_SEGMENTS]loader.LoadedSegment);
var memmap_buffer: [MEMMAP_BUFFER_SIZE]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = std.mem.zeroes([MEMMAP_BUFFER_SIZE]u8);
var boot_memmap: [MAX_MEMMAP_ENTRIES]BootInfo.MemoryDescriptor = std.mem.zeroes([MAX_MEMMAP_ENTRIES]BootInfo.MemoryDescriptor);
var framebuffer_info: BootInfo.FramebufferInfo = std.mem.zeroes(BootInfo.FramebufferInfo);
var boot_info: BootInfo.BootInfo = std.mem.zeroes(BootInfo.BootInfo);
var cmdline_buffer: [64:0]u8 = std.mem.zeroes([64:0]u8);
var kaslr_entropy: [32]u8 = std.mem.zeroes([32]u8); // Entropy for KASLR offsets

pub fn main() void {
    const system_table = uefi.system_table;

    serialPrint("=== Zscapek UEFI Bootloader ===\r\n");

    // Clear screen and print banner
    if (system_table.con_out) |con_out| {
        _ = con_out.clearScreen() catch {};

        const msg = "Zscapek UEFI Bootloader - Phase 3\r\n";
        for (msg) |c| {
            var buf = [2:0]u16{ c, 0 };
            _ = con_out.outputString(&buf) catch {};
        }
    }

    const bs = system_table.boot_services orelse {
        serialPrint("ERROR: Boot services not available\r\n");
        stallForever();
    };

    // Step 0a: Acquire entropy for KASLR
    serialPrint("Acquiring KASLR entropy...\r\n");
    const entropy_result = entropy.getBootEntropy(bs, &kaslr_entropy);
    if (entropy_result.quality == .hardware) {
        serialPrint("KASLR: Using hardware RNG\r\n");
    } else if (entropy_result.quality == .weak) {
        serialPrint("WARNING: KASLR using weak TSC entropy\r\n");
    } else {
        serialPrint("WARNING: No entropy for KASLR\r\n");
    }

    // Step 0b: Show boot menu and get selection
    serialPrint("Showing boot menu...\r\n");
    const selection = menu.showMenu(bs, system_table.con_in, system_table.con_out) catch |err| blk: {
        serialPrint("WARNING: Menu failed (");
        serialPrintMenuError(err);
        serialPrint("), defaulting to shell\r\n");
        break :blk .shell;
    };

    // Set cmdline from selection
    const cmdline_str = selection.toCmdline();
    @memcpy(cmdline_buffer[0..cmdline_str.len], cmdline_str);
    serialPrint("Boot selection: ");
    serialPrint(cmdline_str);
    serialPrint("\r\n");

    // Clear screen before loading kernel
    if (system_table.con_out) |con_out| {
        _ = con_out.clearScreen() catch {};
    }

    // Step 1: Load kernel ELF
    serialPrint("Loading kernel.elf...\r\n");
    const load_result = loader.loadKernel(bs, &kernel_segments) catch |err| {
        serialPrint("ERROR: Failed to load kernel: ");
        serialPrintError(err);
        stallForever();
    };
    serialPrint("Kernel loaded: entry=");
    serialPrintHex(load_result.entry_point);
    serialPrint(" segments=");
    serialPrintNum(load_result.segment_count);
    serialPrint("\r\n");

    // Step 1b: Load initrd.tar
    serialPrint("Loading initrd.tar...\r\n");
    var initrd_addr: u64 = 0;
    var initrd_size: u64 = 0;
    if (loader.loadInitrd(bs)) |initrd| {
        initrd_addr = initrd.address;
        initrd_size = initrd.size;
        serialPrint("Initrd loaded: addr=");
        serialPrintHex(initrd_addr);
        serialPrint(" size=");
        serialPrintNum(initrd_size);
        serialPrint(" bytes\r\n");
    } else |err| {
        serialPrint("WARNING: Initrd not loaded: ");
        serialPrintError(err);
    }

    // Step 2: Get memory map
    serialPrint("Getting memory map...\r\n");
    var uefi_memmap = memory.getMemoryMap(bs, &memmap_buffer) catch {
        serialPrint("ERROR: Failed to get memory map\r\n");
        stallForever();
    };
    serialPrint("Memory map: ");
    serialPrintNum(uefi_memmap.entry_count);
    serialPrint(" entries, total usable: ");
    serialPrintNum(uefi_memmap.totalUsableMemory() / (1024 * 1024));
    serialPrint(" MB\r\n");

    const max_phys = memory.findMaxPhysicalAddress(&uefi_memmap);
    serialPrint("Max physical address: ");
    serialPrintHex(max_phys);
    serialPrint("\r\n");

    // Step 3: Initialize graphics
    serialPrint("Initializing GOP...\r\n");
    if (graphics.initGraphics(bs)) |fb| {
        framebuffer_info = fb;
        serialPrint("Framebuffer: ");
        serialPrintNum(fb.width);
        serialPrint("x");
        serialPrintNum(fb.height);
        serialPrint(" @ ");
        serialPrintHex(fb.address);
        serialPrint("\r\n");
    } else |_| {
        serialPrint("WARNING: GOP not available, continuing without framebuffer\r\n");
        framebuffer_info = std.mem.zeroes(BootInfo.FramebufferInfo);
    }

    // Step 4: Find RSDP
    serialPrint("Searching for RSDP...\r\n");
    const rsdp_addr = findRsdp(system_table);
    if (rsdp_addr != 0) {
        serialPrint("RSDP found at: ");
        serialPrintHex(rsdp_addr);
        serialPrint("\r\n");
    } else {
        serialPrint("WARNING: RSDP not found\r\n");
    }

    // Step 5: Build page tables
    serialPrint("Building page tables...\r\n");
    var paging_segments: [MAX_SEGMENTS]paging.KernelSegment = undefined;
    for (kernel_segments[0..load_result.segment_count], 0..) |seg, i| {
        paging_segments[i] = .{
            .virt_addr = seg.virtual_address,
            .phys_addr = seg.physical_address,
            .size = seg.size,
            .writable = seg.writable,
            .executable = seg.executable,
        };
    }

    const ttbr_phys = paging.createKernelPageTables(
        bs,
        max_phys,
        paging_segments[0..load_result.segment_count],
    ) catch {
        serialPrint("ERROR: Failed to create page tables\r\n");
        stallForever();
    };
    serialPrint("Page tables created at: ");
    serialPrintHex(ttbr_phys);
    serialPrint("\r\n");

    // Step 6: Prepare BootInfo structure
    var kernel_phys_base: u64 = 0;
    var kernel_virt_base: u64 = 0;
    if (load_result.segment_count > 0) {
        kernel_phys_base = kernel_segments[0].physical_address;
        kernel_virt_base = kernel_segments[0].virtual_address;
    }

    const stack_offset = entropy.calculateOffset(kaslr_entropy[0..2], KASLR_STACK_ENTROPY_BITS, KASLR_PAGE_SIZE);
    const mmio_offset = entropy.calculateOffset(kaslr_entropy[2..4], KASLR_MMIO_ENTROPY_BITS, KASLR_PAGE_SIZE);
    const heap_offset = entropy.calculateOffset(kaslr_entropy[4..6], KASLR_HEAP_ENTROPY_BITS, KASLR_PAGE_SIZE);

    boot_info = .{
        .memory_map = &boot_memmap,
        .memory_map_count = 0,
        .descriptor_size = @sizeOf(BootInfo.MemoryDescriptor),
        .framebuffer = &framebuffer_info,
        .rsdp = rsdp_addr,
        .initrd_addr = initrd_addr,
        .initrd_size = initrd_size,
        .cmdline = if (cmdline_buffer[0] != 0) @ptrCast(&cmdline_buffer) else null,
        .hhdm_offset = HHDM_OFFSET,
        .kernel_phys_base = kernel_phys_base,
        .kernel_virt_base = kernel_virt_base,
        .stack_region_offset = stack_offset,
        .mmio_region_offset = mmio_offset,
        .heap_offset = heap_offset,
    };

    serialPrint("BootInfo prepared\r\n");

    // Step 7: Exit boot services
    serialPrint("Calling ExitBootServices...\r\n");

    var exit_memmap = memory.getMemoryMap(bs, &memmap_buffer) catch {
        serialPrint("ERROR: Failed to get final memory map\r\n");
        stallForever();
    };

    const image_handle = uefi.handle;
    const exit_status = bs._exitBootServices(image_handle, exit_memmap.map_key);

    if (exit_status != .success) {
        exit_memmap = memory.getMemoryMap(bs, &memmap_buffer) catch {
            stallForever();
        };
        const retry_status = bs._exitBootServices(image_handle, exit_memmap.map_key);
        if (retry_status != .success) {
            stallForever();
        }
    }

    serialPrint("BOOT: ExitBootServices OK\r\n");

    const memmap_count = memory.convertToBootInfo(&exit_memmap, &boot_memmap);
    boot_info.memory_map_count = memmap_count;
    serialPrint("BOOT: Final memory map: ");
    serialPrintNum(memmap_count);
    serialPrint(" entries\r\n");

    // Step 8: Load new page tables
    serialPrint("BOOT: Loading page tables...\r\n");
    paging.loadPageTables(ttbr_phys);
    serialPrint("BOOT: Page tables loaded\r\n");

    // Step 9: Jump to kernel
    const boot_info_ptr = @intFromPtr(&boot_info);
    const entry_addr = load_result.entry_point;

    serialPrint("BOOT: Jumping to kernel entry=0x");
    serialPrintHex(entry_addr);
    serialPrint(" boot_info=0x");
    serialPrintHex(boot_info_ptr);
    serialPrint("\r\n");

    switch (builtin.cpu.arch) {
        .x86_64 => {
            asm volatile (
                \\mov %[bi], %%rdi
                \\jmp *%[entry]
                :
                : [bi] "r" (boot_info_ptr),
                  [entry] "r" (entry_addr),
            );
        },
        .aarch64 => {
            asm volatile (
                \\mov x0, %[bi]
                \\br %[entry]
                :
                : [bi] "r" (boot_info_ptr),
                  [entry] "r" (entry_addr),
            );
        },
        else => @compileError("Unsupported architecture"),
    }

    unreachable;
}

fn findRsdp(system_table: *uefi.tables.SystemTable) u64 {
    const acpi20_guid = uefi.Guid{
        .time_low = 0x8868e871,
        .time_mid = 0xe4f1,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0xbc,
        .clock_seq_low = 0x22,
        .node = [_]u8{ 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 },
    };

    const acpi10_guid = uefi.Guid{
        .time_low = 0xeb9d2d30,
        .time_mid = 0x2d88,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0x9a,
        .clock_seq_low = 0x16,
        .node = [_]u8{ 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d },
    };

    const MAX_CONFIG_ENTRIES: usize = 1024;
    if (system_table.number_of_table_entries > MAX_CONFIG_ENTRIES) return 0;
    if (system_table.number_of_table_entries == 0) return 0;

    const config_entries = system_table.configuration_table[0..system_table.number_of_table_entries];

    for (config_entries) |entry| {
        if (std.mem.eql(u8, std.mem.asBytes(&entry.vendor_guid), std.mem.asBytes(&acpi20_guid))) {
            return @intFromPtr(entry.vendor_table);
        }
    }

    for (config_entries) |entry| {
        if (std.mem.eql(u8, std.mem.asBytes(&entry.vendor_guid), std.mem.asBytes(&acpi10_guid))) {
            return @intFromPtr(entry.vendor_table);
        }
    }

    return 0;
}

fn stallForever() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            else => {},
        }
    }
}

// Serial output helpers
fn serialWrite(data: u8) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("outb %%al, %%dx" : : [val] "{al}" (data), [port] "{dx}" (@as(u16, 0x3F8))),
        .aarch64 => {
            // In AArch64 UEFI, we should really use UEFI console or a known MMIO address.
            // For now, we stub it or use UEFI console if available.
            // But main() might have already exited boot services.
            // If ExitBootServices was called, we need MMIO.
            // Assume PL011 at 0x09000000 (QEMU virt default) if no other info.
            const uart_base: usize = 0x09000000;
            const uart_dr: *volatile u32 = @ptrFromInt(uart_base);
            const uart_fr: *volatile u32 = @ptrFromInt(uart_base + 0x18);
            while ((uart_fr.* & 0x20) != 0) {} // Wait while TX full
            uart_dr.* = data;
        },
        else => {},
    }
}

fn serialPrint(msg: []const u8) void {
    for (msg) |c| {
        serialWrite(c);
    }
}

fn serialPrintHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    serialPrint("0x");
    var started = false;
    var i: u6 = 60;
    while (true) : (i -= 4) {
        const nibble: u4 = @truncate(value >> i);
        if (nibble != 0 or started or i == 0) {
            serialWrite(hex[nibble]);
            started = true;
        }
        if (i == 0) break;
    }
}

fn serialPrintNum(value: u64) void {
    if (value == 0) {
        serialWrite('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[i] = @truncate((v % 10) + '0');
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        serialWrite(buf[i]);
    }
}

fn serialPrintError(err: loader.LoaderError) void {
    const msg = switch (err) {
        error.LocateProtocolFailed => "LocateProtocolFailed",
        error.OpenVolumeFailed => "OpenVolumeFailed",
        error.KernelNotFound => "KernelNotFound",
        error.ReadFailed => "ReadFailed",
        error.SeekFailed => "SeekFailed",
        error.InvalidElf => "InvalidElf",
        error.AllocateFailed => "AllocateFailed",
        error.SegmentsBufferTooSmall => "SegmentsBufferTooSmall",
        error.SymbolNotFound => "SymbolNotFound",
        error.InitrdNotFound => "InitrdNotFound",
        error.InitrdTooLarge => "InitrdTooLarge",
    };
    serialPrint(msg);
    serialPrint("\r\n");
}

fn serialPrintMenuError(err: menu.MenuError) void {
    const msg = switch (err) {
        error.NoConsoleInput => "NoConsoleInput",
        error.NoConsoleOutput => "NoConsoleOutput",
        error.NoBootServices => "NoBootServices",
    };
    serialPrint(msg);
}
