// Network Core Module
//
// Re-exports core networking types and utilities.

pub const packet = @import("packet.zig");
pub const interface = @import("interface.zig");
pub const checksum = @import("checksum.zig");

// Re-export commonly used types
pub const PacketBuffer = packet.PacketBuffer;
pub const EthernetHeader = packet.EthernetHeader;
pub const Ipv4Header = packet.Ipv4Header;
pub const UdpHeader = packet.UdpHeader;
pub const IcmpHeader = packet.IcmpHeader;
pub const ArpHeader = packet.ArpHeader;
pub const Interface = interface.Interface;

// Re-export utility functions
pub const ipChecksum = checksum.ipChecksum;
pub const icmpChecksum = checksum.icmpChecksum;
pub const udpChecksum = checksum.udpChecksum;
pub const verifyIpChecksum = checksum.verifyIpChecksum;
pub const ipToString = interface.ipToString;
pub const parseIp = interface.parseIp;

// Constants
pub const MAX_PACKET_SIZE = packet.MAX_PACKET_SIZE;
pub const ETH_HEADER_SIZE = packet.ETH_HEADER_SIZE;
pub const IP_HEADER_SIZE = packet.IP_HEADER_SIZE;
pub const UDP_HEADER_SIZE = packet.UDP_HEADER_SIZE;
pub const ICMP_HEADER_SIZE = packet.ICMP_HEADER_SIZE;
