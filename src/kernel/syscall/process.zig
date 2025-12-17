// Process Control Syscall Handlers
//
// Implements process lifecycle and identity syscalls:
// - sys_exit, sys_exit_group: Process termination
// - sys_wait4: Wait for child process state changes
// - sys_getpid, sys_getppid: Process identity
// - sys_getuid, sys_getgid: User/group identity (always root for MVP)

const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const hal = @import("hal");
const sched = @import("sched");
const process_mod = @import("process");

const SyscallError = base.SyscallError;
const Process = base.Process;
const UserPtr = base.UserPtr;

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
                // pid = -1: wait for any child
                // pid > 0: wait for specific child
                // pid = 0: wait for process group (not implemented, treat as -1)
                // pid < -1: wait for process group -pid (not implemented)
                const matches = if (target_pid == -1) true else if (target_pid > 0) (c.pid == @as(u32, @intCast(target_pid))) else true; // MVP fallback

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
        sched.block();
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

/// sys_getuid (102) - Get user ID
///
/// MVP: Always returns 0 (root).
pub fn sys_getuid() SyscallError!usize {
    return 0;
}

/// sys_getgid (104) - Get group ID
///
/// MVP: Always returns 0 (root group).
pub fn sys_getgid() SyscallError!usize {
    return 0;
}

/// sys_setuid (105) - Set user ID
///
/// MVP: Stub - always succeeds (single-user system)
pub fn sys_setuid(uid: usize) SyscallError!usize {
    _ = uid;
    return 0;
}

/// sys_setgid (106) - Set group ID
///
/// MVP: Stub - always succeeds (single-user system)
pub fn sys_setgid(gid: usize) SyscallError!usize {
    _ = gid;
    return 0;
}

/// sys_geteuid (107) - Get effective user ID
///
/// MVP: Always returns 0 (root).
pub fn sys_geteuid() SyscallError!usize {
    return 0;
}

/// sys_getegid (108) - Get effective group ID
///
/// MVP: Always returns 0 (root group).
pub fn sys_getegid() SyscallError!usize {
    return 0;
}

/// sys_umask (95) - Set file creation mask
///
/// MVP: Stub - stores mask but not enforced
var current_umask: u32 = 0o022; // Default umask
pub fn sys_umask(mask: usize) SyscallError!usize {
    const old_mask = current_umask;
    current_umask = @truncate(mask & 0o777);
    return old_mask;
}

/// sys_getrlimit (97) - Get resource limits
///
/// MVP: Returns unlimited for most resources
pub fn sys_getrlimit(resource: usize, rlim_ptr: usize) SyscallError!usize {
    _ = resource;
    if (rlim_ptr == 0) return error.EFAULT;

    // rlimit struct: { rlim_cur: u64, rlim_max: u64 }
    const RLIM_INFINITY: u64 = @bitCast(@as(i64, -1));
    const rlimit = [2]u64{ RLIM_INFINITY, RLIM_INFINITY };

    const uptr = UserPtr.from(rlim_ptr);
    _ = uptr.copyFromKernel(@as(*const [16]u8, @ptrCast(&rlimit))) catch {
        return error.EFAULT;
    };
    return 0;
}

/// sys_setrlimit (160) - Set resource limits
///
/// MVP: Stub - accepts but ignores
pub fn sys_setrlimit(resource: usize, rlim_ptr: usize) SyscallError!usize {
    _ = resource;
    _ = rlim_ptr;
    return 0;
}

/// sys_uname (63) - Get system information
///
/// Returns system name, node name, release, version, machine
pub fn sys_uname(buf_ptr: usize) SyscallError!usize {
    if (buf_ptr == 0) return error.EFAULT;

    // utsname struct: 5 fields of 65 bytes each = 325 bytes
    // Linux uses _UTSNAME_LENGTH = 65
    const UTSNAME_LEN = 65;
    var utsname: [5 * UTSNAME_LEN]u8 = [_]u8{0} ** (5 * UTSNAME_LEN);

    // sysname
    const sysname = "Zscapek";
    @memcpy(utsname[0..sysname.len], sysname);

    // nodename
    const nodename = "localhost";
    @memcpy(utsname[UTSNAME_LEN .. UTSNAME_LEN + nodename.len], nodename);

    // release
    const release = "0.1.0";
    @memcpy(utsname[2 * UTSNAME_LEN .. 2 * UTSNAME_LEN + release.len], release);

    // version
    const version = "#1 SMP";
    @memcpy(utsname[3 * UTSNAME_LEN .. 3 * UTSNAME_LEN + version.len], version);

    // machine
    const machine = "x86_64";
    @memcpy(utsname[4 * UTSNAME_LEN .. 4 * UTSNAME_LEN + machine.len], machine);

    const uptr = UserPtr.from(buf_ptr);
    _ = uptr.copyFromKernel(&utsname) catch {
        return error.EFAULT;
    };
    return 0;
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
