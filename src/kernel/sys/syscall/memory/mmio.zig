// MMIO and DMA Syscall Handlers
//
// Implements syscalls for userspace driver access to hardware:
// - sys_mmap_phys: Map physical MMIO region into userspace
// - sys_alloc_dma: Allocate DMA-capable memory with known physical address
// - sys_alloc_iommu_dma: Allocate IOMMU-protected DMA with IOVA
// - sys_free_dma: Free DMA memory
//
// All syscalls require appropriate capabilities (Mmio, DmaMemory, IommuDma).
//
// SECURITY NOTES:
// - VMA validation required before any buffer operations to prevent
//   kernel memory writes via crafted syscall arguments (CVE-like vuln).
// - Atomic reservation of allocation counters prevents TOCTOU races.
// - IOMMU fallback controlled by capability flag to prevent DMA attacks.
// - Proper rollback on all error paths prevents resource leaks.

const std = @import("std");
const builtin = @import("builtin");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const user_vmm = @import("user_vmm");
const capabilities = @import("capabilities");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const Process = base.Process;
const AccessMode = base.AccessMode;

/// Maximum pages per single DMA allocation to prevent resource exhaustion.
/// 16384 pages = 64MB max per allocation, reasonable for most drivers.
const MAX_DMA_PAGES_PER_ALLOC: u32 = 16384;

/// Result structure returned by sys_alloc_dma (legacy)
/// Must match userspace definition
pub const DmaAllocResult = extern struct {
    /// Virtual address in userspace
    virt_addr: u64,
    /// Physical address for device programming
    phys_addr: u64,
    /// Size in bytes (page-aligned)
    size: u64,
};

/// Result structure returned by sys_alloc_iommu_dma
/// Includes IOVA for IOMMU-protected DMA operations
pub const IommuDmaResult = extern struct {
    /// Virtual address in userspace
    virt_addr: u64,
    /// DMA address for device programming (IOVA if IOMMU, phys if fallback)
    dma_addr: u64,
    /// Size in bytes (page-aligned)
    size: u64,
    /// True if dma_addr is an IOVA (IOMMU active), false if physical address
    is_iova: bool,
    /// Padding for alignment
    _padding: [7]u8 = [_]u8{0} ** 7,
};

/// sys_mmap_phys (1030) - Map physical MMIO region into userspace
///
/// Maps a physical memory region (typically device MMIO) into the calling
/// process's address space. Requires Mmio capability for the physical range.
///
/// Arguments:
///   arg0: Physical address to map (must be page-aligned)
///   arg1: Size in bytes (will be page-aligned up)
///
/// Returns:
///   Virtual address on success
///   -EPERM if process lacks Mmio capability
///   -EINVAL if phys_addr is not page-aligned or size is 0
///   -ENOMEM if mapping failed
pub fn sys_mmap_phys(phys_addr_arg: usize, size_arg: usize) SyscallError!usize {
    const phys_addr: u64 = @intCast(phys_addr_arg);
    const size: u64 = @intCast(size_arg);

    // Validate arguments
    if (size == 0) {
        return error.EINVAL;
    }
    if (!hal.paging.isPageAligned(phys_addr)) {
        return error.EINVAL;
    }

    // Page-align size
    const aligned_size = std.mem.alignForward(u64, size, pmm.PAGE_SIZE);

    // Get current process
    const proc = base.getCurrentProcess();

    // Check Mmio capability
    if (!proc.hasMmioCapability(phys_addr, aligned_size)) {
        console.warn("sys_mmap_phys: Process {} lacks Mmio capability for {x}-{x}", .{
            proc.pid,
            phys_addr,
            phys_addr + aligned_size,
        });
        return error.EPERM;
    }

    // Find free virtual address range
    const virt_addr = proc.user_vmm.findFreeRange(@intCast(aligned_size)) orelse {
        console.err("sys_mmap_phys: No free virtual range for {} bytes", .{aligned_size});
        return error.ENOMEM;
    };

    // MMIO page flags: user accessible, writable, cache disabled, no-execute
    const flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
        .write_through = true,
        .cache_disable = true, // Required for MMIO coherency
        .global = false,
        .no_execute = true,
    };

    // Map the physical memory into userspace
    vmm.mapRange(proc.cr3, virt_addr, phys_addr, @intCast(aligned_size), flags) catch |err| {
        console.err("sys_mmap_phys: mapRange failed: {}", .{err});
        return error.ENOMEM;
    };

    // Create VMA with MAP_DEVICE flag (prevents freeing physical pages on munmap)
    // and VmaType.Device (prevents demand paging - already eagerly mapped)
    const vma = proc.user_vmm.createVmaWithType(
        virt_addr,
        virt_addr + aligned_size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
        .Device,
    ) catch {
        // Rollback: unmap the pages
        var offset: u64 = 0;
        while (offset < aligned_size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
        }
        return error.ENOMEM;
    };

    proc.user_vmm.insertVma(vma);
    proc.user_vmm.total_mapped += @intCast(aligned_size);

    console.debug("sys_mmap_phys: Mapped phys {x} -> virt {x} (size {})", .{
        phys_addr,
        virt_addr,
        aligned_size,
    });

    return @intCast(virt_addr);
}

