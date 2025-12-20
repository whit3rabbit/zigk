const std = @import("std");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const console = @import("console");
const types = @import("types.zig");
const utils = @import("utils.zig");
const validation = @import("validation.zig");

const ElfError = types.ElfError;
const Elf64_Ehdr = types.Elf64_Ehdr;
const Elf64_Phdr = types.Elf64_Phdr;
const ElfLoadResult = types.ElfLoadResult;
const PageFlags = hal.paging.PageFlags;

const validateHeader = validation.validateHeader;
const copyToUserspace = utils.copyToUserspace;
const cleanupMappedSegment = utils.cleanupMappedSegment;

/// Load an ELF executable into an address space
///
/// Args:
///   data: Raw ELF file data (e.g., from InitRD module)
///   pml4_phys: Physical address of target page table (PML4)
///   load_base: Base address for PIE executables (0 for ET_EXEC)
///
/// Returns: ElfLoadResult with entry point and address range
pub fn load(data: []const u8, pml4_phys: u64, load_base: u64) ElfError!ElfLoadResult {
    // Verify we have enough data for the header
    if (data.len < @sizeOf(Elf64_Ehdr)) {
        return ElfError.BufferTooSmall;
    }

    // Parse and validate ELF header
    const ehdr: *const Elf64_Ehdr = @ptrCast(@alignCast(data.ptr));
    try validateHeader(ehdr);

    // Determine if PIE and actual load base
    const is_pie = ehdr.e_type == types.ET_DYN;
    const actual_base: u64 = if (is_pie) load_base else 0;

    // Verify we have program headers
    if (ehdr.e_phnum == 0) {
        return ElfError.NoLoadSegments;
    }

    // SECURITY: Verify program header table is within bounds using checked arithmetic.
    // A malicious ELF could set e_phoff near u64::MAX, causing the addition to wrap
    // around to a small value. The subsequent bounds check would pass, but the
    // pointer at line 265 (data.ptr + e_phoff) would be invalid, leading to OOB read.
    // Using std.math.add catches this overflow and returns an error safely.
    const phdr_table_size = @as(u64, ehdr.e_phnum) * @sizeOf(Elf64_Phdr);
    const phdr_end = std.math.add(u64, ehdr.e_phoff, phdr_table_size) catch {
        console.err("ELF: Program header table offset overflow", .{});
        return ElfError.BufferTooSmall;
    };
    if (phdr_end > data.len) {
        return ElfError.BufferTooSmall;
    }

    // Get program header table
    const phdr_ptr: [*]const Elf64_Phdr = @ptrCast(@alignCast(data.ptr + ehdr.e_phoff));
    const phdrs = phdr_ptr[0..ehdr.e_phnum];

    // Track address range and total memory for security limits
    var lowest_addr: u64 = std.math.maxInt(u64);
    var highest_addr: u64 = 0;
    var load_count: u32 = 0;
    var total_memory: u64 = 0;
    var phdr_vaddr: u64 = 0;
    var tls_phdr: ?Elf64_Phdr = null;

    // First pass: Find PT_PHDR and PT_TLS
    for (phdrs) |*phdr| {
        if (phdr.p_type == types.PT_PHDR) {
            phdr_vaddr = actual_base + phdr.p_vaddr;
        } else if (phdr.p_type == types.PT_TLS) {
            tls_phdr = phdr.*;
        }
    }
    // Fallback if no PT_PHDR: use base + offset
    if (phdr_vaddr == 0) {
        phdr_vaddr = actual_base + ehdr.e_phoff;
    }

    // Load each PT_LOAD segment
    for (phdrs) |*phdr| {
        if (phdr.p_type != types.PT_LOAD) {
            continue;
        }

        // Security: Check segment count limit
        if (load_count >= types.MAX_LOAD_SEGMENTS) {
            console.err("ELF: Too many PT_LOAD segments (max {})", .{types.MAX_LOAD_SEGMENTS});
            return ElfError.TooManySegments;
        }

        // Security: Check individual segment size limit
        if (phdr.p_memsz > types.MAX_SEGMENT_SIZE) {
            console.err("ELF: Segment too large: {} bytes (max {} MB)", .{
                phdr.p_memsz,
                types.MAX_SEGMENT_SIZE / (1024 * 1024),
            });
            return ElfError.SegmentTooLarge;
        }

        // Security: Check total memory limit (with overflow protection)
        if (total_memory > types.MAX_TOTAL_MEMORY - phdr.p_memsz) {
            console.err("ELF: Total memory exceeded: {} + {} > {} MB", .{
                total_memory,
                phdr.p_memsz,
                types.MAX_TOTAL_MEMORY / (1024 * 1024),
            });
            return ElfError.TotalMemoryExceeded;
        }
        total_memory += phdr.p_memsz;

        // Calculate virtual address with base offset (with overflow check)
        if (actual_base > std.math.maxInt(u64) - phdr.p_vaddr) {
            console.err("ELF: Base + p_vaddr overflow: base={x} vaddr={x}", .{ actual_base, phdr.p_vaddr });
            return ElfError.InvalidAddressRange;
        }
        const vaddr = actual_base + phdr.p_vaddr;

        // Calculate end address (with overflow check)
        if (vaddr > std.math.maxInt(u64) - phdr.p_memsz) {
            console.err("ELF: vaddr + p_memsz overflow: vaddr={x} memsz={x}", .{ vaddr, phdr.p_memsz });
            return ElfError.InvalidAddressRange;
        }
        const vaddr_end = vaddr + phdr.p_memsz;

        // Update address range
        if (vaddr < lowest_addr) lowest_addr = vaddr;
        if (vaddr_end > highest_addr) highest_addr = vaddr_end;

        // Load this segment
        try loadSegment(data, phdr, pml4_phys, actual_base);
        load_count += 1;

        console.debug("ELF: Loaded segment {x}-{x} (file={}, mem={}, flags={x})", .{
            vaddr,
            vaddr_end,
            phdr.p_filesz,
            phdr.p_memsz,
            phdr.p_flags,
        });
    }

    if (load_count == 0) {
        return ElfError.NoLoadSegments;
    }

    // Calculate entry point
    const entry = actual_base + ehdr.e_entry;

    // SECURITY: Validate entry point falls within loaded executable segments.
    // A malicious ELF could set e_entry to point at the user stack (which we map)
    // and then place shellcode in argv/envp strings. The "is mapped" check below
    // would pass since the stack is mapped, allowing execution of attacker code.
    // By requiring entry to be within [lowest_addr, highest_addr), we ensure it
    // points to a PT_LOAD segment we just loaded, not arbitrary mapped memory.
    if (entry < lowest_addr or entry >= highest_addr) {
        console.err("ELF: Entry point {x} not within loaded segments [{x}-{x})", .{
            entry,
            lowest_addr,
            highest_addr,
        });
        return ElfError.InvalidAddressRange;
    }

    console.info("ELF: Loaded {} segments, entry={x}", .{ load_count, entry });

    // Verify entry point contains actual code (not zeros from failed copy)
    if (vmm.translate(pml4_phys, entry)) |phys| {
        // Note: phys already includes page offset from translate()
        const ptr: [*]u8 = hal.paging.physToVirt(phys);
        const opcodes = ptr[0..4];
        console.debug("ELF: Entry {x} opcodes: {x} {x} {x} {x}", .{
            entry,
            opcodes[0],
            opcodes[1],
            opcodes[2],
            opcodes[3],
        });
        // All zeros at entry point means copy likely failed
        if (opcodes[0] == 0 and opcodes[1] == 0) {
            console.err("ELF: CRITICAL - Entry point contains zeros! Copy failed.", .{});
            return ElfError.MappingFailed;
        }
    } else {
        console.err("ELF: Entry point {x} is not mapped!", .{entry});
        return ElfError.MappingFailed;
    }



    return ElfLoadResult{
        .entry_point = entry,
        .base_addr = lowest_addr,
        .end_addr = highest_addr,
        .is_pie = is_pie,
        .phdr_addr = phdr_vaddr,
        .phnum = ehdr.e_phnum,
        .tls_phdr = tls_phdr,
    };
}

