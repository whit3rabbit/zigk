// IPv6 Protocol Implementation
//
// This module provides IPv6 (RFC 8200) support for the network stack,
// including:
//   - IPv6 packet processing (RX/TX)
//   - Extension header parsing
//   - ICMPv6 (RFC 4443)
//   - Neighbor Discovery Protocol (RFC 4861)
//   - Fragment reassembly
//
// Design follows the existing IPv4 module structure for consistency.

pub const ipv6 = @import("ipv6/root.zig");
pub const icmpv6 = @import("icmpv6/root.zig");
pub const ndp = @import("ndp/root.zig");

// Re-export common types from core
const packet = @import("../core/packet.zig");
pub const Ipv6Header = packet.Ipv6Header;
pub const Ipv6ExtHeader = packet.Ipv6ExtHeader;
pub const Ipv6FragmentHeader = packet.Ipv6FragmentHeader;
pub const IPV6_HEADER_SIZE = packet.IPV6_HEADER_SIZE;

// Re-export address utilities
pub const addr = @import("../core/addr.zig");
pub const IpAddr = addr.IpAddr;

// Re-export checksum functions
const checksum = @import("../core/checksum.zig");
pub const checksumWithIpv6Pseudo = checksum.checksumWithIpv6Pseudo;
pub const tcpChecksum6 = checksum.tcpChecksum6;
pub const udpChecksum6 = checksum.udpChecksum6;
pub const icmpv6Checksum = checksum.icmpv6Checksum;
