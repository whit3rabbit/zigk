// IPv4 Protocol Implementation
//
// Complies with:
// - RFC 791: Internet Protocol
// - RFC 1191: Path MTU Discovery
// - RFC 7126: Recommendations on Filtering of IP Options
//
// Handles IPv4 packet parsing, validation, and building.
// Dispatches to ICMP, UDP based on protocol field.

const std = @import("std");
const packet = @import("../core/packet.zig");
const interface = @import("../core/interface.zig");
const checksum = @import("../core/checksum.zig");
const ethernet = @import("../ethernet/ethernet.zig");
const arp = @import("arp/root.zig");
const pmtu = @import("pmtu.zig");
const PacketBuffer = packet.PacketBuffer;
const Ipv4Header = packet.Ipv4Header;
const EthernetHeader = packet.EthernetHeader;
const Interface = interface.Interface;
const heap = @import("heap");
const platform = @import("../platform.zig");
const entropy = platform.entropy;
const reassembly = @import("reassembly.zig");
const loopback = @import("../loopback.zig");

// Forward declarations for transport protocols
const icmp = @import("../transport/icmp.zig");
const udp = @import("../transport/udp.zig");
const tcp = @import("../transport/tcp.zig");

/// IP protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// Minimum transport header sizes for validation
/// SECURITY: After reassembly, we must validate the payload is large enough
/// to contain a valid transport header before dispatching. Without this check,
/// transport layer parsing could read beyond buffer bounds.
const ICMP_HEADER_MIN: usize = 8; // Type(1) + Code(1) + Checksum(2) + rest(4)
const UDP_HEADER_MIN: usize = 8; // SrcPort(2) + DstPort(2) + Len(2) + Checksum(2)
const TCP_HEADER_MIN: usize = 20; // Minimum TCP header without options

/// Default TTL for outgoing packets
pub const DEFAULT_TTL: u8 = 64;

var ipv4_allocator: ?std.mem.Allocator = null;

// ============================================================================
// IPv4 Options Constants (RFC 791, RFC 7126)
// ============================================================================

/// IP option types
pub const IPOPT_EOL: u8 = 0; // End of Options List
pub const IPOPT_NOP: u8 = 1; // No Operation (padding)
pub const IPOPT_SEC: u8 = 130; // Security (obsolete)
pub const IPOPT_RR: u8 = 7; // Record Route
pub const IPOPT_TS: u8 = 68; // Timestamp
pub const IPOPT_LSRR: u8 = 131; // Loose Source Routing
pub const IPOPT_SSRR: u8 = 137; // Strict Source Routing

/// Minimum IP header size (without options)
pub const IP_HEADER_MIN: usize = 20;

/// Maximum IP header size (with 40 bytes of options)
pub const IP_HEADER_MAX: usize = 60;

/// IP identification counter for fragmentation
/// IP identification counter (removed in favor of randomization)
// var ip_id_counter: u16 = 0;

/// Initialize IPv4 subsystem
pub fn init(allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    ipv4_allocator = allocator;
    arp.init(allocator, ticks_per_sec);
    reassembly.init(allocator);
}

// ============================================================================
// Path MTU Discovery (RFC 1191)
// ============================================================================

// Logic moved to pmtu.zig
pub const DEFAULT_MTU = pmtu.DEFAULT_MTU;
pub const MIN_MTU = pmtu.MIN_MTU;

pub fn lookupPmtu(dst_ip: u32) u16 {
    return pmtu.lookupPmtu(dst_ip);
}

pub fn updatePmtu(dst_ip: u32, new_mtu: u16) void {
    pmtu.updatePmtu(dst_ip, new_mtu);
}

pub fn getEffectiveMss(dst_ip: u32) u16 {
    return pmtu.getEffectiveMss(dst_ip);
}

// ============================================================================
// IPv4 Options Validation (RFC 791, RFC 7126)
// ============================================================================

