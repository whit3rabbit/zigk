// Process Control Syscall Handlers
//
// Implements process lifecycle and identity syscalls:
// - sys_exit, sys_exit_group: Process termination
// - sys_wait4: Wait for child process state changes
// - sys_getpid, sys_getppid: Process identity
// - sys_getuid, sys_getgid: User/group identity (always root for MVP)

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");
const process_mod = @import("process");

const SyscallError = base.SyscallError;
const Process = base.Process;
const UserPtr = base.UserPtr;
const isValidUserAccess = base.isValidUserAccess;
const AccessMode = base.AccessMode;

// Re-export getCurrentProcessOrNull for use by dispatch table
pub const getCurrentProcessOrNull = process_mod.getCurrentProcessOrNull;

// =============================================================================
// Process Control
// =============================================================================

/// sys_exit (60) - Terminate the current thread
///
/// Note: In MVP, this terminates the current thread. Full implementation
/// would terminate the entire process (all threads).
pub fn sys_exit(status: usize) isize {
    // Linux exit status encoding: (status & 0xFF) << 8
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    process_mod.exit((exit_code & 0xFF) << 8);
    unreachable;
}

/// sys_exit_group (231) - Exit all threads in process group
///
/// MVP: Same as sys_exit since we don't have process groups yet.
pub fn sys_exit_group(status: usize) isize {
    const exit_code: i32 = @truncate(@as(isize, @bitCast(status)));
    process_mod.exit((exit_code & 0xFF) << 8);
    unreachable;
}

/// sys_wait4 (61) - Wait for process state change
/// Full implementation with zombie reaping and parent/child tracking
pub fn sys_wait4(pid_arg: usize, wstatus_ptr: usize, options: usize, rusage_ptr: usize) SyscallError!usize {
    _ = rusage_ptr; // rusage not implemented

    const current_proc = base.getCurrentProcess();

    // Interpret pid argument
    const target_pid: i32 = @bitCast(@as(u32, @truncate(pid_arg)));
    const wnohang = (options & 1) != 0; // WNOHANG flag
    const current_thread = sched.getCurrentThread() orelse return error.ESRCH;

    // Loop until we find a zombie child or no children remain
    while (true) {
        // Disable interrupts to prevent "lost wakeup" race condition
        // if child exits after we check but before we block.
        hal.cpu.disableInterrupts();

        var zombie_proc: ?*Process = null;
        var has_children = false;
        var has_matching_child = false;

        {
            // Acquire process tree lock to safely iterate children
            // Must be Write lock because we might remove a zombie child
            const held = sched.process_tree_lock.acquireWrite();
            defer held.release();

            var child = current_proc.first_child;
            while (child) |c| {
                // Get next sibling early
                const next_child = c.next_sibling;

                // Check if this child matches target_pid
                // POSIX semantics:
                // pid == -1: wait for any child
                // pid > 0: wait for specific child
                // pid == 0: wait for any child in same process group as caller
                // pid < -1: wait for any child in process group |pid|
                const matches = if (target_pid == -1)
                    true
                else if (target_pid > 0)
                    (c.pid == @as(u32, @intCast(target_pid)))
                else if (target_pid == 0)
                    (c.pgid == current_proc.pgid)
                else
                    (c.pgid == @as(u32, @intCast(-target_pid)));

                if (matches) {
                    has_children = true;
                    has_matching_child = true;

                    if (c.state == .Zombie) {
                        // Found a zombie - remove it from the list immediately
                        // This effectively "claims" the zombie for this thread
                        current_proc.removeChildLocked(c);
                        zombie_proc = c;
                        break;
                    }
                }

                child = next_child;
            }
        }

        if (zombie_proc) |zombie| {
            // Re-enable interrupts before doing work that might fault or take time
            hal.cpu.enableInterrupts();

            // We found and removed a zombie. The lock is released, so we can fault safely.
            const reaped_pid = zombie.pid;
            const exit_status = zombie.exit_status;

            // Propagate child's CPU times to parent's cumulative counters
            // Get the main thread's CPU times from the zombie process
            if (sched.findThreadByTid(zombie.pid)) |child_thread| {
                current_proc.cutime += child_thread.utime;
                current_proc.cstime += child_thread.stime;
            }
            // Also inherit the zombie's cumulative children times
            current_proc.cutime += zombie.cutime;
            current_proc.cstime += zombie.cstime;

            // Write exit status if pointer provided
            if (wstatus_ptr != 0) {
                UserPtr.from(wstatus_ptr).writeValue(exit_status) catch {
                    // We already removed the zombie from the list.
                    // If we fault here, we can't easily put it back.
                    // Strictly speaking we should return EFAULT, but the zombie is lost.
                    // We'll proceed with destroying it to avoid a leak.
                    // In a robust kernel, we might try to re-attach or check valid ptr first.
                    console.warn("sys_wait4: EFAULT writing status for pid={}", .{reaped_pid});
                    // Clean up and return error
                    if (zombie.unref()) {
                        process_mod.destroyProcess(zombie);
                    }
                    return error.EFAULT;
                };
            }

            // Clean up the process structure
            if (zombie.unref()) {
                process_mod.destroyProcess(zombie);
            }

            return reaped_pid;
        }

        // No zombie found
        if (!has_matching_child and target_pid > 0) {
            hal.cpu.enableInterrupts();
            return error.ECHILD;
        }
        if (!has_children and target_pid <= 0) {
            hal.cpu.enableInterrupts();
            return error.ECHILD;
        }

        // WNOHANG: don't block, return 0 if no zombies
        if (wnohang) {
            hal.cpu.enableInterrupts();
            return 0;
        }

        // Block and wait for child to exit
        // When a child exits, it (or its thread) wakes the parent.
        // sched.block() atomically enables interrupts and halts.
        current_thread.wait4_waiting.store(true, .release);
        sched.block();
        current_thread.wait4_waiting.store(false, .release);
    }
}

/// sys_waitid (247) - Wait for child process state changes (modern interface)
///
/// Provides extended wait semantics with siginfo_t output and flexible id types.
/// Returns 0 on success (unlike wait4 which returns PID).
pub fn sys_waitid(idtype: usize, id: usize, infop: usize, options: usize, rusage_ptr: usize) SyscallError!usize {
    _ = rusage_ptr; // rusage not implemented

    // waitid idtype values
    const P_ALL: usize = 0;
    const P_PID: usize = 1;
    const P_PGID: usize = 2;

    // waitid option flags
    const WEXITED: usize = 4;
    const WSTOPPED: usize = 2;
    const WCONTINUED: usize = 8;
    const WNOWAIT: usize = 0x01000000;
    const WNOHANG: usize = 1;

    // siginfo_t structure (128 bytes, Linux ABI)
    const SigInfo = extern struct {
        si_signo: i32,
        si_errno: i32,
        si_code: i32,
        _pad0: i32 = 0,
        si_pid: i32,
        si_uid: i32,
        si_status: i32,
        _pad: [128 - 28]u8 = [_]u8{0} ** (128 - 28),
    };

    // Compile-time size check
    comptime {
        if (@sizeOf(SigInfo) != 128) {
            @compileError("SigInfo must be exactly 128 bytes");
        }
    }

    // Signal codes for SIGCHLD
    const CLD_EXITED: i32 = 1;
    const SIGCHLD: i32 = 17;

    // Validate options: must have at least one of WEXITED, WSTOPPED, WCONTINUED
    if ((options & (WEXITED | WSTOPPED | WCONTINUED)) == 0) {
        return error.EINVAL;
    }

    // Validate idtype
    if (idtype != P_ALL and idtype != P_PID and idtype != P_PGID) {
        return error.EINVAL;
    }

    // Validate infop pointer
    if (infop == 0) {
        return error.EFAULT;
    }

    const current_proc = base.getCurrentProcess();
    const current_thread = sched.getCurrentThread() orelse return error.ESRCH;
    const wnohang = (options & WNOHANG) != 0;
    const wnowait = (options & WNOWAIT) != 0;

    // Loop until we find a matching child or no children remain
    while (true) {
        // Disable interrupts to prevent lost wakeup race
        hal.cpu.disableInterrupts();

        var zombie_proc: ?*Process = null;
        var has_matching_child = false;

        {
            // Acquire process tree lock (write lock if reaping, could optimize to read for WNOWAIT)
            const held = sched.process_tree_lock.acquireWrite();
            defer held.release();

            var child = current_proc.first_child;
            while (child) |c| {
                const next_child = c.next_sibling;

                // Check if this child matches idtype/id
                const matches = switch (idtype) {
                    P_ALL => true,
                    P_PID => (c.pid == @as(u32, @truncate(id))),
                    P_PGID => blk: {
                        if (id == 0) {
                            break :blk (c.pgid == current_proc.pgid);
                        } else {
                            break :blk (c.pgid == @as(u32, @truncate(id)));
                        }
                    },
                    else => false,
                };

                if (matches) {
                    has_matching_child = true;

                    // Check for zombie if WEXITED is set
                    if ((options & WEXITED) != 0 and c.state == .Zombie) {
                        // If not WNOWAIT, remove zombie from list (reap it)
                        if (!wnowait) {
                            current_proc.removeChildLocked(c);
                        }
                        zombie_proc = c;
                        break;
                    }
                }

                child = next_child;
            }
        }

        if (zombie_proc) |zombie| {
            hal.cpu.enableInterrupts();

            // Prepare siginfo_t
            const reaped_pid = zombie.pid;
            const exit_status = zombie.exit_status;
            const exit_code: i32 = @intCast((exit_status >> 8) & 0xFF);

            const info = SigInfo{
                .si_signo = SIGCHLD,
                .si_errno = 0,
                .si_code = CLD_EXITED,
                .si_pid = @intCast(reaped_pid),
                .si_uid = @intCast(zombie.uid),
                .si_status = exit_code,
            };

            // Write siginfo to userspace
            UserPtr.from(infop).writeValue(info) catch {
                // If WNOWAIT, zombie is still in list, so we can fail cleanly
                if (wnowait) {
                    return error.EFAULT;
                }
                // If we reaped, we already removed it. Clean up and return error.
                console.warn("sys_waitid: EFAULT writing siginfo for pid={}", .{reaped_pid});
                if (zombie.unref()) {
                    process_mod.destroyProcess(zombie);
                }
                return error.EFAULT;
            };

            // If we reaped (not WNOWAIT), propagate CPU times and destroy
            if (!wnowait) {
                // Propagate child's CPU times to parent
                if (sched.findThreadByTid(zombie.pid)) |child_thread| {
                    current_proc.cutime += child_thread.utime;
                    current_proc.cstime += child_thread.stime;
                }
                current_proc.cutime += zombie.cutime;
                current_proc.cstime += zombie.cstime;

                // Clean up zombie
                if (zombie.unref()) {
                    process_mod.destroyProcess(zombie);
                }
            }

            // waitid returns 0 on success
            return 0;
        }

        // No zombie found
        if (!has_matching_child) {
            hal.cpu.enableInterrupts();
            return error.ECHILD;
        }

        // WNOHANG: don't block, return 0 with zeroed siginfo
        if (wnohang) {
            hal.cpu.enableInterrupts();
            // Zero-fill siginfo (si_pid=0 indicates no child available)
            const zero_info = SigInfo{
                .si_signo = 0,
                .si_errno = 0,
                .si_code = 0,
                .si_pid = 0,
                .si_uid = 0,
                .si_status = 0,
            };
            UserPtr.from(infop).writeValue(zero_info) catch {
                return error.EFAULT;
            };
            return 0;
        }

        // Block and wait for child to exit
        current_thread.wait4_waiting.store(true, .release);
        sched.block();
        current_thread.wait4_waiting.store(false, .release);
    }
}