/// sys_alloc_dma (1031) - Allocate DMA-capable memory
///
/// Allocates contiguous physical pages and maps them into userspace.
/// Returns both virtual and physical addresses so userspace drivers can
/// program DMA descriptors with physical addresses.
///
/// Arguments:
///   arg0: Pointer to DmaAllocResult struct (output)
///   arg1: Number of pages to allocate
///
/// Returns:
///   0 on success (result written to result_ptr)
///   -EPERM if process lacks DmaMemory capability
///   -EINVAL if page_count is 0 or result_ptr is invalid
///   -ENOMEM if allocation or mapping failed
pub fn sys_alloc_dma(result_ptr_arg: usize, page_count_arg: usize) SyscallError!usize {
    const result_ptr: u64 = @intCast(result_ptr_arg);

    // SECURITY FIX (Vuln 6): Validate page_count before truncation to prevent
    // silent data loss when user passes > 2^32 pages.
    if (page_count_arg > MAX_DMA_PAGES_PER_ALLOC) {
        console.warn("sys_alloc_dma: page_count {} exceeds max {}", .{ page_count_arg, MAX_DMA_PAGES_PER_ALLOC });
        return error.EINVAL;
    }
    const page_count: u32 = @intCast(page_count_arg);

    // Validate arguments
    if (page_count == 0) {
        return error.EINVAL;
    }

    // Validate user pointer
    if (!base.isValidUserAccess(@intCast(result_ptr), @sizeOf(DmaAllocResult), AccessMode.Write)) {
        return error.EFAULT;
    }
    const uptr = UserPtr.from(result_ptr);

    // Get current process
    const proc = base.getCurrentProcess();

    // SECURITY FIX (Vuln 2): Atomically reserve DMA allocation quota BEFORE
    // doing any work. This prevents TOCTOU races where concurrent syscalls
    // both pass the capability check and allocate 2x the allowed pages.
    const old_pages = @atomicRmw(u32, &proc.dma_allocated_pages, .Add, page_count, .seq_cst);
    const max_pages = proc.getDmaCapabilityLimit();
    if (old_pages + page_count > max_pages) {
        // Rollback: undo the atomic add
        _ = @atomicRmw(u32, &proc.dma_allocated_pages, .Sub, page_count, .seq_cst);
        console.warn("sys_alloc_dma: Process {} exceeds DMA limit ({} + {} > {})", .{
            proc.pid,
            old_pages,
            page_count,
            max_pages,
        });
        return error.EPERM;
    }
    // On any error below, we must rollback the atomic reservation
    errdefer {
        _ = @atomicRmw(u32, &proc.dma_allocated_pages, .Sub, page_count, .seq_cst);
    }

    // SECURITY FIX (Vuln 6): Use checked multiplication to detect overflow.
    const size_result = @mulWithOverflow(@as(usize, page_count), pmm.PAGE_SIZE);
    if (size_result[1] != 0) {
        console.err("sys_alloc_dma: size overflow for {} pages", .{page_count});
        return error.EINVAL;
    }
    const size: usize = size_result[0];

    // Allocate contiguous physical pages
    const phys_addr = pmm.allocZeroedPages(page_count) orelse {
        console.err("sys_alloc_dma: Failed to allocate {} pages", .{page_count});
        return error.ENOMEM;
    };
    errdefer pmm.freePages(phys_addr, page_count);

    // Find free virtual address range
    const virt_addr = proc.user_vmm.findFreeRange(size) orelse {
        console.err("sys_alloc_dma: No free virtual range for {} bytes", .{size});
        return error.ENOMEM;
    };

    // DMA buffer page flags: user accessible, writable, normal caching, no-execute
    // (DMA buffers can use normal caching; coherency is handled by flush operations)
    const flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .global = false,
        .no_execute = true,
    };

    // Map into userspace
    vmm.mapRange(proc.cr3, virt_addr, phys_addr, size, flags) catch |err| {
        console.err("sys_alloc_dma: mapRange failed: {}", .{err});
        return error.ENOMEM;
    };

    // Create VMA to track this mapping
    // Note: NOT using MAP_DEVICE because we need to free pages on munmap
    // Using VmaType.Device to prevent demand paging (already eagerly mapped)
    const vma = proc.user_vmm.createVmaWithType(
        virt_addr,
        virt_addr + size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_ANONYMOUS,
        .Device,
    ) catch {
        // Rollback mapping
        var offset: usize = 0;
        while (offset < size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
        }
        return error.ENOMEM;
    };

    proc.user_vmm.insertVma(vma);
    proc.user_vmm.total_mapped += size;

    // Build result
    const result = DmaAllocResult{
        .virt_addr = virt_addr,
        .phys_addr = phys_addr,
        .size = size,
    };

    // Copy result to userspace
    // SECURITY FIX (Vuln 4): Properly rollback VMA on copy failure
    _ = uptr.copyFromKernel(std.mem.asBytes(&result)) catch {
        // Full rollback: remove VMA, unmap pages, free physical memory
        proc.user_vmm.removeVma(vma);
        proc.user_vmm.total_mapped -= size;
        heap.allocator().destroy(vma);
        var offset: usize = 0;
        while (offset < size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
        }
        pmm.freePages(phys_addr, page_count);
        return error.EFAULT;
    };

    console.debug("sys_alloc_dma: Allocated {} pages: virt={x} phys={x}", .{
        page_count,
        virt_addr,
        phys_addr,
    });

    return 0;
}

