//! User Virtual Memory Manager
//!
//! Manages userspace virtual address allocations via mmap/munmap/mprotect.
//! Tracks Virtual Memory Areas (VMAs) per-process for memory region management.
//!
//! Design:
//!   - Simple linked list of VMAs per process.
//!   - First-fit address allocation for mmap without hint.
//!   - Interfaces with VMM for actual page table operations.
//!   - Interfaces with PMM for physical page allocation.
//!
//! Linux mmap flags supported:
//!   - MAP_ANONYMOUS: Memory not backed by file.
//!   - MAP_PRIVATE: Private copy-on-write (MVP: just private).
//!   - MAP_FIXED: Use exact address (no address search).
//!   - MAP_DEVICE: Internal flag for MMIO/device mappings (skips PMM free).

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("sync");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const console = @import("console");
const uapi = @import("uapi");

const paging = hal.paging;
const PageFlags = paging.PageFlags;
const Errno = uapi.errno.Errno;

// =============================================================================
// Linux mmap Constants (from linux/mman.h)
// =============================================================================

// Protection flags
pub const PROT_NONE: u32 = 0x0;
pub const PROT_READ: u32 = 0x1;
pub const PROT_WRITE: u32 = 0x2;
pub const PROT_EXEC: u32 = 0x4;

// Map flags
pub const MAP_SHARED: u32 = 0x01;
pub const MAP_PRIVATE: u32 = 0x02;
pub const MAP_FIXED: u32 = 0x10;
pub const MAP_ANONYMOUS: u32 = 0x20;
pub const MAP_ANON: u32 = MAP_ANONYMOUS; // Alias
/// Internal flag for MMIO/device mappings - skip returning pages to PMM
pub const MAP_DEVICE: u32 = 0x1000;

// =============================================================================
// User Address Space Boundaries
// =============================================================================

/// Start of user mappable region (above null guard and executable)
const USER_MMAP_START: u64 = 0x0000_1000_0000_0000; // 16 TB
/// End of user space
const USER_MMAP_END: u64 = 0x0000_7FFF_FFFF_FFFF; // 128 TB

// =============================================================================
// Virtual Memory Area (VMA)
// =============================================================================

/// Type of VMA mapping - determines page fault handling behavior
pub const VmaType = enum {
    /// Anonymous memory (zero-filled on demand)
    Anonymous,
    /// File-backed mapping (not yet implemented)
    File,
    /// Device/MMIO mapping (eagerly mapped, not demand-paged)
    Device,
};

/// Virtual Memory Area - tracks a contiguous region of virtual memory
pub const Vma = struct {
    /// Start virtual address (page-aligned)
    start: u64,
    /// End virtual address (exclusive, page-aligned)
    end: u64,
    /// Protection flags (PROT_READ, PROT_WRITE, PROT_EXEC)
    prot: u32,
    /// Map flags (MAP_PRIVATE, MAP_ANONYMOUS, etc.)
    flags: u32,
    /// Type of mapping (determines page fault handling)
    vma_type: VmaType,

    /// Linked list pointers
    next: ?*Vma,
    prev: ?*Vma,

    /// Get size in bytes
    /// Assumes invariant: end >= start (enforced at VMA creation)
    pub fn size(self: *const Vma) usize {
        // Defensive: validate invariant to prevent underflow
        if (self.end < self.start) {
            if (builtin.mode == .Debug) @panic("VMA corruption: end < start");
            return 0;
        }
        return @intCast(self.end - self.start);
    }

    /// Get size in pages
    pub fn pageCount(self: *const Vma) usize {
        return self.size() / pmm.PAGE_SIZE;
    }

    /// Check if address is within this VMA
    pub fn contains(self: *const Vma, addr: u64) bool {
        return addr >= self.start and addr < self.end;
    }

    /// Check if this VMA overlaps with a range
    pub fn overlaps(self: *const Vma, start: u64, end: u64) bool {
        return self.start < end and start < self.end;
    }

    /// Convert protection flags to PageFlags
    pub fn toPageFlags(self: *const Vma) PageFlags {
        return .{
            .writable = (self.prot & PROT_WRITE) != 0,
            .user = true,
            .no_execute = (self.prot & PROT_EXEC) == 0,
        };
    }
};

