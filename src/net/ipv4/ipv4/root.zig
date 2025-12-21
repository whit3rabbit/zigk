const std = @import("std");
const arp = @import("../arp/root.zig");
const reassembly = @import("../reassembly.zig");
const pmtu = @import("../pmtu.zig");

// Sub-modules
pub const types = @import("types.zig");
pub const utils = @import("utils.zig");
pub const id = @import("id.zig");
pub const validation = @import("validation.zig");
pub const transmit = @import("transmit.zig");
pub const process = @import("process.zig");

// Re-export constants
pub const PROTO_ICMP = types.PROTO_ICMP;
pub const PROTO_TCP = types.PROTO_TCP;
pub const PROTO_UDP = types.PROTO_UDP;
pub const DEFAULT_TTL = types.DEFAULT_TTL;

// Re-export functions
pub const processPacket = process.processPacket;
pub const buildPacket = transmit.buildPacket;
pub const buildPacketWithTos = transmit.buildPacketWithTos;
pub const sendPacket = transmit.sendPacket;
pub const decrementTtl = process.decrementTtl;
pub const getNextId = id.getNextId;

// PMTU re-exports
pub const DEFAULT_MTU = pmtu.DEFAULT_MTU;
pub const MIN_MTU = pmtu.MIN_MTU;
pub const lookupPmtu = pmtu.lookupPmtu;
pub const updatePmtu = pmtu.updatePmtu;
pub const getEffectiveMss = pmtu.getEffectiveMss;

// Utils re-exports
pub const isValidNetmask = utils.isValidNetmask;
pub const isBroadcast = utils.isBroadcast;
pub const isMulticast = utils.isMulticast;
pub const isLoopback = utils.isLoopback;

var ipv4_allocator: ?std.mem.Allocator = null;

/// Initialize IPv4 subsystem
pub fn init(allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    ipv4_allocator = allocator;
    arp.init(allocator, ticks_per_sec);
    reassembly.init();
}
