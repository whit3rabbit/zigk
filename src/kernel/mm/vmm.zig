// Virtual Memory Manager (VMM)
//
// Manages virtual address spaces using 4-level page tables.
// Provides page mapping/unmapping operations for kernel and user space.
//
// Design:
//   - Uses PMM for allocating page table structures
//   - Uses HAL paging module for page table manipulation
//   - Supports kernel (higher half) and user (lower half) mappings
//   - All page table access via HHDM (no identity mapping)
//
// Virtual Address Layout (x86_64 canonical):
//   0x0000_0000_0000_0000 - 0x0000_7FFF_FFFF_FFFF: User space (128 TB)
//   0xFFFF_8000_0000_0000 - 0xFFFF_FFFF_FFFF_FFFF: Kernel space (128 TB)
//     - HHDM starts at offset provided by Bootloader (typically 0xFFFF_8000_0000_0000)

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");
const sync = @import("sync");
const tlb = @import("tlb");
const layout = @import("layout");

const paging = hal.paging;
const PageTableEntry = paging.PageTableEntry;
const PageTable = paging.PageTable;
pub const PageFlags = paging.PageFlags;

// Constants
pub const PAGE_SIZE: usize = paging.PAGE_SIZE;

// Kernel address space boundaries
// KERNEL_BASE and MMIO_BASE are now runtime values from layout module (KASLR)
pub const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF;
pub const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
const MMIO_REGION_SIZE: u64 = 0x1000_0000_0000; // 1TB MMIO region

/// Get the kernel base address (HHDM base, runtime value from layout)
pub fn getKernelBase() u64 {
    return layout.getHhdmBase();
}

/// Get the MMIO region base (runtime value from layout with KASLR offset)
pub fn getMmioBase() u64 {
    return layout.getMmioRegionBase();
}

/// Get the MMIO region end (calculated from base + size)
pub fn getMmioEnd() u64 {
    return layout.getMmioRegionBase() + MMIO_REGION_SIZE;
}
pub const MMIO_END = 0xFFFF_C000_0000_0000; // Legacy fallback constant

// VMM State
var kernel_pml4_phys: u64 = 0;
var initialized: bool = false;

// MMIO Allocator State
var mmio_current: u64 = 0; // Initialized in init()
var mmio_lock: sync.Spinlock = .{};

/// Errors that can occur during VMM operations
pub const VmmError = error{
    /// VMM has not been initialized yet
    NotInitialized,
    /// Physical memory allocation failed
    OutOfMemory,
    /// Virtual or physical address is invalid (not aligned or out of bounds)
    InvalidAddress,
    /// Page is already mapped
    AlreadyMapped,
    /// Page is not mapped
    NotMapped,
    /// Invalid page flags
    InvalidFlags,
};

/// Initialize VMM with kernel page tables
///
/// Allocates a new PML4 for the kernel, copies higher-half kernel mappings
/// from the bootloader's page table, and activates the new table.
/// Must be called after PMM is initialized.
pub fn init() VmmError!void {
    if (initialized) {
        return;
    }

    console.info("VMM: Initializing...", .{});

    // Initialize MMIO allocator with KASLR-randomized base
    mmio_current = layout.getMmioRegionBase();

    // Allocate PML4 for kernel address space
    kernel_pml4_phys = pmm.allocZeroedPage() orelse {
        console.err("VMM: Failed to allocate kernel PML4!", .{});
        return VmmError.OutOfMemory;
    };

    console.info("VMM: Kernel PML4 at phys {x}", .{kernel_pml4_phys});

    // Copy page table entries from current page tables (set up by Bootloader)
    // This preserves HHDM and kernel mappings
    const current_pml4_phys = paging.getCurrentPageTable();
    const current_pml4 = paging.getTablePtr(current_pml4_phys);
    const new_pml4 = paging.getTablePtr(kernel_pml4_phys);

    // Copy ALL entries (0-511) to preserve any bootloader mappings.
    // This is necessary for UEFI boot which uses an identity-mapped stack.
    // For Limine boot, entries 0-255 are typically empty anyway.
    // User-space processes will get their own separate PML4 with only entries 256-511 shared.
    var i: usize = 0;
    while (i < 512) : (i += 1) {
        new_pml4.entries[i] = current_pml4.entries[i];
    }

    // Load the new page table
    paging.loadPageTable(kernel_pml4_phys);

    initialized = true;
    console.info("VMM: Initialized with kernel mappings preserved", .{});
}

