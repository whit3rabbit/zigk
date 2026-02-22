const std = @import("std");

// Export submodules for syscall handlers that need deeper access
pub const core = @import("core/root.zig");
pub const ethernet = @import("ethernet/root.zig");
pub const ipv4 = @import("ipv4/root.zig");
pub const transport = @import("transport/root.zig");
const dns = @import("dns/root.zig");
pub const mdns = @import("mdns/root.zig");
pub const loopback = @import("drivers/loopback.zig");
const net_clock = @import("clock.zig");
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

// Re-export clock abstraction
pub const Clock = net_clock.Clock;
pub const defaultClock = net_clock.defaultClock;

// Network stack initialization
// Called from kernel main after NIC driver is initialized
// Network stack initialization
// Called from kernel main after NIC driver is initialized
pub fn init(iface: *Interface, allocator: std.mem.Allocator, ticks_per_sec: u32, clk: Clock) void {
    net_clock.init(clk);
    // Initialize layers with allocator
    core.pool.init(allocator, core.pool.DEFAULT_MAX_MEMORY);
    ipv4.ipv4.init(allocator, ticks_per_sec); // Includes ARP init
    
    // Initialize Transport Layer (TCP/Sockets) which now uses dynamic memory
    transport.initSockets(iface, allocator);
    transport.initTcp(iface, allocator, ticks_per_sec);

    // Clear ARP cache (redundant if init clears it, but kept for logic)
    ipv4.arp.clearCache();

    // NOTE: mDNS responder init skipped. mdns.init() creates a UDP socket
    // and enters probing state, but mdns.tick() cannot run from ISR context
    // (it calls recvfrom which acquires socket locks). mDNS is a LAN service
    // discovery protocol -- not useful on a loopback-only interface.
    // TODO: Initialize mDNS when a physical NIC is available and a kernel
    // thread can drive the tick loop.

    // Mark interface as up
    iface.up();
}

pub fn processFrame(iface: *Interface, pkt: *PacketBuffer) bool {
    return ethernet.processFrame(iface, pkt);
}

/// System timer tick handler
/// Called from kernel scheduler timer interrupt (ISR context).
/// All functions called here MUST be ISR-safe: no blocking, no socket ops, no sleeping.
pub fn tick() void {
    ipv4.arp.tick();
    // Increment connection_timestamp first so ack_due comparisons are current.
    transport.tcp.tick();
    io.timerTick();

    // Process TCP timers: delayed ACKs, retransmission timeouts, persist probes.
    // Must run after tcp.tick() (which increments connection_timestamp) and before
    // loopback.drain() so that ACKs queued here are delivered in the same tick.
    transport.tcpProcessTimers();

    // Process deferred loopback packets. Loopback transmit queues packets
    // instead of processing inline to avoid re-entrant deadlock on state.lock.
    // drain() may enqueue additional packets (e.g. RST replies) which are
    // processed in the same drain call.
    loopback.drain();

    // NOTE: mdns.tick() is intentionally NOT called here.
    // It calls processIncoming() which does udp_api.recvfrom() -- a socket
    // receive that acquires locks and may block. Calling from ISR context
    // deadlocks if the interrupted code holds a socket lock.
    // mDNS requires a dedicated kernel thread or deferred work context.
}
