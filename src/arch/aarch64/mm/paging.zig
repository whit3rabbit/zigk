// AArch64 Paging HAL Module
//
// Implements AArch64 page table management using the 4-level
// translation table scheme (L0/L1/L2/L3) with 4KB granule.
//
// Address Space Layout:
//   User space (TTBR0_EL1):  0x0000_0000_0000_0000 - 0x0000_FFFF_FFFF_FFFF
//   Kernel space (TTBR1_EL1): 0xFFFF_0000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF
//
// Access Permission (AP) bits for AArch64 (ARMv8-A):
//   AP[2:1] | Kernel (EL1) | User (EL0) | Use case
//   --------|--------------|------------|----------
//   0b00    | RW           | None       | Kernel read-write
//   0b01    | RW           | RW         | User read-write
//   0b10    | RO           | None       | Kernel read-only
//   0b11    | RO           | RO         | User read-only
//
// Execute Never bits:
//   UXN (bit 54): User Execute Never - prevents EL0 execution
//   PXN (bit 53): Privileged Execute Never - prevents EL1 execution

const std = @import("std");
const cpu = @import("../kernel/cpu.zig");
const console = @import("console");

pub const PAGE_SIZE: usize = 4096;

// SECURITY: Maximum ASID value depends on TCR_EL1.AS configuration.
// AS=0: 8-bit ASIDs (0-255), AS=1: 16-bit ASIDs (0-65535).
// This is detected at runtime and stored for validation.
// Defaults to 8-bit (255) for safety until init() is called.
var max_asid: u16 = 255;
var asid_bits_detected: bool = false;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

/// Default HHDM offset for AArch64 (matches common Limine setup)
/// This provides a sensible default if init() is never called.
pub const HHDM_OFFSET_DEFAULT: u64 = 0xFFFF_8000_0000_0000;

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
    table: bool = false, // For L3: must be 1 for page descriptor
    attr_index: u3 = 0, // MAIR index (0=Device, 1=Normal)
    non_secure: bool = false,
    ap: u2 = 0, // AP[2:1] - Access Permissions
    shareability: u2 = 0, // SH[1:0]
    accessed: bool = false, // AF - Access Flag
    non_global: bool = false, // nG
    phys_addr_bits: u36 = 0, // OA[47:12]
    reserved0: u3 = 0, // Bits 48-50: reserved/GP
    dbm: bool = false, // Bit 51: Dirty Bit Modifier
    contiguous: bool = false, // Bit 52: Contiguous hint
    pxn: bool = false, // Bit 53: Privileged Execute Never
    uxn: bool = false, // Bit 54: User Execute Never (XN for EL0)
    // Software-defined bits 55-63 (used for VMM compatibility)
    user_accessible: bool = false, // Bit 55: Software flag for user page tracking
    writable: bool = false, // Bit 56: Software flag for writable tracking
    software: u7 = 0, // Bits 57-63: Reserved for software use

    pub fn empty() Self { return .{}; }
    const Self = @This();
    pub fn tableEntry(phys_addr: u64, user: bool) Self {
        return .{
            .valid = true,
            .table = true,
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
            .user_accessible = user, // Software flag for VMM tracking
        };
    }
    pub fn pageEntry(phys_addr: u64, flags: anytype) Self {
        var entry = Self{
            .valid = true,
            .table = true, // For L3: 1 = page descriptor
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
            .accessed = true,
            .shareability = 0b11, // Inner Shareable
            .attr_index = if (flags.cache_disable) 0 else 1,
            .user_accessible = flags.user, // Software flag for VMM tracking
            .writable = flags.writable, // Software flag for VMM tracking
        };
        // Set AP bits based on user/writable flags
        // AP[2:1]: 00=RW/None, 01=RW/RW, 10=RO/None, 11=RO/RO
        if (flags.user) {
            entry.ap = if (flags.writable) 0b01 else 0b11;
        } else {
            entry.ap = if (flags.writable) 0b00 else 0b10;
        }
        // Set execute-never bits
        // PXN: Prevents EL1 (kernel) execution
        // UXN: Prevents EL0 (user) execution
        entry.pxn = flags.no_execute;
        entry.uxn = flags.no_execute; // User can execute only if no_execute=false
        entry.non_global = flags.user; // Use ASID for user pages
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

    /// MMIO: Device memory (uncacheable + write-through semantics).
    /// On AArch64, attr_index=0 selects Device-nGnRnE memory type from MAIR.
    pub const MMIO: PageFlags = .{ .writable = true, .user = false, .cache_disable = true, .write_through = true, .mmio = true };
};

pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,
    pub fn init() PageTable { return .{ .entries = [_]PageTableEntry{PageTableEntry.empty()} ** ENTRIES_PER_TABLE }; }
};

/// HHDM offset (Higher Half Direct Map)
/// Initialized to a sensible default in case init() is not called.
var hhdm_offset: u64 = HHDM_OFFSET_DEFAULT;

// Minimum valid HHDM offset (must be in kernel space - TTBR1 range)
const HHDM_MIN_OFFSET: u64 = 0xFFFF_0000_0000_0000;

pub fn init(offset: u64) void {
    // SECURITY: Validate offset is in kernel space (higher half / TTBR1 range).
    // A malicious or buggy bootloader could pass a user-space offset, causing
    // physToVirt() to return pointers into user-controllable memory.
    if (offset < HHDM_MIN_OFFSET) {
        @panic("HHDM offset not in kernel space");
    }
    hhdm_offset = offset;

    // SECURITY: Detect ASID size from TCR_EL1.AS bit to enable proper
    // validation in TLB invalidation functions. Mismatched ASID sizes
    // can cause incorrect TLB entries to be flushed, leaving stale
    // entries that could allow unauthorized memory access.
    // NOTE: `undefined` for ASM output operands is safe - `mrs` overwrites immediately.
    var tcr: u64 = undefined;
    asm volatile ("mrs %[ret], tcr_el1" : [ret] "=r" (tcr));

    // AS bit is bit 36 of TCR_EL1
    // AS=0: 8-bit ASIDs (max 255)
    // AS=1: 16-bit ASIDs (max 65535)
    const as_bit = (tcr >> 36) & 1;
    if (as_bit == 1) {
        max_asid = 65535;
        console.debug("paging: 16-bit ASID support detected", .{});
    } else {
        max_asid = 255;
        console.debug("paging: 8-bit ASID support detected", .{});
    }
    asid_bits_detected = true;
}

pub fn getHhdmOffset() u64 {
    return hhdm_offset;
}

/// Get maximum supported ASID value
/// Returns 255 for 8-bit ASIDs, 65535 for 16-bit ASIDs.
pub fn getMaxAsid() u16 {
    return max_asid;
}

/// Convert physical address to virtual address via HHDM.
/// SECURITY: Panics if physical address would overflow and wrap into user space.
pub fn physToVirt(phys: u64) [*]u8 {
    const result = phys +% hhdm_offset;
    // If result < hhdm_offset, the physical address caused a wrap-around
    // into the lower half (user space), which is a security violation.
    if (result < hhdm_offset) {
        @panic("physToVirt: integer overflow - physical address too large");
    }
    return @ptrFromInt(result);
}

/// Convert virtual address to physical address.
/// SECURITY: Panics if address is not in HHDM range.
pub fn virtToPhys(virt: u64) u64 {
    if (virt < hhdm_offset) {
        @panic("virtToPhys: address not in HHDM range");
    }
    // SECURITY: Use regular subtraction since bounds check above guarantees no underflow.
    // Using wrapping subtraction (-%}) would mask bugs if the check is ever removed.
    return virt - hhdm_offset;
}

/// Get page table pointer from physical address.
/// SECURITY: Panics if physical address would overflow.
pub fn getTablePtr(phys_addr: u64) *PageTable {
    const result = phys_addr +% hhdm_offset;
    if (result < hhdm_offset) {
        @panic("getTablePtr: integer overflow - physical address too large");
    }
    return @ptrFromInt(result);
}

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

/// Load user page table (TTBR0_EL1) without ASID
/// Used for userspace mappings (lower half of address space)
/// For ASID support, use loadUserPageTableWithAsid instead.
pub fn loadUserPageTable(l0_phys: u64) void {
    loadUserPageTableWithAsid(l0_phys, 0);
}

