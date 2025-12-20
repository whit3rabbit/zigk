// Memory Management Syscall Handlers
//
// Implements virtual memory syscalls:
// - sys_mmap: Map memory pages
// - sys_mprotect: Set memory protection
// - sys_munmap: Unmap memory pages
// - sys_brk: Change data segment size (heap)

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const pmm = @import("pmm");
const vmm = @import("vmm");
const user_mem = @import("user_mem");
const user_vmm = @import("user_vmm");
const console = @import("console");
const SyscallError = base.SyscallError;

// =============================================================================
// Memory Management
// =============================================================================

/// sys_mmap (9) - Map memory pages
///
/// Maps virtual memory into the process address space.
/// Supports:
///   - Anonymous mappings (MAP_ANONYMOUS)
///   - File-backed mappings for special files (io_uring, etc.)
///
/// Args:
///   addr: Hint address (0 for kernel choice), exact address if MAP_FIXED
///   len: Length of mapping
///   prot: Protection flags (PROT_READ, PROT_WRITE, PROT_EXEC)
///   flags: Mapping flags (MAP_SHARED, MAP_PRIVATE, MAP_ANONYMOUS, etc.)
///   fd: File descriptor (ignored if MAP_ANONYMOUS)
///   offset: Offset in file (used for io_uring ring selection)
///
/// Returns: Virtual address on success, error on failure
pub fn sys_mmap(
    addr: usize,
    len: usize,
    prot: usize,
    flags: usize,
    fd: usize,
    offset: usize,
) SyscallError!usize {
    console.debug("sys_mmap: addr={x} len={x} prot={x} flags={x} fd={d} offset={x}", .{ addr, len, prot, flags, fd, offset });

    // Validate length
    if (len == 0) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();
    const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);

    // Check per-process memory limit
    const new_rss = @addWithOverflow(proc.rss_current, aligned_len);
    if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
        return error.ENOMEM;
    }

    // Handle anonymous mapping
    if ((flags & uapi.mman.MAP_ANONYMOUS) != 0) {
        const addr_u64 = std.math.cast(u64, addr) orelse return error.EINVAL;
        const uvmm = base.getGlobalUserVmm();
        const result = uvmm.mmap(addr_u64, len, @truncate(prot), @truncate(flags));

        if (result >= 0) {
            proc.rss_current += aligned_len;
            return @intCast(result);
        }

        const errno_val: i32 = @intCast(-result);
        return switch (errno_val) {
            12 => error.ENOMEM,
            22 => error.EINVAL,
            else => error.ENOMEM,
        };
    }

    // File-backed mapping: get the file's mmap handler
    const fd_table = base.getGlobalFdTable();
    const fd_num: u32 = std.math.cast(u32, fd) orelse return error.EBADF;
    const file = fd_table.get(fd_num) orelse return error.EBADF;

    // Check if file supports mmap
    const mmap_fn = file.ops.mmap orelse return error.ENODEV;

    // Get physical address and actual size from file
    var actual_size: usize = aligned_len;
    const phys_addr = mmap_fn(file, @intCast(offset), &actual_size);
    if (phys_addr == 0) {
        return error.EINVAL;
    }

    // Validate actual_size
    if (actual_size == 0) {
        return error.EINVAL;
    }
    const map_size = std.mem.alignForward(usize, actual_size, pmm.PAGE_SIZE);

    // Find free virtual address range
    const virt_addr = proc.user_vmm.findFreeRange(map_size) orelse {
        console.err("sys_mmap: No free virtual range for {} bytes", .{map_size});
        return error.ENOMEM;
    };

    // Map the physical pages into userspace
    const page_flags = vmm.PageFlags{
        .writable = (prot & uapi.mman.PROT_WRITE) != 0,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .global = false,
        .no_execute = (prot & uapi.mman.PROT_EXEC) == 0,
    };

    vmm.mapRange(proc.cr3, virt_addr, phys_addr, map_size, page_flags) catch |err| {
        console.err("sys_mmap: mapRange failed: {}", .{err});
        return error.ENOMEM;
    };

    // Create VMA with MAP_SHARED | MAP_DEVICE (don't free physical pages on munmap)
    const vma = proc.user_vmm.createVma(
        virt_addr,
        virt_addr + map_size,
        @truncate(prot),
        user_vmm.MAP_SHARED | user_vmm.MAP_DEVICE,
    ) catch {
        // Rollback mapping
        var off: usize = 0;
        while (off < map_size) : (off += pmm.PAGE_SIZE) {
            vmm.unmapPage(proc.cr3, virt_addr + off) catch {};
        }
        return error.ENOMEM;
    };

    proc.user_vmm.insertVma(vma);
    proc.rss_current += map_size;

    console.debug("sys_mmap: Mapped phys {x} -> virt {x} (size {})", .{
        phys_addr,
        virt_addr,
        map_size,
    });

    return @intCast(virt_addr);
}

