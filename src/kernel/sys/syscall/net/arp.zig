// ARP Syscall Handlers
//
// RFC 5227 - IPv4 Address Conflict Detection
//
// Implements ARP probe and announce syscalls for DHCP IP conflict detection.
// These operations are critical for preventing IP address collisions on
// the local network segment.
//
// ARP Probe (Section 2.1.1):
//   Sender IP = 0.0.0.0 (indicates probe, not claim)
//   Target IP = address being probed
//   Any response indicates conflict
//
// ARP Announcement (Section 2.3):
//   Gratuitous ARP reply to broadcast
//   Updates neighbor caches with our new MAC/IP binding
//
// Security:
//   - Requires CAP_NET_CONFIG capability for both operations
//   - Prevents unprivileged processes from spoofing network addresses
//   - Rate limiting handled implicitly by probe timeout

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const base = @import("base.zig");
const console = @import("console");
const sched = @import("sched");
const hal = @import("hal");

// Network stack imports
const socket_state = net.transport.socket.state;
const arp_packet = net.ipv4.arp.packet;
const arp_cache = net.ipv4.arp.cache;
const core_packet = net.core.packet;
const ethernet = net.ethernet.ethernet;

// ARP probe result codes (must match userspace enum)
pub const ARP_RESULT_NO_CONFLICT: usize = 0;
pub const ARP_RESULT_CONFLICT: usize = 1;
pub const ARP_RESULT_TIMEOUT: usize = 2;

// Probe timing constants
const PROBE_POLL_INTERVAL_MS: u64 = 50; // Check every 50ms
const MIN_TIMEOUT_MS: u64 = 100;
const MAX_TIMEOUT_MS: u64 = 10000; // 10 seconds max

// =============================================================================
// SYS_ARP_PROBE (1061)
// =============================================================================

/// Send an ARP probe to detect IP conflicts (RFC 5227)
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip_addr: Target IP address in host byte order
///   timeout_ms: Maximum time to wait for response in milliseconds
///
/// Returns:
///   0 = No conflict detected (safe to use IP)
///   1 = Conflict detected (IP is already in use)
///   2 = Timeout (no response, safe to use IP)
///
/// The probe sends an ARP request for the target IP and waits for any
/// response indicating the IP is already in use on the network.
pub fn sys_arp_probe(
    iface_idx: usize,
    ip_addr: usize,
    timeout_ms: usize,
) SyscallError!usize {
    // Validate interface index
    if (iface_idx != 0) {
        return error.ENODEV;
    }

    // Validate and clamp timeout
    const timeout = std.math.clamp(timeout_ms, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);

    // Check capability
    const proc = base.getCurrentProcess();
    _ = proc.getNetConfigCapability(iface_idx) orelse {
        console.warn("arp_probe: Process {} lacks CAP_NET_CONFIG", .{proc.pid});
        return error.EPERM;
    };

    // Get network interface
    const iface = socket_state.getInterface() orelse {
        return error.ENODEV;
    };

    // Target IP in u32
    const target_ip: u32 = @truncate(ip_addr);

    // Don't probe for 0.0.0.0 or broadcast
    if (target_ip == 0 or target_ip == 0xFFFFFFFF) {
        return error.EINVAL;
    }

    console.debug("arp_probe: Probing for {}.{}.{}.{} (timeout {}ms)", .{
        (target_ip >> 24) & 0xFF,
        (target_ip >> 16) & 0xFF,
        (target_ip >> 8) & 0xFF,
        target_ip & 0xFF,
        timeout,
    });

    // Send ARP probe (RFC 5227: sender IP = 0)
    sendArpProbe(iface, target_ip);

    // Calculate wait parameters
    // Convert timeout_ms to ticks (assuming 10ms per tick)
    const tick_ns: u64 = 10_000_000;
    const poll_interval_ns = PROBE_POLL_INTERVAL_MS * 1_000_000;
    const poll_ticks = std.math.divCeil(u64, poll_interval_ns, tick_ns) catch 1;
    const total_polls = timeout / PROBE_POLL_INTERVAL_MS;

    // Poll for response
    var polls: u64 = 0;
    while (polls < total_polls) : (polls += 1) {
        // Check if ARP cache has an entry for this IP
        if (checkArpCacheForConflict(target_ip)) {
            console.info("arp_probe: Conflict detected for {}.{}.{}.{}", .{
                (target_ip >> 24) & 0xFF,
                (target_ip >> 16) & 0xFF,
                (target_ip >> 8) & 0xFF,
                target_ip & 0xFF,
            });
            return ARP_RESULT_CONFLICT;
        }

        // Sleep for poll interval
        sched.sleepForTicks(poll_ticks);

        // Send another probe halfway through
        if (polls == total_polls / 2) {
            sendArpProbe(iface, target_ip);
        }
    }

    // Final check after timeout
    if (checkArpCacheForConflict(target_ip)) {
        console.info("arp_probe: Conflict detected for {}.{}.{}.{} (final check)", .{
            (target_ip >> 24) & 0xFF,
            (target_ip >> 16) & 0xFF,
            (target_ip >> 8) & 0xFF,
            target_ip & 0xFF,
        });
        return ARP_RESULT_CONFLICT;
    }

    console.debug("arp_probe: No conflict for {}.{}.{}.{}", .{
        (target_ip >> 24) & 0xFF,
        (target_ip >> 16) & 0xFF,
        (target_ip >> 8) & 0xFF,
        target_ip & 0xFF,
    });

    return ARP_RESULT_TIMEOUT; // No response = safe
}

