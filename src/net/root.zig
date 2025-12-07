// Network Stack Module
//
// Main entry point for the ZigK network stack.
// Re-exports all protocol layers.

pub const core = @import("core/root.zig");
pub const ethernet = @import("ethernet/root.zig");
pub const ipv4 = @import("ipv4/root.zig");
pub const transport = @import("transport/root.zig");

// Re-export key types from core
pub const PacketBuffer = core.PacketBuffer;
pub const Interface = core.Interface;
pub const EthernetHeader = core.EthernetHeader;
pub const Ipv4Header = core.Ipv4Header;
pub const UdpHeader = core.UdpHeader;
pub const IcmpHeader = core.IcmpHeader;
pub const ArpHeader = core.ArpHeader;

// Re-export checksum utilities
pub const ipChecksum = core.ipChecksum;
pub const icmpChecksum = core.icmpChecksum;
pub const udpChecksum = core.udpChecksum;

// Re-export interface utilities
pub const ipToString = core.ipToString;
pub const parseIp = core.parseIp;

// Re-export constants
pub const MAX_PACKET_SIZE = core.MAX_PACKET_SIZE;
pub const ETH_HEADER_SIZE = core.ETH_HEADER_SIZE;
pub const IP_HEADER_SIZE = core.IP_HEADER_SIZE;
pub const UDP_HEADER_SIZE = core.UDP_HEADER_SIZE;
pub const ICMP_HEADER_SIZE = core.ICMP_HEADER_SIZE;

// Network stack initialization
// Called from kernel main after NIC driver is initialized
pub fn init(iface: *Interface) void {
    // Clear ARP cache
    ipv4.arp.clearCache();

    // Mark interface as up
    iface.up();
}

/// Process an incoming Ethernet frame
/// Entry point for received packets from NIC driver
pub fn processFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    return ethernet.processFrame(iface, pkt);
}
