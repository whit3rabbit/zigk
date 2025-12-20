const std = @import("std");
const base = @import("base.zig");
const fd_mod = @import("fd");
const utils = @import("utils.zig");
const error_helpers = @import("error_helpers.zig");

const SyscallError = base.SyscallError;
const safeFdCast = utils.safeFdCast;

/// sys_fcntl (72) - File control
pub fn sys_fcntl(fd_num: usize, cmd: usize, arg: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd_num) orelse return error.EBADF;
    const fd = table.get(fd_u32) orelse return error.EBADF;

    // F_DUPFD (0)
    if (cmd == 0) {
        // Fix potential panic if arg > u32.max (DoS)
        if (arg > std.math.maxInt(u32)) return error.EINVAL;
        const min_fd: u32 = @truncate(arg);

        if (min_fd >= fd_mod.MAX_FDS) return error.EINVAL;

        // Find lowest available FD >= min_fd
        // For now, allocFdNum checks from 0.
        // We need to loop manually.
        var i: u32 = min_fd;
        var found_fd: ?u32 = null;
        while (i < fd_mod.MAX_FDS) : (i += 1) {
            if (table.get(i) == null) {
                found_fd = i;
                break;
            }
        }
        if (found_fd) |new_fd_num| {
            fd.ref();
            table.install(new_fd_num, fd);
            return new_fd_num;
        } else {
            return error.EMFILE;
        }
    }

    // F_GETFD (1)
    if (cmd == 1) {
        // Return flags (FD_CLOEXEC)
        // We don't track FD_CLOEXEC in flags yet (it's separate from O_ flags).
        return 0;
    }

    // F_SETFD (2)
    if (cmd == 2) {
        // Set flags
        return 0;
    }

    // F_GETFL (3)
    if (cmd == 3) {
        return fd.flags;
    }

    // F_SETFL (4)
    if (cmd == 4) {
        // Modify flags (only O_APPEND, O_ASYNC, O_DIRECT, O_NOATIME, O_NONBLOCK)
        const new_flags = @as(u32, @truncate(arg));
        // We only care about O_NONBLOCK for now
        if ((new_flags & fd_mod.O_NONBLOCK) != 0) {
            fd.flags |= fd_mod.O_NONBLOCK;
        } else {
            fd.flags &= ~fd_mod.O_NONBLOCK;
        }
        return 0;
    }

    return error.EINVAL;
}

/// sys_ioctl (16) - Control device
///
/// MVP: Returns -ENOTTY (inappropriate ioctl for device)
/// This is sufficient for musl isatty() checks.
pub fn sys_ioctl(fd: usize, cmd: usize, arg: usize) SyscallError!usize {
    const table = base.getGlobalFdTable();
    const fd_u32 = safeFdCast(fd) orelse return error.EBADF;
    const fd_entry = table.get(fd_u32) orelse return error.EBADF;

    const ioctl_fn = fd_entry.ops.ioctl orelse return error.ENOTTY;

    const held = fd_entry.lock.acquire();
    defer held.release();

    const result = ioctl_fn(fd_entry, @intCast(cmd), @intCast(arg));
    return error_helpers.mapDeviceError(result);
}
