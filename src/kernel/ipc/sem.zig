const std = @import("std");
const process = @import("process");
const hal = @import("hal");
const ipc_perm = @import("ipc_perm.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const sync = @import("sync");
const sched = @import("sched");

const IPC_PRIVATE = uapi.ipc.sysv.IPC_PRIVATE;
const IPC_CREAT = uapi.ipc.sysv.IPC_CREAT;
const IPC_EXCL = uapi.ipc.sysv.IPC_EXCL;
const IPC_NOWAIT = uapi.ipc.sysv.IPC_NOWAIT;
const IPC_RMID = uapi.ipc.sysv.IPC_RMID;
const IPC_STAT = uapi.ipc.sysv.IPC_STAT;
const IPC_SET = uapi.ipc.sysv.IPC_SET;
const SEMMNI = uapi.ipc.sysv.SEMMNI;
const SEMMSL = uapi.ipc.sysv.SEMMSL;
const SEMVMX = uapi.ipc.sysv.SEMVMX;
const SETVAL = uapi.ipc.sysv.SETVAL;
const GETVAL = uapi.ipc.sysv.GETVAL;
const SemidDs = uapi.ipc.sysv.SemidDs;
const SemBuf = uapi.ipc.sysv.SemBuf;
const IpcPermUser = uapi.ipc.sysv.IpcPermUser;
const user_mem = @import("user_mem");

const Semaphore = struct {
    semval: u32,
    sempid: u32, // PID of last semop
};

const SemSet = struct {
    id: u32,
    key: i32,
    perm: ipc_perm.IpcPerm,
    nsems: u32,
    sems: ?[*]Semaphore, // Heap-allocated array
    otime: i64,
    ctime: i64,
    in_use: bool,
    wait_queue: sched.WaitQueue = .{},
};

var sem_sets: [SEMMNI]SemSet = [_]SemSet{.{
    .id = 0,
    .key = 0,
    .perm = .{ .key = 0, .cuid = 0, .cgid = 0, .uid = 0, .gid = 0, .mode = 0, .seq = 0 },
    .nsems = 0,
    .sems = null,
    .otime = 0,
    .ctime = 0,
    .in_use = false,
    .wait_queue = .{},
}} ** SEMMNI;

var sem_lock: sync.Spinlock = .{};
var sem_seq: u16 = 0;

fn getCurrentTime() i64 {
    // Simplified: return 0 for MVP
    return 0;
}

/// Record a SEM_UNDO adjustment for a process
fn recordSemUndo(proc: *process.Process, semid: u32, sem_num: u16, adjustment: i32) void {
    // Search for existing entry
    for (proc.sem_undo_entries[0..proc.sem_undo_count]) |*e| {
        if (e.semid == semid and e.sem_num == sem_num) {
            e.adjustment +|= adjustment; // Saturating add to prevent overflow
            return;
        }
    }

    // Add new entry
    if (proc.sem_undo_count < process.MAX_SEM_UNDO) {
        proc.sem_undo_entries[proc.sem_undo_count] = .{
            .semid = semid,
            .sem_num = sem_num,
            .adjustment = adjustment,
        };
        proc.sem_undo_count += 1;
    }
    // If full, silently drop (POSIX allows this)
}

pub fn semget(key: i32, nsems: u32, flags: i32, proc: *const process.Process) !u32 {
    // Validate nsems
    if (nsems == 0) return error.EINVAL;
    if (nsems > SEMMSL) return error.EINVAL;

    const held = sem_lock.acquire();
    defer held.release();

    // IPC_PRIVATE always creates a new set
    if (key != IPC_PRIVATE) {
        // Search for existing set with this key
        for (&sem_sets) |*set| {
            if (set.in_use and set.key == key) {
                // Found existing set
                if ((flags & IPC_EXCL) != 0 and (flags & IPC_CREAT) != 0) {
                    return error.EEXIST;
                }
                // Check nsems compatibility
                if (nsems != 0 and nsems > set.nsems) {
                    return error.EINVAL;
                }
                // Check read permission
                if (!ipc_perm.checkAccess(&set.perm, proc, .read)) {
                    return error.EACCES;
                }
                return set.id;
            }
        }
    }

    // Not found or IPC_PRIVATE - create new set if IPC_CREAT is set
    if ((flags & IPC_CREAT) == 0 and key != IPC_PRIVATE) {
        return error.ENOENT;
    }

    // Find free slot
    var free_idx: ?usize = null;
    for (&sem_sets, 0..) |*set, i| {
        if (!set.in_use) {
            free_idx = i;
            break;
        }
    }

    const idx = free_idx orelse return error.ENOSPC;

    // Allocate semaphore array
    const sems_slice = heap.allocator().alloc(Semaphore, nsems) catch return error.ENOMEM;
    errdefer heap.allocator().free(sems_slice);

    // Zero-initialize semaphores
    @memset(sems_slice, .{ .semval = 0, .sempid = 0 });

    // Bump sequence number
    sem_seq +%= 1;

    // Fill metadata
    var set = &sem_sets[idx];
    set.id = ipc_perm.makeId(idx, sem_seq);
    set.key = key;
    set.perm = .{
        .key = key,
        .cuid = proc.euid,
        .cgid = proc.egid,
        .uid = proc.euid,
        .gid = proc.egid,
        .mode = @as(u16, @intCast(flags & 0o777)),
        .seq = sem_seq,
    };
    set.nsems = nsems;
    set.sems = sems_slice.ptr;
    set.otime = 0;
    set.ctime = getCurrentTime();
    set.in_use = true;

    return set.id;
}

pub fn semop(id: u32, sops: []const SemBuf, proc: *process.Process) !void {
    while (true) {
        const held = sem_lock.acquire();

        // Find sem set by ID (must re-validate after wakeup)
        const idx = ipc_perm.idToIndex(id);
        const seq = ipc_perm.idToSeq(id);

        if (idx >= SEMMNI) {
            held.release();
            return error.EINVAL;
        }

        const set = &sem_sets[idx];
        if (!set.in_use or set.perm.seq != seq) {
            held.release();
            return error.EIDRM;
        }

        // Validate all operations
        for (sops) |sop| {
            if (sop.sem_num >= set.nsems) {
                held.release();
                return error.EFBIG;
            }

            // Check permission: sem_op >= 0 needs write, < 0 needs read
            const mode: ipc_perm.AccessMode = if (sop.sem_op >= 0) .write else .read;
            if (!ipc_perm.checkAccess(&set.perm, proc, mode)) {
                held.release();
                return error.EACCES;
            }
        }

        const sems = set.sems orelse {
            held.release();
            return error.EINVAL;
        };

        // Check if all operations can proceed
        var would_block = false;
        for (sops) |sop| {
            const sem = &sems[sop.sem_num];

            if (sop.sem_op < 0) {
                // Decrement operation
                const decr = @as(u32, @intCast(-sop.sem_op));
                if (sem.semval < decr) {
                    would_block = true;
                    break;
                }
            } else if (sop.sem_op == 0) {
                // Wait for zero
                if (sem.semval != 0) {
                    would_block = true;
                    break;
                }
            }
            // sem_op > 0 never blocks
        }

        if (would_block) {
            // Check for IPC_NOWAIT flag
            var nowait = false;
            for (sops) |sop| {
                if ((sop.sem_flg & IPC_NOWAIT) != 0) {
                    nowait = true;
                    break;
                }
            }

            if (nowait) {
                held.release();
                return error.EAGAIN;
            } else {
                // Block on wait queue
                sched.waitOn(&set.wait_queue, held);
                continue; // Retry from beginning
            }
        }

        // All operations can proceed - apply them atomically
        var any_increment = false;
        for (sops) |sop| {
            const sem = &sems[sop.sem_num];

            if (sop.sem_op < 0) {
                const decr = @as(u32, @intCast(-sop.sem_op));
                sem.semval -= decr;
            } else if (sop.sem_op > 0) {
                const incr = @as(u32, @intCast(sop.sem_op));
                sem.semval += incr;
                any_increment = true;
            }
            // Update last PID
            sem.sempid = proc.pid;

            // Record SEM_UNDO if flag is set
            if ((sop.sem_flg & uapi.ipc.sysv.SEM_UNDO) != 0) {
                const adj = -@as(i32, sop.sem_op);
                recordSemUndo(proc, id, sop.sem_num, adj);
            }
        }

        set.otime = getCurrentTime();

        // Wake waiting threads if we incremented any semaphore
        if (any_increment) {
            _ = set.wait_queue.wakeUp(set.wait_queue.count);
        }

        held.release();
        return;
    }
}

pub fn semctl(id: u32, semnum: u32, cmd: i32, arg: usize, proc: *const process.Process) !usize {
    const held = sem_lock.acquire();
    defer held.release();

    // Find sem set by ID
    const idx = ipc_perm.idToIndex(id);
    const seq = ipc_perm.idToSeq(id);

    if (idx >= SEMMNI) return error.EINVAL;

    const set = &sem_sets[idx];
    if (!set.in_use or set.perm.seq != seq) return error.EINVAL;

    switch (cmd) {
        IPC_STAT => {
            // Check read permission
            if (!ipc_perm.checkAccess(&set.perm, proc, .read)) {
                return error.EACCES;
            }

            // Fill SemidDs structure
            const ds = SemidDs{
                .sem_perm = .{
                    .key = set.perm.key,
                    .uid = set.perm.uid,
                    .gid = set.perm.gid,
                    .cuid = set.perm.cuid,
                    .cgid = set.perm.cgid,
                    .mode = set.perm.mode,
                    .seq = set.perm.seq,
                },
                .sem_otime = set.otime,
                .sem_ctime = set.ctime,
                .sem_nsems = set.nsems,
            };

            // Copy to userspace
            const user_ptr = user_mem.UserPtr.from(arg);
            _ = user_ptr.writeValue(ds) catch return error.EFAULT;

            return 0;
        },
        IPC_SET => {
            // Check isOwnerOrCreator
            if (!ipc_perm.isOwnerOrCreator(&set.perm, proc.euid)) {
                return error.EPERM;
            }

            // Read from userspace
            const user_ptr = user_mem.UserPtr.from(arg);
            const ds = user_ptr.readValue(SemidDs) catch return error.EFAULT;

            // Update uid/gid/mode
            set.perm.uid = ds.sem_perm.uid;
            set.perm.gid = ds.sem_perm.gid;
            set.perm.mode = ds.sem_perm.mode & 0o777;
            set.ctime = getCurrentTime();

            return 0;
        },
        IPC_RMID => {
            // Check isOwnerOrCreator
            if (!ipc_perm.isOwnerOrCreator(&set.perm, proc.euid)) {
                return error.EPERM;
            }

            // Free semaphore array
            if (set.sems) |sems_ptr| {
                const sems_slice = sems_ptr[0..set.nsems];
                heap.allocator().free(sems_slice);
            }

            // Clear slot
            set.in_use = false;
            set.sems = null;

            // Wake all waiting threads (they will get EIDRM on retry)
            _ = set.wait_queue.wakeUp(std.math.maxInt(usize));

            return 0;
        },
        SETVAL => {
            // Validate semnum
            if (semnum >= set.nsems) return error.ERANGE;

            // Check write permission
            if (!ipc_perm.checkAccess(&set.perm, proc, .write)) {
                return error.EACCES;
            }

            // Validate value
            if (arg > SEMVMX) return error.ERANGE;

            const sems = set.sems orelse return error.EINVAL;
            sems[semnum].semval = @intCast(arg);
            set.ctime = getCurrentTime();

            // Wake one waiting thread to re-check
            _ = set.wait_queue.wakeUp(1);

            return 0;
        },
        GETVAL => {
            // Validate semnum
            if (semnum >= set.nsems) return error.ERANGE;

            // Check read permission
            if (!ipc_perm.checkAccess(&set.perm, proc, .read)) {
                return error.EACCES;
            }

            const sems = set.sems orelse return error.EINVAL;
            return @as(usize, sems[semnum].semval);
        },
        else => return error.EINVAL,
    }
}

/// Apply SEM_UNDO adjustments when a process exits
pub fn applySemUndo(proc: *process.Process) void {
    const held = sem_lock.acquire();
    defer held.release();

    for (proc.sem_undo_entries[0..proc.sem_undo_count]) |entry| {
        if (entry.adjustment == 0) continue;

        const idx = ipc_perm.idToIndex(entry.semid);
        const seq = ipc_perm.idToSeq(entry.semid);
        if (idx >= SEMMNI) continue;

        const set = &sem_sets[idx];
        if (!set.in_use or set.perm.seq != seq) continue;

        const sems = set.sems orelse continue;
        if (entry.sem_num >= set.nsems) continue;

        const sem = &sems[entry.sem_num];
        // Apply undo: add adjustment to current value
        if (entry.adjustment > 0) {
            sem.semval +|= @intCast(entry.adjustment); // saturating add
        } else {
            const sub = @as(u32, @intCast(-entry.adjustment));
            if (sem.semval >= sub) {
                sem.semval -= sub;
            } else {
                sem.semval = 0; // Clamp to 0
            }
        }
        // Wake waiters since semaphore value changed
        _ = set.wait_queue.wakeUp(set.wait_queue.count);
    }

    proc.sem_undo_count = 0;
}