/// Validate IPv4 options without processing them
/// Returns true if options are valid (or absent), false if malformed
/// This is a security-focused validation that drops dangerous source routing
pub fn validateOptions(pkt: *const PacketBuffer, header_len: usize) bool {
    // No options present if header is minimum size
    if (header_len <= IP_HEADER_MIN) {
        return true;
    }

    // Validate header doesn't exceed packet length
    if (pkt.ip_offset + header_len > pkt.len) {
        return false;
    }

    const options_start = pkt.ip_offset + IP_HEADER_MIN;
    const options_end = pkt.ip_offset + header_len;
    var offset = options_start;

    // Walk through options list
    while (offset < options_end) {
        const option_type = pkt.data[offset];

        // End of Options List - valid termination
        if (option_type == IPOPT_EOL) {
            return true;
        }

        // No Operation (single byte padding)
        if (option_type == IPOPT_NOP) {
            offset += 1;
            continue;
        }

        // All other options have type + length + data format
        // Length field is at offset + 1
        if (offset + 1 >= options_end) {
            return false; // Truncated option (no length byte)
        }

        const option_len = pkt.data[offset + 1];

        // Length must be at least 2 (type + length bytes)
        if (option_len < 2) {
            return false; // Invalid length
        }

        // Length must not exceed remaining options space
        if (offset + option_len > options_end) {
            return false; // Option extends beyond header
        }

        // SECURITY: Drop dangerous IP options per RFC 7126 recommendations.
        // These options are rarely used legitimately and enable various attacks:
        // - Source routing (LSRR/SSRR): Bypass firewalls, MITM attacks
        // - Record Route: Network reconnaissance, path discovery
        // - Timestamp: Network reconnaissance, timing attacks
        switch (option_type) {
            IPOPT_LSRR, IPOPT_SSRR => {
                // Source routing allows attackers to specify packet path,
                // bypassing firewalls and enabling MITM attacks
                return false;
            },
            IPOPT_RR => {
                // Record Route reveals network topology to attackers
                return false;
            },
            IPOPT_TS => {
                // Timestamp option enables timing-based attacks and reconnaissance
                return false;
            },
            else => {},
        }

        // Skip to next option
        offset += option_len;
    }

    // Reached end of options area without EOOL - still valid
    return true;
}

