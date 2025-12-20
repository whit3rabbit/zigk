// ICMP Protocol Implementation
//
// Complies with:
// - RFC 792: Internet Control Message Protocol
// - RFC 1122: Requirements for Internet Hosts -- Communication Layers
//
// Implements Echo Request/Reply (ping) functionality.
// Other ICMP types are parsed but not actively used.
//
// Message Format:
// +-----------+--------+-----------+-------------------------+
// | Type (1)  | Code(1)| Checksum(2)| Data (depends on Type)  |
// +-----------+--------+-----------+-------------------------+

const std = @import("std");
const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ipv4 = @import("../ipv4/ipv4.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("../ipv4/arp/root.zig");
const PacketBuffer = packet.PacketBuffer;
const IcmpHeader = packet.IcmpHeader;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;

// Forward declarations to avoid circular dependencies if possible,
// but we need to call them. circular imports are allowed in Zig if done right.
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const sync = @import("../sync.zig");

/// SECURITY: Recent UDP transmit cache for PMTU validation (RFC 5927 defense).
/// Tracks destination IPs we've recently sent UDP packets to, preventing spoofed
/// ICMP "Fragmentation Needed" messages from poisoning our PMTU cache for arbitrary
/// destinations.
const UDP_TRANSMIT_CACHE_SIZE: usize = 64;
const UDP_TRANSMIT_CACHE_TTL_MS: u64 = 30000; // 30 seconds

/// Entry in the UDP transmit cache
const UdpTransmitEntry = struct {
    dst_ip: u32,
    timestamp_ms: u64,
    valid: bool,
};

/// Ring buffer cache of recent UDP transmissions
var udp_transmit_cache: [UDP_TRANSMIT_CACHE_SIZE]UdpTransmitEntry = [_]UdpTransmitEntry{.{
    .dst_ip = 0,
    .timestamp_ms = 0,
    .valid = false,
}} ** UDP_TRANSMIT_CACHE_SIZE;
var udp_transmit_cache_index: usize = 0;
var udp_transmit_cache_lock: sync.Spinlock = .{};

/// Monotonic timestamp for cache entries (milliseconds)
/// Updated externally via tick()
var current_time_ms: u64 = 0;

/// Increment the time counter (call from timer, e.g., 1ms tick)
pub fn tick() void {
    current_time_ms +%= 1;
}

/// Record a UDP transmission for PMTU validation.
/// Called from UDP transmit path.
pub fn recordUdpTransmit(dst_ip: u32) void {
    const held = udp_transmit_cache_lock.acquire();
    defer held.release();

    // Insert at current index (ring buffer)
    udp_transmit_cache[udp_transmit_cache_index] = .{
        .dst_ip = dst_ip,
        .timestamp_ms = current_time_ms,
        .valid = true,
    };
    udp_transmit_cache_index = (udp_transmit_cache_index + 1) % UDP_TRANSMIT_CACHE_SIZE;
}

/// Check if we recently sent UDP to this destination.
/// Returns true if a valid entry exists within TTL.
fn validateUdpTransmit(dst_ip: u32) bool {
    const held = udp_transmit_cache_lock.acquire();
    defer held.release();

    for (&udp_transmit_cache) |*entry| {
        if (entry.valid and entry.dst_ip == dst_ip) {
            const age = current_time_ms -% entry.timestamp_ms;
            if (age <= UDP_TRANSMIT_CACHE_TTL_MS) {
                return true;
            }
        }
    }
    return false;
}

/// ICMP message types
pub const TYPE_ECHO_REPLY: u8 = 0;
pub const TYPE_DEST_UNREACHABLE: u8 = 3;
pub const TYPE_SOURCE_QUENCH: u8 = 4;
pub const TYPE_REDIRECT: u8 = 5;
pub const TYPE_ECHO_REQUEST: u8 = 8;
pub const TYPE_TIME_EXCEEDED: u8 = 11;
pub const TYPE_PARAMETER_PROBLEM: u8 = 12;
pub const TYPE_TIMESTAMP_REQUEST: u8 = 13;
pub const TYPE_TIMESTAMP_REPLY: u8 = 14;

/// Destination Unreachable codes
pub const CODE_NET_UNREACHABLE: u8 = 0;
pub const CODE_HOST_UNREACHABLE: u8 = 1;
pub const CODE_PROTO_UNREACHABLE: u8 = 2;
pub const CODE_PORT_UNREACHABLE: u8 = 3;
pub const CODE_FRAGMENTATION_NEEDED: u8 = 4; // RFC 1191: PMTUD

/// Process an incoming ICMP packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // Validate minimum ICMP header size
    if (pkt.len < pkt.transport_offset + packet.ICMP_HEADER_SIZE) {
        return false;
    }

    const icmp = pkt.icmpHeader();

    // Get ICMP message length from IP header
    const ip = pkt.ipHeader();
    const ip_total_len = ip.getTotalLength();
    const ip_header_len = ip.getHeaderLength();

    // Security: Guard against underflow from malformed packets
    if (ip_total_len < ip_header_len) return false;
    const icmp_len = ip_total_len - ip_header_len;

    // Validate ICMP checksum
    const icmp_data = pkt.data[pkt.transport_offset..][0..icmp_len];
    if (!verifyIcmpChecksum(icmp_data)) {
        return false;
    }

    // Handle based on type
    switch (icmp.icmp_type) {
        TYPE_ECHO_REQUEST => {
            return handleEchoRequest(iface, pkt, icmp_len);
        },
        TYPE_ECHO_REPLY => {
            // Could notify waiting ping processes
            return true;
        },
        TYPE_DEST_UNREACHABLE => {
            return handleDestUnreachable(pkt, icmp);
        },
        else => {
            // Unknown or unsupported type
            return false;
        },
    }
}