/// Load a single PT_LOAD segment
fn loadSegment(
    data: []const u8,
    phdr: *const Elf64_Phdr,
    pml4_phys: u64,
    base: u64,
) ElfError!void {
    const vaddr = base + phdr.p_vaddr;
    const seg_end = vaddr + phdr.p_memsz;

    if (seg_end < vaddr) {
        console.err("ELF: Segment address overflow vaddr={x} memsz={x}", .{ vaddr, phdr.p_memsz });
        return ElfError.InvalidAddressRange;
    }

    if (seg_end >= vmm.KERNEL_BASE) {
        console.err("ELF: Segment overlaps kernel space: {x}-{x}", .{ vaddr, seg_end });
        return ElfError.InvalidAddressRange;
    }

    const stack_base = types.DEFAULT_STACK_TOP - types.DEFAULT_STACK_SIZE;
    const stack_top = types.DEFAULT_STACK_TOP;
    if (vaddr < stack_top and seg_end > stack_base) {
        console.err("ELF: Segment overlaps user stack reservation: {x}-{x}", .{ vaddr, seg_end });
        return ElfError.InvalidAddressRange;
    }

    // Page-align the addresses
    const page_size = pmm.PAGE_SIZE;
    const vaddr_aligned = vaddr & ~@as(u64, page_size - 1);
    const vaddr_offset = vaddr - vaddr_aligned;

    // Calculate total size needed (including alignment padding)
    const total_size = std.mem.alignForward(u64, phdr.p_memsz + vaddr_offset, page_size);
    const page_count = total_size / page_size;

    // Convert flags to page flags
    const page_flags = PageFlags{
        .writable = (phdr.p_flags & types.PF_W) != 0,
        .user = true,
        .no_execute = (phdr.p_flags & types.PF_X) == 0,
    };

    // Allocate and map pages
    const alloc = heap.allocator();
    var mapped_pages = std.ArrayListUnmanaged(u64){};
    defer mapped_pages.deinit(alloc);

    var page_index: usize = 0;
    var current_vaddr = vaddr_aligned;

    while (page_index < page_count) : (page_index += 1) {
        // Allocate a physical page
        const phys_page = pmm.allocPage() orelse {
            cleanupMappedSegment(pml4_phys, vaddr_aligned, page_size, mapped_pages.items);
            return ElfError.OutOfMemory;
        };

        // Map it
        vmm.mapPage(pml4_phys, current_vaddr, phys_page, page_flags) catch {
            pmm.freePage(phys_page);
            cleanupMappedSegment(pml4_phys, vaddr_aligned, page_size, mapped_pages.items);
            return ElfError.MappingFailed;
        };

        // Track mapped page for unwinding on later errors
        mapped_pages.append(alloc, phys_page) catch {
            // Drop the mapping we just added and free the page
            vmm.unmapPage(pml4_phys, current_vaddr) catch {};
            pmm.freePage(phys_page);
            cleanupMappedSegment(pml4_phys, vaddr_aligned, page_size, mapped_pages.items);
            return ElfError.OutOfMemory;
        };

        // Zero the page first (important for BSS)
        const page_ptr: [*]u8 = hal.paging.physToVirt(phys_page);
        hal.mem.fill(page_ptr, 0, page_size);

        current_vaddr += page_size;
    }

    // Copy file data to memory
    if (phdr.p_filesz > 0) {
        // SECURITY: Validate p_filesz <= p_memsz before copying.
        // A malicious ELF could set p_filesz > p_memsz, causing the loader to
        // copy more data than the allocated region can hold. Since we allocate
        // pages based on p_memsz (line 429), but copy based on p_filesz, an
        // attacker could overflow into adjacent memory, corrupting kernel
        // data structures or achieving code execution.
        if (phdr.p_filesz > phdr.p_memsz) {
            console.err("ELF: Invalid segment: p_filesz ({}) > p_memsz ({})", .{ phdr.p_filesz, phdr.p_memsz });
            return ElfError.InvalidAddressRange;
        }

        // Verify file data is within bounds
        const file_end = phdr.p_offset + phdr.p_filesz;
        if (file_end > data.len) {
            return ElfError.BufferTooSmall;
        }

        // Get source data
        const src = data[phdr.p_offset..][0..phdr.p_filesz];

        // Debug: Log what we're copying
        console.debug("ELF: Copying {d} bytes from offset {x} to vaddr {x}", .{ phdr.p_filesz, phdr.p_offset, vaddr });
        if (src.len >= 4) {
            console.debug("ELF: First 4 bytes: {x} {x} {x} {x}", .{ src[0], src[1], src[2], src[3] });
        }

        // Copy to destination (may span multiple pages)
        try copyToUserspace(pml4_phys, vaddr, src);
    } else {
        console.debug("ELF: Segment has filesz=0 (BSS only)", .{});
    }

    // BSS (p_memsz > p_filesz) is already zeroed since we zero pages on allocation

}
