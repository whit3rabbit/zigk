const std = @import("std");

/// Network IPC Message Types
pub const PacketType = enum(u32) {
    /// Network packet (Ethernet frame)
    RX_PACKET = 0,
    TX_PACKET = 1,
    /// Configuration command
    CONFIG = 2,
};

/// Header for all network IPC messages
pub const PacketHeader = extern struct {
    type: PacketType,
    len: u32,
    _pad: u64,
};

/// Maximum size of a standard Ethernet frame + header
pub const MAX_PACKET_SIZE = 1536;