/// Process an incoming IPv4 packet
pub fn processPacket(iface: *Interface, pkt: *PacketBuffer) bool {
    // SECURITY: Use bounds-checked accessor for untrusted incoming packets.
    // This provides defense-in-depth: even if pkt.ip_offset is corrupted,
    // getIpv4HeaderMut returns null rather than accessing invalid memory.
    const ip = packet.getIpv4HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    // Validate IP version (must be 4)
    if (ip.getVersion() != 4) {
        return false;
    }

    // Validate IHL (must be at least 5 = 20 bytes)
    const ihl = ip.version_ihl & 0x0F;
    if (ihl < 5) {
        return false;
    }

    const header_len = @as(usize, ihl) * 4;

    // Defense in depth: Verify packet buffer contains the full header
    if (pkt.ip_offset + header_len > pkt.len) {
        return false;
    }

    // Validate IP options if present (RFC 791, RFC 7126)
    // This also drops dangerous source routing options for security
    if (!validateOptions(pkt, header_len)) {
        return false;
    }

    // Validate header checksum
    const header_bytes = pkt.data[pkt.ip_offset..][0..header_len];
    if (!checksum.verifyIpChecksum(header_bytes)) {
        return false;
    }

    // Validate total length
    const total_len = ip.getTotalLength();
    if (total_len < header_len or pkt.ip_offset + total_len > pkt.len) {
        return false;
    }

    // SECURITY: Validate payload length is non-zero for fragmented packets.
    // A crafted packet with total_len == header_len has zero payload, which
    // could cause issues in reassembly or transport layer dispatch.
    // For non-fragmented packets, zero payload is technically valid but unusual.
    const payload_len = total_len - header_len;
    if (payload_len == 0) {
        // Zero-length payload - drop as likely malformed
        // Valid IP packets should have at least 1 byte of payload
        return false;
    }

    // Security: Trim packet length to match IP Total Length
    // This removes Ethernet padding (e.g. 0-bytes at end of frame)
    // ensuring upper layers don't process garbage data.
    pkt.len = pkt.ip_offset + total_len;

    // Check if packet is for us (unicast, broadcast, or multicast)
    const dst_ip = ip.getDstIp();
    
    // Store destination IP in packet metadata for transport layers
    // Important for reassembled packets where the IP header is virtual/stripped
    pkt.dst_ip = dst_ip;
    pkt.src_ip = ip.getSrcIp();

    // Determine packet type and whether we should accept it
    if (dst_ip == iface.ip_addr) {
        // Unicast to our IP - accept
        pkt.is_broadcast = false;
        pkt.is_multicast = false;
    } else if (dst_ip == 0xFFFFFFFF) {
        // Limited broadcast - accept
        pkt.is_broadcast = true;
        pkt.is_multicast = false;
    } else if (isBroadcast(dst_ip, iface.netmask)) {
        // Directed broadcast - accept
        pkt.is_broadcast = true;
        pkt.is_multicast = false;
    } else if (isMulticast(dst_ip)) {
        // Multicast - accept (UDP layer will filter by group membership)
        pkt.is_broadcast = false;
        pkt.is_multicast = true;
    } else {
        // Not for us - drop
        return false;
    }

    // Check for fragmentation - we don't support it in MVP
    // Check for fragmentation
    // MF (More Fragments) bit or Fragment Offset != 0
    const flags_frag = @byteSwap(ip.flags_fragment);
    const mf_bit = (flags_frag >> 13) & 0x1;
    const frag_offset = flags_frag & 0x1FFF;

    var payload_slice: []u8 = &[_]u8{};
    var is_reassembled = false;
    // SECURITY: Store the ReassemblyResult which owns the buffer.
    // Previously we stored a slice that could become dangling after lock release.
    var reassembly_result: ?reassembly.ReassemblyResult = null;

    if (mf_bit != 0 or frag_offset != 0) {
        // Fragmented packet - attempt reassembly
        // payload_len already validated non-zero above
        const current_payload = pkt.data[pkt.ip_offset + header_len..][0..payload_len];

        if (reassembly.processFragment(
            ip.getSrcIp(),
            ip.getDstIp(),
            ip.protocol,
            @byteSwap(ip.identification),
            frag_offset,
            mf_bit != 0,
            current_payload
        )) |res| {
            // SECURITY: res.owned_buffer is now an OWNED copy, not a reference
            // to the cache entry. The cache entry was already freed inside
            // processFragment while holding the lock. No UAF possible.
            reassembly_result = res;
            payload_slice = res.payload();
            is_reassembled = true;
        } else {
            return true; // Consumed (stored or incomplete), stop processing
        }
    } else {
        // Not fragmented - payload_len already validated non-zero above
        payload_slice = pkt.data[pkt.ip_offset + header_len..][0..payload_len];
    }

    // Set transport layer offset
    
    if (is_reassembled) {
        // SECURITY: reassembly_result now contains an OWNED buffer.
        // The data was copied inside processFragment() while holding the lock,
        // eliminating the UAF window that existed before.
        var result = reassembly_result.?;
        defer result.deinit(); // Free the owned buffer when we're done

        // Create PacketBuffer using the owned buffer directly
        // No extra allocation needed - reassembly already allocated for us
        var virt_pkt = PacketBuffer.init(result.owned_buffer, result.payload_len);

        // Copy relevant metadata from original packet
        virt_pkt.src_ip = pkt.src_ip;
        virt_pkt.dst_ip = pkt.dst_ip;
        virt_pkt.src_port = pkt.src_port;
        virt_pkt.ip_protocol = ip.protocol;

        virt_pkt.eth_offset = 0;
        virt_pkt.ip_offset = 0;
        virt_pkt.transport_offset = 0;

        // SECURITY: Validate minimum payload size before dispatching to transport layer.
        // Attackers could craft fragments that reassemble to a payload smaller than
        // the transport header, causing out-of-bounds reads in the transport layer.
        // In Debug/ReleaseSafe this panics; in ReleaseFast it's undefined behavior.
        const min_size: usize = switch (ip.protocol) {
            PROTO_ICMP => ICMP_HEADER_MIN,
            PROTO_UDP => UDP_HEADER_MIN,
            PROTO_TCP => TCP_HEADER_MIN,
            else => 0,
        };

        if (result.payload_len < min_size) {
            // Reassembled payload too small for transport header - drop
            // defer will call result.deinit() to free memory
            return false;
        }

        // SECURITY REQUIREMENT: Transport layer MUST process synchronously.
        // The virt_pkt.data points to result.owned_buffer which is freed by
        // defer result.deinit() when this scope exits. Transport handlers:
        // 1. MUST NOT store pointers to the packet data for later use
        // 2. MUST copy any data they need to retain
        // 3. MUST complete all processing before returning
        // Violating these rules causes use-after-free when defer runs.
        return switch (ip.protocol) {
            PROTO_ICMP => icmp.processPacket(iface, &virt_pkt),
            PROTO_UDP => udp.processPacket(iface, &virt_pkt),
            PROTO_TCP => tcp.processPacket(iface, &virt_pkt),
            else => false,
        };
    }

    // Normal non-fragmented path (using original pkt)
    pkt.transport_offset = pkt.ip_offset + header_len;
    pkt.ip_protocol = ip.protocol;
    // pkt.src_ip already set above
    
    // Dispatch based on protocol (existing code)
    switch (ip.protocol) {
        PROTO_ICMP => return icmp.processPacket(iface, pkt),
        PROTO_UDP => return udp.processPacket(iface, pkt),
        PROTO_TCP => return tcp.processPacket(iface, pkt),
        else => return false,
    }
}
// Removed original switch block to avoid duplication