/// Get the kernel PML4 physical address
pub fn getKernelPml4() u64 {
    return kernel_pml4_phys;
}

/// Map a single 4KB virtual page to a physical page
///
/// Allocates intermediate page tables (PML4 -> PDPT -> PD -> PT) as needed.
///
/// Arguments:
///   pml4_phys: Physical address of the PML4 table
///   virt_addr: Virtual address to map (must be 4KB aligned)
///   phys_addr: Physical address to map to (must be 4KB aligned)
///   flags: Page flags (present, writable, user, etc.)
pub fn mapPage(pml4_phys: u64, virt_addr: u64, phys_addr: u64, flags: PageFlags) VmmError!void {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    if (!paging.isPageAligned(virt_addr) or !paging.isPageAligned(phys_addr)) {
        return VmmError.InvalidAddress;
    }

    if (config.debug_memory) {
        console.debug("VMM: Mapping {x} -> {x}", .{ virt_addr, phys_addr });
    }

    // Get page table indices
    const indices = paging.getIndices(virt_addr);

    // Navigate/create page table hierarchy
    const pml4 = paging.getTablePtr(pml4_phys);

    // PML4 -> PDPT
    const pdpt_phys = try getOrCreateTable(&pml4.entries[indices.pml4], flags.user);
    const pdpt = paging.getTablePtr(pdpt_phys);

    // PDPT -> PD
    const pd_phys = try getOrCreateTable(&pdpt.entries[indices.pdpt], flags.user);
    const pd = paging.getTablePtr(pd_phys);

    // PD -> PT
    const pt_phys = try getOrCreateTable(&pd.entries[indices.pd], flags.user);
    const pt = paging.getTablePtr(pt_phys);

    // Check if already mapped
    if (pt.entries[indices.pt].isPresent()) {
        return VmmError.AlreadyMapped;
    }

    // Create leaf entry
    pt.entries[indices.pt] = PageTableEntry.pageEntry(phys_addr, flags);

    // Invalidate TLB for this page
    paging.invalidatePage(virt_addr);
}

/// Update flags for a mapped page (without unmapping)
///
/// Changes the permission flags for an existing mapping.
/// Returns error if page is not mapped.
pub fn protectPage(pml4_phys: u64, virt_addr: u64, flags: PageFlags) VmmError!void {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    if (!paging.isPageAligned(virt_addr)) {
        return VmmError.InvalidAddress;
    }

    const indices = paging.getIndices(virt_addr);
    const pml4 = paging.getTablePtr(pml4_phys);

    // Navigate to PT
    if (!pml4.entries[indices.pml4].isPresent()) return VmmError.NotMapped;
    const pdpt = paging.getTablePtr(pml4.entries[indices.pml4].getPhysAddr());

    if (!pdpt.entries[indices.pdpt].isPresent()) return VmmError.NotMapped;
    const pd = paging.getTablePtr(pdpt.entries[indices.pdpt].getPhysAddr());

    if (!pd.entries[indices.pd].isPresent()) return VmmError.NotMapped;
    const pt = paging.getTablePtr(pd.entries[indices.pd].getPhysAddr());

    if (!pt.entries[indices.pt].isPresent()) return VmmError.NotMapped;

    // Get old physical address
    const phys_addr = pt.entries[indices.pt].getPhysAddr();

    // Update entry with new flags, preserving physical address
    pt.entries[indices.pt] = PageTableEntry.pageEntry(phys_addr, flags);

    // TLB shootdown - must invalidate on all CPUs since permissions changed
    tlb.shootdown(virt_addr);
}

