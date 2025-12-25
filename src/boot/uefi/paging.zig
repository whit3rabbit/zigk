// UEFI Bootloader Paging Setup
// Creates page tables for kernel handover
//
// Memory Layout:
//   Identity Map:  0x0000_0000_0000_0000 - Low 4GB (for boot transition)
//   HHDM:          0xFFFF_8000_0000_0000 - All physical RAM
//   Kernel:        0xFFFF_FFFF_8000_0000 - Kernel image (2GB window)

const std = @import("std");
const builtin = @import("builtin");
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

/// Page table entry flags (Architecture-specific)
pub const PageFlags = struct {
    present: bool = false,
    writable: bool = false,
    user: bool = false,
    no_execute: bool = false,
    huge_page: bool = false,
    global: bool = false,

    pub fn toRaw(self: PageFlags, phys_addr: u64) u64 {
        switch (builtin.cpu.arch) {
            .x86_64 => {
                var raw: u64 = 0;
                if (self.present) raw |= 1 << 0;
                if (self.writable) raw |= 1 << 1;
                if (self.user) raw |= 1 << 2;
                if (self.huge_page) raw |= 1 << 7;
                if (self.global) raw |= 1 << 8;
                if (self.no_execute) raw |= 1 << 63;
                raw |= (phys_addr & 0x000F_FFFF_FFFF_F000);
                return raw;
            },
            .aarch64 => {
                // AArch64 page/block descriptor format:
                // [1:0] = 0b11 for page/table, 0b01 for block
                // [4:2] = AttrIndx (MAIR index: 0=Device, 1=Normal WB, 2=Normal NC)
                // [6] = AP[1] (1=EL0 accessible)
                // [7] = AP[2] (1=read-only)
                // [9:8] = SH (shareability: 3=Inner Shareable)
                // [10] = AF (Access Flag, must be 1)
                // [54] = UXN (Unprivileged eXecute Never)
                var raw: u64 = 0x3; // Valid + Page descriptor
                if (self.huge_page) raw = 0x1; // Block descriptor instead

                // AttrIndx = 1 for normal write-back cacheable memory
                raw |= (1 << 2); // MAIR index 1 (Normal WB)

                if (self.no_execute) raw |= (1 << 54); // UXN
                if (!self.writable) raw |= (1 << 7); // AP[2] = 1 (RO)
                if (self.user) raw |= (1 << 6); // AP[1] = 1 (EL0)

                raw |= (1 << 10); // AF (Access Flag) - required
                raw |= (3 << 8); // SH = Inner Shareable
                raw |= (phys_addr & 0x000F_FFFF_FFFF_F000);
                return raw;
            },
            else => @compileError("Unsupported architecture"),
        }
    }
};

const INTERMEDIATE_FLAGS: u64 = switch (builtin.cpu.arch) {
    .x86_64 => (1 << 0) | (1 << 1), // Present + Writable
    .aarch64 => 0x3, // Valid + Table
    else => 0,
};

