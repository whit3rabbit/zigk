//! System information syscall (sys_sysinfo)
//!
//! Provides system statistics including:
//! - Uptime since boot
//! - Load averages (1, 5, 15 minute)
//! - Memory statistics (total, free)
//! - Process count

const uapi = @import("uapi");
const sched = @import("sched");
const pmm = @import("pmm");
const process = @import("process");
const base = @import("base.zig");
const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

/// Get system information
///
/// Fills a SysInfo structure with system statistics.
///
/// Arguments:
///   info_ptr: Pointer to userspace SysInfo structure
///
/// Returns:
///   0 on success
///   -EFAULT if info_ptr is invalid
pub fn sys_sysinfo(info_ptr: usize) SyscallError!usize {
    if (info_ptr == 0) {
        return error.EFAULT;
    }

    var info: uapi.time.SysInfo = undefined;

    // Uptime: tick_count / 100 (100 Hz = 10ms ticks)
    const ticks = sched.getTickCount();
    info.uptime = @intCast(@divTrunc(ticks, 100));

    // Load averages (fixed-point * 65536)
    info.loads = sched.getLoadAverages();

    // Memory statistics from PMM
    const total_pages = pmm.getTotalPages();
    const free_pages = pmm.getFreePages();
    info.totalram = total_pages * pmm.PAGE_SIZE;
    info.freeram = free_pages * pmm.PAGE_SIZE;

    // No swap, shared memory, or buffers currently
    info.sharedram = 0;
    info.bufferram = 0;
    info.totalswap = 0;
    info.freeswap = 0;

    // Process count (truncate to u16 for Linux ABI compatibility)
    const proc_count = process.getProcessCount();
    info.procs = if (proc_count > 0xFFFF) 0xFFFF else @as(u16, @intCast(proc_count));

    // High memory (64-bit systems don't distinguish)
    info.totalhigh = 0;
    info.freehigh = 0;

    // Memory unit size (1 byte)
    info.mem_unit = 1;

    // Reserved padding
    @memset(&info._reserved, 0);

    // Copy to userspace
    UserPtr.from(info_ptr).writeValue(info) catch {
        return error.EFAULT;
    };

    return 0;
}