/// Map a contiguous range of pages
///
/// Maps `size` bytes starting from `virt_start` to `phys_start`.
/// Both addresses and size must be page-aligned (handled by caller or helper logic).
///
/// On failure, all pages mapped during this call are unmapped (rollback)
/// to ensure atomic-like behavior.
pub fn mapRange(pml4_phys: u64, virt_start: u64, phys_start: u64, size: usize, flags: PageFlags) VmmError!void {
    // Check for size overflow: size + PAGE_SIZE - 1 must not wrap
    if (size > std.math.maxInt(usize) - (PAGE_SIZE - 1)) {
        return VmmError.InvalidAddress;
    }
    const page_count = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    var mapped_count: usize = 0;

    // Rollback on failure: unmap all pages we successfully mapped
    errdefer {
        var j: usize = 0;
        while (j < mapped_count) : (j += 1) {
            const virt = virt_start + j * PAGE_SIZE;
            unmapPage(pml4_phys, virt) catch {};
        }
    }

    while (mapped_count < page_count) : (mapped_count += 1) {
        const virt = virt_start + mapped_count * PAGE_SIZE;
        const phys = phys_start + mapped_count * PAGE_SIZE;
        try mapPage(pml4_phys, virt, phys, flags);
    }
}

/// Unmap a virtual page
///
/// Removes the mapping for the specified virtual address.
/// If the unmap results in empty page tables, they are freed recursively.
/// Also invalidates the TLB entry for the unmapped address.
pub fn unmapPage(pml4_phys: u64, virt_addr: u64) VmmError!void {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    if (!paging.isPageAligned(virt_addr)) {
        return VmmError.InvalidAddress;
    }

    const indices = paging.getIndices(virt_addr);
    const pml4 = paging.getTablePtr(pml4_phys);

    // Navigate to PT
    if (!pml4.entries[indices.pml4].isPresent()) {
        return VmmError.NotMapped;
    }

    const pdpt = paging.getTablePtr(pml4.entries[indices.pml4].getPhysAddr());
    if (!pdpt.entries[indices.pdpt].isPresent()) {
        return VmmError.NotMapped;
    }

    const pd = paging.getTablePtr(pdpt.entries[indices.pdpt].getPhysAddr());
    if (!pd.entries[indices.pd].isPresent()) {
        return VmmError.NotMapped;
    }

    const pt = paging.getTablePtr(pd.entries[indices.pd].getPhysAddr());
    if (!pt.entries[indices.pt].isPresent()) {
        return VmmError.NotMapped;
    }

    // Clear the entry
    pt.entries[indices.pt] = PageTableEntry.empty();

    // Cleanup empty tables recursively
    if (isTableEmpty(pt)) {
        const pt_phys = pd.entries[indices.pd].getPhysAddr();
        pmm.freePage(pt_phys);
        pd.entries[indices.pd] = PageTableEntry.empty();

        if (isTableEmpty(pd)) {
            const pd_phys = pdpt.entries[indices.pdpt].getPhysAddr();
            pmm.freePage(pd_phys);
            pdpt.entries[indices.pdpt] = PageTableEntry.empty();

            if (isTableEmpty(pdpt)) {
                const pdpt_phys = pml4.entries[indices.pml4].getPhysAddr();
                pmm.freePage(pdpt_phys);
                pml4.entries[indices.pml4] = PageTableEntry.empty();
            }
        }
    }

    // TLB shootdown - must invalidate on all CPUs since mapping removed
    // Note: Even if page table structures were freed (tables_freed=true),
    // other CPUs may have cached PDE/PDPTE entries, so shootdown is always needed
    tlb.shootdown(virt_addr);

    if (config.debug_memory) {
        console.debug("VMM: Unmapped {x}", .{virt_addr});
    }
}

