// UEFI Bootloader Paging Setup
// Creates PML4 page tables for kernel handover
//
// Memory Layout:
//   Identity Map:  0x0000_0000_0000_0000 - Low 4GB (for boot transition)
//   HHDM:          0xFFFF_8000_0000_0000 - All physical RAM
//   Kernel:        0xFFFF_FFFF_8000_0000 - Kernel image (2GB window)

const std = @import("std");
const uefi = std.os.uefi;

pub const HHDM_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const KERNEL_BASE: u64 = 0xFFFF_FFFF_8000_0000;
pub const PAGE_SIZE: u64 = 4096;
pub const ENTRIES_PER_TABLE: usize = 512;

pub const PagingError = error{
    AllocationFailed,
    InvalidAddress,
    AddressOverflow,
};

/// Page table entry flags
pub const PageFlags = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false, // PS bit - 2MB/1GB pages
    global: bool = false,
    _available: u3 = 0,
    phys_addr_bits: u40 = 0, // Physical address >> 12
    _reserved: u11 = 0,
    no_execute: bool = false,

    pub fn withPhysAddr(self: PageFlags, phys: u64) PageFlags {
        var copy = self;
        copy.phys_addr_bits = @truncate(phys >> 12);
        return copy;
    }

    pub fn getPhysAddr(self: PageFlags) u64 {
        return @as(u64, self.phys_addr_bits) << 12;
    }

    pub fn toU64(self: PageFlags) u64 {
        return @bitCast(self);
    }
};

/// Flags for intermediate page table entries (PML4E, PDPTE, PDE pointing to next level)
/// NX bit in intermediate entries acts as OR gate - if set here, all pages below are NX.
/// We leave NX=0 in intermediates so leaf entries control executability.
/// Value: Present(1) + Writable(2) = 0x03, with explicit documentation
const INTERMEDIATE_FLAGS: u64 = (PageFlags{
    .present = true,
    .writable = true,
    .user = false, // Supervisor only
    .no_execute = false, // Let leaf entries decide
}).toU64();

/// Page table (512 entries)
pub const PageTable = struct {
    entries: [ENTRIES_PER_TABLE]u64,

    pub fn init() PageTable {
        return .{ .entries = [_]u64{0} ** ENTRIES_PER_TABLE };
    }
};

/// Paging context for bootloader
pub const PagingContext = struct {
    pml4_phys: u64,
    bs: *uefi.tables.BootServices,
    max_phys: u64,

    /// Allocate a zeroed page for page tables
    fn allocPage(self: *PagingContext) PagingError!u64 {
        const pages = self.bs.allocatePages(
            .any,
            .loader_data,
            1,
        ) catch return PagingError.AllocationFailed;

        const phys = @intFromPtr(pages.ptr);

        // Zero the page
        const ptr: [*]u8 = @ptrCast(pages.ptr);
        @memset(ptr[0..PAGE_SIZE], 0);

        return phys;
    }

    /// Get virtual address for physical address (UEFI identity maps everything)
    fn physToVirt(self: *PagingContext, phys: u64) [*]u64 {
        _ = self;
        return @ptrFromInt(phys);
    }

    /// Map a single 4KB page
    pub fn mapPage(self: *PagingContext, virt: u64, phys: u64, flags: PageFlags) PagingError!void {
        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;
        const pt_idx = (virt >> 12) & 0x1FF;

        // Get or create PDPT
        var pml4 = self.physToVirt(self.pml4_phys);
        var pdpt_phys: u64 = undefined;
        if (pml4[pml4_idx] & 1 != 0) {
            pdpt_phys = pml4[pml4_idx] & 0x000F_FFFF_FFFF_F000;
        } else {
            pdpt_phys = try self.allocPage();
            pml4[pml4_idx] = pdpt_phys | INTERMEDIATE_FLAGS;
        }

        // Get or create PD
        var pdpt = self.physToVirt(pdpt_phys);
        var pd_phys: u64 = undefined;
        if (pdpt[pdpt_idx] & 1 != 0) {
            pd_phys = pdpt[pdpt_idx] & 0x000F_FFFF_FFFF_F000;
        } else {
            pd_phys = try self.allocPage();
            pdpt[pdpt_idx] = pd_phys | INTERMEDIATE_FLAGS;
        }

        // Get or create PT
        var pd = self.physToVirt(pd_phys);
        var pt_phys: u64 = undefined;
        if (pd[pd_idx] & 1 != 0) {
            pt_phys = pd[pd_idx] & 0x000F_FFFF_FFFF_F000;
        } else {
            pt_phys = try self.allocPage();
            pd[pd_idx] = pt_phys | INTERMEDIATE_FLAGS;
        }

        // Set PT entry
        var pt = self.physToVirt(pt_phys);
        pt[pt_idx] = flags.withPhysAddr(phys).toU64();
    }

    /// Map a 2MB huge page
    pub fn mapHugePage(self: *PagingContext, virt: u64, phys: u64, flags: PageFlags) PagingError!void {
        const pml4_idx = (virt >> 39) & 0x1FF;
        const pdpt_idx = (virt >> 30) & 0x1FF;
        const pd_idx = (virt >> 21) & 0x1FF;

        // Get or create PDPT
        var pml4 = self.physToVirt(self.pml4_phys);
        var pdpt_phys: u64 = undefined;
        if (pml4[pml4_idx] & 1 != 0) {
            pdpt_phys = pml4[pml4_idx] & 0x000F_FFFF_FFFF_F000;
        } else {
            pdpt_phys = try self.allocPage();
            pml4[pml4_idx] = pdpt_phys | INTERMEDIATE_FLAGS;
        }

        // Get or create PD
        var pdpt = self.physToVirt(pdpt_phys);
        var pd_phys: u64 = undefined;
        if (pdpt[pdpt_idx] & 1 != 0) {
            pd_phys = pdpt[pdpt_idx] & 0x000F_FFFF_FFFF_F000;
        } else {
            pd_phys = try self.allocPage();
            pdpt[pdpt_idx] = pd_phys | INTERMEDIATE_FLAGS;
        }

        // Set PD entry with huge page flag
        var pd = self.physToVirt(pd_phys);
        var huge_flags = flags;
        huge_flags.huge_page = true;
        pd[pd_idx] = huge_flags.withPhysAddr(phys).toU64();
    }

    /// Map a range using 2MB pages where possible
    /// Uses checked arithmetic to prevent overflow in ReleaseFast builds
    pub fn mapRange(self: *PagingContext, virt_start: u64, phys_start: u64, size: u64, flags: PageFlags) PagingError!void {
        const huge_size: u64 = 2 * 1024 * 1024; // 2MB
        var offset: u64 = 0;

        while (offset < size) {
            // Security: use checked arithmetic to prevent address wrap-around
            const virt = std.math.add(u64, virt_start, offset) catch return PagingError.AddressOverflow;
            const phys = std.math.add(u64, phys_start, offset) catch return PagingError.AddressOverflow;
            const remaining = size - offset;

            // Use 2MB pages if aligned and enough space
            if (virt % huge_size == 0 and phys % huge_size == 0 and remaining >= huge_size) {
                try self.mapHugePage(virt, phys, flags);
                offset = std.math.add(u64, offset, huge_size) catch return PagingError.AddressOverflow;
            } else {
                try self.mapPage(virt, phys, flags);
                offset = std.math.add(u64, offset, PAGE_SIZE) catch return PagingError.AddressOverflow;
            }
        }
    }
};

