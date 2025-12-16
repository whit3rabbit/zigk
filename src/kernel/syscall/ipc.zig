const std = @import("std");
const uapi = @import("uapi");
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const process = @import("process");
const heap = @import("heap");
const sched = @import("sched");
const ipc_msg = @import("ipc_msg");

pub const Message = ipc_msg.Message;
pub const KernelMessage = ipc_msg.KernelMessage;

pub fn sys_send(target_pid: usize, msg_ptr: usize, len: usize) SyscallError!usize {
    // 1. Validate arguments
    if (len != @sizeOf(Message)) return error.EINVAL;
    
    // Find target process
    const target = process.findProcessByPid(@intCast(target_pid)) orelse return error.ESRCH;
    
    const user_ptr = user_mem.UserPtr.from(msg_ptr);

    // Read message from user space (manual copy)
    var msg: Message = undefined;
    msg.sender_pid = 0; // Filled by kernel
    const msg_bytes = std.mem.asBytes(&msg);
    
    // We catch the error from copyToKernel and map to EFAULT
    _ = user_ptr.copyToKernel(msg_bytes) catch {
        return error.EFAULT;
    };
    
    // Fill in true sender PID
    if (sched.getCurrentThread()) |t| {
        if (t.process) |p_opaque| {
             const p: *process.Process = @ptrCast(@alignCast(p_opaque));
             msg.sender_pid = p.pid;
        }
    }
    
    // Allocate kernel message
    const kmsg = heap.allocator().create(KernelMessage) catch return error.ENOMEM;
    kmsg.* = KernelMessage{ .msg = msg };
    
    // Queue message
    {
        const held = target.mailbox_lock.acquire();
        defer held.release();
        
        target.mailbox.append(kmsg);
        
        // Wake waiter if any
        if (target.msg_waiter) |waiter| {
            sched.unblock(waiter);
            target.msg_waiter = null;
        }
    }
    
    return 0;
}

pub fn sys_recv(msg_ptr: usize, len: usize) SyscallError!usize {
    if (len != @sizeOf(Message)) return error.EINVAL;
    
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));
    
    const user_ptr = user_mem.UserPtr.from(msg_ptr);
    if (user_ptr.isNull()) return error.EFAULT;

    var kmsg: *KernelMessage = undefined;
    
    // Wait for message
    while (true) {
        {
            const held = proc.mailbox_lock.acquire();
            // Check queue
            if (proc.mailbox.popFirst()) |msg| {
                kmsg = msg;
                held.release();
                break;
            }
            
            // Empty - block
            proc.msg_waiter = current;
            held.release();
        }
        
        sched.block();
    }
    
    // Copy to user
    
    // Copy to user
    const msg_slice = std.mem.asBytes(&kmsg.msg);
    
    _ = user_ptr.copyFromKernel(msg_slice) catch {
         heap.allocator().destroy(kmsg);
         return error.EFAULT;
    };
    
    heap.allocator().destroy(kmsg);

    return 0;
}
