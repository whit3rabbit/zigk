const std = @import("std");
const uefi = std.os.uefi;
const elf = std.elf;

pub const LoaderError = error {
    LocateProtocolFailed,
    OpenVolumeFailed,
    KernelNotFound,
    ReadFailed,
    SeekFailed,
    InvalidElf,
    AllocateFailed,
    SegmentsBufferTooSmall,
};

pub const LoadedSegment = struct {
    virtual_address: u64,
    physical_address: u64,
    page_count: usize,
    size: u64,
};

pub fn loadKernel(bs: *uefi.tables.BootServices, segments_buffer: []LoadedSegment) LoaderError!usize {
    // Locate Protocol
    // Wrapper signature: locateProtocol(protocol: *Guid, registration: ?*anyopaque) Error!?*anyopaque
    const fs_opaque = bs.locateProtocol(uefi.protocol.SimpleFileSystem, null) catch {
        return LoaderError.LocateProtocolFailed;
    };
    const fs_ptr = fs_opaque orelse return LoaderError.LocateProtocolFailed;
    const fs = @as(*uefi.protocol.SimpleFileSystem, @ptrCast(@alignCast(fs_ptr)));
    
    var root: *uefi.protocol.File = undefined;
    if (fs.openVolume()) |r| {
        root = r;
    } else |_| {
        return LoaderError.OpenVolumeFailed;
    }
    defer _ = root.close() catch {};
    
    const kernel_path = [11:0]u16{ 'k', 'e', 'r', 'n', 'e', 'l', '.', 'e', 'l', 'f', 0 };
    var kernel_file = root.open(&kernel_path, @enumFromInt(1), @bitCast(@as(u64, 0))) catch {
        return LoaderError.KernelNotFound;
    };
    defer _ = kernel_file.close() catch {};
    
    // Read ELF Header
    var ehdr: elf.Elf64_Ehdr = undefined;
    var len: usize = @sizeOf(elf.Elf64_Ehdr);
    _ = kernel_file.read(std.mem.asBytes(&ehdr)) catch return LoaderError.ReadFailed;
    
    // Validate Magic
    if (!std.mem.eql(u8, ehdr.e_ident[0..4], "\x7fELF")) return LoaderError.InvalidElf;
    if (ehdr.e_phoff == 0) return LoaderError.InvalidElf;

    // Read Program Headers
    _ = kernel_file.setPosition(ehdr.e_phoff) catch return LoaderError.SeekFailed;
    
    var segment_count: usize = 0;
    
    var i: usize = 0;
    while (i < ehdr.e_phnum) : (i += 1) {
        var phdr: elf.Elf64_Phdr = undefined;
        len = @sizeOf(elf.Elf64_Phdr);
        
        // Ensure we are at the right offset
        const offset = ehdr.e_phoff + (i * ehdr.e_phentsize);
        _ = kernel_file.setPosition(offset) catch return LoaderError.SeekFailed;
        
        _ = kernel_file.read(std.mem.asBytes(&phdr)) catch return LoaderError.ReadFailed;
        
        if (phdr.p_type == elf.PT_LOAD) {
            if (segment_count >= segments_buffer.len) return LoaderError.SegmentsBufferTooSmall;
            
            // Calculate pages
            const mem_size = phdr.p_memsz;
            const page_count = (mem_size + 4096 - 1) / 4096;
            
            // Allocate Physical Memory
            const pages_slice = bs.allocatePages(
                .any,
                .loader_data,
                page_count,
            ) catch return LoaderError.AllocateFailed;
            
            const phys_addr = @intFromPtr(pages_slice.ptr);
            
            // Zero out memory (BSS)
            // pages_slice is []align(4096) [4096]u8.
            // Convert to byte slice.
            var dest_slice = std.mem.sliceAsBytes(pages_slice);
            @memset(dest_slice, 0);
            
            // Load file data
            if (phdr.p_filesz > 0) {
                 _ = kernel_file.setPosition(phdr.p_offset) catch return LoaderError.SeekFailed;
                 
                 // Read into slice
                 // dest_slice is []u8.
                 if (phdr.p_filesz > dest_slice.len) return LoaderError.ReadFailed; // Should not happen if logic correct
                 
                 const exact_dest = dest_slice[0..phdr.p_filesz];
                 _ = kernel_file.read(exact_dest) catch return LoaderError.ReadFailed;
            }
            
            segments_buffer[segment_count] = .{
                .virtual_address = phdr.p_vaddr,
                .physical_address = phys_addr,
                .page_count = page_count,
                .size = mem_size,
            };
            segment_count += 1;
        }
    }
    
    return segment_count;
}
