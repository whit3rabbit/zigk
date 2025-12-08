// ELF Loader
//
// Parses and loads ELF64 executables into a process address space.
// Used by sys_execve to replace a process's memory image with a new program.
//
// Supports:
//   - ET_EXEC (fixed address executables)
//   - ET_DYN (position-independent executables) with fixed base
//   - PT_LOAD segments with BSS handling
//   - x86_64 architecture only
//
// Limitations (MVP):
//   - No dynamic linking (static executables only)
//   - No interpreter support (PT_INTERP ignored)
//   - Loads from memory buffer (InitRD modules)

const std = @import("std");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const console = @import("console");
const uapi = @import("uapi");

const paging = hal.paging;
const PageFlags = paging.PageFlags;
const Errno = uapi.errno.Errno;

// =============================================================================
// ELF Constants
// =============================================================================

/// ELF magic bytes
pub const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

/// ELF class (32-bit vs 64-bit)
pub const ELFCLASS64: u8 = 2;

/// ELF data encoding (endianness)
pub const ELFDATA2LSB: u8 = 1; // Little-endian

/// ELF version
pub const EV_CURRENT: u8 = 1;

/// ELF OS/ABI
pub const ELFOSABI_NONE: u8 = 0; // UNIX System V ABI

/// ELF file types
pub const ET_EXEC: u16 = 2; // Executable file
pub const ET_DYN: u16 = 3; // Shared object / PIE executable

/// ELF machine types
pub const EM_X86_64: u16 = 62; // AMD x86-64

/// Program header types
pub const PT_NULL: u32 = 0; // Unused entry
pub const PT_LOAD: u32 = 1; // Loadable segment
pub const PT_DYNAMIC: u32 = 2; // Dynamic linking info
pub const PT_INTERP: u32 = 3; // Interpreter path
pub const PT_NOTE: u32 = 4; // Auxiliary info
pub const PT_PHDR: u32 = 6; // Program header table
pub const PT_GNU_STACK: u32 = 0x6474e551; // Stack flags

/// Program header flags
pub const PF_X: u32 = 1; // Execute
pub const PF_W: u32 = 2; // Write
pub const PF_R: u32 = 4; // Read

// =============================================================================
// ELF Structures (64-bit)
// =============================================================================

/// ELF64 file header
pub const Elf64_Ehdr = extern struct {
    e_ident: [16]u8, // ELF identification
    e_type: u16, // Object file type
    e_machine: u16, // Machine type
    e_version: u32, // Object file version
    e_entry: u64, // Entry point address
    e_phoff: u64, // Program header offset
    e_shoff: u64, // Section header offset
    e_flags: u32, // Processor-specific flags
    e_ehsize: u16, // ELF header size
    e_phentsize: u16, // Size of program header entry
    e_phnum: u16, // Number of program header entries
    e_shentsize: u16, // Size of section header entry
    e_shnum: u16, // Number of section header entries
    e_shstrndx: u16, // Section name string table index
};

/// ELF64 program header
pub const Elf64_Phdr = extern struct {
    p_type: u32, // Segment type
    p_flags: u32, // Segment flags
    p_offset: u64, // Offset in file
    p_vaddr: u64, // Virtual address in memory
    p_paddr: u64, // Physical address (unused)
    p_filesz: u64, // Size in file
    p_memsz: u64, // Size in memory
    p_align: u64, // Alignment
};

// =============================================================================
// ELF Loader Errors
// =============================================================================

pub const ElfError = error{
    InvalidMagic,
    InvalidClass,
    InvalidEndian,
    InvalidVersion,
    InvalidMachine,
    InvalidType,
    InvalidPhdrSize,
    NoLoadSegments,
    OutOfMemory,
    MappingFailed,
    BufferTooSmall,
};

// =============================================================================
// ELF Load Result
// =============================================================================

/// Result of loading an ELF file
pub const ElfLoadResult = struct {
    /// Entry point virtual address
    entry_point: u64,
    /// Lowest loaded virtual address
    base_addr: u64,
    /// Highest loaded virtual address + 1
    end_addr: u64,
    /// Whether executable is PIE
    is_pie: bool,
};

// =============================================================================
// ELF Loader Functions
// =============================================================================