/// Assumes Ethernet header is already in place
/// Sets up IP header and returns pointer to payload area
/// tos: Type of Service / DSCP value for the packet
pub fn buildPacket(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_ip: u32,
    protocol: u8,
    payload_len: usize,
) bool {
    return buildPacketWithTos(iface, pkt, dst_ip, protocol, payload_len, 0);
}

/// Build an IPv4 packet header with explicit ToS value
/// tos: Type of Service / DSCP value (0 = normal service)
pub fn buildPacketWithTos(
    iface: *const Interface,
    pkt: *PacketBuffer,
    dst_ip: u32,
    protocol: u8,
    payload_len: usize,
    tos: u8,
) bool {
    // IP header starts after Ethernet header
    pkt.ip_offset = packet.ETH_HEADER_SIZE;
    pkt.transport_offset = pkt.ip_offset + packet.IP_HEADER_SIZE;

    const ip: *Ipv4Header = @ptrCast(@alignCast(&pkt.data[pkt.ip_offset]));

    // Version 4, IHL 5 (20 bytes, no options)
    ip.version_ihl = 0x45;
    ip.tos = tos;
    ip.setTotalLength(@truncate(packet.IP_HEADER_SIZE + payload_len));

    // Random ID for each packet
    ip.identification = @byteSwap(getNextId());

    // Don't Fragment flag set, no fragmentation offset
    ip.flags_fragment = @byteSwap(@as(u16, 0x4000));

    ip.ttl = DEFAULT_TTL;
    ip.protocol = protocol;
    ip.checksum = 0; // Will calculate after filling header

    ip.setSrcIp(iface.ip_addr);
    ip.setDstIp(dst_ip);

    // Calculate and set header checksum
    const header_bytes = pkt.data[pkt.ip_offset..][0..packet.IP_HEADER_SIZE];
    ip.checksum = checksum.ipChecksum(header_bytes);

    return true;
}

