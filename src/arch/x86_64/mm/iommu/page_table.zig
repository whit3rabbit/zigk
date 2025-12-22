// IOMMU Page Table Management
//
// Manages page tables for Intel VT-d IOMMU DMA remapping.
// IOMMU uses a 3-level hierarchy:
//   1. Root Table (256 entries, one per PCI bus)
//   2. Context Table (256 entries per root, one per device:function)
//   3. Second-Level Page Tables (same format as CPU 4-level paging)
//
// Second-level page tables use identical format to x86_64 CPU page tables,
// allowing reuse of the existing PageTableEntry structure.
//
// Reference: Intel VT-d Specification 3.0+, Section 9 (Translation Structures)

const std = @import("std");
const console = @import("console");
const pmm = @import("pmm");
const regs = @import("regs.zig");

// Use relative imports within HAL
const paging = @import("../paging.zig");

/// Page size constants
pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_SHIFT: u6 = 12;
pub const ENTRIES_PER_TABLE: usize = 512;

/// Root Table - 256 entries covering all PCI buses
/// Each RootEntry is 128 bits (16 bytes), so table is 4KB
pub const RootTable = struct {
    entries: [256]regs.RootEntry,

    const Self = @This();

    /// Allocate and initialize a new root table
    pub fn alloc() ?*Self {
        const phys = pmm.allocZeroedPage() orelse return null;
        const ptr: *Self = @ptrCast(@alignCast(paging.physToVirt(phys)));
        return ptr;
    }

    /// Get physical address of this table
    pub fn getPhysAddr(self: *const Self) u64 {
        return paging.virtToPhys(@intFromPtr(self));
    }

    /// Get or create context table for a bus
    pub fn getOrCreateContext(self: *Self, bus: u8) ?*ContextTable {
        const entry = &self.entries[bus];

        if (entry.isPresent()) {
            // Context table exists
            const ctx_phys = entry.getContextTable();
            return @ptrCast(@alignCast(paging.physToVirt(ctx_phys)));
        }

        // Allocate new context table
        const ctx = ContextTable.alloc() orelse return null;
        entry.setContextTable(ctx.getPhysAddr());
        return ctx;
    }

    /// Get existing context table for a bus (if present)
    pub fn getContext(self: *const Self, bus: u8) ?*ContextTable {
        const entry = &self.entries[bus];
        if (!entry.isPresent()) return null;

        const ctx_phys = entry.getContextTable();
        return @ptrCast(@alignCast(paging.physToVirt(ctx_phys)));
    }

    comptime {
        if (@sizeOf(RootTable) != 4096) @compileError("RootTable must be 4KB");
    }
};

/// Context Table - 256 entries covering all device:function combinations
/// Each ContextEntry is 128 bits (16 bytes), so table is 4KB
pub const ContextTable = struct {
    entries: [256]regs.ContextEntry,

    const Self = @This();

    /// Allocate and initialize a new context table
    pub fn alloc() ?*Self {
        const phys = pmm.allocZeroedPage() orelse return null;
        const ptr: *Self = @ptrCast(@alignCast(paging.physToVirt(phys)));
        return ptr;
    }

    /// Get physical address of this table
    pub fn getPhysAddr(self: *const Self) u64 {
        return paging.virtToPhys(@intFromPtr(self));
    }

    /// Get index for device:function
    fn getIndex(device: u5, func: u3) usize {
        return (@as(usize, device) << 3) | @as(usize, func);
    }

    /// Configure context entry for a device
    pub fn configureDevice(
        self: *Self,
        device: u5,
        func: u3,
        domain_id: u16,
        page_table_phys: u64,
    ) void {
        const idx = getIndex(device, func);
        self.entries[idx].configure(domain_id, page_table_phys, .agaw_48);
    }

    /// Get page table for a device (if configured)
    pub fn getPageTable(self: *const Self, device: u5, func: u3) ?*SecondLevelPageTable {
        const idx = getIndex(device, func);
        const entry = &self.entries[idx];

        if (!entry.p) return null;

        const pt_phys = entry.getPageTablePtr();
        return @ptrCast(@alignCast(paging.physToVirt(pt_phys)));
    }

    /// Check if device is configured
    pub fn isDeviceConfigured(self: *const Self, device: u5, func: u3) bool {
        const idx = getIndex(device, func);
        return self.entries[idx].p;
    }

    comptime {
        if (@sizeOf(ContextTable) != 4096) @compileError("ContextTable must be 4KB");
    }
};