/// Load user page table (TTBR0_EL1) with ASID
/// TTBR format: ASID in bits 63:48, physical address in bits 47:0
/// ASID (Address Space Identifier) enables TLB isolation between processes.
///
/// SECURITY: Validates ASID against hardware-supported range.
/// On 8-bit ASID hardware (AS=0), passing ASID > 255 causes silent truncation,
/// potentially creating TLB collisions between unrelated processes.
pub fn loadUserPageTableWithAsid(l0_phys: u64, asid: u16) void {
    // SECURITY: Validate ASID is within hardware-supported range.
    // Truncation on 8-bit ASID hardware (max_asid=255) would cause
    // process A's TLB entries to collide with process B's.
    if (asid > max_asid) {
        console.err("paging: loadUserPageTableWithAsid({d}) exceeds max_asid({d})", .{ asid, max_asid });
        @panic("ASID out of range - would cause TLB collision");
    }

    // Combine ASID and physical address into TTBR value
    // ASID is placed in bits 63:48
    const ttbr_val = (l0_phys & 0x0000_FFFF_FFFF_F000) | (@as(u64, asid) << 48);
    asm volatile (
        \\dsb ishst
        \\msr ttbr0_el1, %[addr]
        \\isb
        :
        : [addr] "r" (ttbr_val),
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
/// Use after context switch when reusing an ASID.
///
/// SECURITY: Validates ASID against hardware-supported range.
/// Using an out-of-range ASID with 8-bit hardware causes truncation,
/// potentially flushing the wrong address space's TLB entries.
pub fn invalidateAsid(asid: u16) void {
    // SECURITY: Validate ASID is within hardware-supported range.
    // If ASID exceeds max_asid, it would be truncated by hardware,
    // causing incorrect TLB entries to be invalidated.
    if (asid > max_asid) {
        console.err("paging: invalidateAsid({d}) exceeds max_asid({d})", .{ asid, max_asid });
        // Fail-safe: invalidate ALL TLB entries rather than wrong ones
        invalidateAll();
        return;
    }

    // TLBI ASIDE1IS argument format: ASID in bits 63:48
    const asid_arg = @as(u64, asid) << 48;
    asm volatile (
        \\dsb ishst
        \\tlbi aside1is, %[asid]
        \\dsb ish
        \\isb
        :
        : [asid] "r" (asid_arg),
    );
}

/// Invalidate a single TLB entry for a specific ASID and virtual address
///
/// SECURITY: Validates ASID against hardware-supported range.
/// Using an out-of-range ASID with 8-bit hardware causes truncation,
/// potentially leaving stale TLB entries for the intended process.
pub fn invalidatePageAsid(virt_addr: u64, asid: u16) void {
    // SECURITY: Validate ASID is within hardware-supported range.
    if (asid > max_asid) {
        console.err("paging: invalidatePageAsid(0x{x}, {d}) exceeds max_asid({d})", .{ virt_addr, asid, max_asid });
        // Fail-safe: invalidate by VA across all ASIDs
        invalidatePage(virt_addr);
        return;
    }

    // TLBI VAE1IS argument format: ASID in bits 63:48, VA bits 55:12 in bits 43:0
    const tlbi_arg = (@as(u64, asid) << 48) | (virt_addr >> 12);
    asm volatile (
        \\dsb ishst
        \\tlbi vae1is, %[arg]
        \\dsb ish
        \\isb
        :
        : [arg] "r" (tlbi_arg),
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

/// Align address down to page boundary
pub fn pageAlignDown(addr: u64) u64 {
    return addr & ~@as(u64, PAGE_SIZE - 1);
}

/// Align address up to page boundary
/// SECURITY: Uses checked arithmetic to detect overflow.
/// Returns null if the alignment would overflow.
pub fn pageAlignUp(addr: u64) ?u64 {
    const sum = std.math.add(u64, addr, PAGE_SIZE - 1) catch return null;
    return sum & ~@as(u64, PAGE_SIZE - 1);
}

/// Align address up to page boundary (unchecked, for backwards compatibility)
/// WARNING: Only use when addr is known to be well below u64::MAX
pub fn pageAlignUpUnchecked(addr: u64) u64 {
    return (addr + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
}

/// Check if address is page-aligned
pub fn isPageAligned(addr: u64) bool {
    return (addr & (PAGE_SIZE - 1)) == 0;
}

/// Calculate number of pages needed to cover size bytes
/// SECURITY: Uses checked arithmetic to detect overflow.
/// Returns null if the calculation would overflow.
pub fn pagesToCover(size: u64) ?u64 {
    const sum = std.math.add(u64, size, PAGE_SIZE - 1) catch return null;
    return sum / PAGE_SIZE;
}

/// Calculate number of pages (unchecked, for backwards compatibility)
/// WARNING: Only use when size is known to be well below u64::MAX
pub fn pagesToCoverUnchecked(size: u64) u64 {
    return (size + PAGE_SIZE - 1) / PAGE_SIZE;
}

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
