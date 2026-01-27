//! VMware/VirtualBox Hypercall Interface
//!
//! Provides access to the hypercall I/O port interface used by VMware and VirtualBox
//! for guest-host communication (mouse integration, time sync, clipboard, etc.).
//!
//! Note: This interface is historically called "backdoor" in VMware documentation
//! and Linux kernel code. We use "hypercall" following modern Linux 6.11+ convention.
//!
//! Magic Port: 0x5658 ("VX")
//! Magic Value: 0x564D5868 ("VMXh")

const std = @import("std");

pub const HYPERCALL_PORT: u16 = 0x5658;
pub const HYPERCALL_MAGIC: u32 = 0x564D5868;

/// Low-level register state for hypercall.
/// Layout must match the assembly helper expectations (6 consecutive u32 fields).
///
/// SECURITY NOTE on edx: The assembly helper (_asm_vmware_hypercall) intentionally
/// ignores the input edx value and hardcodes the port to 0x5658 ("VX"). This is a
/// security feature that prevents callers from using this interface to access
/// arbitrary I/O ports. The edx field is OUTPUT-ONLY and contains the result
/// after the hypercall.
pub const Registers = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    /// OUTPUT-ONLY: Input value ignored by assembly; port is fixed to 0x5658.
    /// Contains output value after the hypercall.
    edx: u32,
    esi: u32 = 0,
    edi: u32 = 0,
};

/// External assembly function for VMware hypercall.
/// Defined in src/arch/x86_64/lib/asm_helpers.S
extern fn _asm_vmware_hypercall(regs: *Registers) void;

/// Command IDs for the hypercall
pub const Command = enum(u16) {
    GetVersion = 10,
    GetCursorPos = 0x04,
    SetCursorPos = 0x05,
    GetClipboardLen = 0x06,
    GetClipboardData = 0x07,
    SetClipboardLen = 0x08,
    SetClipboardData = 0x09,
    // VMMouse specific
    AbsPointerData = 39,
    AbsPointerStatus = 40,
    AbsPointerCmd = 41,
};

/// Check if the hypercall interface is available
pub fn detect() bool {
    var regs = Registers{
        .eax = @intFromEnum(Command.GetVersion),
        .ebx = ~HYPERCALL_MAGIC, // Initialize with non-magic
        .ecx = 0,
        .edx = HYPERCALL_PORT, // Port goes in DX (sometimes modified by in/out but port is fixed)
    };

    call(&regs);

    // If successful, EBX should contain the magic value 0x564D5868
    // and EAX should usually be valid (not -1 or garbage, though version specific)
    return regs.ebx == HYPERCALL_MAGIC;
}

/// Execute a hypercall command.
///
/// The VMware hypercall instruction is `in eax, dx` with specific values in
/// other registers. The hypervisor traps this specific I/O operation.
/// Uses external assembly due to Zig 0.16 inline asm limitations with
/// multiple register outputs.
pub inline fn call(regs: *Registers) void {
    _asm_vmware_hypercall(regs);
}

/// Helper for VMMouse commands which often use simple command ID in EAX
pub fn sendCommand(cmd: Command) void {
    var regs = Registers{
        .eax = HYPERCALL_MAGIC,
        .ebx = @intFromEnum(cmd),
        .ecx = 0,
        .edx = HYPERCALL_PORT,
    };
    call(&regs);
}

/// Helper specifically for VMMouse data exchange
pub fn sendVMMouseCommand(sub_cmd: u32, data: u32) Registers {
    var regs = Registers{
        .eax = HYPERCALL_MAGIC,
        .ebx = sub_cmd,
        .ecx = data,
        .edx = HYPERCALL_PORT,
        .esi = 0,
        .edi = 0,
    };
    // VMMouse uses "Set" commands or "Data" commands via the AbsPointerCmd (41) usually?
    // Actually, VMMouse protocol is slightly different:
    // It sets EBX to the VMMouse command word.

    // Low level call
    call(&regs);
    return regs;
}