/// Validate an ELF header
/// Returns error if the header is invalid for our purposes
pub fn validateHeader(ehdr: *const Elf64_Ehdr) ElfError!void {
    // Check magic bytes
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], &ELF_MAGIC)) {
        console.err("ELF: Invalid magic bytes", .{});
        return ElfError.InvalidMagic;
    }

    // Check 64-bit class
    if (ehdr.e_ident[4] != ELFCLASS64) {
        console.err("ELF: Not a 64-bit executable (class={})", .{ehdr.e_ident[4]});
        return ElfError.InvalidClass;
    }

    // Check little-endian
    if (ehdr.e_ident[5] != ELFDATA2LSB) {
        console.err("ELF: Not little-endian (data={})", .{ehdr.e_ident[5]});
        return ElfError.InvalidEndian;
    }

    // Check version
    if (ehdr.e_ident[6] != EV_CURRENT) {
        console.err("ELF: Invalid version ({})", .{ehdr.e_ident[6]});
        return ElfError.InvalidVersion;
    }

    // Check machine type (x86_64)
    if (ehdr.e_machine != EM_X86_64) {
        console.err("ELF: Not x86_64 (machine={})", .{ehdr.e_machine});
        return ElfError.InvalidMachine;
    }

    // Check file type (executable or PIE)
    if (ehdr.e_type != ET_EXEC and ehdr.e_type != ET_DYN) {
        console.err("ELF: Not an executable (type={})", .{ehdr.e_type});
        return ElfError.InvalidType;
    }

    // Check program header entry size
    if (ehdr.e_phentsize != @sizeOf(Elf64_Phdr)) {
        console.err("ELF: Invalid phdr size ({} != {})", .{ ehdr.e_phentsize, @sizeOf(Elf64_Phdr) });
        return ElfError.InvalidPhdrSize;
    }

    console.debug("ELF: Valid header (type={}, entry={x})", .{ ehdr.e_type, ehdr.e_entry });
}

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
    const is_pie = ehdr.e_type == ET_DYN;
    const actual_base: u64 = if (is_pie) load_base else 0;

    // Verify we have program headers
    if (ehdr.e_phnum == 0) {
        return ElfError.NoLoadSegments;
    }

    // Verify program header table is within bounds
    const phdr_end = ehdr.e_phoff + @as(u64, ehdr.e_phnum) * @sizeOf(Elf64_Phdr);
    if (phdr_end > data.len) {
        return ElfError.BufferTooSmall;
    }

    // Get program header table
    const phdr_ptr: [*]const Elf64_Phdr = @ptrCast(@alignCast(data.ptr + ehdr.e_phoff));
    const phdrs = phdr_ptr[0..ehdr.e_phnum];

    // Track address range
    var lowest_addr: u64 = std.math.maxInt(u64);
    var highest_addr: u64 = 0;
    var load_count: u32 = 0;

    // Load each PT_LOAD segment
    for (phdrs) |*phdr| {
        if (phdr.p_type != PT_LOAD) {
            continue;
        }

        // Calculate virtual address with base offset
        const vaddr = actual_base + phdr.p_vaddr;
        const vaddr_end = vaddr + phdr.p_memsz;

        // Update address range
        if (vaddr < lowest_addr) lowest_addr = vaddr;
        if (vaddr_end > highest_addr) highest_addr = vaddr_end;

        // Load this segment
        try loadSegment(data, phdr, pml4_phys, actual_base);
        load_count += 1;

        console.debug("ELF: Loaded segment {x}-{x} (file={}, mem={})", .{
            vaddr,
            vaddr_end,
            phdr.p_filesz,
            phdr.p_memsz,
        });
    }

    if (load_count == 0) {
        return ElfError.NoLoadSegments;
    }

    // Calculate entry point
    const entry = actual_base + ehdr.e_entry;

    console.info("ELF: Loaded {} segments, entry={x}", .{ load_count, entry });

    return ElfLoadResult{
        .entry_point = entry,
        .base_addr = lowest_addr,
        .end_addr = highest_addr,
        .is_pie = is_pie,
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

    // Page-align the addresses
    const page_size = pmm.PAGE_SIZE;
    const vaddr_aligned = vaddr & ~@as(u64, page_size - 1);
    const vaddr_offset = vaddr - vaddr_aligned;

    // Calculate total size needed (including alignment padding)
    const total_size = std.mem.alignForward(u64, phdr.p_memsz + vaddr_offset, page_size);
    const page_count = total_size / page_size;

    // Convert flags to page flags
    const page_flags = PageFlags{
        .writable = (phdr.p_flags & PF_W) != 0,
        .user = true,
        .no_execute = (phdr.p_flags & PF_X) == 0,
    };

    // Allocate and map pages
    var pages_mapped: usize = 0;
    var current_vaddr = vaddr_aligned;

    while (pages_mapped < page_count) : (pages_mapped += 1) {
        // Allocate a physical page
        const phys_page = pmm.allocPage() orelse {
            // TODO: Clean up already allocated pages on error
            return ElfError.OutOfMemory;
        };

        // Map it
        vmm.mapPage(pml4_phys, current_vaddr, phys_page, page_flags) catch {
            pmm.freePage(phys_page);
            return ElfError.MappingFailed;
        };

        // Zero the page first (important for BSS)
        const page_ptr: [*]u8 = paging.physToVirt(phys_page);
        @memset(page_ptr[0..page_size], 0);

        current_vaddr += page_size;
    }

    // Copy file data to memory
    if (phdr.p_filesz > 0) {
        // Verify file data is within bounds
        const file_end = phdr.p_offset + phdr.p_filesz;
        if (file_end > data.len) {
            return ElfError.BufferTooSmall;
        }

        // Get source data
        const src = data[phdr.p_offset..][0..phdr.p_filesz];

        // Copy to destination (may span multiple pages)
        copyToUserspace(pml4_phys, vaddr, src);
    }

    // BSS (p_memsz > p_filesz) is already zeroed since we zero pages on allocation
}

