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

pub fn sys_semget(key: usize, nsems: usize, semflg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    const result = kernel_ipc.sem.semget(
        @bitCast(@as(u32, @truncate(key))),
        @intCast(nsems),
        @bitCast(@as(u32, @truncate(semflg))),
        proc,
    ) catch |err| return mapIpcError(err);
    return @intCast(result);
}

pub fn sys_semop(semid: usize, sops_ptr: usize, nsops: usize) SyscallError!usize {
    if (nsops == 0 or nsops > uapi.ipc.sysv.SEMOPM) return error.E2BIG;
    const proc = try getCurrentProcess();

    // Copy SemBuf array from userspace
    var sops_buf: [uapi.ipc.sysv.SEMOPM]uapi.ipc.sysv.SemBuf = undefined;
    const copy_size = nsops * @sizeOf(uapi.ipc.sysv.SemBuf);
    const user_ptr = user_mem.UserPtr.from(sops_ptr);
    const dest = @as([*]u8, @ptrCast(&sops_buf))[0..copy_size];
    _ = user_ptr.copyToKernel(dest) catch return error.EFAULT;

    kernel_ipc.sem.semop(
        @intCast(semid),
        sops_buf[0..nsops],
        proc,
    ) catch |err| return mapIpcError(err);
    return 0;
}

pub fn sys_semctl(semid: usize, semnum: usize, cmd: usize, arg: usize) SyscallError!usize {
    const proc = try getCurrentProcess();
    return kernel_ipc.sem.semctl(
        @intCast(semid),
        @intCast(semnum),
        @bitCast(@as(u32, @truncate(cmd))),
        arg,
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
        error.EFBIG => error.EFBIG,
        error.ERANGE => error.ERANGE,
        error.E2BIG => error.E2BIG,
        else => error.EINVAL,
    };
}