/// Create page tables for kernel
/// Returns physical address of PML4
pub fn createKernelPageTables(
    bs: *uefi.tables.BootServices,
    max_phys_addr: u64,
    kernel_segments: []const KernelSegment,
) PagingError!u64 {
    // Allocate PML4
    const pml4_pages = bs.allocatePages(.any, .loader_data, 1) catch {
        return PagingError.AllocationFailed;
    };
    const pml4_phys = @intFromPtr(pml4_pages.ptr);

    // Zero PML4
    const pml4_ptr: [*]u8 = @ptrCast(pml4_pages.ptr);
    @memset(pml4_ptr[0..PAGE_SIZE], 0);

    var ctx = PagingContext{
        .pml4_phys = pml4_phys,
        .bs = bs,
        .max_phys = max_phys_addr,
    };

    // Data pages: writable but NOT executable (W^X policy)
    const rw_flags = PageFlags{
        .present = true,
        .writable = true,
        .global = true,
        .no_execute = true, // Security: prevent code execution from data pages
    };

    // Code pages: executable but NOT writable (W^X policy)
    const rx_flags = PageFlags{
        .present = true,
        .writable = false,
        .global = true,
        .no_execute = false, // Executable code
    };

    // Read-only data pages: neither writable nor executable
    const ro_flags = PageFlags{
        .present = true,
        .writable = false,
        .global = true,
        .no_execute = true, // Security: .rodata should not be executable
    };

    // 1. Identity map all physical memory (UEFI stack can live above 4GB on EDK2/QEMU)
    try ctx.mapRange(0, 0, max_phys_addr, rw_flags);

    // 2. HHDM: Map all physical memory at HHDM_BASE
    try ctx.mapRange(HHDM_BASE, 0, max_phys_addr, rw_flags);

    // 3. Map kernel segments at high half with proper W^X enforcement
    for (kernel_segments) |seg| {
        const flags = blk: {
            if (seg.writable) {
                // Writable segments must NOT be executable (W^X)
                break :blk rw_flags;
            } else if (seg.executable) {
                // Executable code: read + execute, no write
                break :blk rx_flags;
            } else {
                // Read-only data (.rodata): no write, no execute
                break :blk ro_flags;
            }
        };
        try ctx.mapRange(seg.virt_addr, seg.phys_addr, seg.size, flags);
    }

    return pml4_phys;
}

/// Kernel segment info (from ELF loader)
pub const KernelSegment = struct {
    virt_addr: u64,
    phys_addr: u64,
    size: u64,
    writable: bool,
    executable: bool, // Security: must propagate from ELF PF_X flag
};

/// Load new page tables (switch CR3)
pub fn loadPageTables(pml4_phys: u64) void {
    asm volatile ("mov %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4_phys),
    );
}

/// Remove identity mapping after boot transition is complete
/// SECURITY: This eliminates the low-address executable region that could
/// be exploited if an attacker can redirect control flow to addresses < 4GB.
/// Must be called from kernel init AFTER switching to HHDM addressing.
///
/// The identity map covers PML4 entries 0-3 (each entry covers 512GB).
/// For 4GB identity map, only entry 0 is used.
pub fn unmapIdentityRegion(pml4_phys: u64) void {
    // Access PML4 via HHDM since we're now running in higher half
    const pml4: [*]volatile u64 = @ptrFromInt(HHDM_BASE + pml4_phys);

    // Clear PML4 entry 0 (covers virtual addresses 0x0 - 0x7F_FFFF_FFFF)
    // This removes the entire identity-mapped region
    pml4[0] = 0;

    // Flush TLB by reloading CR3
    asm volatile ("mov %%cr3, %%rax; mov %%rax, %%cr3" ::: .{ .rax = true, .memory = true });
}

/// Check if identity mapping is still present (for debugging/assertions)
pub fn isIdentityMapped(pml4_phys: u64) bool {
    const pml4: [*]volatile u64 = @ptrFromInt(HHDM_BASE + pml4_phys);
    return (pml4[0] & 1) != 0; // Check present bit
}