/// Handle an ICMP Echo Request (ping)
/// Sends back an Echo Reply with the same data
fn handleEchoRequest(iface: *Interface, req_pkt: *PacketBuffer, icmp_len: usize) bool {
    const req_ip = req_pkt.ipHeader();
    const req_icmp = req_pkt.icmpHeader();

    // Get source IP to reply to
    const src_ip = req_ip.getSrcIp();

    // Don't reply to broadcast pings (Smurf attack prevention)
    if (ipv4.isBroadcast(req_ip.getDstIp(), iface.netmask)) {
        return false;
    }
    
    // Security: RFC 1122 - Do not reply if source is Multicast or 0.0.0.0
    if (ipv4.isMulticast(src_ip) or src_ip == 0) {
        return false;
    }

    // Resolve destination MAC
    const next_hop = iface.getGateway(src_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        // Can't resolve MAC - drop reply
        // A real implementation would queue this
        return false;
    };

    // Calculate reply packet size
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const total_len = eth_len + ip_len + icmp_len;

    // Use static buffer for reply (avoid allocation)
    var reply_buf: [packet.MAX_PACKET_SIZE]u8 = undefined;
    if (total_len > reply_buf.len) {
        return false;
    }

    // Build Ethernet header
    const reply_eth: *EthernetHeader = @ptrCast(@alignCast(&reply_buf[0]));
    @memcpy(&reply_eth.dst_mac, &dst_mac);
    @memcpy(&reply_eth.src_mac, &iface.mac_addr);
    reply_eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const reply_ip: *Ipv4Header = @ptrCast(@alignCast(&reply_buf[eth_len]));
    reply_ip.version_ihl = 0x45; // Version 4, IHL 5
    reply_ip.tos = 0;
    reply_ip.setTotalLength(@truncate(ip_len + icmp_len));
    reply_ip.identification = @byteSwap(ipv4.getNextId());
    reply_ip.flags_fragment = @byteSwap(@as(u16, 0x4000)); // Don't Fragment
    reply_ip.ttl = ipv4.DEFAULT_TTL;
    reply_ip.protocol = ipv4.PROTO_ICMP;
    reply_ip.checksum = 0;
    reply_ip.setSrcIp(iface.ip_addr);
    reply_ip.setDstIp(src_ip);

    // Calculate IP checksum
    reply_ip.checksum = checksum.ipChecksum(reply_buf[eth_len..][0..ip_len]);

    // Build ICMP reply
    const reply_icmp: *IcmpHeader = @ptrCast(@alignCast(&reply_buf[eth_len + ip_len]));
    reply_icmp.icmp_type = TYPE_ECHO_REPLY;
    reply_icmp.code = 0;
    reply_icmp.checksum = 0;
    reply_icmp.identifier = req_icmp.identifier; // Keep same identifier
    reply_icmp.sequence = req_icmp.sequence; // Keep same sequence

    // Copy echo data (everything after ICMP header)
    const echo_data_len = icmp_len - packet.ICMP_HEADER_SIZE;
    // Security: Validate that we don't read past the end of the packet buffer
    // The IP header length check only verified packet.ICMP_HEADER_SIZE availability
    const available_data = req_pkt.len - (req_pkt.transport_offset + packet.ICMP_HEADER_SIZE);
    
    if (echo_data_len > 0 and echo_data_len <= available_data) {
        const req_data = req_pkt.data[req_pkt.transport_offset + packet.ICMP_HEADER_SIZE ..][0..echo_data_len];
        const reply_data = reply_buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..echo_data_len];
        @memcpy(reply_data, req_data);
    }

    // Calculate ICMP checksum
    const reply_icmp_data = reply_buf[eth_len + ip_len ..][0..icmp_len];
    reply_icmp.checksum = checksum.icmpChecksum(reply_icmp_data);

    // Transmit reply
    return iface.transmit(reply_buf[0..total_len]);
}

