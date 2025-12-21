// x86_64 Paging HAL Module
//
// Provides 4-level page table management for x86_64 architecture.
// All physical memory access uses HHDM (Higher Half Direct Map) offset.
//
// Page Table Hierarchy:
//   PML4 (512 entries) -> PDPT (512 entries) -> PD (512 entries) -> PT (512 entries)
//   Each entry covers: 512GB -> 1GB -> 2MB -> 4KB
//
// HAL Contract: This module owns all page table manipulation.
// Kernel code must use VMM interface, not this module directly.

const cpu = @import("cpu.zig");

// Page size constants
pub const PAGE_SIZE: usize = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

// Virtual address structure for 4-level paging (48-bit canonical)
// Bits: [63:48] Sign extension | [47:39] PML4 | [38:30] PDPT | [29:21] PD | [20:12] PT | [11:0] Offset
pub const VirtualAddress = packed struct {
    offset: u12,
    pt_index: u9,
    pd_index: u9,
    pdpt_index: u9,
    pml4_index: u9,
    sign_extension: u16,

    pub fn from(addr: u64) VirtualAddress {
        return @bitCast(addr);
    }

    pub fn toU64(self: VirtualAddress) u64 {
        return @bitCast(self);
    }

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("VirtualAddress must be 8 bytes");
        if (@bitSizeOf(@This()) != 64) @compileError("VirtualAddress must be 64 bits");
    }
};

/// Page Table Entry for x86_64 4-level paging
/// Used for all levels: PML4E, PDPTE, PDE, PTE
pub const PageTableEntry = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false, // PS bit: 1GB page in PDPT, 2MB page in PD
    global: bool = false,
    available_low: u3 = 0, // Available for OS use
    // Physical address bits [51:12] (40 bits, but x86_64 typically uses 52-bit physical)
    // We store bits [51:12] in 40 bits
    phys_addr_bits: u40 = 0,
    available_high: u11 = 0, // Available for OS use
    no_execute: bool = false,

    const Self = @This();

    /// Create an empty (not present) entry
    pub fn empty() Self {
        return .{};
    }

    /// Create an entry pointing to the next level page table
    pub fn tableEntry(phys_addr: u64, user: bool) Self {
        return .{
            .present = true,
            .writable = true,
            .user_accessible = user,
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }

    /// Create a leaf entry pointing to a physical page
    pub fn pageEntry(phys_addr: u64, flags: PageFlags) Self {
        return .{
            .present = true,
            .writable = flags.writable,
            .user_accessible = flags.user,
            .write_through = flags.write_through,
            .cache_disable = flags.cache_disable,
            .global = flags.global,
            .no_execute = flags.no_execute,
            .phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT),
        };
    }

    /// Get the physical address this entry points to
    pub fn getPhysAddr(self: Self) u64 {
        return @as(u64, self.phys_addr_bits) << PAGE_SHIFT;
    }

    /// Set the physical address
    pub fn setPhysAddr(self: *Self, phys_addr: u64) void {
        self.phys_addr_bits = @truncate(phys_addr >> PAGE_SHIFT);
    }

    /// Check if entry is present
    pub fn isPresent(self: Self) bool {
        return self.present;
    }

    /// Check if entry maps a huge page (2MB or 1GB)
    pub fn isHugePage(self: Self) bool {
        return self.huge_page;
    }

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("PageTableEntry must be 8 bytes");
    }
};

/// Flags for page mapping
pub const PageFlags = struct {
    writable: bool = true,
    user: bool = false,
    no_execute: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    global: bool = false,

    pub const KERNEL_RW: PageFlags = .{ .writable = true, .user = false };
    pub const KERNEL_RO: PageFlags = .{ .writable = false, .user = false };
    pub const KERNEL_RWX: PageFlags = .{ .writable = true, .user = false, .no_execute = false };
    pub const USER_RW: PageFlags = .{ .writable = true, .user = true };
    pub const USER_RO: PageFlags = .{ .writable = false, .user = true };
    pub const USER_RWX: PageFlags = .{ .writable = true, .user = true, .no_execute = false };
    pub const MMIO: PageFlags = .{ .writable = true, .user = false, .cache_disable = true };
};

