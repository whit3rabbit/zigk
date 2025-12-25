const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const elf = std.elf;

pub const LoaderError = error{
    LocateProtocolFailed,
    OpenVolumeFailed,
    KernelNotFound,
    ReadFailed,
    SeekFailed,
    InvalidElf,
    AllocateFailed,
    SegmentsBufferTooSmall,
    SymbolNotFound,
    InitrdNotFound,
    InitrdTooLarge,
};

pub const LoadedSegment = struct {
    virtual_address: u64,
    physical_address: u64,
    page_count: usize,
    size: u64,
    writable: bool,
    executable: bool,
};

pub const LoadResult = struct {
    entry_point: u64,
    segment_count: usize,
};

pub fn loadKernel(bs: *uefi.tables.BootServices, segments_buffer: []LoadedSegment) LoaderError!LoadResult {
    // Locate Protocol
    const fs = bs.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch {
        return LoaderError.LocateProtocolFailed;
    } orelse return LoaderError.LocateProtocolFailed;

    var root = fs.openVolume() catch {
        return LoaderError.OpenVolumeFailed;
    };
    defer _ = root.close() catch {};

    const kernel_path = [_:0]u16{ 'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f' };
    var kernel_file = root.open(&kernel_path, .read, .{}) catch {
        return LoaderError.KernelNotFound;
    };
    defer _ = kernel_file.close() catch {};

    // Read ELF Header
    var ehdr: elf.Elf64_Ehdr = std.mem.zeroes(elf.Elf64_Ehdr);
    const ehdr_bytes_read = kernel_file.read(std.mem.asBytes(&ehdr)) catch return LoaderError.ReadFailed;

    // Validate full header was read
    if (ehdr_bytes_read != @sizeOf(elf.Elf64_Ehdr)) {
        debugPrint("[ELF] Header size mismatch\r\n");
        return LoaderError.InvalidElf;
    }

    // Validate Magic
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) {
        debugPrint("[ELF] Invalid magic\r\n");
        return LoaderError.InvalidElf;
    }

    // Validate ELF class (must be 64-bit)
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        debugPrint("[ELF] Not 64-bit\r\n");
        return LoaderError.InvalidElf;
    }

    // Validate endianness (must be little-endian)
    if (ehdr.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) {
        debugPrint("[ELF] Not little-endian\r\n");
        return LoaderError.InvalidElf;
    }

    const expected_machine: elf.EM = switch (builtin.cpu.arch) {
        .x86_64 => .X86_64,
        .aarch64 => .AARCH64,
        else => {
            debugPrint("[ELF] Unsupported arch\r\n");
            return LoaderError.InvalidElf;
        },
    };
    if (ehdr.e_machine != expected_machine) {
        debugPrint("[ELF] Machine mismatch: expected ");
        debugPrintHex(@intFromEnum(expected_machine));
        debugPrint(" got ");
        debugPrintHex(@intFromEnum(ehdr.e_machine));
        debugPrint("\r\n");
        return LoaderError.InvalidElf;
    }

    // Validate program header offset and entry size
    if (ehdr.e_phoff == 0) {
        debugPrint("[ELF] No program headers\r\n");
        return LoaderError.InvalidElf;
    }
    if (ehdr.e_phentsize < @sizeOf(elf.Elf64_Phdr)) {
        debugPrint("[ELF] Program header size too small\r\n");
        return LoaderError.InvalidElf;
    }

    // Sanity check: reject unreasonable program header count (DoS prevention)
    const MAX_PHNUM: u16 = 256;
    if (ehdr.e_phnum > MAX_PHNUM) {
        debugPrint("[ELF] Too many program headers\r\n");
        return LoaderError.InvalidElf;
    }

    var segment_count: usize = 0;

    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr: elf.Elf64_Phdr = std.mem.zeroes(elf.Elf64_Phdr);

        // Calculate offset with overflow protection
        const phdr_offset = std.math.mul(u64, i, ehdr.e_phentsize) catch return LoaderError.InvalidElf;
        const offset = std.math.add(u64, ehdr.e_phoff, phdr_offset) catch return LoaderError.InvalidElf;

        kernel_file.setPosition(offset) catch return LoaderError.SeekFailed;

        const phdr_bytes_read = kernel_file.read(std.mem.asBytes(&phdr)) catch return LoaderError.ReadFailed;
        if (phdr_bytes_read != @sizeOf(elf.Elf64_Phdr)) {
            debugPrint("[ELF] Program header read incomplete\r\n");
            return LoaderError.InvalidElf;
        }

        if (phdr.p_type == elf.PT_LOAD) {
            if (segment_count >= segments_buffer.len) return LoaderError.SegmentsBufferTooSmall;

            // Validate virtual address is in expected kernel range (higher half)
            const KERNEL_VADDR_MIN: u64 = 0xFFFF_8000_0000_0000;
            if (phdr.p_vaddr < KERNEL_VADDR_MIN) {
                debugPrint("[ELF] Segment vaddr too low: ");
                debugPrintHex(phdr.p_vaddr);
                debugPrint("\r\n");
                return LoaderError.InvalidElf;
            }

            // Check for overlapping segments with previously loaded ones
            const seg_end = std.math.add(u64, phdr.p_vaddr, phdr.p_memsz) catch {
                debugPrint("[ELF] Segment end overflow\r\n");
                return LoaderError.InvalidElf;
            };
            for (segments_buffer[0..segment_count]) |prev| {
                const prev_end = std.math.add(u64, prev.virtual_address, prev.size) catch {
                    debugPrint("[ELF] Prev segment end overflow\r\n");
                    return LoaderError.InvalidElf;
                };
                // Overlap if: new_start < prev_end AND prev_start < new_end
                if (phdr.p_vaddr < prev_end and prev.virtual_address < seg_end) {
                    debugPrint("[ELF] Overlapping segments\r\n");
                    return LoaderError.InvalidElf;
                }
            }

            // Calculate pages needed with overflow protection
            const mem_size = phdr.p_memsz;
            const aligned_size = std.math.add(u64, mem_size, 4095) catch {
                debugPrint("[ELF] Size alignment overflow\r\n");
                return LoaderError.InvalidElf;
            };
            const page_count = aligned_size / 4096;

            // Sanity check: reject unreasonable kernel sizes (> 1GB)
            const MAX_KERNEL_PAGES: u64 = (1024 * 1024 * 1024) / 4096;
            if (page_count == 0 or page_count > MAX_KERNEL_PAGES) {
                debugPrint("[ELF] Invalid page count\r\n");
                return LoaderError.InvalidElf;
            }

            // Allocate physical memory
            const pages_slice = bs.allocatePages(
                .any,
                .loader_data,
                page_count,
            ) catch return LoaderError.AllocateFailed;

            const phys_addr = @intFromPtr(pages_slice.ptr);

            // Zero out memory (for BSS)
            const dest_slice = std.mem.sliceAsBytes(pages_slice);
            @memset(dest_slice, 0);

            // Load file data
            // Security: Reject malformed ELF where file size exceeds memory size
            // p_filesz should never exceed p_memsz (BSS is p_memsz - p_filesz)
            if (phdr.p_filesz > phdr.p_memsz) {
                debugPrint("[ELF] filesz > memsz\r\n");
                return LoaderError.InvalidElf;
            }

            if (phdr.p_filesz > 0) {
                kernel_file.setPosition(phdr.p_offset) catch return LoaderError.SeekFailed;

                if (phdr.p_filesz > dest_slice.len) return LoaderError.ReadFailed;

                const exact_dest = dest_slice[0..@intCast(phdr.p_filesz)];
                const bytes_read = kernel_file.read(exact_dest) catch return LoaderError.ReadFailed;
                if (bytes_read != phdr.p_filesz) return LoaderError.ReadFailed;
            }

            // Parse segment flags
            const writable = (phdr.p_flags & elf.PF_W) != 0;
            const executable = (phdr.p_flags & elf.PF_X) != 0;

            segments_buffer[segment_count] = .{
                .virtual_address = phdr.p_vaddr,
                .physical_address = phys_addr,
                .page_count = page_count,
                .size = mem_size,
                .writable = writable,
                .executable = executable,
            };
            segment_count += 1;
        }
    }

    // Try to find _uefi_start symbol for UEFI boot
    // If not found, fall back to e_entry (_start)
    const uefi_entry = findSymbol(kernel_file, &ehdr, bs, "_uefi_start") catch ehdr.e_entry;

    debugPrint("[ELF] Entry point: ");
    debugPrintHex(uefi_entry);
    debugPrint(" segments: ");
    debugPrintNum(segment_count);
    debugPrint("\r\n");

    // Validate entry point is within a loaded executable segment
    var entry_valid = false;
    for (segments_buffer[0..segment_count]) |seg| {
        const seg_end = std.math.add(u64, seg.virtual_address, seg.size) catch continue;
        debugPrint("[ELF] Seg: ");
        debugPrintHex(seg.virtual_address);
        debugPrint("-");
        debugPrintHex(seg_end);
        debugPrint(if (seg.executable) " X" else " -");
        debugPrint("\r\n");
        if (uefi_entry >= seg.virtual_address and uefi_entry < seg_end and seg.executable) {
            entry_valid = true;
            break;
        }
    }
    if (!entry_valid) {
        debugPrint("[ELF] Entry point not in executable segment\r\n");
        return LoaderError.InvalidElf;
    }

    return .{
        .entry_point = uefi_entry,
        .segment_count = segment_count,
    };
}