/// Paging context for bootloader
pub const PagingContext = struct {
    root_phys: u64,
    bs: *uefi.tables.BootServices,
    max_phys: u64,

    fn allocPage(self: *PagingContext) PagingError!u64 {
        const pages = self.bs.allocatePages(.any, .loader_data, 1) catch return PagingError.AllocationFailed;
        const phys = @intFromPtr(pages.ptr);
        const ptr: [*]u8 = @ptrCast(pages.ptr);
        var i: usize = 0;
        while (i < PAGE_SIZE) : (i += 1) ptr[i] = 0;
        return phys;
    }

    fn physToVirt(self: *PagingContext, phys: u64) [*]u64 {
        _ = self;
        return @ptrFromInt(phys);
    }

    pub fn mapPage(self: *PagingContext, virt: u64, phys: u64, flags: PageFlags) PagingError!void {
        const idx3 = (virt >> 39) & 0x1FF;
        const idx2 = (virt >> 30) & 0x1FF;
        const idx1 = (virt >> 21) & 0x1FF;
        const idx0 = (virt >> 12) & 0x1FF;

        var table = self.physToVirt(self.root_phys);
        
        // Level 3 -> Level 2
        if ((table[idx3] & 1) == 0) {
            const next = try self.allocPage();
            table[idx3] = next | INTERMEDIATE_FLAGS;
        }
        table = self.physToVirt(table[idx3] & 0x000F_FFFF_FFFF_F000);

        // Level 2 -> Level 1
        if ((table[idx2] & 1) == 0) {
            const next = try self.allocPage();
            table[idx2] = next | INTERMEDIATE_FLAGS;
        }
        table = self.physToVirt(table[idx2] & 0x000F_FFFF_FFFF_F000);

        // Level 1 -> Level 0
        if ((table[idx1] & 1) == 0) {
            const next = try self.allocPage();
            table[idx1] = next | INTERMEDIATE_FLAGS;
        }
        table = self.physToVirt(table[idx1] & 0x000F_FFFF_FFFF_F000);

        // Level 0 (Leaf)
        table[idx0] = flags.toRaw(phys);
    }

    pub fn mapHugePage(self: *PagingContext, virt: u64, phys: u64, flags: PageFlags) PagingError!void {
        const idx3 = (virt >> 39) & 0x1FF;
        const idx2 = (virt >> 30) & 0x1FF;
        const idx1 = (virt >> 21) & 0x1FF;

        var table = self.physToVirt(self.root_phys);
        
        if ((table[idx3] & 1) == 0) {
            const next = try self.allocPage();
            table[idx3] = next | INTERMEDIATE_FLAGS;
        }
        table = self.physToVirt(table[idx3] & 0x000F_FFFF_FFFF_F000);

        if ((table[idx2] & 1) == 0) {
            const next = try self.allocPage();
            table[idx2] = next | INTERMEDIATE_FLAGS;
        }
        table = self.physToVirt(table[idx2] & 0x000F_FFFF_FFFF_F000);

        var huge_flags = flags;
        huge_flags.huge_page = true;
        table[idx1] = huge_flags.toRaw(phys);
    }

    pub fn mapRange(self: *PagingContext, virt_start: u64, phys_start: u64, size: u64, flags: PageFlags) PagingError!void {
        const huge_size: u64 = 2 * 1024 * 1024;
        var offset: u64 = 0;

        while (offset < size) {
            const virt = std.math.add(u64, virt_start, offset) catch return PagingError.AddressOverflow;
            const phys = std.math.add(u64, phys_start, offset) catch return PagingError.AddressOverflow;
            const remaining = size - offset;

            if (virt % huge_size == 0 and phys % huge_size == 0 and remaining >= huge_size) {
                try self.mapHugePage(virt, phys, flags);
                offset += huge_size;
            } else {
                try self.mapPage(virt, phys, flags);
                offset += PAGE_SIZE;
            }
        }
    }
};

pub fn createKernelPageTables(
    bs: *uefi.tables.BootServices,
    max_phys_addr: u64,
    kernel_segments: []const KernelSegment,
) PagingError!u64 {
    const root_pages = bs.allocatePages(.any, .loader_data, 1) catch return PagingError.AllocationFailed;
    const root_phys = @intFromPtr(root_pages.ptr);
    const ptr: [*]u8 = @ptrCast(root_pages.ptr);
    var i: usize = 0;
    while (i < PAGE_SIZE) : (i += 1) ptr[i] = 0;

    var ctx = PagingContext{
        .root_phys = root_phys,
        .bs = bs,
        .max_phys = max_phys_addr,
    };

    const rw_flags = PageFlags{ .present = true, .writable = true, .global = true, .no_execute = true };
    const rx_flags = PageFlags{ .present = true, .writable = false, .global = true, .no_execute = false };
    const ro_flags = PageFlags{ .present = true, .writable = false, .global = true, .no_execute = true };
    const identity_flags = PageFlags{ .present = true, .writable = true, .global = true, .no_execute = false };

    // 1. Identity map low 4GB (or up to max_phys)
    try ctx.mapRange(0, 0, @min(max_phys_addr, 0x1_0000_0000), identity_flags);

    // 2. HHDM
    try ctx.mapRange(HHDM_BASE, 0, max_phys_addr, rw_flags);

    // 3. Kernel segments
    for (kernel_segments) |seg| {
        const flags = if (seg.writable) rw_flags else if (seg.executable) rx_flags else ro_flags;
        try ctx.mapRange(seg.virt_addr, seg.phys_addr, seg.size, flags);
    }

    return root_phys;
}

pub const KernelSegment = struct {
    virt_addr: u64,
    phys_addr: u64,
    size: u64,
    writable: bool,
    executable: bool,
};