/// Page table (array of 512 entries, 4KB aligned)
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]PageTableEntry,

    const Self = @This();

    /// Initialize all entries as empty
    pub fn init() Self {
        return .{
            .entries = [_]PageTableEntry{PageTableEntry.empty()} ** ENTRIES_PER_TABLE,
        };
    }
};

// HHDM (Higher Half Direct Map) offset
// The bootloader sets up HHDM mapping in kernel space.
// This maps physical memory starting at 0x0 to a virtual address in higher half.
// Default value used before init() is called.
pub const HHDM_OFFSET_DEFAULT: u64 = 0xFFFF800000000000;

// Minimum valid HHDM offset (must be in kernel space)
const HHDM_MIN_OFFSET: u64 = 0xFFFF800000000000;

// Runtime HHDM offset - set by bootloader via init()
var hhdm_offset: u64 = HHDM_OFFSET_DEFAULT;
var hhdm_initialized: bool = false;

/// Initialize paging module with bootloader-provided HHDM offset.
/// This enables KASLR support by accepting dynamic HHDM bases.
pub fn init(offset: u64) void {
    // Validate offset is in kernel space (higher half)
    if (offset < HHDM_MIN_OFFSET) {
        @panic("HHDM offset not in kernel space");
    }
    hhdm_offset = offset;
    hhdm_initialized = true;
}

/// Get the current HHDM offset (runtime value from bootloader)
pub fn getHhdmOffset() u64 {
    return hhdm_offset;
}

/// Check if HHDM has been initialized with bootloader value
pub fn isInitialized() bool {
    return hhdm_initialized;
}

const builtin = @import("builtin");

/// Convert physical address to virtual using HHDM
/// All kernel physical memory access must use this function
/// SECURITY: In Debug/ReleaseSafe modes, validates that the result doesn't wrap around
pub fn physToVirt(phys: u64) [*]u8 {
    const result = phys +% hhdm_offset; // Use wrapping add

    // SECURITY: Check for overflow in debug/safe builds
    // If result < hhdm_offset after addition, we wrapped around
    // This would map kernel code to user-controllable addresses
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        if (result < hhdm_offset) {
            @panic("physToVirt: integer overflow - physical address too large");
        }
    }

    return @ptrFromInt(result);
}

/// Convert virtual address to physical using HHDM
/// Only valid for addresses in the HHDM range
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}

/// Get pointer to page table from physical address using HHDM
pub fn getTablePtr(phys_addr: u64) *PageTable {
    const virt: u64 = phys_addr + hhdm_offset;
    return @ptrFromInt(virt);
}

/// Load a new page table root (CR3)
/// Flushes the entire TLB
pub fn loadPageTable(pml4_phys: u64) void {
    cpu.writeCr3(pml4_phys);
}

/// Get the current page table root (CR3)
pub fn getCurrentPageTable() u64 {
    return cpu.readCr3();
}

/// Invalidate a single TLB entry
pub fn invalidatePage(virt_addr: u64) void {
    cpu.invlpg(virt_addr);
}

/// Flush the entire TLB
pub fn flushTlb() void {
    cpu.flushTlb();
}

/// Flush entire TLB including global pages
pub fn flushTlbGlobal() void {
    cpu.flushTlbGlobal();
}

/// Extract page table indices from a virtual address
pub fn getIndices(virt_addr: u64) struct { pml4: usize, pdpt: usize, pd: usize, pt: usize } {
    const va = VirtualAddress.from(virt_addr);
    return .{
        .pml4 = va.pml4_index,
        .pdpt = va.pdpt_index,
        .pd = va.pd_index,
        .pt = va.pt_index,
    };
}

/// Align address down to page boundary
pub fn pageAlignDown(addr: u64) u64 {
    return addr & ~@as(u64, PAGE_SIZE - 1);
}

/// Align address up to page boundary
pub fn pageAlignUp(addr: u64) u64 {
    return (addr + PAGE_SIZE - 1) & ~@as(u64, PAGE_SIZE - 1);
}

/// Check if address is page-aligned
pub fn isPageAligned(addr: u64) bool {
    return (addr & (PAGE_SIZE - 1)) == 0;
}

/// Calculate number of pages needed for a given size
pub fn pagesToCover(size: u64) u64 {
    return (size + PAGE_SIZE - 1) / PAGE_SIZE;
}
