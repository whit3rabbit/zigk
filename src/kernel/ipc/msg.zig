const std = @import("std");
const process = @import("process");
const hal = @import("hal");
const ipc_perm = @import("ipc_perm.zig");
const uapi = @import("uapi");
const heap = @import("heap");
const user_mem = @import("user_mem");
const sync = @import("sync");
const sched = @import("sched");

const IPC_PRIVATE = uapi.ipc.sysv.IPC_PRIVATE;
const IPC_CREAT = uapi.ipc.sysv.IPC_CREAT;
const IPC_EXCL = uapi.ipc.sysv.IPC_EXCL;
const IPC_NOWAIT = uapi.ipc.sysv.IPC_NOWAIT;
const IPC_RMID = uapi.ipc.sysv.IPC_RMID;
const IPC_STAT = uapi.ipc.sysv.IPC_STAT;
const IPC_SET = uapi.ipc.sysv.IPC_SET;
const MSGMNI = uapi.ipc.sysv.MSGMNI;
const MSGMAX = uapi.ipc.sysv.MSGMAX;
const MSGMNB = uapi.ipc.sysv.MSGMNB;
const MsqidDs = uapi.ipc.sysv.MsqidDs;
const MsgBufHeader = uapi.ipc.sysv.MsgBufHeader;
const IpcPermUser = uapi.ipc.sysv.IpcPermUser;

// MSG_NOERROR flag - truncate message instead of returning E2BIG
const MSG_NOERROR: i32 = 0o10000;

const KernelMsg = struct {
    mtype: i64,
    data: []u8, // Heap-allocated
    next: ?*KernelMsg,
};

const MsgQueue = struct {
    id: u32,
    key: i32,
    perm: ipc_perm.IpcPerm,
    head: ?*KernelMsg,
    tail: ?*KernelMsg,
    qnum: usize, // Message count
    qbytes: usize, // Current bytes
    qbytes_max: usize, // Limit
    lspid: u32,
    lrpid: u32,
    stime: i64,
    rtime: i64,
    ctime: i64,
    in_use: bool,
    send_wait_queue: sched.WaitQueue = .{},
    recv_wait_queue: sched.WaitQueue = .{},
};

var queues: [MSGMNI]MsgQueue = [_]MsgQueue{.{
    .id = 0,
    .key = 0,
    .perm = .{ .key = 0, .cuid = 0, .cgid = 0, .uid = 0, .gid = 0, .mode = 0, .seq = 0 },
    .head = null,
    .tail = null,
    .qnum = 0,
    .qbytes = 0,
    .qbytes_max = MSGMNB,
    .lspid = 0,
    .lrpid = 0,
    .stime = 0,
    .rtime = 0,
    .ctime = 0,
    .in_use = false,
    .send_wait_queue = .{},
    .recv_wait_queue = .{},
}} ** MSGMNI;

var msg_lock: sync.Spinlock = .{};
var msg_seq: u16 = 0;

fn getCurrentTime() i64 {
    // Simplified: return 0 for MVP
    return 0;
}

pub fn msgget(key: i32, flags: i32, proc: *const process.Process) !u32 {
    const held = msg_lock.acquire();
    defer held.release();

    // IPC_PRIVATE always creates a new queue
    if (key != IPC_PRIVATE) {
        // Search for existing queue with this key
        for (&queues) |*q| {
            if (q.in_use and q.key == key) {
                // Found existing queue
                if ((flags & IPC_EXCL) != 0 and (flags & IPC_CREAT) != 0) {
                    return error.EEXIST;
                }
                // Check read permission
                if (!ipc_perm.checkAccess(&q.perm, proc, .read)) {
                    return error.EACCES;
                }
                return q.id;
            }
        }
    }

    // Not found or IPC_PRIVATE - create new queue if IPC_CREAT is set
    if ((flags & IPC_CREAT) == 0 and key != IPC_PRIVATE) {
        return error.ENOENT;
    }

    // Find free slot
    var free_idx: ?usize = null;
    for (&queues, 0..) |*q, i| {
        if (!q.in_use) {
            free_idx = i;
            break;
        }
    }

    const idx = free_idx orelse return error.ENOSPC;

    // Bump sequence number
    msg_seq +%= 1;

    // Fill metadata
    var q = &queues[idx];
    q.id = ipc_perm.makeId(idx, msg_seq);
    q.key = key;
    q.perm = .{
        .key = key,
        .cuid = proc.euid,
        .cgid = proc.egid,
        .uid = proc.euid,
        .gid = proc.egid,
        .mode = @as(u16, @intCast(flags & 0o777)),
        .seq = msg_seq,
    };
    q.head = null;
    q.tail = null;
    q.qnum = 0;
    q.qbytes = 0;
    q.qbytes_max = MSGMNB;
    q.lspid = 0;
    q.lrpid = 0;
    q.stime = 0;
    q.rtime = 0;
    q.ctime = getCurrentTime();
    q.in_use = true;

    return q.id;
}