/// Handle ICMP Destination Unreachable messages
/// Specifically handles Code 4 (Fragmentation Needed) for PMTUD (RFC 1191)
/// Security: Validates ICMP payload against active connections per RFC 5927
fn handleDestUnreachable(pkt: *PacketBuffer, icmp: *align(1) const IcmpHeader) bool {
    // ICMP Destination Unreachable format:
    // Bytes 0-1: Type (3) + Code
    // Bytes 2-3: Checksum
    // Bytes 4-5: Unused (for most codes) or Next-Hop MTU (for Code 4)
    // Bytes 6-7: Next-Hop MTU (RFC 1191, only valid for Code 4)
    // Bytes 8+: Original IP header + first 8 bytes of original datagram

    if (icmp.code == CODE_FRAGMENTATION_NEEDED) {
        // Extract next-hop MTU from ICMP message
        // Per RFC 1191, bytes 6-7 contain the next-hop MTU in network byte order
        // The identifier/sequence fields in IcmpHeader overlay bytes 4-7
        // So: identifier = bytes 4-5 (unused), sequence = bytes 6-7 (MTU)
        const next_hop_mtu = @byteSwap(icmp.sequence);

        // RFC 1191: If MTU field is 0, use "plateau" table
        // For simplicity, we use a conservative estimate based on common MTUs
        var effective_mtu: u16 = next_hop_mtu;
        if (next_hop_mtu == 0) {
            // Old-style ICMP without MTU field - use conservative MTU
            // Common plateau: 1492 (PPPoE), 1006, 508, 296
            effective_mtu = 1006;
        }

        // Extract original packet info from the embedded IP header
        // The original IP header starts 8 bytes after ICMP header start
        const orig_ip_offset = pkt.transport_offset + packet.ICMP_HEADER_SIZE;
        if (orig_ip_offset + packet.IP_HEADER_SIZE <= pkt.len) {
            const orig_ip: *const Ipv4Header = @ptrCast(@alignCast(&pkt.data[orig_ip_offset]));
            const original_src = orig_ip.getSrcIp();
            const original_dst = orig_ip.getDstIp();
            const orig_ip_len = orig_ip.getHeaderLength();

            // Security (RFC 5927): Validate ICMP error relates to packet we sent.
            // Extract transport ports and verify against active TCP connections.
            // This prevents cache poisoning via spoofed ICMP messages.
            const transport_offset = orig_ip_offset + orig_ip_len;
            if (transport_offset + 4 <= pkt.len and orig_ip.protocol == ipv4.PROTO_TCP) {
                const orig_transport = pkt.data[transport_offset..][0..4];
                const local_port = (@as(u16, orig_transport[0]) << 8) | orig_transport[1];
                const remote_port = (@as(u16, orig_transport[2]) << 8) | orig_transport[3];

                // Extract Sequence number if possible (need 8 bytes of transport header)
                // TCP: src(2), dst(2), seq(4)
                var seq_num: ?u32 = null;
                if (transport_offset + 8 <= pkt.len) {
                    const seq_bytes = pkt.data[transport_offset + 4..][0..4];
                    seq_num = @byteSwap(std.mem.readInt(u32, seq_bytes, .little));
                    // Alternatively: (@as(u32, seq_bytes[0]) << 24)...
                    // Let's use manual construction to be consistent with other code in file
                    seq_num = (@as(u32, seq_bytes[0]) << 24) | (@as(u32, seq_bytes[1]) << 16) | (@as(u32, seq_bytes[2]) << 8) | @as(u32, seq_bytes[3]);
                }

                // Validate: original packet was from us (src) to them (dst)
                // Only update PMTU if we have an active connection matching this 4-tuple
                if (tcp.validateConnectionExists(original_src, local_port, original_dst, remote_port, seq_num)) {
                    ipv4.updatePmtu(original_dst, effective_mtu);
                }
                // Silently ignore PMTU updates for non-existent connections
            } else if (orig_ip.protocol == ipv4.PROTO_UDP) {
                // SECURITY: Validate we recently sent UDP to this destination.
                // Without this check, an attacker could send spoofed ICMP PMTU
                // messages to degrade performance or cause fragmentation DoS.
                if (validateUdpTransmit(original_dst)) {
                    ipv4.updatePmtu(original_dst, effective_mtu);
                }
                // Silently ignore PMTU updates for destinations we haven't sent to
            }
            // Ignore PMTU for other protocols (ICMP, etc.)
        }
    }

    // Other codes (Network/Host/Protocol/Port Unreachable)
    // Notify transport layer of connection failures
    
    // Parse original IP header to get protocol and ports
    const orig_ip_offset = pkt.transport_offset + packet.ICMP_HEADER_SIZE;
    if (orig_ip_offset + packet.IP_HEADER_SIZE > pkt.len) return true;
    
    const orig_ip: *const Ipv4Header = @ptrCast(@alignCast(&pkt.data[orig_ip_offset]));
    const orig_ip_len = orig_ip.getHeaderLength();
    
    // Check if we have enough data for transport header (at least 8 bytes)
    const transport_offset = orig_ip_offset + orig_ip_len;
    if (transport_offset + 8 > pkt.len) return true;
    
    const orig_transport_data = pkt.data[transport_offset..][0..8];
    const src_ip = orig_ip.getSrcIp(); // This should be US (or one of our IPs)
    const dst_ip = orig_ip.getDstIp(); // The remote host
    
    // Determine Protocol
    switch (orig_ip.protocol) {
        ipv4.PROTO_TCP => {
            // Extract ports (src=local, dst=remote from original packet perspective)
            // TCP: Src Port (0-1), Dst Port (2-3)
            const local_port = (@as(u16, orig_transport_data[0]) << 8) | orig_transport_data[1];
            const remote_port = (@as(u16, orig_transport_data[2]) << 8) | orig_transport_data[3];
            
            var seq_num: ?u32 = null;
            if (transport_offset + 8 <= pkt.len) {
                 const seq_bytes = pkt.data[transport_offset + 4 ..][0..4];
                 seq_num = (@as(u32, seq_bytes[0]) << 24) | (@as(u32, seq_bytes[1]) << 16) | (@as(u32, seq_bytes[2]) << 8) | @as(u32, seq_bytes[3]);
            }

            tcp.handleIcmpError(
                src_ip, local_port,
                dst_ip, remote_port,
                icmp.icmp_type, icmp.code,
                seq_num
            );
        },
        // UDP integration can be added later
        else => {},
    }

    return true;
}