/// sys_getpid (39) - Get process ID
///
/// MVP: Returns thread ID since we don't have processes yet.
pub fn sys_getpid() SyscallError!usize {
    // Phase 4: Use process PID
    // Ensure we have a valid process structure (init fallback handled by getter)
    const proc = base.getCurrentProcess();
    return proc.pid;
}

/// sys_getppid (110) - Get parent process ID
///
/// MVP: Always returns 0 (init process has no parent).
pub fn sys_getppid() SyscallError!usize {
    const proc = base.getCurrentProcess();
    if (proc.parent) |p| {
        return p.pid;
    }
    return 0;
}

/// sys_getuid (102) - Get real user ID
pub fn sys_getuid() SyscallError!usize {
    const proc = base.getCurrentProcess();
    return proc.uid;
}

/// sys_getgid (104) - Get real group ID
pub fn sys_getgid() SyscallError!usize {
    const proc = base.getCurrentProcess();
    return proc.gid;
}

/// sys_setuid (105) - Set user ID
///
/// POSIX behavior:
/// - If euid == 0 (root) or has CAP_SETUID: set real, effective, and saved UID
/// - If euid != 0: set effective UID only if uid matches real or saved UID
///
/// SECURITY: Uses cred_lock to prevent TOCTOU races between permission check
/// and credential writes when multiple threads call setuid/setgid concurrently.
pub fn sys_setuid(uid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_uid: u32 = @truncate(uid);

    // SECURITY: Acquire credential lock for atomic check-and-modify
    const held = proc.cred_lock.acquire();
    defer held.release();

    // Root or CAP_SETUID holder can set any UID
    if (proc.euid == 0 or proc.hasSetUidCapability(new_uid)) {
        proc.uid = new_uid;
        proc.euid = new_uid;
        proc.suid = new_uid;
        proc.fsuid = new_uid; // Auto-sync fsuid
        return 0;
    }

    // Non-root: can only set effective UID to real or saved UID
    if (new_uid == proc.uid or new_uid == proc.suid) {
        proc.euid = new_uid;
        proc.fsuid = new_uid; // Auto-sync fsuid
        return 0;
    }

    return error.EPERM;
}

/// sys_setgid (106) - Set group ID
///
/// POSIX behavior:
/// - If euid == 0 (root) or has CAP_SETGID: set real, effective, and saved GID
/// - If euid != 0: set effective GID only if gid matches real or saved GID
///
/// SECURITY: Uses cred_lock to prevent TOCTOU races between permission check
/// and credential writes when multiple threads call setuid/setgid concurrently.
pub fn sys_setgid(gid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_gid: u32 = @truncate(gid);

    // SECURITY: Acquire credential lock for atomic check-and-modify
    const held = proc.cred_lock.acquire();
    defer held.release();

    // Root or CAP_SETGID holder can set any GID
    if (proc.euid == 0 or proc.hasSetGidCapability(new_gid)) {
        proc.gid = new_gid;
        proc.egid = new_gid;
        proc.sgid = new_gid;
        proc.fsgid = new_gid; // Auto-sync fsgid
        return 0;
    }

    // Non-root: can only set effective GID to real or saved GID
    if (new_gid == proc.gid or new_gid == proc.sgid) {
        proc.egid = new_gid;
        proc.fsgid = new_gid; // Auto-sync fsgid
        return 0;
    }

    return error.EPERM;
}

/// sys_geteuid (107) - Get effective user ID
pub fn sys_geteuid() SyscallError!usize {
    const proc = base.getCurrentProcess();
    return proc.euid;
}

/// sys_getegid (108) - Get effective group ID
pub fn sys_getegid() SyscallError!usize {
    const proc = base.getCurrentProcess();
    return proc.egid;
}

/// Value indicating "leave unchanged" for setresuid/setresgid
const UNCHANGED: u32 = 0xFFFFFFFF;

/// Check if a non-privileged process can set UID to the given value
fn canSetUid(proc: *base.Process, new_uid: u32) bool {
    return new_uid == proc.uid or new_uid == proc.euid or new_uid == proc.suid;
}

/// Check if a non-privileged process can set GID to the given value
fn canSetGid(proc: *base.Process, new_gid: u32) bool {
    return new_gid == proc.gid or new_gid == proc.egid or new_gid == proc.sgid;
}

/// sys_setresuid (117) - Set real, effective, and saved user IDs
///
/// Allows fine-grained control over all three user IDs. This is the proper
/// way to permanently drop privileges (set all three to the same non-zero value).
///
/// Args:
///   ruid: New real UID, or -1 to leave unchanged
///   euid: New effective UID, or -1 to leave unchanged
///   suid: New saved UID, or -1 to leave unchanged
///
/// Security:
/// - Root or CAP_SETUID can set any values
/// - Non-privileged users can only set values that match current real, effective, or saved UID
/// - Permanently drops privileges if all three are set to a non-zero value
/// - Uses cred_lock to prevent TOCTOU races between permission check and credential writes
pub fn sys_setresuid(ruid: usize, euid: usize, suid_arg: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    const new_ruid: u32 = @truncate(ruid);
    const new_euid: u32 = @truncate(euid);
    const new_suid: u32 = @truncate(suid_arg);

    // SECURITY: Acquire credential lock for atomic check-and-modify.
    // Prevents TOCTOU race where another thread could modify credentials
    // between permission check and credential write phases.
    const held = proc.cred_lock.acquire();
    defer held.release();

    const is_privileged = proc.euid == 0;

    // Check permissions for each ID that will be changed
    if (new_ruid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_ruid) and !canSetUid(proc, new_ruid)) {
            return error.EPERM;
        }
    }
    if (new_euid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_euid) and !canSetUid(proc, new_euid)) {
            return error.EPERM;
        }
    }
    if (new_suid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_suid) and !canSetUid(proc, new_suid)) {
            return error.EPERM;
        }
    }

    // All checks passed, apply changes
    if (new_ruid != UNCHANGED) proc.uid = new_ruid;
    if (new_euid != UNCHANGED) {
        proc.euid = new_euid;
        proc.fsuid = new_euid; // Auto-sync fsuid
    }
    if (new_suid != UNCHANGED) proc.suid = new_suid;

    return 0;
}

