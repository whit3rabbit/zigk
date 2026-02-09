const uapi = @import("uapi");
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const sched = @import("sched");
const process = @import("process");
const kernel_ipc = @import("kernel_ipc");

fn getCurrentProcess() SyscallError!*process.Process {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = thread.process orelse return error.ESRCH;
    return @ptrCast(@alignCast(proc_opaque));
}

pub fn sys_msgget(key: usize, msgflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    const result = kernel_ipc.msg.msgget(
        @bitCast(@as(u32, @truncate(key))),
        @bitCast(@as(u32, @truncate(msgflg))),
        proc,
    ) catch |err| return mapIpcError(err);
    return @intCast(result);
}

pub fn sys_msgsnd(msqid: usize, msgp: usize, msgsz: usize, msgflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    kernel_ipc.msg.msgsnd(
        @intCast(msqid),
        msgp,
        msgsz,
        @bitCast(@as(u32, @truncate(msgflg))),
        proc,
    ) catch |err| return mapIpcError(err);
    return 0;
}

pub fn sys_msgrcv(msqid: usize, msgp: usize, msgsz: usize, msgtyp: usize, msgflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    return kernel_ipc.msg.msgrcv(
        @intCast(msqid),
        msgp,
        msgsz,
        @as(i64, @bitCast(msgtyp)),
        @bitCast(@as(u32, @truncate(msgflg))),
        proc,
    ) catch |err| return mapIpcError(err);
}

pub fn sys_msgctl(msqid: usize, cmd: usize, buf: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    return kernel_ipc.msg.msgctl(
        @intCast(msqid),
        @bitCast(@as(u32, @truncate(cmd))),
        buf,
        proc,
    ) catch |err| return mapIpcError(err);
}

fn mapIpcError(err: anyerror) SyscallError {
    return switch (err) {
        error.EINVAL => error.EINVAL,
        error.EEXIST => error.EEXIST,
        error.ENOENT => error.ENOENT,
        error.EACCES => error.EACCES,
        error.ENOMEM => error.ENOMEM,
        error.ENOSPC => error.ENOSPC,
        error.EFAULT => error.EFAULT,
        error.EAGAIN => error.EAGAIN,
        error.EPERM => error.EPERM,
        error.E2BIG => error.E2BIG,
        error.ENOMSG => error.ENOMSG,
        else => error.EINVAL,
    };
}