// =============================================================================
// SYS_ARP_ANNOUNCE (1062)
// =============================================================================

/// Send a gratuitous ARP announcement (RFC 5227)
///
/// Arguments:
///   iface_idx: Interface index (currently only 0 supported)
///   ip_addr: IP address to announce in host byte order
///
/// Returns: 0 on success
///
/// Sends a gratuitous ARP reply to update neighbor ARP caches.
/// Should be called after configuring a new IP address.
pub fn sys_arp_announce(
    iface_idx: usize,
    ip_addr: usize,
) SyscallError!usize {
    // Validate interface index
    if (iface_idx != 0) {
        return error.ENODEV;
    }

    // Check capability
    const proc = base.getCurrentProcess();
    _ = proc.getNetConfigCapability(iface_idx) orelse {
        console.warn("arp_announce: Process {} lacks CAP_NET_CONFIG", .{proc.pid});
        return error.EPERM;
    };

    // Get network interface
    const iface = socket_state.getInterface() orelse {
        return error.ENODEV;
    };

    const announce_ip: u32 = @truncate(ip_addr);

    // Don't announce 0.0.0.0 or broadcast
    if (announce_ip == 0 or announce_ip == 0xFFFFFFFF) {
        return error.EINVAL;
    }

    console.debug("arp_announce: Announcing {}.{}.{}.{}", .{
        (announce_ip >> 24) & 0xFF,
        (announce_ip >> 16) & 0xFF,
        (announce_ip >> 8) & 0xFF,
        announce_ip & 0xFF,
    });

    // Send gratuitous ARP (reply to broadcast with our IP)
    sendGratuitousArp(iface, announce_ip);

    return 0;
}

// =============================================================================
// Internal Helper Functions
// =============================================================================

