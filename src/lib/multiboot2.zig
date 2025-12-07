// ZigK Multiboot2 Information Parser
//
// Parses the Multiboot2 boot information structure provided by GRUB.
// The structure consists of a header followed by a sequence of tags.
//
// Reference: https://www.gnu.org/software/grub/manual/multiboot2/multiboot.html

/// Multiboot2 magic value in EAX after boot
pub const BOOTLOADER_MAGIC: u32 = 0x36D76289;

/// Tag types as defined by Multiboot2 specification
pub const TagType = enum(u32) {
    end = 0,
    boot_cmd_line = 1,
    boot_loader_name = 2,
    module = 3,
    basic_meminfo = 4,
    bootdev = 5,
    mmap = 6,
    vbe = 7,
    framebuffer = 8,
    elf_sections = 9,
    apm = 10,
    efi32 = 11,
    efi64 = 12,
    smbios = 13,
    acpi_old = 14,
    acpi_new = 15,
    network = 16,
    efi_mmap = 17,
    efi_bs = 18,
    efi32_ih = 19,
    efi64_ih = 20,
    load_base_addr = 21,
    _,
};

/// Memory map entry types
pub const MemoryType = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    acpi_nvs = 4,
    bad_memory = 5,
    _,
};

/// Boot information header
pub const BootInfo = extern struct {
    total_size: u32,
    reserved: u32,

    /// Get iterator over all tags
    pub fn tags(self: *const BootInfo) TagIterator {
        const start = @intFromPtr(self) + @sizeOf(BootInfo);
        return TagIterator{
            .current = @ptrFromInt(start),
            .end = @intFromPtr(self) + self.total_size,
        };
    }
};

/// Generic tag header
pub const Tag = extern struct {
    tag_type: TagType,
    size: u32,

    /// Get pointer to tag-specific data after header
    pub fn data(self: *const Tag) [*]const u8 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Tag));
    }
};

/// Tag iterator
pub const TagIterator = struct {
    current: *const Tag,
    end: usize,

    pub fn next(self: *TagIterator) ?*const Tag {
        if (@intFromPtr(self.current) >= self.end) {
            return null;
        }

        const tag = self.current;
        if (tag.tag_type == .end) {
            return null;
        }

        // Move to next tag (aligned to 8 bytes)
        const next_addr = @intFromPtr(self.current) + tag.size;
        const aligned_addr = (next_addr + 7) & ~@as(usize, 7);
        self.current = @ptrFromInt(aligned_addr);

        return tag;
    }
};

/// Memory map tag (type 6)
pub const MmapTag = extern struct {
    tag: Tag,
    entry_size: u32,
    entry_version: u32,

    /// Get iterator over memory map entries
    pub fn entries(self: *const MmapTag) MmapIterator {
        const data_start = @intFromPtr(self) + @sizeOf(MmapTag);
        const data_end = @intFromPtr(self) + self.tag.size;
        return MmapIterator{
            .current = @ptrFromInt(data_start),
            .end = data_end,
            .entry_size = self.entry_size,
        };
    }
};

/// Memory map entry
pub const MmapEntry = extern struct {
    base_addr: u64,
    length: u64,
    mem_type: MemoryType,
    reserved: u32,
};

/// Memory map iterator
pub const MmapIterator = struct {
    current: *const MmapEntry,
    end: usize,
    entry_size: u32,

    pub fn next(self: *MmapIterator) ?*const MmapEntry {
        if (@intFromPtr(self.current) >= self.end) {
            return null;
        }

        const entry = self.current;
        const next_addr = @intFromPtr(self.current) + self.entry_size;
        self.current = @ptrFromInt(next_addr);

        return entry;
    }
};

/// Module tag (type 3)
pub const ModuleTag = extern struct {
    tag: Tag,
    mod_start: u32,
    mod_end: u32,
    // Followed by null-terminated string (cmdline)

    /// Get module command line string
    pub fn cmdline(self: *const ModuleTag) [*:0]const u8 {
        const str_start = @intFromPtr(self) + @sizeOf(ModuleTag);
        return @ptrFromInt(str_start);
    }

    /// Get module size in bytes
    pub fn size(self: *const ModuleTag) u32 {
        return self.mod_end - self.mod_start;
    }
};

/// Basic memory info tag (type 4)
pub const BasicMemInfoTag = extern struct {
    tag: Tag,
    mem_lower: u32, // KB of lower memory (below 1MB)
    mem_upper: u32, // KB of upper memory (above 1MB)
};

