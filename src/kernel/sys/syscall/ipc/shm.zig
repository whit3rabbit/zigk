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

pub fn sys_shmget(key: usize, size: usize, shmflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    const result = kernel_ipc.shm.shmget(
        @bitCast(@as(u32, @truncate(key))),
        size,
        @bitCast(@as(u32, @truncate(shmflg))),
        proc,
    ) catch |err| return mapIpcError(err);
    return @intCast(result);
}

pub fn sys_shmat(shmid: usize, shmaddr: usize, shmflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    return kernel_ipc.shm.shmat(
        @intCast(shmid),
        shmaddr,
        @truncate(shmflg),
        proc,
    ) catch |err| return mapIpcError(err);
}

pub fn sys_shmdt(shmaddr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    kernel_ipc.shm.shmdt(shmaddr, proc) catch |err| return mapIpcError(err);
    return 0;
}

pub fn sys_shmctl(shmid: usize, cmd: usize, buf: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    return kernel_ipc.shm.shmctl(
        @intCast(shmid),
        @bitCast(@as(u32, @truncate(cmd))),
        buf,
        proc,
    ) catch |err| return mapIpcError(err);
}

fn mapIpcError(err: anyerror) SyscallError {
    // Map kernel IPC errors to syscall errors
    return switch (err) {
        error.EINVAL => error.EINVAL,
        error.EEXIST => error.EEXIST,
        error.ENOENT => error.ENOENT,
        error.EACCES => error.EACCES,
        error.ENOMEM => error.ENOMEM,
        error.ENOSPC => error.ENOSPC,
        error.EFAULT => error.EFAULT,
        error.EIDRM => error.EIDRM,
        error.EPERM => error.EPERM,
        else => error.EINVAL,
    };
}