/// sys_getresuid (118) - Get real, effective, and saved user IDs
///
/// Writes the current real, effective, and saved UIDs to userspace pointers.
/// Any pointer may be NULL to skip that value.
pub fn sys_getresuid(ruid_ptr: usize, euid_ptr: usize, suid_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    if (ruid_ptr != 0) {
        const ptr = UserPtr.from(ruid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.uid))) catch return error.EFAULT;
    }
    if (euid_ptr != 0) {
        const ptr = UserPtr.from(euid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.euid))) catch return error.EFAULT;
    }
    if (suid_ptr != 0) {
        const ptr = UserPtr.from(suid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.suid))) catch return error.EFAULT;
    }

    return 0;
}

/// sys_setresgid (119) - Set real, effective, and saved group IDs
///
/// Same semantics as setresuid but for group IDs.
///
/// Security:
/// - Uses cred_lock to prevent TOCTOU races between permission check and credential writes
pub fn sys_setresgid(rgid: usize, egid: usize, sgid_arg: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    const new_rgid: u32 = @truncate(rgid);
    const new_egid: u32 = @truncate(egid);
    const new_sgid: u32 = @truncate(sgid_arg);

    // SECURITY: Acquire credential lock for atomic check-and-modify.
    // Prevents TOCTOU race where another thread could modify credentials
    // between permission check and credential write phases.
    const held = proc.cred_lock.acquire();
    defer held.release();

    const is_privileged = proc.euid == 0;

    // Check permissions for each ID that will be changed
    if (new_rgid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetGidCapability(new_rgid) and !canSetGid(proc, new_rgid)) {
            return error.EPERM;
        }
    }
    if (new_egid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetGidCapability(new_egid) and !canSetGid(proc, new_egid)) {
            return error.EPERM;
        }
    }
    if (new_sgid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetGidCapability(new_sgid) and !canSetGid(proc, new_sgid)) {
            return error.EPERM;
        }
    }

    // All checks passed, apply changes
    if (new_rgid != UNCHANGED) proc.gid = new_rgid;
    if (new_egid != UNCHANGED) {
        proc.egid = new_egid;
        proc.fsgid = new_egid; // Auto-sync fsgid
    }
    if (new_sgid != UNCHANGED) proc.sgid = new_sgid;

    return 0;
}

/// sys_getresgid (120) - Get real, effective, and saved group IDs
///
/// Writes the current real, effective, and saved GIDs to userspace pointers.
pub fn sys_getresgid(rgid_ptr: usize, egid_ptr: usize, sgid_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    if (rgid_ptr != 0) {
        const ptr = UserPtr.from(rgid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.gid))) catch return error.EFAULT;
    }
    if (egid_ptr != 0) {
        const ptr = UserPtr.from(egid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.egid))) catch return error.EFAULT;
    }
    if (sgid_ptr != 0) {
        const ptr = UserPtr.from(sgid_ptr);
        _ = ptr.copyFromKernel(@as(*const [4]u8, @ptrCast(&proc.sgid))) catch return error.EFAULT;
    }

    return 0;
}

/// sys_setreuid (113) - Set real and effective user IDs
///
/// Atomically sets real and effective UID. POSIX semantics:
/// - Privileged (euid==0 or CAP_SETUID): can set any values
/// - Non-privileged: ruid can be set to current real or effective UID,
///   euid can be set to current real, effective, or saved UID
/// - If ruid is set (or euid is set to a value != old ruid), saved UID = new euid
/// - Value -1 (0xFFFFFFFF) means "leave unchanged"
///
/// Security:
/// - Uses cred_lock to prevent TOCTOU races
/// - Auto-syncs fsuid when euid changes
pub fn sys_setreuid(ruid: usize, euid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_ruid: u32 = @truncate(ruid);
    const new_euid: u32 = @truncate(euid);

    // SECURITY: Acquire credential lock for atomic check-and-modify
    const held = proc.cred_lock.acquire();
    defer held.release();

    const old_ruid = proc.uid;
    const old_euid = proc.euid;
    const is_privileged = old_euid == 0;

    // Check permissions
    if (new_ruid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_ruid)) {
            if (new_ruid != old_ruid and new_ruid != old_euid) {
                return error.EPERM;
            }
        }
    }
    if (new_euid != UNCHANGED) {
        if (!is_privileged and !proc.hasSetUidCapability(new_euid)) {
            if (new_euid != old_ruid and new_euid != old_euid and new_euid != proc.suid) {
                return error.EPERM;
            }
        }
    }

    // Apply changes
    if (new_ruid != UNCHANGED) proc.uid = new_ruid;
    if (new_euid != UNCHANGED) {
        proc.euid = new_euid;
        proc.fsuid = new_euid; // Auto-sync fsuid
    }

    // POSIX: If ruid was set, or euid was set to value != old real UID, set saved UID to new euid
    if (new_ruid != UNCHANGED or (new_euid != UNCHANGED and new_euid != old_ruid)) {
        proc.suid = proc.euid;
    }

    return 0;
}

/// sys_setregid (114) - Set real and effective group IDs
///
/// Atomically sets real and effective GID. Same semantics as setreuid but for GIDs.
///
/// Security:
/// - Uses cred_lock to prevent TOCTOU races
/// - Auto-syncs fsgid when egid changes
pub fn sys_setregid(rgid: usize, egid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_rgid: u32 = @truncate(rgid);
    const new_egid: u32 = @truncate(egid);

    // SECURITY: Acquire credential lock for atomic check-and-modify
    const held = proc.cred_lock.acquire();
    defer held.release();

    const old_rgid = proc.gid;
    const is_privileged = proc.euid == 0;

    // Check permissions - POSIX requires rgid/egid to match current gid, egid, or sgid
    if (new_rgid != UNCHANGED) {
        if (!is_privileged and !canSetGid(proc, new_rgid)) {
            return error.EPERM;
        }
    }
    if (new_egid != UNCHANGED) {
        if (!is_privileged and !canSetGid(proc, new_egid)) {
            return error.EPERM;
        }
    }

    // Apply changes
    if (new_rgid != UNCHANGED) proc.gid = new_rgid;
    if (new_egid != UNCHANGED) {
        proc.egid = new_egid;
        proc.fsgid = new_egid; // Auto-sync fsgid
    }

    // POSIX: If rgid was set, or egid was set to value != old real GID, set saved GID to new egid
    if (new_rgid != UNCHANGED or (new_egid != UNCHANGED and new_egid != old_rgid)) {
        proc.sgid = proc.egid;
    }

    return 0;
}

/// sys_setfsuid (122) - Set filesystem user ID
///
/// Sets the filesystem UID used for permission checks. This is a Linux extension.
/// Returns the PREVIOUS fsuid value, NOT 0 on success. This is by design.
///
/// Security:
/// - Non-privileged users can only set to uid, euid, suid, or current fsuid
/// - If not permitted, returns old fsuid without changing it (NOT an error)
/// - Uses cred_lock to prevent races
pub fn sys_setfsuid(fsuid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_fsuid: u32 = @truncate(fsuid);

    // SECURITY: Acquire credential lock
    const held = proc.cred_lock.acquire();
    defer held.release();

    const old_fsuid = proc.fsuid;
    const is_privileged = proc.euid == 0;

    // Permission check: non-privileged must match one of the UIDs
    if (!is_privileged) {
        if (new_fsuid != proc.uid and new_fsuid != proc.euid and
            new_fsuid != proc.suid and new_fsuid != old_fsuid)
        {
            // Not permitted - return old value unchanged
            return old_fsuid;
        }
    }

    // Permitted - apply change
    proc.fsuid = new_fsuid;
    return old_fsuid;
}

/// sys_setfsgid (123) - Set filesystem group ID
///
/// Sets the filesystem GID used for permission checks. This is a Linux extension.
/// Returns the PREVIOUS fsgid value, NOT 0 on success. This is by design.
///
/// Security:
/// - Non-privileged users can only set to gid, egid, sgid, or current fsgid
/// - If not permitted, returns old fsgid without changing it (NOT an error)
/// - Uses cred_lock to prevent races
pub fn sys_setfsgid(fsgid: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const new_fsgid: u32 = @truncate(fsgid);

    // SECURITY: Acquire credential lock
    const held = proc.cred_lock.acquire();
    defer held.release();

    const old_fsgid = proc.fsgid;
    const is_privileged = proc.euid == 0;

    // Permission check: non-privileged must match one of the GIDs
    if (!is_privileged) {
        if (new_fsgid != proc.gid and new_fsgid != proc.egid and
            new_fsgid != proc.sgid and new_fsgid != old_fsgid)
        {
            // Not permitted - return old value unchanged
            return old_fsgid;
        }
    }

    // Permitted - apply change
    proc.fsgid = new_fsgid;
    return old_fsgid;
}

