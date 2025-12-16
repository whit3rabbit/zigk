const std = @import("std");

/// Fixed-size message for IPC
/// 64 bytes payload + metadata
pub const MAX_PAYLOAD_SIZE = 64;

pub const Message = extern struct {
    sender_pid: u64,
    payload_len: u64,
    payload: [MAX_PAYLOAD_SIZE]u8,
};

/// IPC Operation type (for potential future expansion)
pub const IpcOp = enum(u64) {
    SEND = 0,
    RECV = 1,
};

/// Kernel-side message node for linked lists
pub const KernelMessage = struct {
    msg: Message,
    next: ?*KernelMessage = null,
    prev: ?*KernelMessage = null,
};