/// Check if a page table is completely empty
fn isTableEmpty(table: *const PageTable) bool {
    for (table.entries) |entry| {
        if (entry.isPresent()) return false;
    }
    return true;
}

/// Translate a virtual address to a physical address
///
/// Traverses the page table hierarchy to find the physical address.
/// Supports 4KB, 2MB, and 1GB pages.
/// Returns null if the address is not mapped.
pub fn translate(pml4_phys: u64, virt_addr: u64) ?u64 {
    const indices = paging.getIndices(virt_addr);
    const pml4 = paging.getTablePtr(pml4_phys);

    if (!pml4.entries[indices.pml4].isPresent()) {
        return null;
    }

    const pdpt = paging.getTablePtr(pml4.entries[indices.pml4].getPhysAddr());
    if (!pdpt.entries[indices.pdpt].isPresent()) {
        return null;
    }

    // Check for 1GB huge page
    if (pdpt.entries[indices.pdpt].isHugePage()) {
        const base = pdpt.entries[indices.pdpt].getPhysAddr();
        const offset = virt_addr & 0x3FFFFFFF; // 30-bit offset for 1GB page
        return base + offset;
    }

    const pd = paging.getTablePtr(pdpt.entries[indices.pdpt].getPhysAddr());
    if (!pd.entries[indices.pd].isPresent()) {
        return null;
    }

    // Check for 2MB huge page
    if (pd.entries[indices.pd].isHugePage()) {
        const base = pd.entries[indices.pd].getPhysAddr();
        const offset = virt_addr & 0x1FFFFF; // 21-bit offset for 2MB page
        return base + offset;
    }

    const pt = paging.getTablePtr(pd.entries[indices.pd].getPhysAddr());
    if (!pt.entries[indices.pt].isPresent()) {
        return null;
    }

    const base = pt.entries[indices.pt].getPhysAddr();
    const offset = virt_addr & 0xFFF; // 12-bit offset for 4KB page
    return base + offset;
}

/// Check if a virtual address is mapped
pub fn isMapped(pml4_phys: u64, virt_addr: u64) bool {
    return translate(pml4_phys, virt_addr) != null;
}

/// Check if a user page is mapped with user-accessible permissions.
/// This verifies the user bit is set at ALL levels of the page table hierarchy.
/// Returns false if the page is not mapped or any level lacks user permission.
pub fn isUserPageMapped(pml4_phys: u64, virt_addr: u64) bool {
    const indices = paging.getIndices(virt_addr);
    const pml4 = paging.getTablePtr(pml4_phys);

    // Check PML4 entry
    if (!pml4.entries[indices.pml4].isPresent()) return false;
    if (!pml4.entries[indices.pml4].user_accessible) return false;

    const pdpt = paging.getTablePtr(pml4.entries[indices.pml4].getPhysAddr());

    // Check PDPT entry
    if (!pdpt.entries[indices.pdpt].isPresent()) return false;
    if (!pdpt.entries[indices.pdpt].user_accessible) return false;

    // 1GB huge page check
    if (pdpt.entries[indices.pdpt].isHugePage()) {
        return true; // User bit already checked
    }

    const pd = paging.getTablePtr(pdpt.entries[indices.pdpt].getPhysAddr());

    // Check PD entry
    if (!pd.entries[indices.pd].isPresent()) return false;
    if (!pd.entries[indices.pd].user_accessible) return false;

    // 2MB huge page check
    if (pd.entries[indices.pd].isHugePage()) {
        return true; // User bit already checked
    }

    const pt = paging.getTablePtr(pd.entries[indices.pd].getPhysAddr());

    // Check PT entry (leaf)
    if (!pt.entries[indices.pt].isPresent()) return false;
    if (!pt.entries[indices.pt].user_accessible) return false;

    return true;
}