/// sys_getgroups (115) - Get supplementary group list
///
/// Returns the list of supplementary group IDs for the calling process.
/// If size == 0, returns the count without writing to the list.
/// If size > 0, writes up to size group IDs to the list.
///
/// Args:
///   size: Size of the list array (in number of u32 elements), or 0 to query count
///   list_ptr: Pointer to u32 array in userspace
///
/// Returns:
///   Number of supplementary groups (on success)
///   EINVAL if size < count (buffer too small)
///   EFAULT if list_ptr is invalid
pub fn sys_getgroups(size: usize, list_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const count = proc.supplementary_groups_count;

    // If size == 0, just return count (query only)
    if (size == 0) {
        return count;
    }

    // Check buffer size
    if (size < count) {
        return error.EINVAL;
    }

    // Validate user buffer
    if (!isValidUserAccess(list_ptr, size * @sizeOf(u32), AccessMode.Write)) {
        return error.EFAULT;
    }

    // Copy supplementary groups to userspace
    if (count > 0) {
        const data_bytes = @as(*const [@sizeOf(u32) * 16]u8, @ptrCast(&proc.supplementary_groups));
        const uptr = UserPtr.from(list_ptr);
        _ = uptr.copyFromKernel(data_bytes[0 .. count * @sizeOf(u32)]) catch return error.EFAULT;
    }

    return count;
}

/// sys_setgroups (116) - Set supplementary group list
///
/// Sets the list of supplementary group IDs for the calling process.
/// Requires root privileges (euid == 0) or CAP_SETGID.
///
/// Args:
///   size: Number of group IDs in the list (max 16)
///   list_ptr: Pointer to u32 array in userspace
///
/// Returns:
///   0 on success
///   EINVAL if size > 16
///   EPERM if not privileged
///   EFAULT if list_ptr is invalid
pub fn sys_setgroups(size: usize, list_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    // Permission check: must be root or have CAP_SETGID
    if (proc.euid != 0 and !proc.hasSetGidCapability(0)) {
        return error.EPERM;
    }

    // Validate size
    if (size > 16) {
        return error.EINVAL;
    }

    // Read groups from userspace (if any)
    if (size > 0) {
        // Validate user buffer
        if (!isValidUserAccess(list_ptr, size * @sizeOf(u32), AccessMode.Read)) {
            return error.EFAULT;
        }

        // Copy from userspace
        const uptr = UserPtr.from(list_ptr);
        var temp_groups: [16]u32 = undefined;
        const data_bytes = @as(*[16 * @sizeOf(u32)]u8, @ptrCast(&temp_groups));
        _ = uptr.copyToKernel(data_bytes[0 .. size * @sizeOf(u32)]) catch return error.EFAULT;

        // SECURITY: Acquire credential lock
        const held = proc.cred_lock.acquire();
        defer held.release();

        // Copy to process structure
        @memcpy(proc.supplementary_groups[0..size], temp_groups[0..size]);
        proc.supplementary_groups_count = @truncate(size);

        // Zero remaining entries to prevent info leak
        if (size < 16) {
            @memset(proc.supplementary_groups[size..16], 0);
        }
    } else {
        // size == 0: clear supplementary groups
        const held = proc.cred_lock.acquire();
        defer held.release();

        proc.supplementary_groups_count = 0;
        @memset(&proc.supplementary_groups, 0);
    }

    return 0;
}

/// sys_umask (95) - Set file creation mask
///
/// MVP: Stored per-process but not enforced yet
pub fn sys_umask(mask: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();
    const old_mask = proc.umask;
    proc.umask = @truncate(mask & 0o777);
    return old_mask;
}

/// Linux rlimit structure (matches Linux x86_64 ABI)
const Rlimit = extern struct {
    rlim_cur: u64, // Soft limit
    rlim_max: u64, // Hard limit

    comptime {
        // Validate struct matches Linux ABI (16 bytes, no padding)
        std.debug.assert(@sizeOf(Rlimit) == 16);
        std.debug.assert(@alignOf(Rlimit) == 8);
    }
};

/// Unlimited resource limit value (Linux RLIM_INFINITY)
const RLIM_INFINITY: u64 = @bitCast(@as(i64, -1));

/// Linux RLIMIT_* resource identifiers
const RLIMIT_CPU: usize = 0; // CPU time in seconds
const RLIMIT_FSIZE: usize = 1; // Maximum file size
const RLIMIT_DATA: usize = 2; // Maximum data segment size
const RLIMIT_STACK: usize = 3; // Maximum stack size
const RLIMIT_CORE: usize = 4; // Maximum core file size
const RLIMIT_RSS: usize = 5; // Maximum resident set size
const RLIMIT_NPROC: usize = 6; // Maximum number of processes
const RLIMIT_NOFILE: usize = 7; // Maximum number of open files
const RLIMIT_MEMLOCK: usize = 8; // Maximum locked memory
const RLIMIT_AS: usize = 9; // Maximum address space
const RLIMIT_LOCKS: usize = 10; // Maximum file locks
const RLIMIT_SIGPENDING: usize = 11; // Maximum pending signals
const RLIMIT_MSGQUEUE: usize = 12; // Maximum message queue bytes
const RLIMIT_NICE: usize = 13; // Maximum nice priority
const RLIMIT_RTPRIO: usize = 14; // Maximum realtime priority
const RLIMIT_RTTIME: usize = 15; // Maximum realtime timeout

/// Default stack size (8 MB, standard Linux default)
const DEFAULT_STACK_LIMIT: u64 = 8 * 1024 * 1024;

/// Default NOFILE limit (1024, common Linux default)
const DEFAULT_NOFILE_SOFT: u64 = 1024;
const DEFAULT_NOFILE_HARD: u64 = 4096;

/// sys_getrlimit (97) - Get resource limits
///
/// Returns process resource limits for the specified resource type.
pub fn sys_getrlimit(resource: usize, rlim_ptr: usize) SyscallError!usize {
    if (rlim_ptr == 0) return error.EFAULT;

    const proc = base.getCurrentProcess();

    const rlimit: Rlimit = switch (resource) {
        RLIMIT_AS => .{
            .rlim_cur = proc.rlimit_as,
            .rlim_max = proc.rlimit_as,
        },
        RLIMIT_STACK => .{
            .rlim_cur = proc.rlimit_stack_soft,
            .rlim_max = proc.rlimit_stack_hard,
        },
        RLIMIT_NOFILE => .{
            .rlim_cur = proc.rlimit_nofile_soft,
            .rlim_max = proc.rlimit_nofile_hard,
        },
        RLIMIT_NPROC => .{
            .rlim_cur = proc.rlimit_nproc_soft,
            .rlim_max = proc.rlimit_nproc_hard,
        },
        RLIMIT_CORE => .{
            .rlim_cur = proc.rlimit_core_soft,
            .rlim_max = proc.rlimit_core_hard,
        },
        RLIMIT_CPU, RLIMIT_FSIZE, RLIMIT_DATA, RLIMIT_RSS, RLIMIT_MEMLOCK, RLIMIT_LOCKS, RLIMIT_SIGPENDING, RLIMIT_MSGQUEUE, RLIMIT_NICE, RLIMIT_RTPRIO, RLIMIT_RTTIME => .{
            // Not tracked/enforced, return unlimited
            .rlim_cur = RLIM_INFINITY,
            .rlim_max = RLIM_INFINITY,
        },
        else => {
            // Unknown resource, return EINVAL
            return error.EINVAL;
        },
    };

    UserPtr.from(rlim_ptr).writeValue(rlimit) catch {
        return error.EFAULT;
    };
    return 0;
}