/// Second-Level Page Table Entry
/// Uses identical format to CPU page table entries (64-bit)
pub const SlPageEntry = packed struct(u64) {
    read: bool = false, // Bit 0: Read permission
    write: bool = false, // Bit 1: Write permission
    _reserved0: u5 = 0, // Bits 2-6: Reserved
    super_page: bool = false, // Bit 7: Super page (2MB/1GB)
    _reserved1: u3 = 0, // Bits 8-10: Reserved
    snoop: bool = true, // Bit 11: Snoop behavior (1 = snoop)
    phys_addr: u40 = 0, // Bits 12-51: Physical address
    _reserved2: u10 = 0, // Bits 52-61: Reserved
    transient: bool = false, // Bit 62: Transient mapping
    _reserved3: bool = false, // Bit 63: Reserved

    const Self = @This();

    /// Check if entry is present (readable or writable)
    pub fn isPresent(self: Self) bool {
        return self.read or self.write;
    }

    /// Get physical address from entry
    pub fn getPhysAddr(self: Self) u64 {
        return @as(u64, self.phys_addr) << PAGE_SHIFT;
    }

    /// Set physical address in entry
    pub fn setPhysAddr(self: *Self, addr: u64) void {
        self.phys_addr = @truncate(addr >> PAGE_SHIFT);
    }

    /// Create a table entry (points to next level page table)
    pub fn tableEntry(phys_addr: u64) Self {
        var entry = Self{};
        entry.read = true;
        entry.write = true;
        entry.setPhysAddr(phys_addr);
        return entry;
    }

    /// Create a leaf entry (points to physical page)
    pub fn leafEntry(phys_addr: u64, readable: bool, writable: bool) Self {
        var entry = Self{};
        entry.read = readable;
        entry.write = writable;
        entry.snoop = true; // Enable cache snooping by default
        entry.setPhysAddr(phys_addr);
        return entry;
    }

    /// Create a super page entry (2MB or 1GB)
    pub fn superPageEntry(phys_addr: u64, readable: bool, writable: bool) Self {
        var entry = Self{};
        entry.read = readable;
        entry.write = writable;
        entry.super_page = true;
        entry.snoop = true;
        entry.setPhysAddr(phys_addr);
        return entry;
    }
};

/// Second-Level Page Table (512 entries)
pub const SecondLevelPageTable = struct {
    entries: [ENTRIES_PER_TABLE]SlPageEntry,

    const Self = @This();

    /// Allocate and initialize a new page table
    pub fn alloc() ?*Self {
        const phys = pmm.allocZeroedPage() orelse return null;
        const ptr: *Self = @ptrCast(@alignCast(paging.physToVirt(phys)));
        return ptr;
    }

    /// Get physical address of this table
    pub fn getPhysAddr(self: *const Self) u64 {
        return paging.virtToPhys(@intFromPtr(self));
    }

    comptime {
        if (@sizeOf(SecondLevelPageTable) != 4096) @compileError("SecondLevelPageTable must be 4KB");
    }
};

/// IOVA (IO Virtual Address) decomposition
/// Uses same 9-9-9-9-12 bit structure as CPU virtual addresses
pub const IovaAddress = packed struct(u64) {
    offset: u12, // Page offset
    pt_index: u9, // Page Table index
    pd_index: u9, // Page Directory index
    pdpt_index: u9, // PDPT index
    pml4_index: u9, // PML4 index
    _reserved: u16 = 0, // Must be zero for valid IOVA

    /// Create from raw IOVA
    pub fn from(iova: u64) IovaAddress {
        return @bitCast(iova);
    }

    /// Convert back to raw IOVA
    pub fn toU64(self: IovaAddress) u64 {
        return @bitCast(self);
    }
};