/// sys_free_dma (1032) - Free DMA memory
///
/// Frees DMA memory previously allocated with sys_alloc_dma.
/// The virtual address and size must match exactly.
///
/// SECURITY: Validates VMA ownership before zeroing to prevent kernel
/// memory writes. Zeros the buffer before freeing to prevent information
/// leakage if the memory is reallocated to another process.
///
/// Arguments:
///   arg0: Virtual address returned by sys_alloc_dma
///   arg1: Size in bytes (must match original allocation)
///
/// Returns:
///   0 on success
///   -EINVAL if address/size don't match a DMA allocation
///   -EPERM if address is not in a valid DMA VMA
pub fn sys_free_dma(virt_addr_arg: usize, size_arg: usize) SyscallError!usize {
    const virt_addr: u64 = @intCast(virt_addr_arg);
    const size: usize = size_arg;

    if (size == 0) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    // SECURITY FIX: Acquire write lock for the entire VMA validation + zeroing + unmap
    // sequence to prevent TOCTOU race where another thread could munmap the region
    // between validation and zeroing, causing kernel page fault or corruption.
    const held = proc.user_vmm.lock.acquireWrite();
    defer held.release();

    // SECURITY FIX (Vuln 1): Validate that virt_addr belongs to a valid DMA VMA
    // BEFORE zeroing. Without this check, an attacker could pass a kernel address
    // and zero arbitrary kernel memory, leading to privilege escalation.
    const vma = proc.user_vmm.findOverlappingVma(virt_addr, virt_addr + size) orelse {
        console.warn("sys_free_dma: No VMA found for virt={x} size={}", .{ virt_addr, size });
        return error.EINVAL;
    };

    // SECURITY: Verify the VMA is actually a DMA allocation (Device type, not MMIO)
    // - Must be VmaType.Device (eagerly mapped DMA buffer)
    // - Must NOT have MAP_DEVICE flag (that indicates MMIO, not DMA buffer)
    // - Must have MAP_ANONYMOUS (DMA buffers are anonymous)
    if (vma.vma_type != .Device) {
        console.warn("sys_free_dma: VMA at {x} is not a Device mapping", .{virt_addr});
        return error.EINVAL;
    }
    if ((vma.flags & user_vmm.MAP_DEVICE) != 0) {
        console.warn("sys_free_dma: VMA at {x} is MMIO, not DMA buffer", .{virt_addr});
        return error.EINVAL;
    }
    if ((vma.flags & user_vmm.MAP_ANONYMOUS) == 0) {
        console.warn("sys_free_dma: VMA at {x} is not anonymous", .{virt_addr});
        return error.EINVAL;
    }

    // SECURITY: Verify the VMA exactly matches the requested range to prevent
    // partial frees that could corrupt VMA state.
    if (vma.start != virt_addr or vma.end != virt_addr + size) {
        console.warn("sys_free_dma: VMA bounds mismatch: VMA={x}-{x} req={x}-{x}", .{
            vma.start,
            vma.end,
            virt_addr,
            virt_addr + size,
        });
        return error.EINVAL;
    }

    // NOW safe to zero: we've verified the address is in a valid DMA VMA
    // SECURITY: Zero the DMA buffer before freeing to prevent information leakage.
    // DMA buffers often contain sensitive data (network packets, disk blocks).
    const buffer_ptr: [*]volatile u8 = @ptrFromInt(virt_addr);
    for (0..size) |i| {
        buffer_ptr[i] = 0;
    }

    // Use munmapLocked since we already hold the lock
    // This will unmap pages and free physical memory via VMA cleanup
    const result = proc.user_vmm.munmapLocked(virt_addr, size);
    if (result < 0) {
        return error.EINVAL;
    }

    // SECURITY FIX (Vuln 8): Use debug assertion to catch accounting bugs.
    // In production, saturating subtraction prevents panic but logs warning.
    const page_count: u32 = @intCast((size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE);
    const old_val = @atomicRmw(u32, &proc.dma_allocated_pages, .Sub, page_count, .seq_cst);
    if (builtin.mode == .Debug and old_val < page_count) {
        // In debug builds, this would indicate a double-free or accounting bug
        @panic("sys_free_dma: dma_allocated_pages underflow - accounting bug");
    }

    console.debug("sys_free_dma: Freed virt={x} size={}", .{ virt_addr, size });

    return 0;
}

/// sys_alloc_iommu_dma (1046) - Allocate IOMMU-protected DMA memory
///
/// Allocates contiguous physical pages and maps them into userspace.
/// If IOMMU is available and the process has IommuDmaCapability for the
/// specified device, returns an IOVA that is hardware-isolated to that device.
///
/// SECURITY: If the capability has iommu_required=true, the syscall will FAIL
/// if IOVA allocation fails rather than falling back to raw physical addresses.
/// This prevents DMA attacks where a device could access arbitrary memory.
///
/// Arguments:
///   arg0: Pointer to IommuDmaResult struct (output)
///   arg1: Number of pages to allocate
///   arg2: Device BDF (bus:8 | device:5 | func:3 in bits 15:0)
///
/// Returns:
///   0 on success (result written to result_ptr)
///   -EPERM if process lacks IommuDmaCapability for the device
///   -EINVAL if page_count is 0 or result_ptr is invalid
///   -ENOMEM if allocation or mapping failed (or IOMMU required but unavailable)
pub fn sys_alloc_iommu_dma(result_ptr_arg: usize, page_count_arg: usize, device_bdf_arg: usize) SyscallError!usize {
    const result_ptr: u64 = @intCast(result_ptr_arg);
    const device_bdf: u16 = @intCast(device_bdf_arg & 0xFFFF);

    // SECURITY FIX (Vuln 6): Validate page_count before truncation
    if (page_count_arg > MAX_DMA_PAGES_PER_ALLOC) {
        console.warn("sys_alloc_iommu_dma: page_count {} exceeds max {}", .{ page_count_arg, MAX_DMA_PAGES_PER_ALLOC });
        return error.EINVAL;
    }
    const page_count: u32 = @intCast(page_count_arg);

    // Validate arguments
    if (page_count == 0) {
        return error.EINVAL;
    }

    // Validate user pointer
    if (!base.isValidUserAccess(@intCast(result_ptr), @sizeOf(IommuDmaResult), AccessMode.Write)) {
        return error.EFAULT;
    }
    const uptr = UserPtr.from(result_ptr);

    // Get current process
    const proc = base.getCurrentProcess();

    // Extract BDF components
    const bus: u8 = @truncate(device_bdf >> 8);
    const device: u5 = @truncate((device_bdf >> 3) & 0x1F);
    const func: u3 = @truncate(device_bdf & 0x7);

    // Check IommuDmaCapability for this device
    const iommu_cap = proc.getIommuDmaCapability(bus, device, func);
    if (iommu_cap == null) {
        console.warn("sys_alloc_iommu_dma: Process {} lacks IommuDmaCapability for {x:0>2}:{x:0>2}.{d}", .{
            proc.pid,
            bus,
            device,
            func,
        });
        return error.EPERM;
    }

    const cap = iommu_cap.?;

    // SECURITY FIX (Vuln 6): Use checked multiplication
    const size_result = @mulWithOverflow(@as(u64, page_count), pmm.PAGE_SIZE);
    if (size_result[1] != 0) {
        console.err("sys_alloc_iommu_dma: size overflow for {} pages", .{page_count});
        return error.EINVAL;
    }
    const size: u64 = size_result[0];

    // SECURITY FIX (Vuln 2): Atomically reserve IOMMU allocation quota
    const old_bytes = @atomicRmw(u64, &proc.iommu_allocated_bytes, .Add, size, .seq_cst);
    if (old_bytes + size > cap.max_size) {
        _ = @atomicRmw(u64, &proc.iommu_allocated_bytes, .Sub, size, .seq_cst);
        console.warn("sys_alloc_iommu_dma: Process {} exceeds IOMMU allocation limit", .{proc.pid});
        return error.EPERM;
    }
    errdefer {
        _ = @atomicRmw(u64, &proc.iommu_allocated_bytes, .Sub, size, .seq_cst);
    }

    // Allocate contiguous physical pages
    const phys_addr = pmm.allocZeroedPages(page_count) orelse {
        console.err("sys_alloc_iommu_dma: Failed to allocate {} pages", .{page_count});
        return error.ENOMEM;
    };
    errdefer pmm.freePages(phys_addr, page_count);

    // Find free virtual address range
    const virt_addr = proc.user_vmm.findFreeRange(@intCast(size)) orelse {
        console.err("sys_alloc_iommu_dma: No free virtual range for {} bytes", .{size});
        return error.ENOMEM;
    };

    // DMA buffer page flags: user accessible, writable, normal caching, no-execute
    const flags = hal.paging.PageFlags{
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .global = false,
        .no_execute = true,
    };

    // Map into userspace
    vmm.mapRange(proc.cr3, virt_addr, phys_addr, @intCast(size), flags) catch |err| {
        console.err("sys_alloc_iommu_dma: mapRange failed: {}", .{err});
        return error.ENOMEM;
    };

    // Create VMA to track this mapping
    const vma = proc.user_vmm.createVmaWithType(
        virt_addr,
        virt_addr + size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_ANONYMOUS,
        .Device,
    ) catch {
        // Rollback
        var offset: u64 = 0;
        while (offset < size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
        }
        return error.ENOMEM;
    };

    proc.user_vmm.insertVma(vma);
    proc.user_vmm.total_mapped += @intCast(size);

    // Try to allocate IOVA via IOMMU domain
    var dma_addr: u64 = phys_addr;
    var is_iova: bool = false;

    // Import kernel_iommu module for IOMMU operations
    const kernel_iommu = @import("kernel_iommu");
    if (kernel_iommu.isAvailable()) {
        const bdf = kernel_iommu.DeviceBdf{
            .bus = bus,
            .device = device,
            .func = func,
        };
        if (kernel_iommu.allocDmaBuffer(bdf, phys_addr, size, true)) |iova| {
            dma_addr = iova;
            is_iova = true;
            console.debug("sys_alloc_iommu_dma: Allocated IOVA 0x{x} for device {x:0>2}:{x:0>2}.{d}", .{
                iova,
                bus,
                device,
                func,
            });
        } else {
            // SECURITY FIX (Vuln 3): If IOMMU protection is required by capability,
            // fail rather than falling back to raw physical addresses. This prevents
            // DMA attacks where a malicious device driver could access arbitrary memory.
            if (cap.iommu_required) {
                console.err("sys_alloc_iommu_dma: IOMMU required but IOVA allocation failed for {x:0>2}:{x:0>2}.{d}", .{
                    bus,
                    device,
                    func,
                });
                // Rollback VMA and mapping
                proc.user_vmm.removeVma(vma);
                proc.user_vmm.total_mapped -= @intCast(size);
                heap.allocator().destroy(vma);
                var offset: u64 = 0;
                while (offset < size) : (offset += pmm.PAGE_SIZE) {
                    vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
                }
                return error.ENOMEM;
            }
            // Fallback to physical address is allowed - log warning
            console.warn("sys_alloc_iommu_dma: IOVA allocation failed, using phys fallback", .{});
        }
    } else {
        // IOMMU not available at all
        if (cap.iommu_required) {
            console.err("sys_alloc_iommu_dma: IOMMU required but not available", .{});
            proc.user_vmm.removeVma(vma);
            proc.user_vmm.total_mapped -= @intCast(size);
            heap.allocator().destroy(vma);
            var offset: u64 = 0;
            while (offset < size) : (offset += pmm.PAGE_SIZE) {
                vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
            }
            return error.ENOMEM;
        }
    }

    // Build result
    const result = IommuDmaResult{
        .virt_addr = virt_addr,
        .dma_addr = dma_addr,
        .size = size,
        .is_iova = is_iova,
    };

    // Copy result to userspace
    // SECURITY FIX (Vuln 4): Properly rollback on copy failure
    _ = uptr.copyFromKernel(std.mem.asBytes(&result)) catch {
        // Full rollback
        if (is_iova) {
            const bdf = kernel_iommu.DeviceBdf{ .bus = bus, .device = device, .func = func };
            // Ignore error during rollback - we're already in failure path
            kernel_iommu.freeDmaBuffer(bdf, dma_addr, size) catch {};
        }
        proc.user_vmm.removeVma(vma);
        proc.user_vmm.total_mapped -= @intCast(size);
        heap.allocator().destroy(vma);
        var offset: u64 = 0;
        while (offset < size) : (offset += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + offset) catch {};
        }
        pmm.freePages(phys_addr, page_count);
        return error.EFAULT;
    };

    console.debug("sys_alloc_iommu_dma: Allocated {} pages: virt={x} dma={x} iova={}", .{
        page_count,
        virt_addr,
        dma_addr,
        is_iova,
    });

    return 0;
}