pub fn msgsnd(id: u32, msgp: usize, msgsz: usize, msgflg: i32, proc: *const process.Process) !void {
    // Validate size
    if (msgsz > MSGMAX) return error.EINVAL;

    // Copy message from userspace BEFORE acquiring lock (to avoid holding spinlock during page faults)
    const user_ptr = user_mem.UserPtr.from(msgp);
    const header = user_ptr.readValue(MsgBufHeader) catch return error.EFAULT;

    // Validate mtype > 0
    if (header.mtype <= 0) return error.EINVAL;

    // Allocate and copy data
    const data = heap.allocator().alloc(u8, msgsz) catch return error.ENOMEM;
    errdefer heap.allocator().free(data);

    const data_ptr = user_mem.UserPtr.from(msgp + @sizeOf(MsgBufHeader));
    _ = data_ptr.copyToKernel(data) catch {
        heap.allocator().free(data);
        return error.EFAULT;
    };

    // Now enter the retry loop with lock
    while (true) {
        const held = msg_lock.acquire();

        // Find queue by ID (must re-validate after wakeup)
        const idx = ipc_perm.idToIndex(id);
        const seq = ipc_perm.idToSeq(id);

        if (idx >= MSGMNI) {
            held.release();
            heap.allocator().free(data);
            return error.EINVAL;
        }

        const q = &queues[idx];
        if (!q.in_use or q.perm.seq != seq) {
            held.release();
            heap.allocator().free(data);
            return error.EIDRM;
        }

        // Check write permission
        if (!ipc_perm.checkAccess(&q.perm, proc, .write)) {
            held.release();
            heap.allocator().free(data);
            return error.EACCES;
        }

        // Check queue capacity
        if (q.qbytes + msgsz > q.qbytes_max) {
            if ((msgflg & IPC_NOWAIT) != 0) {
                held.release();
                heap.allocator().free(data);
                return error.EAGAIN;
            } else {
                // Block on send wait queue
                sched.waitOn(&q.send_wait_queue, held);
                continue; // Retry
            }
        }

        // Capacity available - allocate KernelMsg and enqueue
        const msg = heap.allocator().create(KernelMsg) catch {
            held.release();
            heap.allocator().free(data);
            return error.ENOMEM;
        };

        msg.mtype = header.mtype;
        msg.data = data;
        msg.next = null;

        // Append to tail
        if (q.tail) |tail| {
            tail.next = msg;
        } else {
            q.head = msg;
        }
        q.tail = msg;

        q.qnum += 1;
        q.qbytes += msgsz;
        q.lspid = proc.pid;
        q.stime = getCurrentTime();

        // Wake one receiver
        _ = q.recv_wait_queue.wakeUp(1);

        held.release();
        return;
    }
}

pub fn msgrcv(id: u32, msgp: usize, msgsz: usize, msgtyp: i64, msgflg: i32, proc: *const process.Process) !usize {
    while (true) {
        const held = msg_lock.acquire();

        // Find queue by ID (must re-validate after wakeup)
        const idx = ipc_perm.idToIndex(id);
        const seq = ipc_perm.idToSeq(id);

        if (idx >= MSGMNI) {
            held.release();
            return error.EINVAL;
        }

        const q = &queues[idx];
        if (!q.in_use or q.perm.seq != seq) {
            held.release();
            return error.EIDRM;
        }

        // Check read permission
        if (!ipc_perm.checkAccess(&q.perm, proc, .read)) {
            held.release();
            return error.EACCES;
        }

        // Search for matching message
        var prev: ?*KernelMsg = null;
        var curr = q.head;

        while (curr) |msg| {
            const matches = if (msgtyp == 0) true // Any type
            else if (msgtyp > 0) msg.mtype == msgtyp // Exact match
            else msg.mtype <= -msgtyp; // Lowest mtype <= |msgtyp|

            if (matches) {
                // Found matching message - remove from list
                if (prev) |p| {
                    p.next = msg.next;
                } else {
                    q.head = msg.next;
                }

                if (q.tail == msg) {
                    q.tail = prev;
                }

                const actual_size = msg.data.len;

                // Check if message too large
                if (actual_size > msgsz) {
                    if ((msgflg & MSG_NOERROR) == 0) {
                        // Put message back at front
                        msg.next = q.head;
                        q.head = msg;
                        if (q.tail == null) q.tail = msg;
                        held.release();
                        return error.E2BIG;
                    }
                    // Truncate message
                }

                // Copy to userspace
                const user_ptr = user_mem.UserPtr.from(msgp);

                // Write header (mtype)
                const header = MsgBufHeader{ .mtype = msg.mtype };
                _ = user_ptr.writeValue(header) catch {
                    // Put message back
                    msg.next = q.head;
                    q.head = msg;
                    if (q.tail == null) q.tail = msg;
                    held.release();
                    return error.EFAULT;
                };

                // Write data (min of actual_size and msgsz)
                const copy_size = @min(actual_size, msgsz);
                const data_ptr = user_mem.UserPtr.from(msgp + @sizeOf(MsgBufHeader));
                _ = data_ptr.copyFromKernel(msg.data[0..copy_size]) catch {
                    // Put message back
                    msg.next = q.head;
                    q.head = msg;
                    if (q.tail == null) q.tail = msg;
                    held.release();
                    return error.EFAULT;
                };

                // Update queue metadata
                q.qnum -= 1;
                q.qbytes -= actual_size;
                q.lrpid = proc.pid;
                q.rtime = getCurrentTime();

                // Wake one sender since space is now available
                _ = q.send_wait_queue.wakeUp(1);

                // Free message
                heap.allocator().free(msg.data);
                heap.allocator().destroy(msg);

                held.release();
                return copy_size;
            }

            prev = msg;
            curr = msg.next;
        }

        // No matching message found
        if ((msgflg & IPC_NOWAIT) != 0) {
            held.release();
            return error.ENOMSG;
        } else {
            // Block on receive wait queue
            sched.waitOn(&q.recv_wait_queue, held);
            continue; // Retry
        }
    }
}