/// Send an ARP probe packet
///
/// RFC 5227 Section 2.1.1:
/// "A host probes to see if an address is already in use by broadcasting
/// an ARP Request for the desired address. The client MUST fill in the
/// 'sender hardware address' field of the ARP Request with the hardware
/// address of the interface through which it is sending the packet. The
/// 'sender IP address' field MUST be set to all zeroes."
///
/// The zero sender IP distinguishes a probe from a normal ARP request,
/// ensuring we don't accidentally update anyone's ARP cache.
fn sendArpProbe(iface: *socket_state.Interface, target_ip: u32) void {
    // SECURITY: Zero-init to prevent stack leaks in padding bytes
    var buf: [core_packet.ETH_HEADER_SIZE + @sizeOf(core_packet.ArpHeader)]u8 =
        [_]u8{0} ** (core_packet.ETH_HEADER_SIZE + @sizeOf(core_packet.ArpHeader));

    const eth: *core_packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &ethernet.BROADCAST_MAC);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    const arp: *align(1) core_packet.ArpHeader = @ptrCast(&buf[core_packet.ETH_HEADER_SIZE]);
    arp.hw_type = @byteSwap(@as(u16, 1)); // Ethernet (RFC 826)
    arp.proto_type = @byteSwap(@as(u16, 0x0800)); // IPv4
    arp.hw_len = 6;
    arp.proto_len = 4;
    arp.operation = core_packet.ArpHeader.OP_REQUEST;

    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = 0; // RFC 5227: Probe uses sender IP = 0

    @memcpy(&arp.target_mac, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    arp.target_ip = @byteSwap(target_ip);

    _ = iface.transmit(&buf);
}

/// Send a gratuitous ARP announcement
///
/// RFC 5227 Section 2.3:
/// "Having probed to determine that an address is not in use, the host
/// announces its claim to the address... An ARP Announcement is identical
/// to the ARP Probe described above, except that now the sender and
/// target IP addresses are both set to the host's newly selected IPv4 address."
///
/// RFC 5227 Section 3:
/// "A host SHOULD transmit an ARP Announcement... This allows other hosts
/// on the link to update their ARP caches with the new information."
fn sendGratuitousArp(iface: *socket_state.Interface, ip: u32) void {
    // SECURITY: Zero-init to prevent stack leaks in padding bytes
    var buf: [core_packet.ETH_HEADER_SIZE + @sizeOf(core_packet.ArpHeader)]u8 =
        [_]u8{0} ** (core_packet.ETH_HEADER_SIZE + @sizeOf(core_packet.ArpHeader));

    const eth: *core_packet.EthernetHeader = @ptrCast(@alignCast(&buf[0]));
    @memcpy(&eth.dst_mac, &ethernet.BROADCAST_MAC);
    @memcpy(&eth.src_mac, &iface.mac_addr);
    eth.setEthertype(ethernet.ETHERTYPE_ARP);

    const arp: *align(1) core_packet.ArpHeader = @ptrCast(&buf[core_packet.ETH_HEADER_SIZE]);
    arp.hw_type = @byteSwap(@as(u16, 1)); // Ethernet (RFC 826)
    arp.proto_type = @byteSwap(@as(u16, 0x0800)); // IPv4
    arp.hw_len = 6;
    arp.proto_len = 4;
    arp.operation = core_packet.ArpHeader.OP_REPLY; // Gratuitous uses reply

    @memcpy(&arp.sender_mac, &iface.mac_addr);
    arp.sender_ip = @byteSwap(ip);

    // RFC 5227: sender = target for announcement (claims ownership)
    @memcpy(&arp.target_mac, &iface.mac_addr);
    arp.target_ip = @byteSwap(ip);

    _ = iface.transmit(&buf);
}

/// Check if ARP cache has a reachable entry for the target IP
/// Returns true if conflict detected (IP is in use).
fn checkArpCacheForConflict(target_ip: u32) bool {
    // Check if the ARP cache has resolved this IP
    // If there's a reachable entry, someone else has this IP
    const held = arp_cache.lock.acquire();
    defer held.release();

    if (arp_cache.findEntry(target_ip)) |entry| {
        // If entry is reachable or stale, IP is in use
        if (entry.state == .reachable or entry.state == .stale) {
            return true;
        }
        // If incomplete entry got a reply, check MAC
        if (entry.has_received_reply) {
            return true;
        }
    }

    return false;
}