/// Search for a symbol by name in the ELF symbol table
fn findSymbol(
    file: *uefi.protocol.File,
    ehdr: *const elf.Elf64_Ehdr,
    bs: *uefi.tables.BootServices,
    name: []const u8,
) LoaderError!u64 {
    if (ehdr.e_shoff == 0 or ehdr.e_shnum == 0) return LoaderError.SymbolNotFound;

    // Validate section header entry size
    if (ehdr.e_shentsize < @sizeOf(elf.Elf64_Shdr)) return LoaderError.InvalidElf;

    // Sanity check: reject unreasonable section header count (DoS prevention)
    const MAX_SHNUM: u16 = 256;
    if (ehdr.e_shnum > MAX_SHNUM) return LoaderError.InvalidElf;

    // Read section headers to find .symtab and .strtab
    var symtab_shdr: ?elf.Elf64_Shdr = null;
    var strtab_shdr: ?elf.Elf64_Shdr = null;

    var i: usize = 0;
    while (i < ehdr.e_shnum) : (i += 1) {
        var shdr: elf.Elf64_Shdr = std.mem.zeroes(elf.Elf64_Shdr);

        // Calculate offset with overflow protection
        const shdr_offset = std.math.mul(u64, i, ehdr.e_shentsize) catch return LoaderError.InvalidElf;
        const offset = std.math.add(u64, ehdr.e_shoff, shdr_offset) catch return LoaderError.InvalidElf;

        file.setPosition(offset) catch return LoaderError.SeekFailed;
        const bytes_read = file.read(std.mem.asBytes(&shdr)) catch return LoaderError.ReadFailed;
        if (bytes_read != @sizeOf(elf.Elf64_Shdr)) return LoaderError.InvalidElf;

        if (shdr.sh_type == elf.SHT_SYMTAB) {
            symtab_shdr = shdr;
        } else if (shdr.sh_type == elf.SHT_STRTAB and symtab_shdr != null) {
            // Get the string table linked from symtab
            if (symtab_shdr.?.sh_link == i) {
                strtab_shdr = shdr;
            }
        }
    }

    // Also check if we need to find strtab by link index
    if (symtab_shdr != null and strtab_shdr == null) {
        var shdr: elf.Elf64_Shdr = std.mem.zeroes(elf.Elf64_Shdr);
        const link_idx = symtab_shdr.?.sh_link;

        // Validate link index is within bounds
        if (link_idx >= ehdr.e_shnum) return LoaderError.InvalidElf;

        // Calculate offset with overflow protection
        const shdr_offset = std.math.mul(u64, link_idx, ehdr.e_shentsize) catch return LoaderError.InvalidElf;
        const offset = std.math.add(u64, ehdr.e_shoff, shdr_offset) catch return LoaderError.InvalidElf;

        file.setPosition(offset) catch return LoaderError.SeekFailed;
        const bytes_read = file.read(std.mem.asBytes(&shdr)) catch return LoaderError.ReadFailed;
        if (bytes_read != @sizeOf(elf.Elf64_Shdr)) return LoaderError.InvalidElf;

        // Validate the linked section is actually a string table
        if (shdr.sh_type != elf.SHT_STRTAB) return LoaderError.InvalidElf;
        strtab_shdr = shdr;
    }

    const symtab = symtab_shdr orelse return LoaderError.SymbolNotFound;
    const strtab = strtab_shdr orelse return LoaderError.SymbolNotFound;

    // Validate symbol table size is reasonable (< 64MB)
    const MAX_SYMTAB_SIZE: u64 = 64 * 1024 * 1024;
    if (symtab.sh_size == 0 or symtab.sh_size > MAX_SYMTAB_SIZE) return LoaderError.InvalidElf;

    // Validate string table size is reasonable (< 64MB)
    const MAX_STRTAB_SIZE: u64 = 64 * 1024 * 1024;
    if (strtab.sh_size == 0 or strtab.sh_size > MAX_STRTAB_SIZE) return LoaderError.InvalidElf;

    // Allocate buffer for string table with overflow protection
    const strtab_aligned = std.math.add(u64, strtab.sh_size, 4095) catch return LoaderError.InvalidElf;
    const strtab_pages = strtab_aligned / 4096;
    const strtab_buf = bs.allocatePages(.any, .loader_data, strtab_pages) catch {
        return LoaderError.AllocateFailed;
    };
    defer _ = bs.freePages(strtab_buf) catch {};

    const strtab_slice = @as([*]u8, @ptrCast(strtab_buf.ptr))[0..@intCast(strtab.sh_size)];
    file.setPosition(strtab.sh_offset) catch return LoaderError.SeekFailed;
    const strtab_bytes_read = file.read(strtab_slice) catch return LoaderError.ReadFailed;
    if (strtab_bytes_read != strtab.sh_size) return LoaderError.InvalidElf;

    // Search symbols
    const sym_count = symtab.sh_size / @sizeOf(elf.Elf64_Sym);
    var sym_idx: usize = 0;
    while (sym_idx < sym_count) : (sym_idx += 1) {
        var sym: elf.Elf64_Sym = std.mem.zeroes(elf.Elf64_Sym);

        // Calculate offset with overflow protection
        const sym_entry_offset = std.math.mul(u64, sym_idx, @sizeOf(elf.Elf64_Sym)) catch return LoaderError.InvalidElf;
        const sym_offset = std.math.add(u64, symtab.sh_offset, sym_entry_offset) catch return LoaderError.InvalidElf;

        file.setPosition(sym_offset) catch return LoaderError.SeekFailed;
        const sym_bytes_read = file.read(std.mem.asBytes(&sym)) catch return LoaderError.ReadFailed;
        if (sym_bytes_read != @sizeOf(elf.Elf64_Sym)) return LoaderError.InvalidElf;

        if (sym.st_name == 0) continue;
        if (sym.st_name >= strtab.sh_size) continue;

        // Get symbol name from strtab
        const sym_name_start = strtab_slice[@intCast(sym.st_name)..];
        const sym_name_end = std.mem.indexOfScalar(u8, sym_name_start, 0) orelse sym_name_start.len;
        const sym_name = sym_name_start[0..sym_name_end];

        if (std.mem.eql(u8, sym_name, name)) {
            return sym.st_value;
        }
    }

    return LoaderError.SymbolNotFound;
}

