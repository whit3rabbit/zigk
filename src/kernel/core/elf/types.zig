const std = @import("std");
const uapi = @import("uapi");

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
pub const EM_X86_64: u16 = 62;   // AMD x86-64
pub const EM_AARCH64: u16 = 183; // ARM AArch64

/// Program header types
pub const PT_NULL: u32 = 0; // Unused entry
pub const PT_LOAD: u32 = 1; // Loadable segment
pub const PT_DYNAMIC: u32 = 2; // Dynamic linking info
pub const PT_INTERP: u32 = 3; // Interpreter path
pub const PT_NOTE: u32 = 4; // Auxiliary info
pub const PT_PHDR: u32 = 6; // Program header table
pub const PT_TLS: u32 = 7; // Thread-local storage segment
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

    comptime {
        if (@sizeOf(@This()) != 64) @compileError("Elf64_Ehdr must be 64 bytes");
    }
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

    comptime {
        if (@sizeOf(@This()) != 56) @compileError("Elf64_Phdr must be 56 bytes");
    }
};

// =============================================================================
// ELF Loader Limits (Security)
// =============================================================================

/// Maximum size of a single segment (128 MB)
/// Prevents malicious ELF files from exhausting memory via large p_memsz
pub const MAX_SEGMENT_SIZE: u64 = 128 * 1024 * 1024;

/// Maximum total process memory from all segments (256 MB)
/// Prevents DoS via many small segments
pub const MAX_TOTAL_MEMORY: u64 = 256 * 1024 * 1024;

/// Maximum number of PT_LOAD segments
pub const MAX_LOAD_SEGMENTS: u32 = 64;

/// Default stack size for new programs (2 MB)
pub const DEFAULT_STACK_SIZE: usize = 2 * 1024 * 1024;

/// Default stack top address (below kernel space)
pub const DEFAULT_STACK_TOP: u64 = 0x7FFF_FFFF_F000;

/// Stack bounds for ELF loading validation
/// SECURITY: Use actual ASLR bounds instead of defaults to prevent
/// segment overlap attacks where malicious ELF segments target the
/// randomized stack location.
pub const StackBounds = struct {
    stack_top: u64,
    stack_size: usize,

    pub fn base(self: StackBounds) u64 {
        return self.stack_top - self.stack_size;
    }

    /// Default bounds (used when ASLR offsets not available)
    pub const default = StackBounds{
        .stack_top = DEFAULT_STACK_TOP,
        .stack_size = DEFAULT_STACK_SIZE,
    };
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
    InvalidHeaderSize,
    NoLoadSegments,
    OutOfMemory,
    MappingFailed,
    BufferTooSmall,
    SegmentTooLarge,
    TotalMemoryExceeded,
    TooManySegments,
    InvalidAddressRange,
    StackOverflow,      // Added, was implicitly error!u64
    InvalidExecutable,  // Added for top-level
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
    /// Address of Program Headers (for AT_PHDR)
    phdr_addr: u64,
    /// Number of Program Headers (for AT_PHNUM)
    phnum: u16,
    /// TLS segment header (if present)
    tls_phdr: ?Elf64_Phdr = null,
};

/// Auxiliary Vector Entry (for AT_* values passed to _start)
pub const AuxEntry = struct {
    id: u64,
    value: u64,
};

/// Execute result containing everything needed for sys_execve
pub const ExecResult = struct {
    entry_point: u64,
    stack_pointer: u64,
    pml4_phys: u64,
    heap_start: u64,
    user_vmm: *@import("user_vmm").UserVmm,
};