/// Check if a user page is mapped with write permission.
/// Verifies both user-accessible AND writable flags at the leaf level.
pub fn isUserPageWritable(pml4_phys: u64, virt_addr: u64) bool {
    const indices = paging.getIndices(virt_addr);
    const pml4 = paging.getTablePtr(pml4_phys);

    // Navigate to leaf, checking user bit at each level
    if (!pml4.entries[indices.pml4].isPresent()) return false;
    if (!pml4.entries[indices.pml4].user_accessible) return false;

    const pdpt = paging.getTablePtr(pml4.entries[indices.pml4].getPhysAddr());
    if (!pdpt.entries[indices.pdpt].isPresent()) return false;
    if (!pdpt.entries[indices.pdpt].user_accessible) return false;

    if (pdpt.entries[indices.pdpt].isHugePage()) {
        return pdpt.entries[indices.pdpt].writable;
    }

    const pd = paging.getTablePtr(pdpt.entries[indices.pdpt].getPhysAddr());
    if (!pd.entries[indices.pd].isPresent()) return false;
    if (!pd.entries[indices.pd].user_accessible) return false;

    if (pd.entries[indices.pd].isHugePage()) {
        return pd.entries[indices.pd].writable;
    }

    const pt = paging.getTablePtr(pd.entries[indices.pd].getPhysAddr());
    if (!pt.entries[indices.pt].isPresent()) return false;
    if (!pt.entries[indices.pt].user_accessible) return false;

    return pt.entries[indices.pt].writable;
}

/// Verify an entire range of user memory is mapped and accessible.
/// Iterates over all pages in the range and checks user permission.
/// Returns false if any page in the range fails the check.
pub fn verifyUserRange(pml4_phys: u64, start: u64, len: usize) bool {
    if (len == 0) return true;

    // Check for address overflow: start + len must not wrap
    if (start > std.math.maxInt(u64) - len) return false;

    // Align start down to page boundary
    const aligned_start = paging.pageAlignDown(start);
    const end = start + len;

    // Check each page in the range
    var addr = aligned_start;
    while (addr < end) : (addr += PAGE_SIZE) {
        if (!isUserPageMapped(pml4_phys, addr)) {
            return false;
        }
    }
    return true;
}

/// Verify user memory range with write permission check.
/// Used for buffers that will be written to (e.g., sys_read output).
pub fn verifyUserRangeWritable(pml4_phys: u64, start: u64, len: usize) bool {
    if (len == 0) return true;

    // Check for address overflow: start + len must not wrap
    if (start > std.math.maxInt(u64) - len) return false;

    const aligned_start = paging.pageAlignDown(start);
    const end = start + len;

    var addr = aligned_start;
    while (addr < end) : (addr += PAGE_SIZE) {
        if (!isUserPageWritable(pml4_phys, addr)) {
            return false;
        }
    }
    return true;
}

/// Create a new user address space
/// Returns physical address of new PML4
pub fn createAddressSpace() VmmError!u64 {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    // Allocate new PML4
    const new_pml4_phys = pmm.allocZeroedPage() orelse {
        return VmmError.OutOfMemory;
    };

    // Copy kernel mappings (higher half)
    const kernel_pml4 = paging.getTablePtr(kernel_pml4_phys);
    const new_pml4 = paging.getTablePtr(new_pml4_phys);

    var i: usize = 256;
    while (i < 512) : (i += 1) {
        new_pml4.entries[i] = kernel_pml4.entries[i];
    }

    console.debug("VMM: Created new address space at {x}", .{new_pml4_phys});
    return new_pml4_phys;
}

