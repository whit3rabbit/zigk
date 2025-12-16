// MMIO and DMA Syscall Handlers
//
// Implements syscalls for userspace driver access to hardware:
// - sys_mmap_phys: Map physical MMIO region into userspace
// - sys_alloc_dma: Allocate DMA-capable memory with known physical address
// - sys_free_dma: Free DMA memory
//
// All syscalls require appropriate capabilities (Mmio, DmaMemory).

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const vmm = @import("vmm");
const pmm = @import("pmm");
const heap = @import("heap");
const user_vmm = @import("user_vmm");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const Process = base.Process;

/// Result structure returned by sys_alloc_dma
/// Must match userspace definition
pub const DmaAllocResult = extern struct {
    /// Virtual address in userspace
    virt_addr: u64,
    /// Physical address for device programming
    phys_addr: u64,
    /// Size in bytes (page-aligned)
    size: u64,
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
    const vma = proc.user_vmm.createVma(
        virt_addr,
        virt_addr + aligned_size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
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
    const page_count: u32 = @intCast(@min(page_count_arg, std.math.maxInt(u32)));

    // Validate arguments
    if (page_count == 0) {
        return error.EINVAL;
    }

    // Validate user pointer
    if (!base.isValidUserPtr(@intCast(result_ptr), @sizeOf(DmaAllocResult))) {
        return error.EFAULT;
    }
    const uptr = UserPtr.from(result_ptr);

    // Get current process
    const proc = base.getCurrentProcess();

    // Check DmaMemory capability
    if (!proc.hasDmaCapability(page_count)) {
        console.warn("sys_alloc_dma: Process {} lacks DmaMemory capability for {} pages", .{
            proc.pid,
            page_count,
        });
        return error.EPERM;
    }

    const size: usize = @as(usize, page_count) * pmm.PAGE_SIZE;

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
    const vma = proc.user_vmm.createVma(
        virt_addr,
        virt_addr + size,
        user_vmm.PROT_READ | user_vmm.PROT_WRITE,
        user_vmm.MAP_SHARED | user_vmm.MAP_ANONYMOUS,
    ) catch {
        // Rollback
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
    _ = uptr.copyFromKernel(std.mem.asBytes(&result)) catch {
        // Rollback VMA and mapping
        proc.user_vmm.total_mapped -= size;
        // Note: VMA already inserted, would need removeVma for full cleanup
        // For now, just fail - the pages will be freed on process exit
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
/// Arguments:
///   arg0: Virtual address returned by sys_alloc_dma
///   arg1: Size in bytes (must match original allocation)
///
/// Returns:
///   0 on success
///   -EINVAL if address/size don't match a DMA allocation
pub fn sys_free_dma(virt_addr_arg: usize, size_arg: usize) SyscallError!usize {
    const virt_addr: u64 = @intCast(virt_addr_arg);
    const size: usize = size_arg;

    if (size == 0) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    // Use munmap to free the region
    // This will unmap pages and free physical memory via VMA cleanup
    const result = proc.user_vmm.munmap(virt_addr, size);
    if (result < 0) {
        return error.EINVAL;
    }

    console.debug("sys_free_dma: Freed virt={x} size={}", .{ virt_addr, size });

    return 0;
}
