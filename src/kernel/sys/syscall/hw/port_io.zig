const uapi = @import("uapi");
const hal = @import("hal");
const process = @import("process");
const sched = @import("sched");

const SyscallError = uapi.errno.SyscallError;

pub fn sys_outb(port: usize, value: usize) SyscallError!usize {
    const p: u16 = @intCast(port);
    const v: u8 = @intCast(value);

    // Permission check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasIoPortCapability(p)) return error.EPERM;

    hal.io.outb(p, v);
    return 0;
}

pub fn sys_inb(port: usize) SyscallError!usize {
    const p: u16 = @intCast(port);

    // Permission check
    const current = sched.getCurrentThread() orelse return error.EPERM;
    const proc_opaque = current.process orelse return error.EPERM;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (!proc.hasIoPortCapability(p)) return error.EPERM;

    const val = hal.io.inb(p);
    return val;
}