/// Domain Page Table Manager
/// Manages the 4-level page table hierarchy for a single IOMMU domain
pub const DomainPageTables = struct {
    /// Physical address of PML4 (root of second-level tables)
    pml4_phys: u64,

    /// Virtual pointer to PML4 for kernel access
    pml4: *SecondLevelPageTable,

    const Self = @This();

    /// Create a new domain page table set
    pub fn create() ?Self {
        const pml4 = SecondLevelPageTable.alloc() orelse return null;
        return Self{
            .pml4_phys = pml4.getPhysAddr(),
            .pml4 = pml4,
        };
    }

    /// Map an IOVA range to physical memory
    /// Returns error if allocation fails
    pub fn mapRange(
        self: *Self,
        iova_start: u64,
        phys_start: u64,
        size: u64,
        readable: bool,
        writable: bool,
    ) error{OutOfMemory}!void {
        const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
        var iova = iova_start;
        var phys = phys_start;

        var i: u64 = 0;
        while (i < pages) : (i += 1) {
            try self.mapPage(iova, phys, readable, writable);
            iova += PAGE_SIZE;
            phys += PAGE_SIZE;
        }
    }

    /// Map a single 4KB page
    pub fn mapPage(
        self: *Self,
        iova: u64,
        phys: u64,
        readable: bool,
        writable: bool,
    ) error{OutOfMemory}!void {
        const addr = IovaAddress.from(iova);

        // Walk/create page table hierarchy
        const pdpt = try self.getOrCreateTable(self.pml4, addr.pml4_index);
        const pd = try self.getOrCreateTable(pdpt, addr.pdpt_index);
        const pt = try self.getOrCreateTable(pd, addr.pd_index);

        // Set leaf entry
        pt.entries[addr.pt_index] = SlPageEntry.leafEntry(phys, readable, writable);
    }

    /// Unmap an IOVA range
    pub fn unmapRange(self: *Self, iova_start: u64, size: u64) void {
        const pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
        var iova = iova_start;

        var i: u64 = 0;
        while (i < pages) : (i += 1) {
            self.unmapPage(iova);
            iova += PAGE_SIZE;
        }
    }

    /// Unmap a single page
    pub fn unmapPage(self: *Self, iova: u64) void {
        const addr = IovaAddress.from(iova);

        // Walk page table hierarchy
        const pml4_entry = &self.pml4.entries[addr.pml4_index];
        if (!pml4_entry.isPresent()) return;

        const pdpt: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pml4_entry.getPhysAddr()),
        ));
        const pdpt_entry = &pdpt.entries[addr.pdpt_index];
        if (!pdpt_entry.isPresent()) return;

        const pd: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pdpt_entry.getPhysAddr()),
        ));
        const pd_entry = &pd.entries[addr.pd_index];
        if (!pd_entry.isPresent()) return;

        const pt: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pd_entry.getPhysAddr()),
        ));

        // Clear the leaf entry
        pt.entries[addr.pt_index] = SlPageEntry{};
    }

    /// Translate IOVA to physical address
    /// Returns null if not mapped
    pub fn translate(self: *const Self, iova: u64) ?u64 {
        const addr = IovaAddress.from(iova);

        const pml4_entry = &self.pml4.entries[addr.pml4_index];
        if (!pml4_entry.isPresent()) return null;

        const pdpt: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pml4_entry.getPhysAddr()),
        ));
        const pdpt_entry = &pdpt.entries[addr.pdpt_index];
        if (!pdpt_entry.isPresent()) return null;

        // Check for 1GB super page
        if (pdpt_entry.super_page) {
            const base = pdpt_entry.getPhysAddr();
            const offset = iova & 0x3FFFFFFF; // 30-bit offset
            return base + offset;
        }

        const pd: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pdpt_entry.getPhysAddr()),
        ));
        const pd_entry = &pd.entries[addr.pd_index];
        if (!pd_entry.isPresent()) return null;

        // Check for 2MB super page
        if (pd_entry.super_page) {
            const base = pd_entry.getPhysAddr();
            const offset = iova & 0x1FFFFF; // 21-bit offset
            return base + offset;
        }

        const pt: *SecondLevelPageTable = @ptrCast(@alignCast(
            paging.physToVirt(pd_entry.getPhysAddr()),
        ));
        const pt_entry = &pt.entries[addr.pt_index];
        if (!pt_entry.isPresent()) return null;

        const base = pt_entry.getPhysAddr();
        const offset = iova & 0xFFF; // 12-bit offset
        return base + offset;
    }

    /// Get or create a page table at the given index
    fn getOrCreateTable(
        self: *Self,
        table: *SecondLevelPageTable,
        index: u9,
    ) error{OutOfMemory}!*SecondLevelPageTable {
        _ = self;
        const entry = &table.entries[index];

        if (entry.isPresent()) {
            // Table exists
            return @ptrCast(@alignCast(paging.physToVirt(entry.getPhysAddr())));
        }

        // Allocate new table
        const new_table = SecondLevelPageTable.alloc() orelse return error.OutOfMemory;
        entry.* = SlPageEntry.tableEntry(new_table.getPhysAddr());
        return new_table;
    }
};

/// Full IOMMU table hierarchy for a VT-d unit
pub const IommuTables = struct {
    /// Root table
    root: *RootTable,

    /// Physical address of root table (for hardware register)
    root_phys: u64,

    const Self = @This();

    /// Create a new IOMMU table set
    pub fn create() ?Self {
        const root = RootTable.alloc() orelse return null;
        return Self{
            .root = root,
            .root_phys = root.getPhysAddr(),
        };
    }

    /// Configure a PCI device with a domain's page tables
    pub fn configureDevice(
        self: *Self,
        bus: u8,
        device: u5,
        func: u3,
        domain_id: u16,
        domain_tables: *const DomainPageTables,
    ) ?void {
        const ctx = self.root.getOrCreateContext(bus) orelse return null;
        ctx.configureDevice(device, func, domain_id, domain_tables.pml4_phys);
    }

    /// Check if a device is configured
    pub fn isDeviceConfigured(self: *const Self, bus: u8, device: u5, func: u3) bool {
        const ctx = self.root.getContext(bus) orelse return false;
        return ctx.isDeviceConfigured(device, func);
    }
};
