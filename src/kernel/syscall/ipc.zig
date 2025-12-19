const std = @import("std");
const uapi = @import("uapi");
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const process = @import("process");
const heap = @import("heap");
const sched = @import("sched");
const ipc_msg = @import("ipc_msg");
const keyboard = @import("keyboard");
const mouse = @import("mouse");
const service = @import("ipc_service");
const hal = @import("hal");

pub const Message = ipc_msg.Message;
pub const KernelMessage = ipc_msg.KernelMessage;

const MAX_MAILBOX_MESSAGES: usize = 128;

pub fn sys_send(target_pid: usize, msg_ptr: usize, len: usize) SyscallError!usize {
    // 1. Validate arguments
    if (len != @sizeOf(Message)) return error.EINVAL;

    // Check if target is Kernel (PID 0)
    if (target_pid == 0) {
        // SECURITY: Require InputInjection capability to send messages to kernel
        // This prevents unprivileged processes from injecting keyboard/mouse input
        const thread = sched.getCurrentThread() orelse return error.ESRCH;
        const proc_opaque = thread.process orelse return error.ESRCH;
        const proc: *process.Process = @ptrCast(@alignCast(proc_opaque));

        if (!proc.hasInputInjectionCapability()) {
            return error.EPERM;
        }
        return handleKernelMessage(msg_ptr);
    }

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
    errdefer heap.allocator().destroy(kmsg);
    kmsg.* = KernelMessage{ .msg = msg };
    
    // Queue message
    {
        const held = target.mailbox_lock.acquire();
        defer held.release();

        if (target.mailbox_len >= MAX_MAILBOX_MESSAGES) {
            return error.EAGAIN;
        }
        
        target.mailbox.append(kmsg);
        target.mailbox_len += 1;
        
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
                if (proc.mailbox_len > 0) {
                    proc.mailbox_len -= 1;
                }
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
    
    const sender = kmsg.msg.sender_pid;
    heap.allocator().destroy(kmsg);

    return sender;
}

/// Helper for Kernel to send IPC messages (e.g. console logs)
pub fn sendKernelMessage(target_pid: usize, payload: []const u8) !void {
    const target = process.findProcessByPid(@intCast(target_pid)) orelse return error.ESRCH;

    var msg: Message = undefined;
    msg.sender_pid = 0; // 0 = Kernel
    
    // Copy payload (truncate if too long)
    const len = @min(payload.len, ipc_msg.MAX_PAYLOAD_SIZE);
    msg.payload_len = len;
    hal.mem.copy(msg.payload[0..len].ptr, payload[0..len].ptr, len);
    
    // Allocate kernel message
    const kmsg = heap.allocator().create(KernelMessage) catch return error.ENOMEM;
    errdefer heap.allocator().destroy(kmsg);
    kmsg.* = KernelMessage{ .msg = msg };
    
    // Queue message
    {
        const held = target.mailbox_lock.acquire();
        defer held.release();

        if (target.mailbox_len >= MAX_MAILBOX_MESSAGES) {
            return error.EAGAIN;
        }
        
        target.mailbox.append(kmsg);
        target.mailbox_len += 1;
        
        // Wake waiter if any
        if (target.msg_waiter) |waiter| {
            sched.unblock(waiter);
            target.msg_waiter = null;
        }
    }
}

// Helper for console.zig to register logging
const console = @import("console");

pub fn sys_register_ipc_logger() SyscallError!usize {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = thread.process orelse return error.ESRCH;
    const process_ptr: *process.Process = @ptrCast(@alignCast(proc_opaque));
    
    console.addIpcBackend(process_ptr.pid);
    return 0;
}

pub fn sys_register_service(name_ptr: usize, name_len: usize) SyscallError!usize {
    const thread = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = thread.process orelse return error.ESRCH;
    const process_ptr: *process.Process = @ptrCast(@alignCast(proc_opaque));

    if (name_len > service.MAX_SERVICE_NAME) return error.EINVAL;

    var name_buf: [service.MAX_SERVICE_NAME]u8 = undefined;
    const user_ptr = user_mem.UserPtr.from(name_ptr);
    
    _ = user_ptr.copyToKernel(name_buf[0..name_len]) catch return error.EFAULT;

    if (service.register(name_buf[0..name_len], process_ptr.pid) catch return error.ENOMEM) {
        return 0;
    } else {
        return error.EEXIST; // Name taken
    }
}

pub fn sys_lookup_service(name_ptr: usize, name_len: usize) SyscallError!usize {
    if (name_len > service.MAX_SERVICE_NAME) return error.EINVAL;

    var name_buf: [service.MAX_SERVICE_NAME]u8 = undefined;
    const user_ptr = user_mem.UserPtr.from(name_ptr);
    
    _ = user_ptr.copyToKernel(name_buf[0..name_len]) catch return error.EFAULT;

    if (service.lookup(name_buf[0..name_len])) |pid| {
        return pid;
    } else {
        return error.ENOENT;
    }
}

// Input Event Types (must match userspace)
const INPUT_TYPE_KEYBOARD = 1;
const INPUT_TYPE_MOUSE = 2;

const InputHeader = extern struct {
    type: u32,
    _pad: u32,
};

const KeyboardEvent = extern struct {
    header: InputHeader,
    scancode: u8,
};

const MouseEvent = extern struct {
    header: InputHeader,
    dx: i16,
    dy: i16,
    dz: i8,
    buttons: u8,
};

fn handleKernelMessage(msg_ptr: usize) SyscallError!usize {
    const user_ptr = user_mem.UserPtr.from(msg_ptr);
    var msg: Message = undefined;
    const msg_bytes = std.mem.asBytes(&msg);

    _ = user_ptr.copyToKernel(msg_bytes) catch return error.EFAULT;

    // SECURITY: Validate payload_len bounds to prevent logical errors.
    // payload_len must be within the fixed-size payload array.
    if (msg.payload_len > ipc_msg.MAX_PAYLOAD_SIZE) return error.EINVAL;
    if (msg.payload_len < @sizeOf(InputHeader)) return error.EINVAL;

    const header: *const InputHeader = @ptrCast(@alignCast(&msg.payload));

    switch (header.type) {
        INPUT_TYPE_KEYBOARD => {
             if (msg.payload_len < @sizeOf(KeyboardEvent)) return error.EINVAL;
             const evt: *const KeyboardEvent = @ptrCast(@alignCast(&msg.payload));
             keyboard.injectScancode(evt.scancode);
        },
        INPUT_TYPE_MOUSE => {
             if (msg.payload_len < @sizeOf(MouseEvent)) return error.EINVAL;
             const evt: *const MouseEvent = @ptrCast(@alignCast(&msg.payload));
             // Map u8 buttons to packed struct
             const buttons = mouse.Buttons{
                 .left = (evt.buttons & 1) != 0,
                 .right = (evt.buttons & 2) != 0,
                 .middle = (evt.buttons & 4) != 0,
             };
             mouse.injectRawInput(evt.dx, evt.dy, evt.dz, buttons);
        },
        else => return error.EINVAL, // Unknown kernel message type
    }

    return 0;
}
