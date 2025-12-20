// IPv4 Module
//
// Re-exports IPv4 and ARP protocol types and functions.

pub const ipv4 = @import("ipv4.zig");
pub const arp = @import("arp/root.zig");

// Re-export commonly used IPv4 items
pub const processPacket = ipv4.processPacket;
pub const buildPacket = ipv4.buildPacket;
pub const sendPacket = ipv4.sendPacket;
pub const PROTO_ICMP = ipv4.PROTO_ICMP;
pub const PROTO_UDP = ipv4.PROTO_UDP;
pub const PROTO_TCP = ipv4.PROTO_TCP;
pub const DEFAULT_TTL = ipv4.DEFAULT_TTL;

// Re-export ARP items
pub const ArpEntry = arp.ArpEntry;
pub const ArpState = arp.ArpState;
pub const resolve = arp.resolve;
pub const resolveOrRequest = arp.resolveOrRequest;
pub const sendRequest = arp.sendRequest;
pub const clearCache = arp.clearCache;
pub const ageCache = arp.ageCache;
