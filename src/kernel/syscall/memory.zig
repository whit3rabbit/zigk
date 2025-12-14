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
const user_mem = @import("user_mem");
const user_vmm = @import("user_vmm");

const SyscallError = base.SyscallError;

// =============================================================================
// Memory Management
// =============================================================================

/// sys_mmap (9) - Map memory pages
///
/// Maps virtual memory into the process address space.
/// Currently supports anonymous mappings only.
///
/// Args:
///   addr: Hint address (0 for kernel choice), exact address if MAP_FIXED
///   len: Size in bytes
///   prot: Protection flags (PROT_READ, PROT_WRITE, PROT_EXEC)
///   flags: Map flags (MAP_ANONYMOUS, MAP_PRIVATE, MAP_FIXED)
///   fd: File descriptor (ignored for MAP_ANONYMOUS)
///   offset: File offset (ignored for MAP_ANONYMOUS)
///
/// Returns: Mapped address on success, negative errno on error
pub fn sys_mmap(addr: usize, len: usize, prot: usize, flags: usize, fd: usize, offset: usize) SyscallError!usize {
    _ = fd; // File mappings not supported
    _ = offset;

    // Enforce per-process memory limit (DoS protection)
    const proc = base.getCurrentProcess();
    const aligned_len = std.mem.alignForward(usize, len, pmm.PAGE_SIZE);

    const new_rss = @addWithOverflow(proc.rss_current, aligned_len);
    if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
        return error.ENOMEM;
    }

    const uvmm = base.getGlobalUserVmm();
    const result = uvmm.mmap(@intCast(addr), len, @truncate(prot), @truncate(flags));

    // Update RSS on successful mapping
    if (result >= 0) {
        proc.rss_current += aligned_len;
        return @intCast(result);
    }

    // Convert negative errno
    const errno_val: i32 = @intCast(-result);
    return switch (errno_val) {
        12 => error.ENOMEM,
        22 => error.EINVAL,
        else => error.ENOMEM,
    };
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
    const uvmm = base.getGlobalUserVmm();
    const result = uvmm.mprotect(@intCast(addr), len, @truncate(prot));
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
    const uvmm = base.getGlobalUserVmm();
    const result = uvmm.munmap(@intCast(addr), len);

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
pub fn sys_brk(addr: u64) SyscallError!usize {
    const proc = base.getCurrentProcess();

    // If addr is 0, return current break
    if (addr == 0) {
        return @intCast(proc.heap_break);
    }

    // Checking inputs
    // We only support growing the heap for now, or keeping it same.
    // Shrinking is valid but complicates things (need to unmap).
    // Also need to check if new break is valid (e.g. not overlapping stack or kernel)

    // Check if less than start (invalid)
    if (addr < proc.heap_start) {
        return @intCast(proc.heap_break);
    }

    // Check upper bound - must not exceed user space
    if (addr > user_mem.USER_SPACE_END) {
        return @intCast(proc.heap_break);
    }

    // Enforce per-process memory limit (DoS protection)
    if (addr > proc.heap_break) {
        const growth = addr - proc.heap_break;
        const new_rss = @addWithOverflow(proc.rss_current, growth);
        if (new_rss[1] != 0 or new_rss[0] > proc.rlimit_as) {
            return error.ENOMEM;
        }
    }

    // Align to page size for mapping
    const current_break_aligned = std.mem.alignForward(usize, proc.heap_break, pmm.PAGE_SIZE);
    const new_break_aligned = std.mem.alignForward(usize, addr, pmm.PAGE_SIZE);

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
    proc.heap_break = addr;
    return @intCast(addr);
}