/// Destroy a user address space
/// Frees all user-space page tables and mapped pages
pub fn destroyAddressSpace(pml4_phys: u64) void {
    if (!initialized) return;

    // Do not destroy the kernel PML4
    if (pml4_phys == kernel_pml4_phys) {
        console.warn("VMM: Attempt to destroy kernel address space!", .{});
        return;
    }

    const pml4 = paging.getTablePtr(pml4_phys);

    // Only free user space entries (0-255)
    var pml4_idx: usize = 0;
    while (pml4_idx < 256) : (pml4_idx += 1) {
        if (pml4.entries[pml4_idx].isPresent()) {
            freePageTableTree(pml4.entries[pml4_idx].getPhysAddr(), 3);
        }
    }

    // Free PML4 itself
    pmm.freePage(pml4_phys);
    console.debug("VMM: Destroyed address space at {x}", .{pml4_phys});
}

/// Switch to an address space
pub fn switchAddressSpace(pml4_phys: u64) void {
    paging.loadPageTable(pml4_phys);
}

/// Map kernel memory range in current address space
pub fn mapKernel(virt_start: u64, phys_start: u64, size: usize, flags: PageFlags) VmmError!void {
    return mapRange(kernel_pml4_phys, virt_start, phys_start, size, flags);
}

/// Map MMIO region with cache-disabled pages
/// Returns virtual address of mapped region
/// Used for device register access (PCI config space, NIC MMIO, etc.)
pub fn mapMmio(phys_addr: u64, size: usize) VmmError!u64 {
    // Legacy wrapper - use explicit mapping logic now
    return mapMmioExplicit(phys_addr, size);
}

/// Map MMIO region with explicit remapping (cache-disabled 4KB pages)
/// This is the proper approach for hardware that requires strict MMIO semantics
/// Returns virtual address of mapped region
pub fn mapMmioExplicit(phys_addr: u64, size: usize) VmmError!u64 {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    // Align addresses
    const aligned_phys = paging.pageAlignDown(phys_addr);
    const offset = phys_addr - aligned_phys;
    const aligned_size = paging.pageAlignUp(size + offset) orelse return VmmError.OutOfMemory;

    // Allocate virtual address range from MMIO space
    const held = mmio_lock.acquire();
    const virt_base = mmio_current;

    // SECURITY: Check for overflow and ensure we stay within MMIO region bounds.
    // Without this check, large BAR allocations (from malicious firmware or
    // many devices) could cause mmio_current to grow into kernel heap or other
    // critical memory regions, leading to memory corruption.
    if (std.math.maxInt(u64) - virt_base < aligned_size) {
        held.release();
        return VmmError.OutOfMemory;
    }

    const new_mmio_current = virt_base + aligned_size;
    const mmio_end = getMmioEnd();
    if (new_mmio_current > mmio_end) {
        console.err("VMM: MMIO region exhausted (requested={d}KB, current=0x{x}, limit=0x{x})", .{
            aligned_size / 1024,
            virt_base,
            mmio_end,
        });
        held.release();
        return VmmError.OutOfMemory;
    }

    mmio_current = new_mmio_current;
    held.release();

    // Map each page with cache-disabled flag
    const page_count = aligned_size / PAGE_SIZE;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const page_phys = aligned_phys + i * PAGE_SIZE;
        const page_virt = virt_base + i * PAGE_SIZE;

        mapPage(kernel_pml4_phys, page_virt, page_phys, PageFlags.MMIO) catch |err| {
            // Rollback on failure: unmap pages mapped so far
            var j: usize = 0;
            while (j < i) : (j += 1) {
                const cleanup_virt = virt_base + j * PAGE_SIZE;
                unmapPage(kernel_pml4_phys, cleanup_virt) catch {};
            }
            return err;
        };
    }

    console.info("VMM: MMIO explicit map: phys=0x{x:0>16} virt=0x{x:0>16} size={d}KB", .{
        phys_addr,
        virt_base + offset,
        size / 1024,
    });

    return virt_base + offset;
}