/// Copy data to userspace virtual address
/// Handles page boundaries by looking up each page's physical address
fn copyToUserspace(pml4_phys: u64, vaddr: u64, data: []const u8) void {
    const page_size = pmm.PAGE_SIZE;
    var offset: usize = 0;
    var current_vaddr = vaddr;

    while (offset < data.len) {
        // Calculate how much to copy to this page
        const page_offset = current_vaddr & (page_size - 1);
        const bytes_in_page = @min(page_size - page_offset, data.len - offset);

        // Look up physical address
        if (vmm.translate(pml4_phys, current_vaddr)) |phys| {
            // Get kernel-accessible pointer via HHDM
            const dest_ptr: [*]u8 = paging.physToVirt(phys);
            const dest = dest_ptr[page_offset..][0..bytes_in_page];

            // Copy data
            @memcpy(dest, data[offset..][0..bytes_in_page]);
        }

        offset += bytes_in_page;
        current_vaddr += bytes_in_page;
    }
}

// =============================================================================
// Stack Setup for New Program
// =============================================================================

/// Default stack size for new programs (2 MB)
pub const DEFAULT_STACK_SIZE: usize = 2 * 1024 * 1024;

/// Default stack top address (below kernel space)
pub const DEFAULT_STACK_TOP: u64 = 0x7FFF_FFFF_F000;