/// sys_setrlimit (160) - Set resource limits
///
/// Sets process resource limits. Non-root can only lower limits.
pub fn sys_setrlimit(resource: usize, rlim_ptr: usize) SyscallError!usize {
    if (rlim_ptr == 0) return error.EFAULT;

    const new_limit = UserPtr.from(rlim_ptr).readValue(Rlimit) catch {
        return error.EFAULT;
    };

    // Validate soft <= hard
    if (new_limit.rlim_cur > new_limit.rlim_max and new_limit.rlim_max != RLIM_INFINITY) {
        return error.EINVAL;
    }

    const proc = base.getCurrentProcess();

    switch (resource) {
        RLIMIT_AS => {
            // Only root can raise the address space limit
            if (new_limit.rlim_max > proc.rlimit_as and proc.euid != 0) {
                return error.EPERM;
            }
            proc.rlimit_as = new_limit.rlim_cur;
        },
        RLIMIT_NOFILE => {
            // Non-root cannot raise hard limit above current hard limit
            if (new_limit.rlim_max > proc.rlimit_nofile_hard and proc.euid != 0) {
                return error.EPERM;
            }
            proc.rlimit_nofile_soft = new_limit.rlim_cur;
            proc.rlimit_nofile_hard = new_limit.rlim_max;
        },
        RLIMIT_STACK => {
            // Non-root cannot raise hard limit above current hard limit
            if (new_limit.rlim_max > proc.rlimit_stack_hard and proc.euid != 0) {
                return error.EPERM;
            }
            proc.rlimit_stack_soft = new_limit.rlim_cur;
            proc.rlimit_stack_hard = new_limit.rlim_max;
        },
        RLIMIT_NPROC => {
            // Non-root cannot raise hard limit above current hard limit
            if (new_limit.rlim_max > proc.rlimit_nproc_hard and proc.euid != 0) {
                return error.EPERM;
            }
            proc.rlimit_nproc_soft = new_limit.rlim_cur;
            proc.rlimit_nproc_hard = new_limit.rlim_max;
        },
        RLIMIT_CORE => {
            // Non-root cannot raise hard limit above current hard limit
            if (new_limit.rlim_max > proc.rlimit_core_hard and proc.euid != 0) {
                return error.EPERM;
            }
            proc.rlimit_core_soft = new_limit.rlim_cur;
            proc.rlimit_core_hard = new_limit.rlim_max;
        },
        else => {
            // Unknown or unsupported resource
            return error.EINVAL;
        },
    }

    return 0;
}

/// sys_prlimit64 (302) - Get/set resource limits for any process
///
/// Modern replacement for getrlimit/setrlimit. Can read and/or set limits
/// in a single atomic operation. Can target any process by PID.
pub fn sys_prlimit64(pid: usize, resource: usize, new_limit_ptr: usize, old_limit_ptr: usize) SyscallError!usize {
    const caller = base.getCurrentProcess();
    const target_pid: u32 = @truncate(pid);
    const proc = if (target_pid == 0)
        caller
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    // SECURITY: Cross-process permission check (POSIX DAC model)
    if (proc != caller and caller.euid != 0) {
        // Caller's real/effective UID must match target's real/effective UID
        if (caller.uid != proc.uid and caller.uid != proc.euid and
            caller.euid != proc.uid and caller.euid != proc.euid)
        {
            return error.EPERM;
        }
    }

    // If old_limit_ptr != 0, return current limits
    if (old_limit_ptr != 0) {
        const old_limit: Rlimit = switch (resource) {
            RLIMIT_AS => .{
                .rlim_cur = proc.rlimit_as,
                .rlim_max = proc.rlimit_as,
            },
            RLIMIT_STACK => .{
                .rlim_cur = proc.rlimit_stack_soft,
                .rlim_max = proc.rlimit_stack_hard,
            },
            RLIMIT_NOFILE => .{
                .rlim_cur = proc.rlimit_nofile_soft,
                .rlim_max = proc.rlimit_nofile_hard,
            },
            RLIMIT_NPROC => .{
                .rlim_cur = proc.rlimit_nproc_soft,
                .rlim_max = proc.rlimit_nproc_hard,
            },
            RLIMIT_CORE => .{
                .rlim_cur = proc.rlimit_core_soft,
                .rlim_max = proc.rlimit_core_hard,
            },
            RLIMIT_CPU, RLIMIT_FSIZE, RLIMIT_DATA, RLIMIT_RSS, RLIMIT_MEMLOCK, RLIMIT_LOCKS, RLIMIT_SIGPENDING, RLIMIT_MSGQUEUE, RLIMIT_NICE, RLIMIT_RTPRIO, RLIMIT_RTTIME => .{
                .rlim_cur = RLIM_INFINITY,
                .rlim_max = RLIM_INFINITY,
            },
            else => {
                return error.EINVAL;
            },
        };

        UserPtr.from(old_limit_ptr).writeValue(old_limit) catch {
            return error.EFAULT;
        };
    }

    // If new_limit_ptr != 0, set new limits
    if (new_limit_ptr != 0) {
        const new_limit = UserPtr.from(new_limit_ptr).readValue(Rlimit) catch {
            return error.EFAULT;
        };

        // Validate soft <= hard
        if (new_limit.rlim_cur > new_limit.rlim_max and new_limit.rlim_max != RLIM_INFINITY) {
            return error.EINVAL;
        }

        switch (resource) {
            RLIMIT_AS => {
                // Check permission for raising hard limit
                if (new_limit.rlim_max > proc.rlimit_as and caller.euid != 0) {
                    return error.EPERM;
                }
                proc.rlimit_as = new_limit.rlim_cur;
            },
            RLIMIT_NOFILE => {
                // Non-root cannot raise hard limit above current hard limit
                if (new_limit.rlim_max > proc.rlimit_nofile_hard and caller.euid != 0) {
                    return error.EPERM;
                }
                proc.rlimit_nofile_soft = new_limit.rlim_cur;
                proc.rlimit_nofile_hard = new_limit.rlim_max;
            },
            RLIMIT_STACK => {
                // Non-root cannot raise hard limit above current hard limit
                if (new_limit.rlim_max > proc.rlimit_stack_hard and caller.euid != 0) {
                    return error.EPERM;
                }
                proc.rlimit_stack_soft = new_limit.rlim_cur;
                proc.rlimit_stack_hard = new_limit.rlim_max;
            },
            RLIMIT_NPROC => {
                // Non-root cannot raise hard limit above current hard limit
                if (new_limit.rlim_max > proc.rlimit_nproc_hard and caller.euid != 0) {
                    return error.EPERM;
                }
                proc.rlimit_nproc_soft = new_limit.rlim_cur;
                proc.rlimit_nproc_hard = new_limit.rlim_max;
            },
            RLIMIT_CORE => {
                // Non-root cannot raise hard limit above current hard limit
                if (new_limit.rlim_max > proc.rlimit_core_hard and caller.euid != 0) {
                    return error.EPERM;
                }
                proc.rlimit_core_soft = new_limit.rlim_cur;
                proc.rlimit_core_hard = new_limit.rlim_max;
            },
            RLIMIT_CPU, RLIMIT_FSIZE, RLIMIT_DATA, RLIMIT_RSS, RLIMIT_MEMLOCK, RLIMIT_LOCKS, RLIMIT_SIGPENDING, RLIMIT_MSGQUEUE, RLIMIT_NICE, RLIMIT_RTPRIO, RLIMIT_RTTIME => {
                // Accept but don't enforce for MVP
            },
            else => {
                return error.EINVAL;
            },
        }
    }

    return 0;
}

/// sys_getrusage (98) - Get resource usage statistics
///
/// Returns resource usage information for the calling process, its children,
/// or the calling thread. For MVP, returns zeroed statistics (no tracking yet).
pub fn sys_getrusage(who: usize, usage_ptr: usize) SyscallError!usize {
    if (usage_ptr == 0) return error.EFAULT;

    // Define Linux-compatible rusage struct
    const Timeval = extern struct {
        tv_sec: i64,
        tv_usec: i64,
    };

    const Rusage = extern struct {
        ru_utime: Timeval, // user CPU time
        ru_stime: Timeval, // system CPU time
        ru_maxrss: i64, // max RSS in KB
        ru_ixrss: i64,
        ru_idrss: i64,
        ru_isrss: i64,
        ru_minflt: i64,
        ru_majflt: i64,
        ru_nswap: i64,
        ru_inblock: i64,
        ru_oublock: i64,
        ru_msgsnd: i64,
        ru_msgrcv: i64,
        ru_nsignals: i64,
        ru_nvcsw: i64,
        ru_nivcsw: i64,
    };

    // Validate who parameter
    // RUSAGE_SELF = 0
    // RUSAGE_CHILDREN = -1 (as usize = 0xFFFFFFFFFFFFFFFF)
    // RUSAGE_THREAD = 1
    const RUSAGE_SELF: usize = 0;
    const RUSAGE_CHILDREN: usize = @bitCast(@as(isize, -1));
    const RUSAGE_THREAD: usize = 1;

    if (who != RUSAGE_SELF and who != RUSAGE_CHILDREN and who != RUSAGE_THREAD) {
        return error.EINVAL;
    }

    // For MVP, return zeroed statistics (kernel doesn't track usage yet)
    const usage = std.mem.zeroes(Rusage);

    UserPtr.from(usage_ptr).writeValue(usage) catch {
        return error.EFAULT;
    };

    return 0;
}

const config = @import("config");

