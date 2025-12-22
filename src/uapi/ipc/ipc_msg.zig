/// IPC Message format shared between kernel and userspace
///
/// This defines the wire format for inter-process communication messages.
/// Both kernel and userspace must use identical definitions.

/// Maximum size of message payload in bytes
pub const MAX_PAYLOAD_SIZE: usize = 2048;

/// IPC Message structure
///
/// Layout (2064 bytes total):
///   - sender_pid: u64 (8 bytes) - PID of sending process (filled by kernel)
///   - payload_len: u64 (8 bytes) - Actual length of payload data
///   - payload: [2048]u8 - Message payload
pub const Message = extern struct {
    /// PID of the sending process (set by kernel, ignored on send)
    sender_pid: u64,
    /// Length of valid data in payload
    payload_len: u64,
    /// Message payload data
    payload: [MAX_PAYLOAD_SIZE]u8,
};

/// IPC Operation type (for potential future expansion)
pub const IpcOp = enum(u64) {
    SEND = 0,
    RECV = 1,
};
