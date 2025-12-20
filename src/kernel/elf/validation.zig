const std = @import("std");
const console = @import("console");
const types = @import("types.zig");

const ElfError = types.ElfError;
const Elf64_Ehdr = types.Elf64_Ehdr;
const Elf64_Phdr = types.Elf64_Phdr;

// =============================================================================
// ELF Loader Functions
// =============================================================================

/// Validate an ELF header
/// Returns error if the header is invalid for our purposes
pub fn validateHeader(ehdr: *const Elf64_Ehdr) ElfError!void {
    // Check magic bytes
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], &types.ELF_MAGIC)) {
        console.err("ELF: Invalid magic bytes", .{});
        return ElfError.InvalidMagic;
    }

    // Check 64-bit class
    if (ehdr.e_ident[4] != types.ELFCLASS64) {
        console.err("ELF: Not a 64-bit executable (class={})", .{ehdr.e_ident[4]});
        return ElfError.InvalidClass;
    }

    // Check little-endian
    if (ehdr.e_ident[5] != types.ELFDATA2LSB) {
        console.err("ELF: Not little-endian (data={})", .{ehdr.e_ident[5]});
        return ElfError.InvalidEndian;
    }

    // Check version
    if (ehdr.e_ident[6] != types.EV_CURRENT) {
        console.err("ELF: Invalid version ({})", .{ehdr.e_ident[6]});
        return ElfError.InvalidVersion;
    }

    // Check machine type (x86_64)
    if (ehdr.e_machine != types.EM_X86_64) {
        console.err("ELF: Not x86_64 (machine={})", .{ehdr.e_machine});
        return ElfError.InvalidMachine;
    }

    // Check file type (executable or PIE)
    if (ehdr.e_type != types.ET_EXEC and ehdr.e_type != types.ET_DYN) {
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