// ...
/// sys_uname (63) - Get system information
///
/// Returns system name, node name, release, version, machine
pub fn sys_uname(buf_ptr: usize) SyscallError!usize {
    if (buf_ptr == 0) return error.EFAULT;

    // utsname struct: 5 fields of 65 bytes each = 325 bytes
    // Linux uses _UTSNAME_LENGTH = 65
    const UTSNAME_LEN = 65;
    const utsname_len = 5 * UTSNAME_LEN;
    if (!isValidUserAccess(buf_ptr, utsname_len, AccessMode.Write)) {
        return error.EFAULT;
    }
    var utsname: [5 * UTSNAME_LEN]u8 = [_]u8{0} ** (5 * UTSNAME_LEN);

    // sysname
    const sysname = config.name;
    hal.mem.copy(utsname[0..sysname.len].ptr, sysname.ptr, sysname.len);

    // nodename
    const nodename = "localhost";
    hal.mem.copy(utsname[UTSNAME_LEN .. UTSNAME_LEN + nodename.len].ptr, nodename.ptr, nodename.len);

    // release
    const release = config.version;
    hal.mem.copy(utsname[2 * UTSNAME_LEN .. 2 * UTSNAME_LEN + release.len].ptr, release.ptr, release.len);

    // version
    const version = "#1 SMP";
    hal.mem.copy(utsname[3 * UTSNAME_LEN .. 3 * UTSNAME_LEN + version.len].ptr, version.ptr, version.len);

    // machine - architecture-dependent
    const machine = switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
    hal.mem.copy(utsname[4 * UTSNAME_LEN .. 4 * UTSNAME_LEN + machine.len].ptr, machine.ptr, machine.len);

    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyFromKernel(&utsname) catch {
        return error.EFAULT;
    };
    return 0;
}

// =============================================================================
// Process Groups and Sessions
// =============================================================================

/// sys_getpgid (121) - Get process group ID
pub fn sys_getpgid(pid: usize) SyscallError!usize {
    const target_pid: u32 = @truncate(pid);
    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    return proc.pgid;
}

/// sys_setpgid (109) - Set process group ID
///
/// SECURITY NOTE (MVP): This syscall uses findProcessByPid which returns a raw
/// pointer without refcounting. In the current single-threaded cooperative model,
/// this is safe because:
///   1. If target == current, process can't exit while running
///   2. If target is a child, parent-child relationship provides implicit reference
///   3. Process destruction only happens after wait() reaps zombie
///
/// For full SMP safety, this should use findAndRefProcess() with proper unref(),
/// or hold process_tree_lock during the entire operation.
pub fn sys_setpgid(pid: usize, pgid_arg: usize) SyscallError!usize {
    const target_pid: u32 = @truncate(pid);
    const new_pgid: u32 = @truncate(pgid_arg);

    const current = base.getCurrentProcess();
    const target = if (target_pid == 0)
        current
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    // Security: Only allow setting pgid for current process or its children
    if (target != current and target.parent != current) {
        return error.ESRCH;
    }

    // POSIX: New pgid must be 0 (current pid) or an existing pgid in the same session
    // For MVP, we allow setting it to any value or target's own pid
    const pgid = if (new_pgid == 0) target.pid else new_pgid;

    // Cannot change pgid if process has already called execve? (Simplified for now)
    // Cannot change pgid if target is session leader
    if (target.sid == target.pid) {
        return error.EPERM;
    }

    target.pgid = pgid;
    return 0;
}

/// sys_setsid (112) - Create new session
pub fn sys_setsid() SyscallError!usize {
    const proc = base.getCurrentProcess();

    // If already a process group leader, return EPERM
    if (proc.pgid == proc.pid) {
        return error.EPERM;
    }

    // Create new session: sid = pid, pgid = pid
    proc.sid = proc.pid;
    proc.pgid = proc.pid;

    // POSIX: Creating a new session loses the controlling terminal
    proc.ctty = -1;

    return proc.sid;
}

/// sys_getsid (124) - Get session ID
pub fn sys_getsid(pid: usize) SyscallError!usize {
    const target_pid: u32 = @truncate(pid);
    const proc = if (target_pid == 0)
        base.getCurrentProcess()
    else
        process_mod.findProcessByPid(target_pid) orelse return error.ESRCH;

    return proc.sid;
}

/// sys_getpgrp (111) - Get process group of calling process
///
/// Equivalent to getpgid(0) but with no arguments.
/// This is the POSIX getpgrp() - not to be confused with the
/// obsolete BSD getpgrp(pid) which takes an argument.
pub fn sys_getpgrp() SyscallError!usize {
    const proc = base.getCurrentProcess();
    return proc.pgid;
}

/// sys_sethostname (170) - Set hostname
///
/// MVP: Stub - returns EPERM (not permitted)
pub fn sys_sethostname(name_ptr: usize, len: usize) SyscallError!usize {
    _ = name_ptr;
    _ = len;
    return error.EPERM;
}

/// sys_setdomainname (171) - Set domain name
///
/// MVP: Stub - returns EPERM (not permitted)
pub fn sys_setdomainname(name_ptr: usize, len: usize) SyscallError!usize {
    _ = name_ptr;
    _ = len;
    return error.EPERM;
}

// =============================================================================
// Capability Syscalls (capget/capset)
// =============================================================================

const cap_uapi = uapi.capability;

/// sys_capget (125 on x86_64, 90 on aarch64) - Get process capabilities
///
/// Linux ABI: capget(cap_user_header_t *hdrp, cap_user_data_t *datap)
///
/// If datap is NULL, writes the preferred kernel version into hdrp->version
/// and returns 0 (version query mode).
///
/// Supports v1 (32-bit, single data struct) and v3 (64-bit, two data structs).
/// For v1: returns low 32 bits of each capability set.
/// For v3: returns full 64 bits split across two CapUserData entries.
pub fn sys_capget(hdrp: usize, datap: usize) SyscallError!usize {
    if (hdrp == 0) return error.EFAULT;

    // Read header from userspace
    const hdr_uptr = UserPtr.from(hdrp);
    var hdr = hdr_uptr.readValue(cap_uapi.CapUserHeader) catch return error.EFAULT;

    // Version negotiation: if version is unrecognized, write preferred version and return EINVAL
    const valid_version = switch (hdr.version) {
        cap_uapi._LINUX_CAPABILITY_VERSION_1,
        cap_uapi._LINUX_CAPABILITY_VERSION_2,
        cap_uapi._LINUX_CAPABILITY_VERSION_3,
        => true,
        else => false,
    };

    if (!valid_version) {
        // Write back preferred version so caller knows what to use
        hdr.version = cap_uapi._LINUX_CAPABILITY_VERSION_3;
        hdr_uptr.writeValue(hdr) catch return error.EFAULT;
        return error.EINVAL;
    }

    // If datap is NULL, this is a version query -- return success
    if (datap == 0) return 0;

    // Find target process
    const target_proc = if (hdr.pid == 0)
        base.getCurrentProcess()
    else
        findProcessByPidForCaps(hdr.pid) orelse return error.ESRCH;

    // Read capability sets from target process
    const eff = target_proc.cap_effective;
    const perm = target_proc.cap_permitted;
    const inh = target_proc.cap_inheritable;

    const data_uptr = UserPtr.from(datap);

    if (hdr.version == cap_uapi._LINUX_CAPABILITY_VERSION_1) {
        // v1: single data struct, low 32 bits only
        const data = cap_uapi.CapUserData{
            .effective = @truncate(eff),
            .permitted = @truncate(perm),
            .inheritable = @truncate(inh),
        };
        data_uptr.writeValue(data) catch return error.EFAULT;
    } else {
        // v3 (and v2): two data structs
        // data[0] = low 32 bits, data[1] = high 32 bits
        const data0 = cap_uapi.CapUserData{
            .effective = @truncate(eff),
            .permitted = @truncate(perm),
            .inheritable = @truncate(inh),
        };
        const data1 = cap_uapi.CapUserData{
            .effective = @truncate(eff >> 32),
            .permitted = @truncate(perm >> 32),
            .inheritable = @truncate(inh >> 32),
        };

        data_uptr.writeValue(data0) catch return error.EFAULT;
        // Write second struct at offset sizeof(CapUserData)
        const data1_uptr = UserPtr.from(datap + @sizeOf(cap_uapi.CapUserData));
        data1_uptr.writeValue(data1) catch return error.EFAULT;
    }

    return 0;
}