/// Send an IP packet
/// Resolves destination MAC via ARP and transmits
pub fn sendPacket(iface: *Interface, pkt: *PacketBuffer, dst_ip: u32) bool {
    // Check for loopback destination (127.x.x.x)
    // Route through loopback interface instead of physical NIC
    if (isLoopback(dst_ip)) {
        if (loopback.getInterface()) |lo| {
            // Build minimal Ethernet header (loopback transmit expects it)
            if (!ethernet.buildFrame(lo, pkt, [_]u8{0} ** 6, ethernet.ETHERTYPE_IPV4)) {
                return false;
            }

            // Update packet length
            // SAFETY: ip_offset was set by buildPacket above, packet is trusted
            const ip = pkt.ipHeader();
            pkt.len = pkt.ip_offset + ip.getTotalLength();

            // Transmit via loopback (injects back to receive path)
            return lo.transmit(pkt.data[0..pkt.len]);
        }
        // Loopback not initialized - drop packet
        return false;
    }

    // Determine next-hop IP (gateway if not on local subnet)
    const next_hop = iface.getGateway(dst_ip);

    // Resolve MAC address
    // Resolve MAC address
    // Check for broadcast (255.255.255.255 or subnet broadcast)
    var dst_mac: [6]u8 = undefined;

    if (isBroadcast(dst_ip, iface.netmask) or dst_ip == 0xFFFFFFFF) {
        dst_mac = ethernet.BROADCAST_MAC;
    } else if (isMulticast(dst_ip)) {
        // Construct IPv4 Multicast MAC: 01:00:5E:xx:xx:xx
        // Lower 23 bits of IP address mapped to MAC
        dst_mac[0] = 0x01;
        dst_mac[1] = 0x00;
        dst_mac[2] = 0x5E;
        dst_mac[3] = @truncate((dst_ip >> 16) & 0x7F);
        dst_mac[4] = @truncate((dst_ip >> 8) & 0xFF);
        dst_mac[5] = @truncate(dst_ip & 0xFF);
    } else {
        // Unicast - resolve via ARP
        dst_mac = arp.resolveOrRequest(iface, next_hop, pkt) orelse {
            // ARP not resolved yet - packet queued in ARP module
            return true;
        };
    }

    // Build Ethernet header
    if (!ethernet.buildFrame(iface, pkt, dst_mac, ethernet.ETHERTYPE_IPV4)) {
        return false;
    }

    // Update packet length
    // SAFETY: ip_offset was set by buildPacket, packet is trusted outgoing
    const ip = pkt.ipHeader();
    pkt.len = pkt.ip_offset + ip.getTotalLength();

    // Check if fragmentation is needed
    // PacketBuffer contains Eth + IP + Payload. `pkt.len` is total length.
    if (pkt.len > iface.mtu) {
        // Fragmentation needed
        return sendFragmentedPacket(iface, pkt, dst_mac);
    }

    // Transmit normally
    return ethernet.sendFrame(iface, pkt);
}

/// Maximum IP payload size (65535 - 20 = 65515 bytes)
/// Fragment offset field is 13 bits, representing 8-byte units (max offset = 8191 * 8 = 65528)
const MAX_IP_PAYLOAD: usize = 65515;