/// Result of loading the initrd
pub const InitrdResult = struct {
    address: u64,
    size: u64,
};

/// Load initrd.tar from the EFI filesystem into memory
/// Returns physical address and size of the loaded initrd
pub fn loadInitrd(bs: *uefi.tables.BootServices) LoaderError!InitrdResult {
    // Maximum initrd size: 256MB
    const MAX_INITRD_SIZE: u64 = 256 * 1024 * 1024;

    // Locate filesystem protocol
    const fs = bs.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch {
        return LoaderError.LocateProtocolFailed;
    } orelse return LoaderError.LocateProtocolFailed;

    var root = fs.openVolume() catch {
        return LoaderError.OpenVolumeFailed;
    };
    defer _ = root.close() catch {};

    // Try to open initrd.tar
    const initrd_path = [_:0]u16{ 'i', 'n', 'i', 't', 'r', 'd', '.', 't', 'a', 'r' };
    var initrd_file = root.open(&initrd_path, .read, .{}) catch {
        return LoaderError.InitrdNotFound;
    };
    defer _ = initrd_file.close() catch {};

    // Get file size by seeking to end
    // First, get current position (should be 0)
    const start_pos = initrd_file.getPosition() catch return LoaderError.SeekFailed;
    _ = start_pos;

    // Seek to end to get file size
    initrd_file.setPosition(0xFFFFFFFFFFFFFFFF) catch return LoaderError.SeekFailed;
    const file_size = initrd_file.getPosition() catch return LoaderError.SeekFailed;

    // Seek back to start
    initrd_file.setPosition(0) catch return LoaderError.SeekFailed;

    if (file_size == 0) {
        return LoaderError.ReadFailed;
    }

    if (file_size > MAX_INITRD_SIZE) {
        return LoaderError.InitrdTooLarge;
    }

    // Calculate pages needed
    const aligned_size = std.math.add(u64, file_size, 4095) catch return LoaderError.InvalidElf;
    const page_count = aligned_size / 4096;

    // Allocate memory for initrd
    const pages_slice = bs.allocatePages(
        .any,
        .loader_data,
        page_count,
    ) catch return LoaderError.AllocateFailed;

    const phys_addr = @intFromPtr(pages_slice.ptr);

    // Zero the buffer first (security)
    const dest_slice = std.mem.sliceAsBytes(pages_slice);
    @memset(dest_slice, 0);

    // Read the file
    const exact_dest = dest_slice[0..@intCast(file_size)];
    const bytes_read = initrd_file.read(exact_dest) catch return LoaderError.ReadFailed;
    if (bytes_read != file_size) {
        return LoaderError.ReadFailed;
    }

    return .{
        .address = phys_addr,
        .size = file_size,
    };
}

