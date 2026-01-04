//! IPC Message Definitions
//!
//! This module defines the structure of messages used in the Inter-Process Communication (IPC)
//! subsystem. It re-exports shared types from the `uapi` module and defines kernel-internal
//! structures for message queuing.
//!
//! The IPC mechanism uses a fixed-size message format to ensure deterministic behavior
//! and avoid complex memory management in the kernel.

const std = @import("std");
const uapi = @import("uapi");

// Re-export shared types from uapi for kernel use
pub const MAX_PAYLOAD_SIZE = uapi.ipc_msg.MAX_PAYLOAD_SIZE;
pub const Message = uapi.ipc_msg.Message;
pub const IpcOp = uapi.ipc_msg.IpcOp;

/// Kernel-side message node for linked lists.
///
/// This structure wraps the standard user-facing `Message` struct with additional
/// pointers for maintaining a doubly-linked list within the kernel's IPC queues.
/// It is used internally by the kernel and is not exposed to userspace.
pub const KernelMessage = struct {
    /// The actual message data (payload, sender, receiver, etc.)
    msg: Message,
    /// Pointer to the next message in the queue
    next: ?*KernelMessage = null,
    /// Pointer to the previous message in the queue
    prev: ?*KernelMessage = null,
};