/// Verify ICMP checksum
fn verifyIcmpChecksum(data: []const u8) bool {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) {
        const word = (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
        sum += word;
    }

    // Handle odd byte
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }

    // Fold
    while (sum > 0xFFFF) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return @as(u16, @truncate(sum)) == 0xFFFF;
}

/// Send an ICMP Echo Request (ping)
/// Returns false if packet couldn't be sent (ARP not resolved, etc.)
pub fn sendEchoRequest(
    iface: *Interface,
    dst_ip: u32,
    identifier: u16,
    sequence: u16,
    data: []const u8,
) bool {
    // Resolve destination MAC
    const next_hop = iface.getGateway(dst_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        return false;
    };

    // Calculate sizes
    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const icmp_len = packet.ICMP_HEADER_SIZE + data.len;
    const total_len = eth_len + ip_len + icmp_len;

    var buf: [packet.MAX_PACKET_SIZE]u8 = undefined;
    if (total_len > buf.len) {
        return false;
    }

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@truncate(ip_len + icmp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_ICMP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);
    ip.checksum = checksum.ipChecksum(buf[eth_len..][0..ip_len]);

    // Build ICMP header
    const icmp_hdr: *IcmpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    icmp_hdr.icmp_type = TYPE_ECHO_REQUEST;
    icmp_hdr.code = 0;
    icmp_hdr.checksum = 0;
    icmp_hdr.identifier = @byteSwap(identifier);
    icmp_hdr.sequence = @byteSwap(sequence);

    // Copy data
    if (data.len > 0) {
        @memcpy(buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..data.len], data);
    }

    // Calculate ICMP checksum
    icmp_hdr.checksum = checksum.icmpChecksum(buf[eth_len + ip_len ..][0..icmp_len]);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}

