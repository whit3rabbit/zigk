// AArch64 Paging HAL Module

const cpu = @import("../kernel/cpu.zig");

pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

pub const VirtualAddress = packed struct(u64) {
    offset: u12,
    l3_index: u9,
    l2_index: u9,
    l1_index: u9,
    l0_index: u9,
    sign_extension: u16,
    pub fn from(addr: u64) VirtualAddress { return @bitCast(addr); }
};

pub const PageTableEntry = packed struct(u64) {
    valid: bool = false,
    table: bool = false,
    attr_index: u3 = 0,
    non_secure: bool = false,
    ap: u2 = 0,
    shareability: u2 = 0,
    accessed: bool = false,
    non_global: bool = false,
    phys_addr_bits: u36 = 0,
    reserved0: u4 = 0,
    privileged_execute_never: bool = false,
    execute_never: bool = false,
    user_accessible: bool = false,
    writable: bool = false,
    ignored: u8 = 0,

    pub fn empty() Self { return .{}; }
    const Self = @This();
    pub fn tableEntry(phys_addr: u64, _: bool) Self {
        return .{
            .valid = true,
            .table = true,
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }
    pub fn pageEntry(phys_addr: u64, flags: anytype) Self {
        var entry = Self{
            .valid = true,
            .table = true,
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
            .accessed = true,
            .shareability = 0b11,
            .attr_index = if (flags.cache_disable) 0 else 1,
            .user_accessible = flags.user,
            .writable = flags.writable,
        };
        if (flags.user) {
            entry.ap = if (flags.writable) 0b01 else 0b11;
        } else {
            entry.ap = if (flags.writable) 0b00 else 0b10;
        }
        entry.execute_never = flags.no_execute;
        entry.privileged_execute_never = flags.no_execute;
        entry.non_global = flags.user;
        return entry;
    }
    pub fn getPhysAddr(self: Self) u64 { return @as(u64, self.phys_addr_bits) << PAGE_SHIFT; }
    pub fn isPresent(self: Self) bool { return self.valid; }
    pub fn isHugePage(self: Self) bool { return !self.table; }
};

pub const PageFlags = struct {
    writable: bool = true,
    user: bool = false,
    no_execute: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    global: bool = false,
    mmio: bool = false,

    pub const MMIO = PageFlags{ .mmio = true };
};

pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,
    pub fn init() PageTable { return .{ .entries = [_]PageTableEntry{PageTableEntry.empty()} ** ENTRIES_PER_TABLE }; }
};

var hhdm_offset: u64 = 0;
pub fn init(offset: u64) void { hhdm_offset = offset; }
pub fn getHhdmOffset() u64 { return hhdm_offset; }
pub fn physToVirt(phys: u64) [*]u8 { return @ptrFromInt(phys +% hhdm_offset); }
pub fn virtToPhys(virt: u64) u64 { return virt -% hhdm_offset; }
pub fn getTablePtr(phys_addr: u64) *PageTable { return @ptrFromInt(phys_addr +% hhdm_offset); }

/// Get current kernel page table (TTBR1_EL1)
pub fn getCurrentPageTable() u64 {
    var ttbr1: u64 = undefined;
    asm volatile ("mrs %[ret], ttbr1_el1"
        : [ret] "=r" (ttbr1),
    );
    // Mask out ASID (bits 63:48) if present
    return ttbr1 & 0x0000_FFFF_FFFF_F000;
}

/// Load kernel page table (TTBR1_EL1)
/// Used for kernel mappings (upper half of address space)
pub fn loadPageTable(pml4_phys: u64) void {
    asm volatile (
        \\dsb ishst
        \\msr ttbr1_el1, %[addr]
        \\isb
        :
        : [addr] "r" (pml4_phys),
    );
}

/// Load user page table (TTBR0_EL1)
/// Used for userspace mappings (lower half of address space)
pub fn loadUserPageTable(l0_phys: u64) void {
    asm volatile (
        \\dsb ishst
        \\msr ttbr0_el1, %[addr]
        \\isb
        :
        : [addr] "r" (l0_phys),
    );
}

/// Invalidate a single TLB entry
pub fn invalidatePage(virt_addr: u64) void {
    // TLBI VAAE1IS: Invalidate by VA, All ASIDs, EL1, Inner Shareable
    // The address is shifted right by 12 to form the TLB entry format
    const tlbi_addr = virt_addr >> 12;
    asm volatile (
        \\dsb ishst
        \\tlbi vaae1is, %[addr]
        \\dsb ish
        \\isb
        :
        : [addr] "r" (tlbi_addr),
    );
}

/// Invalidate all TLB entries
pub fn invalidateAll() void {
    asm volatile (
        \\dsb ishst
        \\tlbi vmalle1is
        \\dsb ish
        \\isb
    );
}

/// Invalidate all TLB entries for a specific ASID
pub fn invalidateAsid(asid: u16) void {
    const aside_arg = @as(u64, asid) << 48;
    asm volatile (
        \\dsb ishst
        \\tlbi aside1is, %[asid]
        \\dsb ish
        \\isb
        :
        : [asid] "r" (aside_arg),
    );
}

pub fn getIndices(virt_addr: u64) struct { pml4: usize, pdpt: usize, pd: usize, pt: usize, l0: usize, l1: usize, l2: usize, l3: usize } {
    const va = VirtualAddress.from(virt_addr);
    return .{
        .pml4 = va.l0_index,
        .pdpt = va.l1_index,
        .pd = va.l2_index,
        .pt = va.l3_index,
        .l0 = va.l0_index,
        .l1 = va.l1_index,
        .l2 = va.l2_index,
        .l3 = va.l3_index,
    };
}

pub fn pageAlignDown(addr: u64) u64 { return addr & ~@as(u64, PAGE_SIZE - 1); }
pub fn pageAlignUp(addr: u64) u64 { return (addr + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1); }
pub fn isPageAligned(addr: u64) bool { return (addr & (PAGE_SIZE - 1)) == 0; }
pub fn pagesToCover(size: u64) u64 { return (size + PAGE_SIZE - 1) / PAGE_SIZE; }

pub const DomainPageTables = struct {
    pml4_phys: u64 = 0,
    pub fn create() ?DomainPageTables { return null; }
    pub fn mapRange(self: *DomainPageTables, _: u64, _: u64, _: u64, _: bool, _: bool) !void { _ = self; }
    pub fn unmapRange(self: *DomainPageTables, _: u64, _: u64) void { _ = self; }
    pub fn translate(self: *const DomainPageTables, _: u64) ?u64 { _ = self; return null; }
};
pub const IommuTables = struct {
    root_phys: u64 = 0,
    pub fn create() ?IommuTables { return null; }
    pub fn configureDevice(self: *IommuTables, _: u8, _: u5, _: u3, _: u32, _: *DomainPageTables) void { _ = self; }
};
