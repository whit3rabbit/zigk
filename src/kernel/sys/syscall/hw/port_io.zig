const std = @import("std");
const uapi = @import("uapi");
const hal = @import("hal");
const process = @import("process");
const sched = @import("sched");

const SyscallError = uapi.errno.SyscallError;

pub fn sys_outb(port: usize, value: usize) SyscallError!usize {
    // SECURITY: Validate bounds before truncation to prevent capability bypass.
    // Without this, port=0x1_0080 would truncate to 0x0080 in ReleaseFast,
    // potentially bypassing capability checks.
    if (port > std.math.maxInt(u16)) return error.EINVAL;
    if (value > std.math.maxInt(u8)) return error.EINVAL;
    const p: u16 = @truncate(port);
    const v: u8 = @truncate(value);

    // Permission check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasIoPortCapability(p)) return error.EPERM;

    hal.io.outb(p, v);
    return 0;
}

pub fn sys_inb(port: usize) SyscallError!usize {
    // SECURITY: Validate bounds before truncation to prevent capability bypass.
    if (port > std.math.maxInt(u16)) return error.EINVAL;
    const p: u16 = @truncate(port);

    // Permission check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasIoPortCapability(p)) return error.EPERM;

    const val = hal.io.inb(p);
    return val;
}