// =============================================================================
// RPCI (Remote Procedure Call Interface) - Kernel Level
// =============================================================================
//
// RPCI provides a message-passing channel between guest and VMware host.
// Used for: HGFS shared folders, guest info, capabilities, tools integration.
//
// Protocol:
// 1. Open channel with protocol ID (RPCI=0x49435052, TCLO=0x4F4C4354)
// 2. Send/receive messages in chunks
// 3. Close channel when done
//
// This kernel-level implementation supports both low-bandwidth (byte-at-a-time)
// and high-bandwidth (REP OUTSB/INSB) modes for efficient large transfers.

/// High-bandwidth port for REP-based transfers
pub const HYPERCALL_HB_PORT: u16 = 0x5659;

/// RPCI protocol identifiers
pub const RpciProtocol = struct {
    /// Guest->Host RPC channel
    pub const RPCI: u32 = 0x49435052; // "RPCI" little-endian
    /// Host->Guest command channel (TCLO)
    pub const TCLO: u32 = 0x4F4C4354; // "TCLO" little-endian
};

/// Message command IDs
pub const MessageCommand = enum(u16) {
    Open = 30,
    Send = 31,
    Receive = 32,
    Close = 33,
};

/// Message status flags (returned in ECX high bits)
pub const MessageStatus = struct {
    pub const SUCCESS: u32 = 0x0001_0000;
    pub const DORECV: u32 = 0x0002_0000; // More data to receive
    pub const CLOSED: u32 = 0x0004_0000; // Channel was closed
    pub const UNSENT: u32 = 0x0008_0000; // Message not fully sent
    pub const HB: u32 = 0x0010_0000; // High-bandwidth available
};