/// sys_mprotect (10) - Set memory protection
///
/// Changes protection on a region of memory.
///
/// Args:
///   addr: Start address (must be page-aligned)
///   len: Size in bytes
///   prot: New protection flags
///
/// Returns: 0 on success, negative errno on error
pub fn sys_mprotect(addr: usize, len: usize, prot: usize) SyscallError!usize {
    // Validate addr fits target type
    const addr_u64 = std.math.cast(u64, addr) orelse return error.EINVAL;

    const uvmm = base.getGlobalUserVmm();
    const result = uvmm.mprotect(addr_u64, len, @truncate(prot));
    if (result < 0) {
        const errno_val: i32 = @intCast(-result);
        return switch (errno_val) {
            12 => error.ENOMEM,
            22 => error.EINVAL,
            13 => error.EACCES,
            else => error.EINVAL,
        };
    }
    return 0;
}

/// sys_munmap (11) - Unmap memory pages
///
/// Unmaps a region of memory from the process address space.
///
/// Args:
///   addr: Start address (must be page-aligned)
///   len: Size in bytes
///
/// Returns: 0 on success, negative errno on error
pub fn sys_munmap(addr: usize, len: usize) SyscallError!usize {
    // Validate addr fits target type
    const addr_u64 = std.math.cast(u64, addr) orelse return error.EINVAL;

    const uvmm = base.getGlobalUserVmm();
    const result = uvmm.munmap(addr_u64, len);

    // Update RSS on successful unmap (mirrors sys_mmap increment)
    if (result == 0) {
        const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);
        const proc = base.getCurrentProcess();
        if (proc.rss_current >= aligned_len) {
            proc.rss_current -= aligned_len;
        } else {
            // Underflow protection - reset to 0 if accounting got out of sync
            proc.rss_current = 0;
        }
        return 0;
    }

    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        22 => error.EINVAL,
        else => error.EINVAL,
    };
}

/// sys_brk (12) - Change data segment size
///
/// Changes the location of the program break, which defines the end of the process's data segment.
///
/// Args:
///   brk: New program break (0 to return current break)
///
/// Returns: New program break
pub fn sys_brk(brk: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    console.debug("sys_brk: current={x} new={x}", .{ proc.heap_break, brk });

    if (brk == 0) {
        return proc.heap_break;
    }

    // Validate new break
    // Must be >= start_brk and within sane limits
    if (brk < proc.heap_start) {
        return error.EINVAL;
    }

    // Check upper bound - must not exceed user space
    if (brk > user_mem.USER_SPACE_END) {
        return @intCast(proc.heap_break);
    }

    // Enforce per-process memory limit (DoS protection)
    if (brk > proc.heap_break) {
        const growth = brk - proc.heap_break;
        const new_rss = @addWithOverflow(proc.rss_current, growth);
        if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
            return error.ENOMEM;
        }
    }

    // Align to page size for mapping
    const current_break_aligned = std.mem.alignForward(usize, proc.heap_break, pmm.PAGE_SIZE);
    const new_break_aligned = std.mem.alignForward(usize, brk, pmm.PAGE_SIZE);

    // Aligned value must also be within bounds (alignment could push it over)
    if (new_break_aligned > user_mem.USER_SPACE_END) {
        return @intCast(proc.heap_break);
    }

    if (new_break_aligned > current_break_aligned) {
        // Growing heap
        // Check for overlap with existing VMAs
        if (proc.user_vmm.findOverlappingVma(current_break_aligned, new_break_aligned)) |_| {
            return error.ENOMEM;
        }

        // The expandHeap method in UserVmm handles mapping pages and updating VMA list.
        const res = proc.user_vmm.expandHeap(current_break_aligned, new_break_aligned);
        if (res < 0) {
            const errno_val: i32 = @intCast(-res);
            return switch (errno_val) {
                12 => error.ENOMEM,
                else => error.ENOMEM,
            };
        }

        // Update RSS manually since expandHeap relies on caller for accounting
        const size = new_break_aligned - current_break_aligned;
        proc.rss_current += size;
    } else if (new_break_aligned < current_break_aligned) {
        // Shrinking heap
        // The shrinkHeap method in UserVmm handles unmapping pages and updating VMA list.
        proc.user_vmm.shrinkHeap(current_break_aligned, new_break_aligned);

        // Update RSS manually
        const size = current_break_aligned - new_break_aligned;
        if (proc.rss_current >= size) {
            proc.rss_current -= size;
        } else {
            proc.rss_current = 0;
        }
    }

    // Update break
    // SECURITY: Always maintain page alignment for the internal heap break.
    // This prevents inconsistencies between the mapped memory region and
    // the program break value, ensuring subsequent allocations behave predictably.
    proc.heap_break = new_break_aligned;
    return @intCast(new_break_aligned);
}
