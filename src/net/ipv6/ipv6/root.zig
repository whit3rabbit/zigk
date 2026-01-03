// IPv6 Core Protocol Implementation
//
// Handles IPv6 packet processing, validation, and extension header parsing.

pub const types = @import("types.zig");
pub const process = @import("process.zig");
pub const transmit = @import("transmit.zig");
pub const fragment = @import("fragment.zig");

// Re-export main processing functions
pub const processPacket = process.processPacket;
pub const sendPacket = transmit.sendPacket;
pub const buildPacket = transmit.buildPacket;

// Re-export fragment reassembly
pub const processFragment = fragment.processFragment;
pub const ReassemblyResult = fragment.ReassemblyResult;

// Re-export types
pub const Ipv6Header = @import("../../core/packet.zig").Ipv6Header;