/// Map MMIO region with explicit virtual address alignment
/// Used when hardware requires the virtual base address to be aligned to a specific boundary.
/// For example, PCI ECAM requires 1MB alignment for bitwise OR address calculation.
///
/// Parameters:
///   phys_addr: Physical address of the MMIO region
///   size: Size in bytes of the region
///   alignment: Required virtual address alignment (must be power of 2, >= PAGE_SIZE)
///
/// Returns: Virtual address of mapped region (with offset preserved)
pub fn mapMmioExplicitAligned(phys_addr: u64, size: usize, alignment: usize) VmmError!u64 {
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    // Validate alignment is power of 2 and at least PAGE_SIZE
    if (alignment < PAGE_SIZE or (alignment & (alignment - 1)) != 0) {
        console.err("VMM: Invalid alignment {x} (must be power of 2 >= PAGE_SIZE)", .{alignment});
        return VmmError.InvalidAddress;
    }

    // Align physical addresses to page boundary
    const aligned_phys = paging.pageAlignDown(phys_addr);
    const offset = phys_addr - aligned_phys;
    const aligned_size = paging.pageAlignUp(size + offset) orelse return VmmError.OutOfMemory;

    // Allocate virtual address range from MMIO space with requested alignment
    const held = mmio_lock.acquire();

    // Align mmio_current UP to the requested alignment boundary
    const align_u64: u64 = @intCast(alignment);
    const remainder = mmio_current & (align_u64 - 1);
    const virt_base = if (remainder == 0) mmio_current else mmio_current + (align_u64 - remainder);

    // Verify alignment succeeded
    if ((virt_base & (align_u64 - 1)) != 0) {
        held.release();
        console.err("VMM: Alignment calculation failed (base=0x{x}, align=0x{x})", .{ virt_base, alignment });
        return VmmError.OutOfMemory;
    }

    // SECURITY: Check for overflow and ensure we stay within MMIO region bounds
    if (std.math.maxInt(u64) - virt_base < aligned_size) {
        held.release();
        return VmmError.OutOfMemory;
    }

    const new_mmio_current = virt_base + aligned_size;
    const mmio_end = getMmioEnd();
    if (new_mmio_current > mmio_end) {
        console.err("VMM: MMIO region exhausted (requested={d}KB, current=0x{x}, limit=0x{x})", .{
            aligned_size / 1024,
            virt_base,
            mmio_end,
        });
        held.release();
        return VmmError.OutOfMemory;
    }

    mmio_current = new_mmio_current;
    held.release();

    // Map each page with cache-disabled flag
    const page_count = aligned_size / PAGE_SIZE;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const page_phys = aligned_phys + i * PAGE_SIZE;
        const page_virt = virt_base + i * PAGE_SIZE;

        mapPage(kernel_pml4_phys, page_virt, page_phys, PageFlags.MMIO) catch |err| {
            // Rollback on failure: unmap pages mapped so far
            var j: usize = 0;
            while (j < i) : (j += 1) {
                const cleanup_virt = virt_base + j * PAGE_SIZE;
                unmapPage(kernel_pml4_phys, cleanup_virt) catch {};
            }
            return err;
        };
    }

    console.info("VMM: MMIO aligned map: phys=0x{x:0>16} virt=0x{x:0>16} size={d}KB align={d}MB", .{
        phys_addr,
        virt_base + offset,
        size / 1024,
        alignment / (1024 * 1024),
    });

    return virt_base + offset;
}

/// Unmap MMIO region
pub fn unmapMmio(virt_addr: u64, size: usize) void {
    if (!initialized) return;

    const aligned_virt = paging.pageAlignDown(virt_addr);
    const offset = virt_addr - aligned_virt;
    const aligned_size = paging.pageAlignUp(size + offset) orelse return;

    // Unmap the pages
    // Note: We do not reclaim the virtual address space (bump allocator),
    // but we must release the page table entries and TLB entries.
    const page_count = aligned_size / PAGE_SIZE;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const page_virt = aligned_virt + i * PAGE_SIZE;
        unmapPage(kernel_pml4_phys, page_virt) catch |err| {
            console.warn("VMM: Failed to unmap MMIO page {x}: {}", .{ page_virt, err });
        };
    }

    console.debug("VMM: unmapMmio {x} (size {d})", .{ virt_addr, size });
}

