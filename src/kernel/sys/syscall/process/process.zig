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
            .rlim_cur = DEFAULT_STACK_LIMIT,
            .rlim_max = RLIM_INFINITY,
        },
        RLIMIT_NOFILE => .{
            .rlim_cur = DEFAULT_NOFILE_SOFT,
            .rlim_max = DEFAULT_NOFILE_HARD,
        },
        RLIMIT_NPROC => .{
            // No per-user process limit enforced yet
            .rlim_cur = RLIM_INFINITY,
            .rlim_max = RLIM_INFINITY,
        },
        RLIMIT_CORE => .{
            // Core dumps not implemented
            .rlim_cur = 0,
            .rlim_max = RLIM_INFINITY,
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
        RLIMIT_CORE => {
            // Accept but don't enforce (no core dumps implemented)
        },
        RLIMIT_STACK, RLIMIT_NOFILE, RLIMIT_NPROC => {
            // Accept the values but don't store them yet (would need process struct fields)
            // Non-root cannot raise above hard limit, but we don't track hard limits per-process
            if (proc.euid != 0) {
                // For now, non-root can only set to existing defaults or lower
            }
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
                .rlim_cur = DEFAULT_STACK_LIMIT,
                .rlim_max = RLIM_INFINITY,
            },
            RLIMIT_NOFILE => .{
                .rlim_cur = DEFAULT_NOFILE_SOFT,
                .rlim_max = DEFAULT_NOFILE_HARD,
            },
            RLIMIT_NPROC => .{
                .rlim_cur = RLIM_INFINITY,
                .rlim_max = RLIM_INFINITY,
            },
            RLIMIT_CORE => .{
                .rlim_cur = 0,
                .rlim_max = RLIM_INFINITY,
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
            RLIMIT_STACK, RLIMIT_NOFILE, RLIMIT_NPROC, RLIMIT_CORE, RLIMIT_CPU, RLIMIT_FSIZE, RLIMIT_DATA, RLIMIT_RSS, RLIMIT_MEMLOCK, RLIMIT_LOCKS, RLIMIT_SIGPENDING, RLIMIT_MSGQUEUE, RLIMIT_NICE, RLIMIT_RTPRIO, RLIMIT_RTTIME => {
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