/// Send a packet fragmented into multiple IP datagrams
fn sendFragmentedPacket(iface: *Interface, pkt: *PacketBuffer, dst_mac: [6]u8) bool {
    // Original IP header
    // SAFETY: Called only from sendPacket with trusted outgoing packets
    const orig_ip = pkt.ipHeader();

    const ip_header_len = orig_ip.getHeaderLength();

    // Total payload to fragment (everything after IP header)
    // This includes Transport Header + Data
    const payload_start = pkt.ip_offset + ip_header_len;
    const payload = pkt.data[payload_start..pkt.len];

    // SECURITY: Validate payload size to prevent fragment offset overflow.
    // Fragment offset is 13 bits representing 8-byte units (max = 8191 * 8 = 65528).
    // If payload exceeds this, later fragments would have truncated offsets,
    // causing incorrect reassembly or memory corruption on receiver.
    if (payload.len > MAX_IP_PAYLOAD) {
        return false;
    }
    
    // Max payload per fragment (MTU - IP Header), aligned to 8 bytes
    const mtu_payload = (iface.mtu - ip_header_len) & ~@as(u16, 7);

    const alloc = heap.allocator();
    const frag_buf = alloc.alloc(u8, packet.MAX_PACKET_SIZE) catch {
        return false;
    };
    defer alloc.free(frag_buf);
    
    var offset: usize = 0;
    while (offset < payload.len) {
        // Calculate chunk size
        const remaining = payload.len - offset;
        const chunk_len = @min(remaining, mtu_payload);
        const last_frag = (chunk_len == remaining);
        
        // Build fragment packet
        var frag_pkt = PacketBuffer.init(frag_buf, 0);

        // 1. Build Ethernet Header (recycle buildFrame)
        if (!ethernet.buildFrame(iface, &frag_pkt, dst_mac, ethernet.ETHERTYPE_IPV4)) {
            return false;
        }

        // 2. Build IP Header
        const frag_ip_offset = packet.ETH_HEADER_SIZE;
        frag_pkt.ip_offset = frag_ip_offset;
        frag_pkt.transport_offset = frag_ip_offset + ip_header_len; // roughly
        
        const frag_ip: *Ipv4Header = @ptrCast(@alignCast(&frag_buf[frag_ip_offset]));
        
        // Copy original IP header fields
        frag_ip.* = orig_ip.*;
        
        // Update lengths
        const total_len = ip_header_len + chunk_len;
        frag_ip.setTotalLength(@truncate(total_len));
        
        // Update fragmentation fields
        // ID is same as original
        const frag_off_val = (offset / 8);
        var flags = frag_off_val & 0x1FFF;
        if (!last_frag) {
            flags |= 0x2000; // Set MF bit (bit 13)
        }
        frag_ip.flags_fragment = @byteSwap(@as(u16, @truncate(flags)));
        
        // Recalculate checksum
        frag_ip.checksum = 0;
        const header_bytes = frag_buf[frag_ip_offset..][0..ip_header_len];
        frag_ip.checksum = checksum.ipChecksum(header_bytes);
        
        // 3. Copy Payload Chunk
        const payload_dest = frag_ip_offset + ip_header_len;
        @memcpy(frag_buf[payload_dest..][0..chunk_len], payload[offset..][0..chunk_len]);
        
        // Update fragment packet length
        frag_pkt.len = payload_dest + chunk_len;
        
        // Transmit fragment
        if (!ethernet.sendFrame(iface, &frag_pkt)) {
            return false;
        }
        
        offset += chunk_len;
    }
    
    return true;
}

/// Decrement TTL and update checksum (for routing, if we ever support it)
pub fn decrementTtl(pkt: *PacketBuffer) bool {
    // SECURITY: Use bounds-checked accessor - this is a public function
    // that may receive packets from various sources.
    const ip = packet.getIpv4HeaderMut(pkt.data, pkt.ip_offset) orelse return false;

    if (ip.ttl <= 1) {
        return false; // TTL expired
    }

    // Use incremental checksum update
    const old_ttl = ip.ttl;
    ip.ttl -= 1;

    // Update checksum: TTL is in high byte of a 16-bit word with protocol
    const old_value = (@as(u16, old_ttl) << 8) | ip.protocol;
    const new_value = (@as(u16, ip.ttl) << 8) | ip.protocol;
    ip.checksum = checksum.updateChecksum(ip.checksum, old_value, new_value);

    return true;
}