pub fn msgctl(id: u32, cmd: i32, buf_ptr: usize, proc: *const process.Process) !usize {
    const held = msg_lock.acquire();
    defer held.release();

    // Find queue by ID
    const idx = ipc_perm.idToIndex(id);
    const seq = ipc_perm.idToSeq(id);

    if (idx >= MSGMNI) return error.EINVAL;

    const q = &queues[idx];
    if (!q.in_use or q.perm.seq != seq) return error.EINVAL;

    switch (cmd) {
        IPC_STAT => {
            // Check read permission
            if (!ipc_perm.checkAccess(&q.perm, proc, .read)) {
                return error.EACCES;
            }

            // Fill MsqidDs structure
            const ds = MsqidDs{
                .msg_perm = .{
                    .key = q.perm.key,
                    .uid = q.perm.uid,
                    .gid = q.perm.gid,
                    .cuid = q.perm.cuid,
                    .cgid = q.perm.cgid,
                    .mode = q.perm.mode,
                    .seq = q.perm.seq,
                },
                .msg_stime = q.stime,
                .msg_rtime = q.rtime,
                .msg_ctime = q.ctime,
                .msg_cbytes = q.qbytes,
                .msg_qnum = q.qnum,
                .msg_qbytes = q.qbytes_max,
                .msg_lspid = q.lspid,
                .msg_lrpid = q.lrpid,
            };

            // Copy to userspace
            const user_ptr = user_mem.UserPtr.from(buf_ptr);
            _ = user_ptr.writeValue(ds) catch return error.EFAULT;

            return 0;
        },
        IPC_SET => {
            // Check isOwnerOrCreator
            if (!ipc_perm.isOwnerOrCreator(&q.perm, proc.euid)) {
                return error.EPERM;
            }

            // Read from userspace
            const user_ptr = user_mem.UserPtr.from(buf_ptr);
            const ds = user_ptr.readValue(MsqidDs) catch return error.EFAULT;

            // Update uid/gid/mode/qbytes_max
            q.perm.uid = ds.msg_perm.uid;
            q.perm.gid = ds.msg_perm.gid;
            q.perm.mode = ds.msg_perm.mode & 0o777;
            q.qbytes_max = ds.msg_qbytes;
            q.ctime = getCurrentTime();

            return 0;
        },
        IPC_RMID => {
            // Check isOwnerOrCreator
            if (!ipc_perm.isOwnerOrCreator(&q.perm, proc.euid)) {
                return error.EPERM;
            }

            // Free all queued messages
            var curr = q.head;
            while (curr) |msg| {
                const next = msg.next;
                heap.allocator().free(msg.data);
                heap.allocator().destroy(msg);
                curr = next;
            }

            // Clear slot
            q.in_use = false;
            q.head = null;
            q.tail = null;

            // Wake all waiting threads (they will get EIDRM on retry)
            _ = q.send_wait_queue.wakeUp(std.math.maxInt(usize));
            _ = q.recv_wait_queue.wakeUp(std.math.maxInt(usize));

            return 0;
        },
        else => return error.EINVAL,
    }
}
