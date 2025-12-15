const std = @import("std");
const core = @import("core/root.zig");
const ethernet = @import("ethernet/root.zig");
const ipv4 = @import("ipv4/root.zig");
pub const transport = @import("transport/root.zig");
const dns = @import("dns/root.zig");
pub const loopback = @import("loopback.zig");
const io = @import("io");

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
// Network stack initialization
// Called from kernel main after NIC driver is initialized
pub fn init(iface: *Interface, allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    // Initialize layers with allocator
    ipv4.ipv4.init(allocator, ticks_per_sec); // Includes ARP init
    
    // Initialize Transport Layer (TCP/Sockets) which now uses dynamic memory
    transport.initSockets(iface, allocator);
    transport.initTcp(iface, allocator, ticks_per_sec);

    // Clear ARP cache (redundant if init clears it, but kept for logic)
    ipv4.arp.clearCache();

    // Mark interface as up
    iface.up();
}

pub fn processFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    return ethernet.processFrame(iface, pkt);
}

/// System timer tick handler
/// Called from kernel scheduler timer interrupt
pub fn tick() void {
    ipv4.arp.tick();
    transport.tcp.tick();

    // Process async I/O timer expirations (Phase 2)
    io.timerTick();
}