/// Fallback PRNG state for when hardware entropy is unavailable
/// SECURITY: Uses atomic operations for thread-safety on SMP systems.
/// Without atomics, concurrent CPU access could cause torn reads/writes,
/// producing predictable or duplicate IP IDs enabling fragment injection attacks.
var fallback_prng_state: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var prng_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Get next IP identification value
/// SECURITY: Unpredictable IP IDs prevent idle scanning attacks where an attacker
/// can infer host activity by observing predictable ID increments. We use hardware
/// entropy (RDRAND) when available, with a seeded PRNG fallback.
/// Thread-safe: Uses atomic operations to prevent race conditions on SMP.
pub fn getNextId() u16 {
    // Try hardware entropy first (RDRAND on x86_64)
    const hw_entropy = entropy.getHardwareEntropy();

    // Check if hardware entropy is available and not returning a constant
    // (Some VMs return 0 or -1 when RDRAND fails)
    if (hw_entropy != 0 and hw_entropy != @as(u64, 0xFFFFFFFFFFFFFFFF)) {
        return @truncate(hw_entropy);
    }

    // Fallback: Use xorshift64* PRNG seeded from available entropy sources
    // This is better than a counter but not cryptographically secure
    // SECURITY: Use compare-exchange for initialization to prevent double-init race
    if (!prng_initialized.load(.acquire)) {
        // SECURITY: Mix multiple entropy sources to reduce predictability:
        // 1. TSC/timer value - adds timing jitter
        // 2. Address of static variable - varies with ASLR
        // 3. Constant to ensure non-zero seed
        const tsc = platform.timing.rdtsc();
        const addr_entropy = @intFromPtr(&fallback_prng_state);

        // Mix sources using multiplication and XOR for distribution
        var seed: u64 = tsc;
        seed ^= addr_entropy *% 0x9E3779B97F4A7C15; // Golden ratio
        seed ^= 0xDEADBEEFCAFEBABE;

        // Ensure non-zero state
        if (seed == 0) {
            seed = 0x853C49E6748FEA9B; // Arbitrary non-zero constant
        }

        // Atomically initialize - if another CPU beat us, that's fine
        _ = fallback_prng_state.cmpxchgStrong(0, seed, .acq_rel, .acquire);
        prng_initialized.store(true, .release);
    }

    // SECURITY: Atomically update PRNG state using compare-exchange loop.
    // This prevents torn reads/writes and ensures each CPU gets unique IDs.
    const jitter = platform.timing.rdtsc();

    while (true) {
        const old_state = fallback_prng_state.load(.acquire);

        // Mix in jitter and apply xorshift64* step
        var x = old_state ^ jitter;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;

        // Try to update state atomically
        if (fallback_prng_state.cmpxchgWeak(old_state, x, .acq_rel, .acquire)) |_| {
            // CAS failed - another CPU modified state, retry with new value
            continue;
        } else {
            // Success - return the result
            return @truncate(x *% 0x2545F4914F6CDD1D);
        }
    }
}

/// Validate that a netmask has contiguous 1s followed by 0s
/// Valid examples: 0xFFFFFF00 (255.255.255.0), 0xFFFFFE00 (255.255.254.0)
/// Invalid examples: 0xFF00FF00 (255.0.255.0), 0x00000000 (0.0.0.0)
pub fn isValidNetmask(mask: u32) bool {
    if (mask == 0) return false;
    const inverted = ~mask;
    // For a valid contiguous mask, inverted should be (2^n - 1)
    // i.e., all 1s in low bits. (inverted & (inverted + 1)) == 0 tests this.
    return (inverted & (inverted +% 1)) == 0;
}

/// Check if IP is broadcast (all 1s or directed broadcast)
/// Note: Assumes netmask is valid (contiguous). Use isValidNetmask to verify.
pub fn isBroadcast(ip: u32, netmask: u32) bool {
    if (ip == 0xFFFFFFFF) {
        return true;
    }
    // Directed broadcast: all host bits are 1
    const host_mask = ~netmask;
    return (ip & host_mask) == host_mask;
}

/// Check if IP is multicast (224.0.0.0 - 239.255.255.255)
pub fn isMulticast(ip: u32) bool {
    return (ip >> 24) >= 224 and (ip >> 24) <= 239;
}

/// Check if IP is loopback (127.x.x.x)
pub fn isLoopback(ip: u32) bool {
    return (ip >> 24) == 127;
}