/// Allocate and map a virtual page (allocates physical page from PMM)
pub fn allocAndMapPage(pml4_phys: u64, virt_addr: u64, flags: PageFlags) VmmError!void {
    const phys = pmm.allocZeroedPage() orelse {
        return VmmError.OutOfMemory;
    };

    mapPage(pml4_phys, virt_addr, phys, flags) catch |err| {
        pmm.freePage(phys);
        return err;
    };
}

/// Unmap and free a virtual page (returns physical page to PMM)
pub fn unmapAndFreePage(pml4_phys: u64, virt_addr: u64) VmmError!void {
    const phys = translate(pml4_phys, virt_addr) orelse {
        return VmmError.NotMapped;
    };

    try unmapPage(pml4_phys, virt_addr);
    pmm.freePage(paging.pageAlignDown(phys));
}

/// Securely unmap and free a page containing sensitive data
///
/// SECURITY: This function zeros page content BEFORE clearing the PTE to
/// prevent information disclosure via TLB race. The sequence is:
///   1. Zero page content via HHDM (kernel always has access)
///   2. Clear PTE entry
///   3. TLB shootdown to all CPUs
///   4. Return physical page to PMM
///
/// Use this for pages containing: keys, passwords, decrypted data, etc.
/// For non-sensitive data, use regular unmapAndFreePage().
pub fn unmapAndFreePageSecure(pml4_phys: u64, virt_addr: u64) VmmError!void {
    const phys = translate(pml4_phys, virt_addr) orelse {
        return VmmError.NotMapped;
    };

    const aligned_phys = paging.pageAlignDown(phys);

    // Step 1: Zero page via HHDM before unmapping
    // This is safe because kernel HHDM mapping remains even after user PTE is cleared
    const hhdm_ptr = paging.physToVirt(aligned_phys);
    @memset(hhdm_ptr[0..PAGE_SIZE], 0);

    // Memory barrier to ensure zero is visible before PTE clear
    std.atomic.fence(.seq_cst);

    // Step 2-3: Clear PTE and shootdown (unmapPage handles this)
    try unmapPage(pml4_phys, virt_addr);

    // Step 4: Now safe to return page to PMM
    pmm.freePage(aligned_phys);
}

// Helper: Get or create a page table at the next level
fn getOrCreateTable(entry: *PageTableEntry, user: bool) VmmError!u64 {
    if (entry.isPresent()) {
        // Table exists, but we may need to upgrade permissions
        // If mapping user page, ensure path is user-accessible
        if (user and !entry.user_accessible) {
            entry.user_accessible = true;
        }
        return entry.getPhysAddr();
    }

    // Allocate new page table
    const new_table_phys = pmm.allocZeroedPage() orelse {
        return VmmError.OutOfMemory;
    };

    // Create table entry (intermediate tables are always writable)
    entry.* = PageTableEntry.tableEntry(new_table_phys, user);

    return new_table_phys;
}

// Helper: Recursively free page table tree
fn freePageTableTree(table_phys: u64, level: u8) void {
    if (level == 0) {
        pmm.freePage(table_phys);
        return;
    }

    const table = paging.getTablePtr(table_phys);

    var i: usize = 0;
    while (i < 512) : (i += 1) {
        if (table.entries[i].isPresent() and !table.entries[i].isHugePage()) {
            freePageTableTree(table.entries[i].getPhysAddr(), level - 1);
        }
    }

    pmm.freePage(table_phys);
}

/// Debug: Print VMM statistics
pub fn printStats() void {
    console.info("VMM Stats:", .{});
    console.info("  Kernel PML4: {x}", .{kernel_pml4_phys});
    console.info("  Initialized: {}", .{initialized});
}
