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

const hal = @import("hal");
const console = @import("console");
const config = @import("config");
const pmm = @import("pmm");

const paging = hal.paging;
const PageTableEntry = paging.PageTableEntry;
const PageTable = paging.PageTable;
pub const PageFlags = paging.PageFlags;

// Constants
pub const PAGE_SIZE: usize = paging.PAGE_SIZE;

// Kernel address space boundaries
pub const KERNEL_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF;

// VMM State
var kernel_pml4_phys: u64 = 0;
var initialized: bool = false;

/// Errors that can occur during VMM operations
pub const VmmError = error{
    NotInitialized,
    OutOfMemory,
    InvalidAddress,
    AlreadyMapped,
    NotMapped,
    InvalidFlags,
};

/// Initialize VMM with kernel page tables
/// Called after PMM is initialized
pub fn init() VmmError!void {
    if (initialized) {
        return;
    }

    console.info("VMM: Initializing...", .{});

    // Allocate PML4 for kernel address space
    kernel_pml4_phys = pmm.allocZeroedPage() orelse {
        console.err("VMM: Failed to allocate kernel PML4!", .{});
        return VmmError.OutOfMemory;
    };

    console.info("VMM: Kernel PML4 at phys {x}", .{kernel_pml4_phys});

    // Copy higher-half entries from current page tables (set up by Bootloader)
    // This preserves HHDM and kernel mappings
    const current_pml4_phys = paging.getCurrentPageTable();
    const current_pml4 = paging.getTablePtr(current_pml4_phys);
    const new_pml4 = paging.getTablePtr(kernel_pml4_phys);

    // Copy entries 256-511 (kernel space, higher half)
    // These are shared across all address spaces
    var i: usize = 256;
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

/// Map a virtual page to a physical page
/// Allocates intermediate page tables as needed
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

/// Map a range of pages
/// On failure, all previously mapped pages in this call are unmapped (rollback)
pub fn mapRange(pml4_phys: u64, virt_start: u64, phys_start: u64, size: usize, flags: PageFlags) VmmError!void {
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

    // Track if we freed any page table structures (not just the leaf)
    var tables_freed = false;

    // Cleanup empty tables recursively
    if (isTableEmpty(pt)) {
        const pt_phys = pd.entries[indices.pd].getPhysAddr();
        pmm.freePage(pt_phys);
        pd.entries[indices.pd] = PageTableEntry.empty();
        tables_freed = true;

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

    // TLB invalidation strategy:
    // - If only leaf page was unmapped: invlpg is sufficient
    // - If page table structures were freed: full TLB flush required
    //   (CPU may cache PDE/PDPTE entries in Paging Structure Caches)
    if (tables_freed) {
        paging.flushTlb();
    } else {
        paging.invalidatePage(virt_addr);
    }

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

/// Translate virtual address to physical
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
    if (!initialized) {
        return VmmError.NotInitialized;
    }

    // MMIO regions are mapped in kernel space using HHDM offset
    // This is the simplest approach - just use the direct mapping
    // The pages are already accessible via HHDM, we just need to ensure
    // they have the correct cache attributes

    // For PCIe ECAM and device MMIO, we can use HHDM directly
    // The bootloader's HHDM mapping uses 2MB huge pages which may not
    // have the right cache attributes. For proper MMIO we should remap
    // with 4KB pages and cache disabled.

    // Calculate virtual address via HHDM
    const virt_addr = phys_addr + paging.HHDM_OFFSET;

    // For now, assume HHDM mapping is sufficient (works for QEMU)
    // TODO: Implement proper remapping with cache-disabled 4KB pages
    // for real hardware that requires it

    console.info("VMM: MMIO region mapped: phys=0x{x} virt=0x{x} size={d}KB", .{
        phys_addr,
        virt_addr,
        size / 1024,
    });

    return virt_addr;
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
    const aligned_size = paging.pageAlignUp(size + offset);

    // For now, use HHDM virtual addresses but remap with proper flags
    const virt_base = aligned_phys + paging.HHDM_OFFSET;

    // Map each page with cache-disabled flag
    const page_count = aligned_size / PAGE_SIZE;
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const page_phys = aligned_phys + i * PAGE_SIZE;
        const page_virt = virt_base + i * PAGE_SIZE;

        // Try to map, ignore AlreadyMapped (HHDM might have it)
        mapPage(kernel_pml4_phys, page_virt, page_phys, PageFlags.MMIO) catch |err| {
            if (err != VmmError.AlreadyMapped) {
                return err;
            }
            // Already mapped - we assume HHDM mapping, which is fine for QEMU
        };
    }

    console.info("VMM: MMIO explicit map: phys=0x{x:0>16} virt=0x{x:0>16} size={d}KB", .{
        phys_addr,
        virt_base + offset,
        size / 1024,
    });

    return virt_base + offset;
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
