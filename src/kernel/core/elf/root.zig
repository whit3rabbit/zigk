const std = @import("std");
const vmm = @import("vmm");
const pmm = @import("pmm");
const console = @import("console");
const types = @import("types.zig");
const loader = @import("loader.zig");
const setup = @import("setup.zig");
const validation = @import("validation.zig");

// Export public types and constants
pub const ELF_MAGIC = types.ELF_MAGIC;
pub const ELFCLASS64 = types.ELFCLASS64;
pub const ELFDATA2LSB = types.ELFDATA2LSB;
pub const EV_CURRENT = types.EV_CURRENT;
pub const EM_X86_64 = types.EM_X86_64;
pub const ET_EXEC = types.ET_EXEC;
pub const ET_DYN = types.ET_DYN;
pub const PT_LOAD = types.PT_LOAD;
pub const PT_TLS = types.PT_TLS;
pub const PF_X = types.PF_X;
pub const PF_W = types.PF_W;
pub const PF_R = types.PF_R;
pub const MAX_SEGMENT_SIZE = types.MAX_SEGMENT_SIZE;
pub const MAX_TOTAL_MEMORY = types.MAX_TOTAL_MEMORY;
pub const MAX_LOAD_SEGMENTS = types.MAX_LOAD_SEGMENTS;
pub const DEFAULT_STACK_SIZE = types.DEFAULT_STACK_SIZE;
pub const DEFAULT_STACK_TOP = types.DEFAULT_STACK_TOP;
pub const StackBounds = types.StackBounds;

pub const Elf64_Ehdr = types.Elf64_Ehdr;
pub const Elf64_Phdr = types.Elf64_Phdr;
pub const ElfError = types.ElfError;
pub const ElfLoadResult = types.ElfLoadResult;
pub const AuxEntry = types.AuxEntry;
pub const ExecResult = types.ExecResult;

// Export public functions
pub const load = loader.load;
pub const validateHeader = validation.validateHeader;
pub const setupStack = setup.setupStack;
pub const setupTls = setup.setupTls;

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
    vdso_base: ?u64,
    stack_top_opt: ?u64,
    pie_base_opt: ?u64,
) !types.ExecResult {
    // Create new address space
    const pml4_phys = vmm.createAddressSpace() catch {
        return error.OutOfMemory;
    };
    errdefer vmm.destroyAddressSpace(pml4_phys);

    // Use provided PIE base or default (for ASLR)
    const pie_base: u64 = pie_base_opt orelse 0x400000;

    // Use provided stack top or default (for ASLR)
    const stack_top = stack_top_opt orelse types.DEFAULT_STACK_TOP;
    const stack_size = types.DEFAULT_STACK_SIZE;

    // SECURITY: Construct actual stack bounds for ELF loading validation
    const stack_bounds = types.StackBounds{
        .stack_top = stack_top,
        .stack_size = stack_size,
    };

    // Load the ELF
    const load_result = loader.load(data, pml4_phys, pie_base, stack_bounds) catch |err| {
        console.err("ELF: Load failed: {}", .{err});
        return error.InvalidExecutable;
    };

    // Construct basic auxiliary vector
    var auxv_buf: [8]types.AuxEntry = undefined;
    var auxv_count: usize = 0;
    
    // AT_PHDR
    auxv_buf[auxv_count] = .{ .id = 3, .value = load_result.phdr_addr }; auxv_count += 1;
    // AT_PHENT
    auxv_buf[auxv_count] = .{ .id = 4, .value = 56 }; auxv_count += 1;
    // AT_PHNUM
    auxv_buf[auxv_count] = .{ .id = 5, .value = load_result.phnum }; auxv_count += 1;
    // AT_PAGESZ
    auxv_buf[auxv_count] = .{ .id = 6, .value = 4096 }; auxv_count += 1;
    // AT_ENTRY
    auxv_buf[auxv_count] = .{ .id = 9, .value = load_result.entry_point }; auxv_count += 1;
    
    // AT_SYSINFO_EHDR (value 33 per Linux ABI)
    // Points to the VDSO ELF header in userspace for fast syscalls
    const AT_SYSINFO_EHDR: u64 = 33;
    if (vdso_base) |base| {
        auxv_buf[auxv_count] = .{ .id = AT_SYSINFO_EHDR, .value = base };
        auxv_count += 1;
    }

    const auxv = auxv_buf[0..auxv_count];

    const sp = setup.setupStack(pml4_phys, stack_top, stack_size, argv, envp, auxv) catch |err| {
        console.err("ELF: Stack setup failed: {}", .{err});
        return error.OutOfMemory;
    };

    // Calculate initial heap start (aligned to page boundary)
    const heap_start = std.mem.alignForward(u64, load_result.end_addr, pmm.PAGE_SIZE);

    return types.ExecResult{
        .entry_point = load_result.entry_point,
        .stack_pointer = sp,
        .pml4_phys = pml4_phys,
        .heap_start = heap_start,
    };
}