/// sys_capset (126 on x86_64, 91 on aarch64) - Set process capabilities
///
/// Linux ABI: capset(cap_user_header_t *hdrp, const cap_user_data_t *datap)
///
/// Security rules (matching Linux):
/// 1. Can only modify own capabilities (pid must be 0 or current pid)
/// 2. New effective must be subset of new permitted
/// 3. New permitted must be subset of old permitted (cannot gain caps)
/// 4. New inheritable must be subset of old permitted | old inheritable
///    (on Linux with CAP_SETPCAP; we use the permissive rule since all procs are root)
pub fn sys_capset(hdrp: usize, datap: usize) SyscallError!usize {
    if (hdrp == 0 or datap == 0) return error.EFAULT;

    // Read header
    const hdr_uptr = UserPtr.from(hdrp);
    const hdr = hdr_uptr.readValue(cap_uapi.CapUserHeader) catch return error.EFAULT;

    // Validate version
    const valid_version = switch (hdr.version) {
        cap_uapi._LINUX_CAPABILITY_VERSION_1,
        cap_uapi._LINUX_CAPABILITY_VERSION_2,
        cap_uapi._LINUX_CAPABILITY_VERSION_3,
        => true,
        else => false,
    };
    if (!valid_version) return error.EINVAL;

    // Can only set own capabilities
    const current_proc = base.getCurrentProcess();
    if (hdr.pid != 0 and @as(u32, @bitCast(hdr.pid)) != current_proc.pid) {
        return error.EPERM;
    }

    // Read new capability data
    const data_uptr = UserPtr.from(datap);

    var new_eff: u64 = 0;
    var new_perm: u64 = 0;
    var new_inh: u64 = 0;

    if (hdr.version == cap_uapi._LINUX_CAPABILITY_VERSION_1) {
        const data = data_uptr.readValue(cap_uapi.CapUserData) catch return error.EFAULT;
        new_eff = data.effective;
        new_perm = data.permitted;
        new_inh = data.inheritable;
    } else {
        // v3: two data structs
        const data0 = data_uptr.readValue(cap_uapi.CapUserData) catch return error.EFAULT;
        const data1_uptr = UserPtr.from(datap + @sizeOf(cap_uapi.CapUserData));
        const data1 = data1_uptr.readValue(cap_uapi.CapUserData) catch return error.EFAULT;

        new_eff = @as(u64, data0.effective) | (@as(u64, data1.effective) << 32);
        new_perm = @as(u64, data0.permitted) | (@as(u64, data1.permitted) << 32);
        new_inh = @as(u64, data0.inheritable) | (@as(u64, data1.inheritable) << 32);
    }

    // Mask to valid capability range (bits 0 through CAP_LAST_CAP)
    const cap_mask = cap_uapi.CAP_FULL_SET;
    new_eff &= cap_mask;
    new_perm &= cap_mask;
    new_inh &= cap_mask;

    // Security checks:

    // Rule 1: New effective must be subset of new permitted
    if ((new_eff & ~new_perm) != 0) return error.EPERM;

    // Rule 2: New permitted must be subset of old permitted (cannot gain caps)
    if ((new_perm & ~current_proc.cap_permitted) != 0) return error.EPERM;

    // Rule 3: New inheritable -- on Linux, needs CAP_SETPCAP to add caps to inheritable
    // that are not in permitted. Since our processes run as root (euid=0) with full caps,
    // we use the permissive rule: new_inh must be subset of (old_permitted | old_inheritable).
    if ((new_inh & ~(current_proc.cap_permitted | current_proc.cap_inheritable)) != 0) {
        return error.EPERM;
    }

    // Apply new capabilities
    current_proc.cap_effective = new_eff;
    current_proc.cap_permitted = new_perm;
    current_proc.cap_inheritable = new_inh;

    return 0;
}

/// Find a process by PID for capget cross-process queries.
/// Returns null if the process is not found or not accessible.
fn findProcessByPidForCaps(pid: i32) ?*Process {
    if (pid < 0) return null;

    const target_pid: u32 = @intCast(@as(u32, @bitCast(pid)));
    const current_proc = base.getCurrentProcess();

    // Check if it is our own PID
    if (target_pid == current_proc.pid) return current_proc;

    // Check children (most common cross-process capget use case)
    const held = sched.process_tree_lock.acquireRead();
    defer held.release();

    // Walk the process tree starting from current process's children
    var child = current_proc.first_child;
    while (child) |c| {
        if (c.pid == target_pid) return c;
        child = c.next_sibling;
    }

    // Also check parent
    if (current_proc.parent) |parent| {
        if (parent.pid == target_pid) return parent;
    }

    // Process not found in accessible tree
    return null;
}

// =============================================================================
// Seccomp Syscall Filtering
// =============================================================================

/// sys_seccomp (317 on x86_64, 277 on aarch64) - Install seccomp filters
///
/// Implements Linux-compatible syscall filtering for process sandboxing.
///
/// Modes:
/// - SECCOMP_SET_MODE_STRICT: Only read/write/exit/sigreturn allowed
/// - SECCOMP_SET_MODE_FILTER: Install BPF program to filter syscalls
///
/// Security requirements:
/// - STRICT mode: No special requirements (can be enabled anytime)
/// - FILTER mode: Requires no_new_privs=true OR CAP_SYS_ADMIN
/// - Seccomp cannot be undone once enabled
/// - Filters are inherited across fork
///
/// Returns: 0 on success
pub fn sys_seccomp(op: usize, flags: usize, args_ptr: usize) SyscallError!usize {
    const proc = base.getCurrentProcess();

    switch (op) {
        uapi.seccomp.SECCOMP_SET_MODE_STRICT => {
            // Strict mode: flags and args must be 0
            if (flags != 0 or args_ptr != 0) return error.EINVAL;

            // Once in STRICT mode, cannot change
            if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_STRICT) {
                return 0; // Idempotent
            }

            // Cannot downgrade from FILTER to STRICT
            if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_FILTER) {
                return error.EACCES;
            }

            // Enable strict mode
            proc.seccomp_mode = uapi.seccomp.SECCOMP_MODE_STRICT;
            return 0;
        },

        uapi.seccomp.SECCOMP_SET_MODE_FILTER => {
            // Filter mode requires no_new_privs or CAP_SYS_ADMIN
            if (!proc.no_new_privs) {
                // Check for CAP_SYS_ADMIN (bit 21)
                const CAP_SYS_ADMIN: u64 = 1 << 21;
                if ((proc.cap_effective & CAP_SYS_ADMIN) == 0) {
                    return error.EACCES;
                }
            }

            // Cannot install filters in STRICT mode
            if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_STRICT) {
                return error.EACCES;
            }

            // flags must be 0 for MVP
            if (flags != 0) return error.EINVAL;

            // args_ptr points to SockFprog in userspace
            if (args_ptr == 0) return error.EFAULT;

            // Copy SockFprog header from userspace
            const uptr = UserPtr.from(args_ptr);
            const fprog = uptr.readValue(uapi.seccomp.SockFprog) catch return error.EFAULT;

            // Validate filter length
            if (fprog.len == 0 or fprog.len > uapi.seccomp.BPF_MAXINSNS) {
                return error.EINVAL;
            }

            // Check if we have space for this filter
            const new_count = std.math.add(u16, proc.seccomp_filter_count, fprog.len) catch return error.ENOMEM;
            if (new_count > 256) return error.ENOMEM;

            // Check if we can store another filter program metadata
            if (proc.seccomp_filter_prog_count >= 8) return error.ENOMEM;

            // Copy filter instructions from userspace
            const filter_ptr = UserPtr.from(fprog.filter);
            const filter_size = std.math.mul(usize, @as(usize, fprog.len), @sizeOf(uapi.seccomp.SockFilterInsn)) catch return error.EINVAL;
            if (!isValidUserAccess(fprog.filter, filter_size, .Read)) return error.EFAULT;

            // Copy instructions into our filter array
            const dest_slice = proc.seccomp_filters[proc.seccomp_filter_count..new_count];
            const bytes_to_copy = filter_size;
            const dest_bytes = std.mem.sliceAsBytes(dest_slice);
            _ = filter_ptr.copyToKernel(dest_bytes[0..bytes_to_copy]) catch return error.EFAULT;

            // Update filter metadata
            proc.seccomp_filter_lengths[proc.seccomp_filter_prog_count] = fprog.len;
            proc.seccomp_filter_prog_count += 1;
            proc.seccomp_filter_count = new_count;
            proc.seccomp_mode = uapi.seccomp.SECCOMP_MODE_FILTER;

            return 0;
        },

        uapi.seccomp.SECCOMP_GET_ACTION_AVAIL => {
            // flags must be 0
            if (flags != 0) return error.EINVAL;

            // args_ptr points to u32 action value
            if (args_ptr == 0) return error.EFAULT;

            const uptr = UserPtr.from(args_ptr);
            const action = uptr.readValue(u32) catch return error.EFAULT;

            // Check if action is supported
            const action_code = action & uapi.seccomp.SECCOMP_RET_ACTION_FULL;
            switch (action_code) {
                uapi.seccomp.SECCOMP_RET_KILL_THREAD,
                uapi.seccomp.SECCOMP_RET_KILL_PROCESS,
                uapi.seccomp.SECCOMP_RET_ERRNO,
                uapi.seccomp.SECCOMP_RET_ALLOW,
                => return 0,
                else => return error.EINVAL,
            }
        },

        else => return error.EINVAL,
    }
}