/// Set up the initial user stack with argc, argv, envp
///
/// Stack layout (growing downward):
///   [envp strings]
///   [argv strings]
///   NULL (envp terminator)
///   envp[n-1]..envp[0] pointers
///   NULL (argv terminator)
///   argv[n-1]..argv[0] pointers
///   argc
///   <- RSP points here
///
/// Args:
///   pml4_phys: Page table physical address
///   stack_top: Top of stack virtual address
///   stack_size: Stack size in bytes
///   argv: Argument strings (can be empty)
///   envp: Environment strings (can be empty)
///
/// Returns: Initial RSP value
pub fn setupStack(
    pml4_phys: u64,
    stack_top: u64,
    stack_size: usize,
    argv: []const []const u8,
    envp: []const []const u8,
) !u64 {
    const page_size = pmm.PAGE_SIZE;
    const stack_base = stack_top - stack_size;

    // Allocate and map stack pages
    const page_count = stack_size / page_size;
    var pages_mapped: usize = 0;
    var current_vaddr = stack_base;

    const stack_flags = PageFlags{
        .writable = true,
        .user = true,
        .no_execute = true,
    };

    while (pages_mapped < page_count) : (pages_mapped += 1) {
        const phys_page = pmm.allocPage() orelse {
            return error.OutOfMemory;
        };

        vmm.mapPage(pml4_phys, current_vaddr, phys_page, stack_flags) catch {
            pmm.freePage(phys_page);
            return error.MappingFailed;
        };

        // Zero the stack page
        const page_ptr: [*]u8 = paging.physToVirt(phys_page);
        @memset(page_ptr[0..page_size], 0);

        current_vaddr += page_size;
    }

    // Build stack contents from the top down
    var sp = stack_top;

    // First, push the actual strings (argv and envp)
    // We need to track where each string ends up
    var argv_ptrs: [64]u64 = undefined; // Max 64 args for simplicity
    var envp_ptrs: [64]u64 = undefined;

    const argc = @min(argv.len, 64);
    const envc = @min(envp.len, 64);

    // Push envp strings (in reverse order)
    var i: usize = envc;
    while (i > 0) {
        i -= 1;
        sp -= envp[i].len + 1; // +1 for null terminator
        envp_ptrs[i] = sp;
        copyToUserspace(pml4_phys, sp, envp[i]);
        // Write null terminator
        writeToUserspace(pml4_phys, sp + envp[i].len, &[_]u8{0});
    }

    // Push argv strings (in reverse order)
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= argv[i].len + 1;
        argv_ptrs[i] = sp;
        copyToUserspace(pml4_phys, sp, argv[i]);
        writeToUserspace(pml4_phys, sp + argv[i].len, &[_]u8{0});
    }

    // Align to 16 bytes
    sp = sp & ~@as(u64, 15);

    // Push NULL terminator for envp
    sp -= 8;
    writeU64ToUserspace(pml4_phys, sp, 0);

    // Push envp pointers
    i = envc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        writeU64ToUserspace(pml4_phys, sp, envp_ptrs[i]);
    }

    // Push NULL terminator for argv
    sp -= 8;
    writeU64ToUserspace(pml4_phys, sp, 0);

    // Push argv pointers
    i = argc;
    while (i > 0) {
        i -= 1;
        sp -= 8;
        writeU64ToUserspace(pml4_phys, sp, argv_ptrs[i]);
    }

    // Push argc
    sp -= 8;
    writeU64ToUserspace(pml4_phys, sp, argc);

    // Ensure 16-byte alignment for ABI
    sp = sp & ~@as(u64, 15);

    console.debug("ELF: Stack setup complete, sp={x}", .{sp});

    return sp;
}

/// Write a u64 to userspace
fn writeU64ToUserspace(pml4_phys: u64, vaddr: u64, value: u64) void {
    const bytes = std.mem.toBytes(value);
    writeToUserspace(pml4_phys, vaddr, &bytes);
}

/// Write bytes to userspace (handles page boundaries)
fn writeToUserspace(pml4_phys: u64, vaddr: u64, data: []const u8) void {
    copyToUserspace(pml4_phys, vaddr, data);
}

// =============================================================================
// High-Level Exec Function
// =============================================================================

/// Execute result containing everything needed for sys_execve
pub const ExecResult = struct {
    entry_point: u64,
    stack_pointer: u64,
    pml4_phys: u64,
};

/// Load and prepare an ELF executable for execution
///
/// This is the main function called by sys_execve. It:
/// 1. Creates a fresh address space
/// 2. Loads the ELF segments
/// 3. Sets up the user stack with argv/envp
///
/// Args:
///   data: Raw ELF file data
///   argv: Argument strings
///   envp: Environment strings
///
/// Returns: ExecResult with entry point, stack pointer, and page table
pub fn exec(
    data: []const u8,
    argv: []const []const u8,
    envp: []const []const u8,
) !ExecResult {
    // Create new address space
    const pml4_phys = vmm.createAddressSpace() catch {
        return error.OutOfMemory;
    };
    errdefer vmm.destroyAddressSpace(pml4_phys);

    // Default load base for PIE executables
    const pie_base: u64 = 0x400000;

    // Load the ELF
    const load_result = load(data, pml4_phys, pie_base) catch |err| {
        console.err("ELF: Load failed: {}", .{err});
        return error.InvalidExecutable;
    };

    // Set up stack
    const stack_top = DEFAULT_STACK_TOP;
    const stack_size = DEFAULT_STACK_SIZE;

    const sp = setupStack(pml4_phys, stack_top, stack_size, argv, envp) catch |err| {
        console.err("ELF: Stack setup failed: {}", .{err});
        return error.OutOfMemory;
    };

    return ExecResult{
        .entry_point = load_result.entry_point,
        .stack_pointer = sp,
        .pml4_phys = pml4_phys,
    };
}