/// Boot command line tag (type 1)
pub const BootCmdLineTag = extern struct {
    tag: Tag,
    // Followed by null-terminated string

    pub fn cmdline(self: *const BootCmdLineTag) [*:0]const u8 {
        const str_start = @intFromPtr(self) + @sizeOf(Tag);
        return @ptrFromInt(str_start);
    }
};

/// Boot loader name tag (type 2)
pub const BootLoaderNameTag = extern struct {
    tag: Tag,
    // Followed by null-terminated string

    pub fn name(self: *const BootLoaderNameTag) [*:0]const u8 {
        const str_start = @intFromPtr(self) + @sizeOf(Tag);
        return @ptrFromInt(str_start);
    }
};

/// Framebuffer tag (type 8)
pub const FramebufferTag = extern struct {
    tag: Tag,
    framebuffer_addr: u64,
    framebuffer_pitch: u32,
    framebuffer_width: u32,
    framebuffer_height: u32,
    framebuffer_bpp: u8,
    framebuffer_type: FramebufferType,
    reserved: u8,
    // Color info follows for indexed/RGB modes
};

pub const FramebufferType = enum(u8) {
    indexed = 0,
    rgb = 1,
    ega_text = 2,
    _,
};

/// ACPI old RSDP tag (type 14)
pub const AcpiOldTag = extern struct {
    tag: Tag,
    // Followed by RSDP v1 structure
};

/// ACPI new RSDP tag (type 15)
pub const AcpiNewTag = extern struct {
    tag: Tag,
    // Followed by RSDP v2 structure
};

/// EFI 64-bit system table pointer (type 12)
pub const Efi64Tag = extern struct {
    tag: Tag,
    pointer: u64,
};

/// Load base address tag (type 21)
pub const LoadBaseAddrTag = extern struct {
    tag: Tag,
    load_base_addr: u32,
};

// ============================================================================
// Helper functions
// ============================================================================

/// Find a specific tag type in boot info
pub fn findTag(boot_info: *const BootInfo, tag_type: TagType) ?*const Tag {
    var iter = boot_info.tags();
    while (iter.next()) |tag| {
        if (tag.tag_type == tag_type) {
            return tag;
        }
    }
    return null;
}

/// Find memory map tag
pub fn findMmapTag(boot_info: *const BootInfo) ?*const MmapTag {
    if (findTag(boot_info, .mmap)) |tag| {
        return @ptrCast(tag);
    }
    return null;
}

/// Find framebuffer tag
pub fn findFramebufferTag(boot_info: *const BootInfo) ?*const FramebufferTag {
    if (findTag(boot_info, .framebuffer)) |tag| {
        return @ptrCast(@alignCast(tag));
    }
    return null;
}

/// Find basic memory info tag
pub fn findBasicMemInfoTag(boot_info: *const BootInfo) ?*const BasicMemInfoTag {
    if (findTag(boot_info, .basic_meminfo)) |tag| {
        return @ptrCast(tag);
    }
    return null;
}

/// Find boot command line tag
pub fn findCmdLineTag(boot_info: *const BootInfo) ?*const BootCmdLineTag {
    if (findTag(boot_info, .boot_cmd_line)) |tag| {
        return @ptrCast(tag);
    }
    return null;
}

/// Find boot loader name tag
pub fn findBootLoaderNameTag(boot_info: *const BootInfo) ?*const BootLoaderNameTag {
    if (findTag(boot_info, .boot_loader_name)) |tag| {
        return @ptrCast(tag);
    }
    return null;
}

/// Iterator for module tags
pub const ModuleIterator = struct {
    tag_iter: TagIterator,

    pub fn next(self: *ModuleIterator) ?*const ModuleTag {
        while (self.tag_iter.next()) |tag| {
            if (tag.tag_type == .module) {
                return @ptrCast(tag);
            }
        }
        return null;
    }
};

/// Get iterator over all module tags
pub fn modules(boot_info: *const BootInfo) ModuleIterator {
    return ModuleIterator{
        .tag_iter = boot_info.tags(),
    };
}

/// Count total usable memory from memory map
pub fn countUsableMemory(boot_info: *const BootInfo) u64 {
    var total: u64 = 0;
    if (findMmapTag(boot_info)) |mmap| {
        var iter = mmap.entries();
        while (iter.next()) |entry| {
            if (entry.mem_type == .available) {
                total += entry.length;
            }
        }
    }
    return total;
}