// Debug output helpers for diagnostics
fn debugWrite(c: u8) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("outb %%al, %%dx" : : [val] "{al}" (c), [port] "{dx}" (@as(u16, 0x3F8))),
        .aarch64 => {
            const uart_base: usize = 0x09000000;
            const uart_dr: *volatile u32 = @ptrFromInt(uart_base);
            const uart_fr: *volatile u32 = @ptrFromInt(uart_base + 0x18);
            while ((uart_fr.* & 0x20) != 0) {}
            uart_dr.* = c;
        },
        else => {},
    }
}

fn debugPrint(msg: []const u8) void {
    for (msg) |c| {
        debugWrite(c);
    }
}

fn debugPrintHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    debugPrint("0x");
    var started = false;
    var i: u6 = 60;
    while (true) : (i -= 4) {
        const nibble: u4 = @truncate(value >> i);
        if (nibble != 0 or started or i == 0) {
            debugWrite(hex[nibble]);
            started = true;
        }
        if (i == 0) break;
    }
}

fn debugPrintNum(value: u64) void {
    if (value == 0) {
        debugWrite('0');
        return;
    }
    var buf: [20]u8 = undefined;
    var idx: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        buf[idx] = @truncate((v % 10) + '0');
        idx += 1;
    }
    while (idx > 0) {
        idx -= 1;
        debugWrite(buf[idx]);
    }
}