pub fn loadPageTables(root_phys: u64) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            asm volatile ("mov %[root], %%cr3" : : [root] "r" (root_phys));
        },
        .aarch64 => {
            // AArch64 uses TTBR0 for lower half (0x0000...) and TTBR1 for upper half (0xFFFF...)
            // Kernel is at 0xFFFFFFFF80000000 which is in TTBR1 range
            // Identity map is at 0x0 which is in TTBR0 range
            // HHDM is at 0xFFFF800000000000 which is in TTBR1 range

            // Configure MAIR_EL1 (Memory Attribute Indirection Register)
            // Index 0: Device-nGnRnE (strongly ordered device memory)
            // Index 1: Normal, Inner/Outer Write-Back, Non-transient, Allocate
            // Index 2: Normal, Inner/Outer Non-Cacheable
            const MAIR_DEVICE: u64 = 0x00; // Device-nGnRnE
            const MAIR_NORMAL_WB: u64 = 0xFF; // Inner/Outer WB, R+W Allocate
            const MAIR_NORMAL_NC: u64 = 0x44; // Inner/Outer Non-Cacheable
            const mair_value: u64 = MAIR_DEVICE | (MAIR_NORMAL_WB << 8) | (MAIR_NORMAL_NC << 16);

            // Configure TCR_EL1:
            // - T0SZ = 16 (48-bit VA for TTBR0)
            // - T1SZ = 16 (48-bit VA for TTBR1)
            // - TG0 = 0b00 (4KB granule for TTBR0)
            // - TG1 = 0b10 (4KB granule for TTBR1)
            // - IPS = 0b010 (40-bit PA, 1TB)
            // - SH0/SH1 = 0b11 (Inner Shareable)
            // - ORGN0/ORGN1 = 0b01 (Write-Back Write-Allocate Cacheable)
            // - IRGN0/IRGN1 = 0b01 (Write-Back Write-Allocate Cacheable)
            const TCR_T0SZ: u64 = 16;
            const TCR_T1SZ: u64 = 16;
            const TCR_TG0_4K: u64 = 0b00 << 14;
            const TCR_TG1_4K: u64 = 0b10 << 30;
            const TCR_SH0_INNER: u64 = 0b11 << 12;
            const TCR_SH1_INNER: u64 = 0b11 << 28;
            const TCR_ORGN0_WBWA: u64 = 0b01 << 10;
            const TCR_ORGN1_WBWA: u64 = 0b01 << 26;
            const TCR_IRGN0_WBWA: u64 = 0b01 << 8;
            const TCR_IRGN1_WBWA: u64 = 0b01 << 24;
            const TCR_IPS_1TB: u64 = 0b010 << 32;

            const tcr_value = TCR_T0SZ | (TCR_T1SZ << 16) | TCR_TG0_4K | TCR_TG1_4K |
                TCR_SH0_INNER | TCR_SH1_INNER | TCR_ORGN0_WBWA | TCR_ORGN1_WBWA |
                TCR_IRGN0_WBWA | TCR_IRGN1_WBWA | TCR_IPS_1TB;

            asm volatile (
                // Disable MMU temporarily to safely switch page tables
                \\mrs x4, sctlr_el1
                \\bic x5, x4, #1
                \\msr sctlr_el1, x5
                \\isb
                // Configure memory attributes
                \\msr mair_el1, %[mair]
                // Configure translation control
                \\msr tcr_el1, %[tcr]
                // Set page table bases
                \\msr ttbr0_el1, %[root]
                \\msr ttbr1_el1, %[root]
                // Invalidate all TLBs
                \\tlbi vmalle1
                \\dsb sy
                \\isb
                // Re-enable MMU
                \\msr sctlr_el1, x4
                \\isb
                :
                : [mair] "r" (mair_value), [tcr] "r" (tcr_value), [root] "r" (root_phys)
                : .{ .x4 = true, .x5 = true, .memory = true }
            );
        },
        else => {},
    }
}

pub fn unmapIdentityRegion(root_phys: u64) void {
    const root: [*]volatile u64 = @ptrFromInt(HHDM_BASE + root_phys);
    root[0] = 0;
    
    switch (builtin.cpu.arch) {
        .x86_64 => {
            asm volatile ("mov %%cr3, %%rax; mov %%rax, %%cr3" ::: .{ .rax = true, .memory = true });
        },
        .aarch64 => {
            asm volatile (
                \\tlbi vmalle1
                \\dsb sy
                \\isb
                : : : .{ .memory = true }
            );
        },
        else => {},
    }
}