/// Check seccomp filters before syscall dispatch
///
/// Called by dispatch_syscall before executing any syscall handler.
/// Returns a seccomp action code (SECCOMP_RET_*).
///
/// IMPORTANT: This function is called for ALL syscalls including SYS_SECCOMP.
/// In strict mode, seccomp() itself is blocked (only read/write/exit/sigreturn allowed).
pub fn checkSeccomp(proc: *const Process, syscall_num: usize, args: [6]usize) u32 {
    if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_DISABLED) {
        return uapi.seccomp.SECCOMP_RET_ALLOW;
    }

    if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_STRICT) {
        // Strict mode: only read/write/exit/sigreturn allowed
        // Note: We need to check both architectures' syscall numbers
        const builtin = @import("builtin");
        const allowed = switch (builtin.cpu.arch) {
            .x86_64 => (syscall_num == 0 or // read
                syscall_num == 1 or // write
                syscall_num == 60 or // exit
                syscall_num == 231 or // exit_group
                syscall_num == 15), // rt_sigreturn
            .aarch64 => (syscall_num == 63 or // read
                syscall_num == 64 or // write
                syscall_num == 93 or // exit
                syscall_num == 94 or // exit_group
                syscall_num == 139), // rt_sigreturn
            else => false,
        };

        return if (allowed) uapi.seccomp.SECCOMP_RET_ALLOW else uapi.seccomp.SECCOMP_RET_KILL_THREAD;
    }

    if (proc.seccomp_mode == uapi.seccomp.SECCOMP_MODE_FILTER) {
        // Build seccomp_data for BPF filters
        const builtin = @import("builtin");
        const arch: u32 = switch (builtin.cpu.arch) {
            .x86_64 => uapi.seccomp.AUDIT_ARCH_X86_64,
            .aarch64 => uapi.seccomp.AUDIT_ARCH_AARCH64,
            else => 0,
        };

        var data = uapi.seccomp.SeccompData{
            .nr = @intCast(@as(i32, @bitCast(@as(u32, @truncate(syscall_num))))),
            .arch = arch,
            .instruction_pointer = 0, // TODO: Get actual RIP/PC from frame
            .args = args,
        };

        // Run each filter program in the chain
        // The most restrictive result wins (lowest action value)
        var most_restrictive: u32 = uapi.seccomp.SECCOMP_RET_ALLOW;
        var offset: usize = 0;
        var i: usize = 0;
        while (i < proc.seccomp_filter_prog_count) : (i += 1) {
            const filter_len = proc.seccomp_filter_lengths[i];
            const filter = proc.seccomp_filters[offset .. offset + filter_len];
            const result = runBpfFilter(filter, &data);

            // Lower action value = more restrictive
            if (result < most_restrictive) {
                most_restrictive = result;
            }

            offset += filter_len;
        }

        return most_restrictive;
    }

    // Unknown mode: fail secure
    return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
}

/// Classic BPF interpreter for seccomp filters
///
/// Executes a BPF program on the given seccomp_data.
/// Returns a SECCOMP_RET_* action code.
///
/// Security: Fails secure on invalid instructions or out-of-bounds access.
fn runBpfFilter(insns: []const uapi.seccomp.SockFilterInsn, data: *const uapi.seccomp.SeccompData) u32 {
    // BPF registers
    var a: u32 = 0; // Accumulator
    var x: u32 = 0; // Index register
    var mem: [16]u32 = [_]u32{0} ** 16; // Scratch memory

    // Treat seccomp_data as a byte array for BPF_ABS loads
    const data_bytes = std.mem.asBytes(data);
    const data_len = @sizeOf(uapi.seccomp.SeccompData); // 64 bytes

    var pc: usize = 0;
    var steps: usize = 0;
    const max_steps = 4096; // Prevent infinite loops

    while (pc < insns.len and steps < max_steps) : (steps += 1) {
        const insn = insns[pc];
        const code = insn.code;
        const k = insn.k;

        // Extract opcode fields
        const class = code & 0x07;
        const size = code & 0x18;
        const mode = code & 0xe0;
        const op = code & 0xf0;
        const src = code & 0x08;

        if (class == uapi.seccomp.BPF_LD) {
            // Load into A
            if (mode == uapi.seccomp.BPF_ABS) {
                // Load from seccomp_data at absolute offset k
                if (size == uapi.seccomp.BPF_W) {
                    // 32-bit word
                    const offset = k;
                    if (offset + 4 > data_len) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                    a = std.mem.readInt(u32, data_bytes[offset..][0..4], .little);
                } else if (size == uapi.seccomp.BPF_H) {
                    // 16-bit halfword
                    const offset = k;
                    if (offset + 2 > data_len) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                    a = std.mem.readInt(u16, data_bytes[offset..][0..2], .little);
                } else if (size == uapi.seccomp.BPF_B) {
                    // 8-bit byte
                    const offset = k;
                    if (offset + 1 > data_len) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                    a = data_bytes[offset];
                } else {
                    return uapi.seccomp.SECCOMP_RET_KILL_PROCESS; // Invalid size
                }
            } else if (mode == uapi.seccomp.BPF_IMM) {
                // Load immediate value
                a = k;
            } else if (mode == uapi.seccomp.BPF_MEM) {
                // Load from scratch memory
                if (k >= 16) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                a = mem[k];
            } else if (mode == uapi.seccomp.BPF_LEN) {
                // Load packet length
                a = data_len;
            } else {
                return uapi.seccomp.SECCOMP_RET_KILL_PROCESS; // Invalid mode
            }
        } else if (class == uapi.seccomp.BPF_LDX) {
            // Load into X
            if (mode == uapi.seccomp.BPF_IMM) {
                x = k;
            } else if (mode == uapi.seccomp.BPF_MEM) {
                if (k >= 16) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                x = mem[k];
            } else if (mode == uapi.seccomp.BPF_LEN) {
                x = data_len;
            } else {
                return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            }
        } else if (class == uapi.seccomp.BPF_ST) {
            // Store A to scratch memory
            if (k >= 16) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            mem[k] = a;
        } else if (class == uapi.seccomp.BPF_STX) {
            // Store X to scratch memory
            if (k >= 16) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            mem[k] = x;
        } else if (class == uapi.seccomp.BPF_ALU) {
            // Arithmetic/logic operations
            const operand = if (src == uapi.seccomp.BPF_K) k else x;

            if (op == uapi.seccomp.BPF_ADD) {
                a = a +% operand;
            } else if (op == uapi.seccomp.BPF_SUB) {
                a = a -% operand;
            } else if (op == uapi.seccomp.BPF_MUL) {
                a = a *% operand;
            } else if (op == uapi.seccomp.BPF_DIV) {
                if (operand == 0) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                a = a / operand;
            } else if (op == uapi.seccomp.BPF_MOD) {
                if (operand == 0) return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
                a = a % operand;
            } else if (op == uapi.seccomp.BPF_OR) {
                a = a | operand;
            } else if (op == uapi.seccomp.BPF_AND) {
                a = a & operand;
            } else if (op == uapi.seccomp.BPF_LSH) {
                a = a << @intCast(operand);
            } else if (op == uapi.seccomp.BPF_RSH) {
                a = a >> @intCast(operand);
            } else if (op == uapi.seccomp.BPF_XOR) {
                a = a ^ operand;
            } else if (op == uapi.seccomp.BPF_NEG) {
                a = -%a;
            } else {
                return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            }
        } else if (class == uapi.seccomp.BPF_JMP) {
            // Jump instructions
            if (op == uapi.seccomp.BPF_JA) {
                // Unconditional jump
                pc +%= k;
                pc += 1;
                continue;
            }

            // Conditional jumps
            const operand = if (src == uapi.seccomp.BPF_K) k else x;
            var take_jump = false;

            if (op == uapi.seccomp.BPF_JEQ) {
                take_jump = (a == operand);
            } else if (op == uapi.seccomp.BPF_JGT) {
                take_jump = (a > operand);
            } else if (op == uapi.seccomp.BPF_JGE) {
                take_jump = (a >= operand);
            } else if (op == uapi.seccomp.BPF_JSET) {
                take_jump = ((a & operand) != 0);
            } else {
                return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            }

            if (take_jump) {
                pc +%= insn.jt;
            } else {
                pc +%= insn.jf;
            }
            pc += 1;
            continue;
        } else if (class == uapi.seccomp.BPF_RET) {
            // Return action value
            const ret_val = if (mode == uapi.seccomp.BPF_K) k else a;
            return ret_val;
        } else if (class == uapi.seccomp.BPF_MISC) {
            // Register transfer
            if (code == uapi.seccomp.BPF_MISC | uapi.seccomp.BPF_TAX) {
                x = a;
            } else if (code == uapi.seccomp.BPF_MISC | uapi.seccomp.BPF_TXA) {
                a = x;
            } else {
                return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
            }
        } else {
            // Invalid instruction class
            return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
        }

        pc += 1;
    }

    // Exceeded max steps or fell off end of program: fail secure
    return uapi.seccomp.SECCOMP_RET_KILL_PROCESS;
}