/// Send ICMP Destination Unreachable message
pub fn sendDestUnreachable(
    iface: *Interface,
    original_pkt: *const PacketBuffer,
    code: u8,
) bool {
    const orig_ip = original_pkt.ipHeader();
    const src_ip = orig_ip.getSrcIp();

    // Don't send ICMP errors for:
    // - ICMP errors (to prevent loops)
    // - Broadcast/multicast destinations
    if (orig_ip.protocol == ipv4.PROTO_ICMP) {
        const orig_icmp = original_pkt.icmpHeader();
        if (orig_icmp.icmp_type != TYPE_ECHO_REQUEST and
            orig_icmp.icmp_type != TYPE_ECHO_REPLY)
        {
            return false;
        }
    }

    // Resolve MAC
    const next_hop = iface.getGateway(src_ip);
    const dst_mac = arp.resolveOrRequest(iface, next_hop, null) orelse {
        return false;
    };

    // ICMP error includes IP header + 8 bytes of original datagram
    const orig_ip_len = orig_ip.getHeaderLength();
    const orig_data_len = @min(orig_ip_len + 8, original_pkt.len - original_pkt.ip_offset);

    const eth_len = packet.ETH_HEADER_SIZE;
    const ip_len = packet.IP_HEADER_SIZE;
    const icmp_len = packet.ICMP_HEADER_SIZE + orig_data_len;
    const total_len = eth_len + ip_len + icmp_len;

    var buf: [packet.MAX_PACKET_SIZE]u8 = undefined;
    if (total_len > buf.len) {
        return false;
    }

    // Build Ethernet header
    const eth: *EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &dst_mac);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_IPV4);

    // Build IP header
    const ip: *Ipv4Header = @ptrCast(@alignCast(&buf[eth_len]));
    ip.version_ihl = 0x45;
    ip.tos = 0;
    ip.setTotalLength(@truncate(ip_len + icmp_len));
    ip.identification = @byteSwap(ipv4.getNextId());
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));
    ip.ttl = ipv4.DEFAULT_TTL;
    ip.protocol = ipv4.PROTO_ICMP;
    ip.checksum = 0;
    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(src_ip);
    ip.checksum = checksum.ipChecksum(buf[eth_len..][0..ip_len]);

    // Build ICMP header
    const icmp_hdr: *IcmpHeader = @ptrCast(@alignCast(&buf[eth_len + ip_len]));
    icmp_hdr.icmp_type = TYPE_DEST_UNREACHABLE;
    icmp_hdr.code = code;
    icmp_hdr.checksum = 0;
    icmp_hdr.identifier = 0; // Unused for Dest Unreachable
    icmp_hdr.sequence = 0;

    // Copy original IP header + 8 bytes
    const orig_data = original_pkt.data[original_pkt.ip_offset..][0..orig_data_len];
    @memcpy(buf[eth_len + ip_len + packet.ICMP_HEADER_SIZE ..][0..orig_data_len], orig_data);

    // Calculate ICMP checksum
    icmp_hdr.checksum = checksum.icmpChecksum(buf[eth_len + ip_len ..][0..icmp_len]);

    // Transmit
    return iface.transmit(buf[0..total_len]);
}
