const std = @import("std");
const uapi = @import("uapi");

// Re-export shared types from uapi for kernel use
pub const MAX_PAYLOAD_SIZE = uapi.ipc_msg.MAX_PAYLOAD_SIZE;
pub const Message = uapi.ipc_msg.Message;
pub const IpcOp = uapi.ipc_msg.IpcOp;

/// Kernel-side message node for linked lists
/// This is kernel-only and not exposed to userspace
pub const KernelMessage = struct {
    msg: Message,
    next: ?*KernelMessage = null,
    prev: ?*KernelMessage = null,
};