/// RPCI channel state
pub const RpciChannel = struct {
    /// Channel ID (from open response, in high bits of EDX)
    id: u16,
    /// Cookie for channel authentication
    cookie1: u32,
    cookie2: u32,
    /// Whether channel is open
    is_open: bool,
    /// Whether high-bandwidth is available
    hb_available: bool,

    const Self = @This();

    /// Open a new RPCI channel
    pub fn open(protocol: u32) RpciError!Self {
        var regs = Registers{
            .eax = HYPERCALL_MAGIC,
            .ebx = protocol,
            .ecx = @intFromEnum(MessageCommand.Open),
            .edx = HYPERCALL_PORT,
            .esi = 0,
            .edi = 0,
        };

        call(&regs);

        // Check success flag
        if ((regs.ecx & MessageStatus.SUCCESS) == 0) {
            return error.OpenFailed;
        }

        return Self{
            .id = @truncate(regs.edx >> 16),
            .cookie1 = regs.esi,
            .cookie2 = regs.edi,
            .is_open = true,
            .hb_available = (regs.ecx & MessageStatus.HB) != 0,
        };
    }

    /// Close the channel
    pub fn close(self: *Self) void {
        if (!self.is_open) return;

        var regs = Registers{
            .eax = HYPERCALL_MAGIC,
            .ebx = 0,
            .ecx = @intFromEnum(MessageCommand.Close) | (@as(u32, self.id) << 16),
            .edx = HYPERCALL_PORT,
            .esi = self.cookie1,
            .edi = self.cookie2,
        };

        call(&regs);
        self.is_open = false;
    }

    /// Send a message on the channel
    /// Returns number of bytes sent, or error
    pub fn send(self: *Self, data: []const u8) RpciError!usize {
        if (!self.is_open) return error.ChannelClosed;
        if (data.len == 0) return 0;

        // Send message length first
        var regs = Registers{
            .eax = HYPERCALL_MAGIC,
            .ebx = @truncate(data.len),
            .ecx = @intFromEnum(MessageCommand.Send) | (@as(u32, self.id) << 16),
            .edx = HYPERCALL_PORT,
            .esi = self.cookie1,
            .edi = self.cookie2,
        };

        call(&regs);

        if ((regs.ecx & MessageStatus.SUCCESS) == 0) {
            return error.SendFailed;
        }

        // Send data bytes (low-bandwidth, one byte at a time)
        // High-bandwidth would use REP OUTSB but requires additional assembly
        for (data) |byte| {
            var send_regs = Registers{
                .eax = HYPERCALL_MAGIC,
                .ebx = byte,
                .ecx = @intFromEnum(MessageCommand.Send) | (@as(u32, self.id) << 16),
                .edx = HYPERCALL_PORT,
                .esi = self.cookie1,
                .edi = self.cookie2,
            };

            call(&send_regs);

            if ((send_regs.ecx & MessageStatus.SUCCESS) == 0) {
                return error.SendFailed;
            }
        }

        return data.len;
    }

    /// Receive a message from the channel
    /// Returns number of bytes received
    pub fn receive(self: *Self, buf: []u8) RpciError!usize {
        if (!self.is_open) return error.ChannelClosed;
        if (buf.len == 0) return 0;

        // Check for available message
        var regs = Registers{
            .eax = HYPERCALL_MAGIC,
            .ebx = 0,
            .ecx = @intFromEnum(MessageCommand.Receive) | (@as(u32, self.id) << 16),
            .edx = HYPERCALL_PORT,
            .esi = self.cookie1,
            .edi = self.cookie2,
        };

        call(&regs);

        if ((regs.ecx & MessageStatus.SUCCESS) == 0) {
            // No message available
            return 0;
        }

        // Message length in EBX
        const msg_len = regs.ebx;
        if (msg_len == 0) return 0;

        // Receive bytes (low-bandwidth)
        var received: usize = 0;
        while (received < msg_len and received < buf.len) {
            var recv_regs = Registers{
                .eax = HYPERCALL_MAGIC,
                .ebx = 1, // Request 1 byte
                .ecx = @intFromEnum(MessageCommand.Receive) | (@as(u32, self.id) << 16),
                .edx = HYPERCALL_PORT,
                .esi = self.cookie1,
                .edi = self.cookie2,
            };

            call(&recv_regs);

            if ((recv_regs.ecx & MessageStatus.SUCCESS) == 0) {
                break;
            }

            buf[received] = @truncate(recv_regs.ebx);
            received += 1;
        }

        return received;
    }

    /// Send an RPC command string and receive response
    /// Convenience wrapper for simple request/response patterns
    pub fn rpc(self: *Self, command: []const u8, response_buf: []u8) RpciError!usize {
        _ = try self.send(command);
        return try self.receive(response_buf);
    }
};

/// RPCI error types
pub const RpciError = error{
    OpenFailed,
    ChannelClosed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    ProtocolError,
};

// =============================================================================
// HGFS (Host-Guest File System) Protocol Support
// =============================================================================
//
// HGFS uses RPCI channel with "f " prefix for file operations.
// Request format: "f <op_code> <request_data>"
// Response format: "<status> [response_data]"

/// HGFS operation codes (V4 protocol)
pub const HgfsOp = enum(u32) {
    CreateSessionV4 = 31,
    DestroySessionV4 = 32,
    OpenV3 = 21,
    Close = 6,
    ReadV3 = 15,
    WriteV3 = 17,
    GetAttrV2 = 12,
    SetAttrV2 = 13,
    SearchOpenV3 = 22,
    SearchReadV3 = 23,
    SearchClose = 10,
    CreateDirV3 = 24,
    DeleteFileV3 = 25,
    DeleteDirV3 = 26,
    RenameV3 = 27,
};

/// HGFS status codes
pub const HgfsStatus = enum(u32) {
    Success = 0,
    NoSuchFile = 2,
    PermissionDenied = 13,
    InvalidHandle = 14,
    OperationNotSupported = 18,
    NameTooLong = 22,
    DirNotEmpty = 39,
    ProtocolError = 1000,
    IoError = 1005,
    NotSupported = 1009,
    SessionNotFound = 1010,
    TooManySessions = 1011,
    StaleSession = 1012,
    _,
};
