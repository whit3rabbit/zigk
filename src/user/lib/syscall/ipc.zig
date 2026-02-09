const primitive = @import("primitive.zig");
const syscall1 = primitive.syscall1;
const syscall2 = primitive.syscall2;
const syscall3 = primitive.syscall3;
const syscall4 = primitive.syscall4;
const syscall5 = primitive.syscall5;
const isError = primitive.isError;
const errorFromReturn = primitive.errorFromReturn;
const uapi = primitive.uapi;
const SyscallError = primitive.SyscallError;

// SysV IPC constants re-exported for convenience
pub const IPC_CREAT: i32 = uapi.ipc.sysv.IPC_CREAT;
pub const IPC_EXCL: i32 = uapi.ipc.sysv.IPC_EXCL;
pub const IPC_NOWAIT: i32 = uapi.ipc.sysv.IPC_NOWAIT;
pub const IPC_RMID: i32 = uapi.ipc.sysv.IPC_RMID;
pub const IPC_SET: i32 = uapi.ipc.sysv.IPC_SET;
pub const IPC_STAT: i32 = uapi.ipc.sysv.IPC_STAT;
pub const IPC_PRIVATE: i32 = uapi.ipc.sysv.IPC_PRIVATE;
pub const SHM_RDONLY: u32 = uapi.ipc.sysv.SHM_RDONLY;
pub const SETVAL: i32 = uapi.ipc.sysv.SETVAL;
pub const GETVAL: i32 = uapi.ipc.sysv.GETVAL;
pub const MSG_NOERROR: i32 = 0o10000;

// Re-export types
pub const ShmidDs = uapi.ipc.sysv.ShmidDs;
pub const SemidDs = uapi.ipc.sysv.SemidDs;
pub const SemBuf = uapi.ipc.sysv.SemBuf;
pub const MsqidDs = uapi.ipc.sysv.MsqidDs;
pub const MsgBufHeader = uapi.ipc.sysv.MsgBufHeader;

// ========== Shared Memory ==========

pub fn shmget(key: i32, size: usize, shmflg: i32) SyscallError!u32 {
    const ret = syscall3(
        uapi.syscalls.SYS_SHMGET,
        @as(usize, @bitCast(@as(isize, key))),
        size,
        @as(usize, @bitCast(@as(isize, shmflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @intCast(ret);
}

pub fn shmat(shmid: u32, shmaddr: ?[*]u8, shmflg: u32) SyscallError![*]u8 {
    const addr: usize = if (shmaddr) |a| @intFromPtr(a) else 0;
    const ret = syscall3(
        uapi.syscalls.SYS_SHMAT,
        @as(usize, shmid),
        addr,
        @as(usize, shmflg),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @ptrFromInt(ret);
}

pub fn shmdt(shmaddr: [*]const u8) SyscallError!void {
    const ret = syscall1(
        uapi.syscalls.SYS_SHMDT,
        @intFromPtr(shmaddr),
    );
    if (isError(ret)) return errorFromReturn(ret);
}

pub fn shmctl(shmid: u32, cmd: i32, buf: ?*ShmidDs) SyscallError!usize {
    const buf_addr: usize = if (buf) |b| @intFromPtr(b) else 0;
    const ret = syscall3(
        uapi.syscalls.SYS_SHMCTL,
        @as(usize, shmid),
        @as(usize, @bitCast(@as(isize, cmd))),
        buf_addr,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

// ========== Semaphores ==========

pub fn semget(key: i32, nsems: u32, semflg: i32) SyscallError!u32 {
    const ret = syscall3(
        uapi.syscalls.SYS_SEMGET,
        @as(usize, @bitCast(@as(isize, key))),
        @as(usize, nsems),
        @as(usize, @bitCast(@as(isize, semflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @intCast(ret);
}

pub fn semop(semid: u32, sops: []const SemBuf) SyscallError!void {
    const ret = syscall3(
        uapi.syscalls.SYS_SEMOP,
        @as(usize, semid),
        @intFromPtr(sops.ptr),
        sops.len,
    );
    if (isError(ret)) return errorFromReturn(ret);
}

pub fn semctl(semid: u32, semnum: u32, cmd: i32, arg: usize) SyscallError!usize {
    const ret = syscall4(
        uapi.syscalls.SYS_SEMCTL,
        @as(usize, semid),
        @as(usize, semnum),
        @as(usize, @bitCast(@as(isize, cmd))),
        arg,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

// ========== Message Queues ==========

pub fn msgget(key: i32, msgflg: i32) SyscallError!u32 {
    const ret = syscall2(
        uapi.syscalls.SYS_MSGGET,
        @as(usize, @bitCast(@as(isize, key))),
        @as(usize, @bitCast(@as(isize, msgflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return @intCast(ret);
}

pub fn msgsnd(msqid: u32, msgp: [*]const u8, msgsz: usize, msgflg: i32) SyscallError!void {
    const ret = syscall4(
        uapi.syscalls.SYS_MSGSND,
        @as(usize, msqid),
        @intFromPtr(msgp),
        msgsz,
        @as(usize, @bitCast(@as(isize, msgflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
}

pub fn msgrcv(msqid: u32, msgp: [*]u8, msgsz: usize, msgtyp: i64, msgflg: i32) SyscallError!usize {
    const ret = syscall5(
        uapi.syscalls.SYS_MSGRCV,
        @as(usize, msqid),
        @intFromPtr(msgp),
        msgsz,
        @as(usize, @bitCast(msgtyp)),
        @as(usize, @bitCast(@as(isize, msgflg))),
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}

pub fn msgctl(msqid: u32, cmd: i32, buf: ?*MsqidDs) SyscallError!usize {
    const buf_addr: usize = if (buf) |b| @intFromPtr(b) else 0;
    const ret = syscall3(
        uapi.syscalls.SYS_MSGCTL,
        @as(usize, msqid),
        @as(usize, @bitCast(@as(isize, cmd))),
        buf_addr,
    );
    if (isError(ret)) return errorFromReturn(ret);
    return ret;
}
