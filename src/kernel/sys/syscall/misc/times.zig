//! Process times syscall (sys_times)
//!
//! Returns CPU time consumed by the current process and its children.
//! Times are measured in clock ticks (1000 Hz = 1ms per tick).

const uapi = @import("uapi");
const sched = @import("sched");
const base = @import("base.zig");
const process = @import("process");
const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;

/// Get process times
///
/// Fills a Tms structure with process CPU times.
/// Times include:
/// - tms_utime: User CPU time of this process
/// - tms_stime: System CPU time of this process
/// - tms_cutime: User CPU time of reaped children
/// - tms_cstime: System CPU time of reaped children
///
/// Arguments:
///   buf_ptr: Pointer to userspace Tms structure
///
/// Returns:
///   Current tick count on success
///   -EFAULT if buf_ptr is invalid
pub fn sys_times(buf_ptr: usize) SyscallError!usize {
    if (buf_ptr == 0) {
        return error.EFAULT;
    }

    const proc = base.getCurrentProcess();

    var tms: uapi.time.Tms = undefined;

    // Get current thread's CPU times
    // In zk, each process has one main thread (fork creates new processes)
    if (sched.getCurrentThread()) |thread| {
        tms.tms_utime = @intCast(thread.utime);
        tms.tms_stime = @intCast(thread.stime);
    } else {
        tms.tms_utime = 0;
        tms.tms_stime = 0;
    }

    // Children times (accumulated from wait4)
    tms.tms_cutime = @intCast(proc.cutime);
    tms.tms_cstime = @intCast(proc.cstime);

    // Copy to userspace
    UserPtr.from(buf_ptr).writeValue(tms) catch {
        return error.EFAULT;
    };

    // Return current tick count (POSIX requirement)
    return sched.getTickCount();
}