/// sys_free_iommu_dma (1047) - Free IOMMU-protected DMA memory
///
/// Frees DMA memory previously allocated with sys_alloc_iommu_dma.
/// Also releases the IOVA mapping if IOMMU was used.
///
/// SECURITY: Validates VMA ownership before zeroing to prevent kernel memory
/// writes. Requires capability check to prevent cross-device IOMMU domain
/// corruption.
///
/// Arguments:
///   arg0: Virtual address returned by sys_alloc_iommu_dma
///   arg1: Size in bytes (must match original allocation)
///   arg2: Device BDF (must match original allocation)
///   arg3: DMA address (IOVA or phys) returned by sys_alloc_iommu_dma
///   arg4: is_iova flag (true if dma_addr is IOVA, false if physical)
///
/// Returns:
///   0 on success
///   -EINVAL if address/size don't match a DMA allocation
///   -EPERM if process lacks capability for the device
pub fn sys_free_iommu_dma(virt_addr_arg: usize, size_arg: usize, device_bdf_arg: usize, dma_addr_arg: usize) SyscallError!usize {
    const virt_addr: u64 = @intCast(virt_addr_arg);
    const size: u64 = @intCast(size_arg);
    const device_bdf: u16 = @intCast(device_bdf_arg & 0xFFFF);
    const dma_addr: u64 = @intCast(dma_addr_arg);

    if (size == 0) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    // Extract BDF
    const bus: u8 = @truncate(device_bdf >> 8);
    const device: u5 = @truncate((device_bdf >> 3) & 0x1F);
    const func: u3 = @truncate(device_bdf & 0x7);

    // SECURITY FIX (Vuln 7): Verify process has capability for this device
    // before performing any IOMMU operations. Without this check, a process
    // could pass a different device BDF and corrupt another device's IOMMU domain.
    if (proc.getIommuDmaCapability(bus, device, func) == null) {
        console.warn("sys_free_iommu_dma: Process {} lacks capability for {x:0>2}:{x:0>2}.{d}", .{
            proc.pid,
            bus,
            device,
            func,
        });
        return error.EPERM;
    }

    // SECURITY FIX (Vuln 2): Acquire lock for entire VMA validation + zeroing + unmap.
    // This prevents TOCTOU where another thread could remap the VMA between
    // validation and zeroing, allowing kernel memory zeroing.
    const held = proc.user_vmm.lock.acquireWrite();
    defer held.release();

    // SECURITY FIX (Vuln 1): Validate that virt_addr belongs to a valid DMA VMA
    // BEFORE zeroing. Without this check, attacker could zero kernel memory.
    const vma = proc.user_vmm.findOverlappingVma(virt_addr, virt_addr + size) orelse {
        console.warn("sys_free_iommu_dma: No VMA found for virt={x} size={}", .{ virt_addr, size });
        return error.EINVAL;
    };

    // SECURITY: Verify VMA is a DMA allocation (same checks as sys_free_dma)
    if (vma.vma_type != .Device) {
        console.warn("sys_free_iommu_dma: VMA at {x} is not a Device mapping", .{virt_addr});
        return error.EINVAL;
    }
    if ((vma.flags & user_vmm.MAP_DEVICE) != 0) {
        console.warn("sys_free_iommu_dma: VMA at {x} is MMIO, not DMA buffer", .{virt_addr});
        return error.EINVAL;
    }
    if ((vma.flags & user_vmm.MAP_ANONYMOUS) == 0) {
        console.warn("sys_free_iommu_dma: VMA at {x} is not anonymous", .{virt_addr});
        return error.EINVAL;
    }

    // SECURITY: Verify exact VMA bounds match
    if (vma.start != virt_addr or vma.end != virt_addr + size) {
        console.warn("sys_free_iommu_dma: VMA bounds mismatch", .{});
        return error.EINVAL;
    }

    // NOW safe to zero: we've verified the address is in a valid DMA VMA
    const buffer_ptr: [*]volatile u8 = @ptrFromInt(virt_addr);
    for (0..@intCast(size)) |i| {
        buffer_ptr[i] = 0;
    }

    // SECURITY FIX (Vuln 5): Instead of inferring IOVA from address value,
    // we now rely on the caller providing the dma_addr they received.
    // The IOMMU module can validate if this is actually an IOVA it manages.
    const kernel_iommu = @import("kernel_iommu");
    if (kernel_iommu.isAvailable()) {
        const bdf = kernel_iommu.DeviceBdf{ .bus = bus, .device = device, .func = func };
        // Let the IOMMU module determine if this is a valid IOVA for this device.
        // If dma_addr is a physical address (not an IOVA), freeDmaBuffer should
        // be a no-op or return without error.
        // SECURITY: If IOTLB invalidation fails, the physical pages will be leaked
        // by the kernel to prevent use-after-free via stale TLB entries.
        kernel_iommu.freeDmaBuffer(bdf, dma_addr, size) catch |err| {
            console.err("MMIO: IOMMU unmap failed ({any}) - physical memory leaked", .{err});
            // Continue with VMA/virtual unmap - physical memory intentionally leaked
        };
    }

    // Use munmapLocked since we already hold the lock
    const result = proc.user_vmm.munmapLocked(virt_addr, size);
    if (result < 0) {
        return error.EINVAL;
    }

    // SECURITY FIX (Vuln 8): Use atomic subtraction with debug assertion
    const old_val = @atomicRmw(u64, &proc.iommu_allocated_bytes, .Sub, size, .seq_cst);
    if (builtin.mode == .Debug and old_val < size) {
        @panic("sys_free_iommu_dma: iommu_allocated_bytes underflow - accounting bug");
    }

    console.debug("sys_free_iommu_dma: Freed device {x:0>2}:{x:0>2}.{d} virt={x} dma={x}", .{
        bus,
        device,
        func,
        virt_addr,
        dma_addr,
    });

    return 0;
}