// =============================================================================
// User VMM State (per-process)
// =============================================================================

/// User Virtual Memory Manager state
/// One instance per process/thread in MVP (moves to Process in Phase 4)
pub const UserVmm = struct {
    /// Page table physical address (PML4)
    pml4_phys: u64,

    /// Head of VMA linked list (sorted by start address)
    vma_head: ?*Vma,

    /// Number of VMAs
    vma_count: usize,

    /// Total mapped bytes
    total_mapped: usize,

    /// Randomized mmap base address (ASLR)
    /// First-fit allocation starts searching from here
    mmap_base: u64,

    /// Read-Writer lock protecting VMA list and operations
    /// Required for thread-safety (CLONE_VM) and to prevent races between
    /// mprotect and page faults.
    lock: sync.RwLock = .{},

    /// Initialize a new UserVmm with a fresh address space (default mmap base)
    pub fn init() !*UserVmm {
        return initWithMmapBase(USER_MMAP_START);
    }

    /// Initialize a new UserVmm with a randomized mmap base (ASLR)
    pub fn initWithMmapBase(mmap_base: u64) !*UserVmm {
        // Validation: mmap_base must be within user range
        if (mmap_base < USER_MMAP_START or mmap_base >= USER_MMAP_END) {
            return error.InvalidAddress;
        }

        const alloc = heap.allocator();

        // Create new page table
        const pml4 = vmm.createAddressSpace() catch {
            return error.OutOfMemory;
        };

        const self = try alloc.create(UserVmm);
        self.* = UserVmm{
            .pml4_phys = pml4,
            .vma_head = null,
            .vma_count = 0,
            .total_mapped = 0,
            .mmap_base = mmap_base,
        };

        return self;
    }

    /// Initialize with existing page table
    pub fn initWithPml4(pml4_phys: u64) !*UserVmm {
        const alloc = heap.allocator();

        const self = try alloc.create(UserVmm);
        self.* = UserVmm{
            .pml4_phys = pml4_phys,
            .vma_head = null,
            .vma_count = 0,
            .total_mapped = 0,
            .mmap_base = USER_MMAP_START, // Default for compatibility
        };

        return self;
    }

    /// Destroy the UserVmm and free all resources
    pub fn deinit(self: *UserVmm) void {
        const alloc = heap.allocator();

        // Free all VMAs and their physical pages
        var vma = self.vma_head;
        while (vma) |v| {
            const next = v.next;

            // Unmap and free physical pages for this VMA
            self.freeVmaPages(v);

            // Free VMA struct
            alloc.destroy(v);
            vma = next;
        }

        // Destroy address space (frees page tables)
        vmm.destroyAddressSpace(self.pml4_phys);

        // Free self
        alloc.destroy(self);
    }

    /// Map anonymous memory region
    /// addr: Hint address (0 = kernel chooses), must be page-aligned if MAP_FIXED
    /// len: Size in bytes (will be rounded up to page size)
    /// prot: Protection flags (PROT_READ, PROT_WRITE, PROT_EXEC)
    /// flags: Map flags (MAP_ANONYMOUS | MAP_PRIVATE required)
    /// Returns: Start address of mapping, or negative errno
    pub fn mmap(self: *UserVmm, addr: u64, len: usize, prot: u32, flags: u32) isize {
        // Acquire write lock as we are modifying the VMA list
        const held = self.lock.acquireWrite();
        defer held.release();

        // Validate flags - only anonymous private mappings supported
        if ((flags & MAP_ANONYMOUS) == 0) {
            return Errno.ENOSYS.toReturn(); // File mappings not supported
        }

        // Calculate page-aligned size
        if (len == 0) {
            return Errno.EINVAL.toReturn();
        }
        const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);
        const page_count = aligned_len / pmm.PAGE_SIZE;

        // Determine mapping address
        var map_addr: u64 = undefined;

        if ((flags & MAP_FIXED) != 0) {
            // MAP_FIXED: use exact address
            if (!paging.isPageAligned(addr)) {
                return Errno.EINVAL.toReturn();
            }
            // Check for overflow: addr + aligned_len must not wrap
            if (addr > std.math.maxInt(u64) - aligned_len) {
                return Errno.ENOMEM.toReturn();
            }
            if (addr < USER_MMAP_START or addr + aligned_len > USER_MMAP_END) {
                return Errno.ENOMEM.toReturn();
            }
            // Check for overlap with existing VMAs
            if (self.findOverlappingVma(addr, addr + aligned_len) != null) {
                // MAP_FIXED with overlap: unmap existing first
                // For MVP, just fail - proper impl would munmap the overlap
                return Errno.ENOMEM.toReturn();
            }
            map_addr = addr;
        } else {
            // Find free address range
            map_addr = self.findFreeRange(aligned_len) orelse {
                return Errno.ENOMEM.toReturn();
            };
        }

        // LAZY PAGING: Do NOT allocate physical pages here.
        // Physical pages will be allocated on-demand when page faults occur.
        // This is more memory-efficient as pages are only allocated when accessed.
        _ = page_count; // Unused now that allocation is lazy

        // Create VMA to track this mapping (no physical pages yet)
        const vma = self.createVma(map_addr, map_addr + aligned_len, prot, flags) catch {
            return Errno.ENOMEM.toReturn();
        };

        // Insert VMA into list
        self.insertVma(vma);
        self.total_mapped += aligned_len;

        console.debug("UserVmm: lazy mmap {x}-{x} prot={x} flags={x}", .{
            map_addr,
            map_addr + aligned_len,
            prot,
            flags,
        });

        return @bitCast(map_addr);
    }

    /// Unmap memory region
    /// addr: Start address (must be page-aligned)
    /// len: Size in bytes (will be rounded up)
    /// Returns: 0 on success, negative errno on error
    pub fn munmap(self: *UserVmm, addr: u64, len: usize) isize {
        // Acquire write lock as we are modifying the VMA list
        const held = self.lock.acquireWrite();
        defer held.release();

        if (!paging.isPageAligned(addr)) {
            return Errno.EINVAL.toReturn();
        }

        if (len == 0) {
            return Errno.EINVAL.toReturn();
        }

        const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);

        // Check for overflow: addr + aligned_len must not wrap
        if (addr > std.math.maxInt(u64) - aligned_len) {
            return Errno.EINVAL.toReturn();
        }
        const end_addr = addr + aligned_len;

        // Find VMAs that overlap with the range
        var vma = self.vma_head;
        while (vma) |v| {
            const next = v.next;

            if (v.overlaps(addr, end_addr)) {
                // This VMA overlaps - handle partial/full unmapping
                if (addr <= v.start and end_addr >= v.end) {
                    // Full overlap: remove entire VMA
                    self.freeVmaPages(v);
                    self.removeVma(v);
                    self.total_mapped -= v.size();

                    const alloc = heap.allocator();
                    alloc.destroy(v);
                } else if (addr <= v.start) {
                    // Partial from start: shrink VMA
                    const unmap_end = @min(end_addr, v.end);
                    self.unmapRange(v.start, @intCast(unmap_end - v.start));
                    self.total_mapped -= @intCast(unmap_end - v.start);
                    v.start = unmap_end;
                } else if (end_addr >= v.end) {
                    // Partial from end: shrink VMA
                    const unmap_start = @max(addr, v.start);
                    self.unmapRange(unmap_start, @intCast(v.end - unmap_start));
                    self.total_mapped -= @intCast(v.end - unmap_start);
                    v.end = unmap_start;
                } else {
                    // Hole in middle: split VMA
                    // Create new VMA for the right part first to handle OOM cleanly
                    const right_vma = self.createVma(end_addr, v.end, v.prot, v.flags) catch {
                        return Errno.ENOMEM.toReturn();
                    };

                    // Unmap the middle portion
                    self.unmapRange(addr, aligned_len);
                    self.total_mapped -= aligned_len;

                    // Shrink existing VMA to be the left part
                    v.end = addr;

                    // Insert the new VMA (right part)
                    self.insertVma(right_vma);
                }
            }

            vma = next;
        }

        console.debug("UserVmm: munmap {x}-{x}", .{ addr, end_addr });
        return 0;
    }

    /// Change memory protection
    /// addr: Start address (must be page-aligned)
    /// len: Size in bytes (will be rounded up)
    /// prot: New protection flags
    /// Returns: 0 on success, negative errno on error
    pub fn mprotect(self: *UserVmm, addr: u64, len: usize, prot: u32) isize {
        // Acquire write lock to prevent race with page fault handler
        // Page fault needs consistent view of VMA protection flags
        const held = self.lock.acquireWrite();
        defer held.release();

        if (!paging.isPageAligned(addr)) {
            return Errno.EINVAL.toReturn();
        }

        if (len == 0) {
            return 0; // Success for zero length
        }

        const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);

        // Check for overflow: addr + aligned_len must not wrap
        if (addr > std.math.maxInt(u64) - aligned_len) {
            return Errno.EINVAL.toReturn();
        }
        const end_addr = addr + aligned_len;

        // Find VMAs that overlap with the range
        var found_any = false;
        var vma = self.vma_head;
        while (vma) |v| {
            if (v.overlaps(addr, end_addr)) {
                found_any = true;

                // Update VMA protection
                v.prot = prot;

                // Update page table entries for this VMA
                const new_flags = protToPageFlags(prot);
                const update_start = @max(addr, v.start);
                const update_end = @min(end_addr, v.end);

                // Update each page in the range
                var page_addr = update_start;
                while (page_addr < update_end) : (page_addr += pmm.PAGE_SIZE) {
                    // Update flags safely without unmapping
                    vmm.protectPage(self.pml4_phys, page_addr, new_flags) catch {};
                }
            }
            vma = v.next;
        }

        if (!found_any) {
            return Errno.ENOMEM.toReturn();
        }

        console.debug("UserVmm: mprotect {x}-{x} prot={x}", .{ addr, end_addr, prot });
        return 0;
    }

    /// Expand heap VMA and map new pages
    /// old_brk: Current heap break (page aligned)
    /// new_brk: New heap break (page aligned)
    /// Returns: 0 on success, negative errno on error
    /// Note: Caller must update process RSS accounting
    pub fn expandHeap(self: *UserVmm, old_brk: u64, new_brk: u64) isize {
        // Acquire write lock for VMA manipulation
        const held = self.lock.acquireWrite();
        defer held.release();

        if (new_brk <= old_brk) return 0;

        const size = new_brk - old_brk;
        const page_count = size / pmm.PAGE_SIZE;

        // Standard heap protection and flags
        const prot = PROT_READ | PROT_WRITE;
        const flags = MAP_PRIVATE | MAP_ANONYMOUS;
        const page_flags = protToPageFlags(prot);

        // Map pages one by one to avoid requiring contiguous physical memory
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            // Allocate single page
            const phys_page = pmm.allocPage() orelse {
                // Allocation failed - rollback previous pages
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    const rollback_addr = old_brk + (j * pmm.PAGE_SIZE);
                    if (vmm.translate(self.pml4_phys, rollback_addr)) |paddr| {
                        vmm.unmapPage(self.pml4_phys, rollback_addr) catch {};
                        pmm.freePage(paddr);
                    }
                }
                return Errno.ENOMEM.toReturn();
            };

            // Zero the page (security)
            const ptr: [*]u8 = @ptrCast(hal.paging.physToVirt(phys_page));
            hal.mem.fill(ptr, 0, pmm.PAGE_SIZE);

            // Map the page
            const vaddr = old_brk + (i * pmm.PAGE_SIZE);
            vmm.mapPage(self.pml4_phys, vaddr, phys_page, page_flags) catch {
                // Mapping failed - free this page
                pmm.freePage(phys_page);

                // Rollback previous pages
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    const rollback_addr = old_brk + (j * pmm.PAGE_SIZE);
                    if (vmm.translate(self.pml4_phys, rollback_addr)) |paddr| {
                        vmm.unmapPage(self.pml4_phys, rollback_addr) catch {};
                        pmm.freePage(paddr);
                    }
                }
                return Errno.ENOMEM.toReturn();
            };
        }

        const rollbackNewPages = struct {
            fn run(vmm_instance: *UserVmm, start: u64, count: usize) void {
                var j: usize = 0;
                while (j < count) : (j += 1) {
                    const rollback_addr = start + (j * pmm.PAGE_SIZE);
                    if (vmm.translate(vmm_instance.pml4_phys, rollback_addr)) |paddr| {
                        vmm.unmapPage(vmm_instance.pml4_phys, rollback_addr) catch {};
                        pmm.freePage(paddr);
                    }
                }
            }
        }.run;

        // Update or create VMA
        // Check if we can extend existing heap VMA
        // Safe check for overlap to prevent underflow if old_brk is 0 (though heap starts > 0)
        const check_addr = if (old_brk > 0) old_brk - 1 else 0;
        if (self.findOverlappingVma(check_addr, old_brk)) |vma| {
            // Found VMA ending at old_brk, extend it
            if (vma.end == old_brk and vma.prot == prot and vma.flags == flags) {
                vma.end = new_brk;
            } else {
                // Different attributes or gap - create new VMA
                const new_vma = self.createVma(old_brk, new_brk, prot, flags) catch {
                    rollbackNewPages(self, old_brk, page_count);
                    return Errno.ENOMEM.toReturn();
                };
                self.insertVma(new_vma);
            }
        } else {
            // No preceding VMA - create new one
            const new_vma = self.createVma(old_brk, new_brk, prot, flags) catch {
                rollbackNewPages(self, old_brk, page_count);
                return Errno.ENOMEM.toReturn();
            };
            self.insertVma(new_vma);
        }

        self.total_mapped += size;
        return 0;
    }

    /// Shrink heap VMA and unmap pages
    /// old_brk: Current heap break (page aligned)
    /// new_brk: New heap break (page aligned)
    /// Returns: 0 on success
    /// Note: Caller must update process RSS accounting
    pub fn shrinkHeap(self: *UserVmm, old_brk: u64, new_brk: u64) void {
        // Acquire write lock for VMA manipulation
        const held = self.lock.acquireWrite();
        defer held.release();

        if (new_brk >= old_brk) return;

        const size = old_brk - new_brk;

        // Unmap and free physical pages
        var offset: u64 = 0;
        while (offset < size) : (offset += pmm.PAGE_SIZE) {
            const vaddr = new_brk + offset;
            if (vmm.translate(self.pml4_phys, vaddr)) |phys| {
                vmm.unmapPage(self.pml4_phys, vaddr) catch {};
                pmm.freePage(phys);
            }
        }

        // Update VMA
        if (self.findOverlappingVma(new_brk, old_brk)) |vma| {
            // If VMA covers the range being shrunk
            if (vma.end > new_brk) {
                if (vma.start >= new_brk) {
                    // Fully remove VMA if it starts after new break
                    self.removeVma(vma);
                    const alloc = heap.allocator();
                    alloc.destroy(vma);
                } else {
                    // Shrink VMA
                    vma.end = new_brk;
                }
            }
        }

        if (self.total_mapped >= size) {
            self.total_mapped -= size;
        } else {
            self.total_mapped = 0;
        }
    }

    // =========================================================================
    // Page Fault Handling (Demand Paging)
    // =========================================================================

    /// Handle a user page fault for demand paging
    /// addr: Faulting virtual address (from CR2)
    /// err_code: x86 page fault error code:
    ///   bit 0 (P): 0 = not-present, 1 = protection violation
    ///   bit 1 (W): 0 = read access, 1 = write access
    ///   bit 2 (U): 0 = supervisor, 1 = user mode
    /// Returns: true if fault was handled (page allocated), false if segfault
    pub fn handlePageFault(self: *UserVmm, addr: u64, err_code: u64) bool {
        // Check for kernel space access (security hard-stop)
        if (addr >= vmm.KERNEL_BASE) {
            console.err("PageFault: SECURITY VIOLATION: User fault in kernel space {x}", .{addr});
            return false;
        }

        // Acquire read lock - we need stable VMA list and permissions
        // This blocks if mprotect is updating permissions
        const held = self.lock.acquireRead();
        defer held.release();

        // 1. Find VMA covering the fault address
        var vma_iter = self.vma_head;
        var target_vma: ?*Vma = null;
        while (vma_iter) |v| {
            if (v.contains(addr)) {
                target_vma = v;
                break;
            }
            vma_iter = v.next;
        }

        const vma = target_vma orelse {
            // Address not in any VMA - genuine segfault
            console.warn("PageFault: addr {x} not in any VMA (SIGSEGV)", .{addr});
            return false;
        };

        // 2. Check if this is a Device mapping (should never fault - already mapped)
        if (vma.vma_type == .Device) {
            console.warn("PageFault: addr {x} in Device VMA (should be pre-mapped)", .{addr});
            return false;
        }

        // 3. Check permissions
        const is_write = (err_code & 2) != 0;
        const is_user = (err_code & 4) != 0;

        // Only handle user-mode faults
        if (!is_user) {
            console.warn("PageFault: kernel-mode fault at {x}", .{addr});
            return false;
        }

        // Write to read-only page is a protection violation
        if (is_write and (vma.prot & PROT_WRITE) == 0) {
            console.warn("PageFault: write to read-only VMA at {x}", .{addr});
            return false;
        }

        // 4. Allocate physical page (zeroed for anonymous mappings)
        const phys = pmm.allocPage() orelse {
            console.err("PageFault: OOM allocating page for {x}", .{addr});
            return false;
        };

        // Zero the page for security (prevent info leaks)
        const ptr: [*]u8 = @ptrCast(hal.paging.physToVirt(phys));
        hal.mem.fill(ptr, 0, pmm.PAGE_SIZE);

        // 5. Map the page with VMA's protection flags
        const page_base = addr & ~@as(u64, pmm.PAGE_SIZE - 1);
        const page_flags = vma.toPageFlags();

        vmm.mapPage(self.pml4_phys, page_base, phys, page_flags) catch {
            console.err("PageFault: failed to map page at {x}", .{page_base});
            pmm.freePage(phys);
            return false;
        };

        console.debug("PageFault: demand-allocated page at {x} -> phys {x}", .{ page_base, phys });
        return true;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// Find a free virtual address range of given size
    /// Public for use by MMIO/DMA syscalls
    pub fn findFreeRange(self: *UserVmm, size: usize) ?u64 {
        // Start from randomized mmap base (ASLR)
        var search_addr: u64 = self.mmap_base;

        // Walk VMAs looking for a gap
        var vma = self.vma_head;
        while (vma) |v| {
            // Check for overflow: search_addr + size must not wrap
            if (search_addr > std.math.maxInt(u64) - size) {
                return null; // Would overflow, no valid range possible
            }
            // Check if there's space before this VMA
            if (search_addr + size <= v.start) {
                return search_addr;
            }
            // Move past this VMA
            search_addr = v.end;
            vma = v.next;
        }

        // Check for overflow before final bounds check
        if (search_addr > std.math.maxInt(u64) - size) {
            return null;
        }

        // Check if there's space after all VMAs
        if (search_addr + size <= USER_MMAP_END) {
            return search_addr;
        }

        return null;
    }

    /// Find VMA that overlaps with given range
    pub fn findOverlappingVma(self: *UserVmm, start: u64, end: u64) ?*Vma {
        var vma = self.vma_head;
        while (vma) |v| {
            if (v.overlaps(start, end)) {
                return v;
            }
            vma = v.next;
        }
        return null;
    }

    /// Create a new VMA struct
    /// Public for use by process fork
    pub fn createVma(self: *UserVmm, start: u64, end: u64, prot: u32, flags: u32) !*Vma {
        return self.createVmaWithType(start, end, prot, flags, .Anonymous);
    }

    /// Create a new VMA struct with explicit type
    pub fn createVmaWithType(self: *UserVmm, start: u64, end: u64, prot: u32, flags: u32, vma_type: VmaType) !*Vma {
        _ = self;
        const alloc = heap.allocator();
        const vma = try alloc.create(Vma);
        vma.* = Vma{
            .start = start,
            .end = end,
            .prot = prot,
            .flags = flags,
            .vma_type = vma_type,
            .next = null,
            .prev = null,
        };
        return vma;
    }

    /// Insert VMA into sorted list
    /// Public for use by process fork
    pub fn insertVma(self: *UserVmm, vma: *Vma) void {
        self.vma_count += 1;

        // Empty list
        if (self.vma_head == null) {
            self.vma_head = vma;
            return;
        }

        // Find insertion point (sorted by start address)
        var prev: ?*Vma = null;
        var curr = self.vma_head;

        while (curr) |c| {
            if (vma.start < c.start) {
                break;
            }
            prev = c;
            curr = c.next;
        }

        // Insert between prev and curr
        vma.prev = prev;
        vma.next = curr;

        if (prev) |p| {
            p.next = vma;
        } else {
            self.vma_head = vma;
        }

        if (curr) |c| {
            c.prev = vma;
        }
    }

    /// Remove VMA from list
    fn removeVma(self: *UserVmm, vma: *Vma) void {
        self.vma_count -= 1;

        if (vma.prev) |p| {
            p.next = vma.next;
        } else {
            self.vma_head = vma.next;
        }

        if (vma.next) |n| {
            n.prev = vma.prev;
        }

        vma.next = null;
        vma.prev = null;
    }

    /// Unmap a range of pages (does not free physical memory)
    fn unmapRange(self: *UserVmm, start: u64, len: usize) void {
        const page_count = len / pmm.PAGE_SIZE;
        var i: usize = 0;
        while (i < page_count) : (i += 1) {
            const addr = start + i * pmm.PAGE_SIZE;
            vmm.unmapPage(self.pml4_phys, addr) catch {};
        }
    }

    /// Free physical pages for a VMA and unmap them
    fn freeVmaPages(self: *UserVmm, vma: *Vma) void {
        const page_count = vma.pageCount();
        var i: usize = 0;
        const should_free_phys = (vma.flags & MAP_DEVICE) == 0;
        while (i < page_count) : (i += 1) {
            const addr = vma.start + i * pmm.PAGE_SIZE;
            // Get physical address before unmapping
            if (vmm.translate(self.pml4_phys, addr)) |phys| {
                vmm.unmapPage(self.pml4_phys, addr) catch {};
                if (should_free_phys) {
                    pmm.freePage(phys);
                }
            }
        }
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Convert PROT_* flags to PageFlags
fn protToPageFlags(prot: u32) PageFlags {
    return .{
        .writable = (prot & PROT_WRITE) != 0,
        .user = true,
        .no_execute = (prot & PROT_EXEC) == 0,
    };
}
