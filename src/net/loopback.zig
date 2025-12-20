// Loopback Interface Implementation
//
// Virtual network interface for local (127.x.x.x) traffic.
// Packets transmitted on loopback are injected directly back into the receive path.
//
// Design:
// - Implements standard Interface abstraction (no special casing in IP layer)
// - Transmit callback re-injects packet to IPv4 processPacket
// - No actual hardware, just memory copy
// - Packet processing is SYNCHRONOUS - protocol handlers must copy data before returning
//
// Note: The loopback interface is separate from the physical NIC interface.
// Traffic to 127.x.x.x should be routed through this interface.

const std = @import("std");
const Interface = @import("core/interface.zig").Interface;
const packet = @import("core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const ipv4 = @import("ipv4/root.zig").ipv4;
const heap = @import("heap");

/// Loopback interface instance
var loopback_interface: Interface = undefined;

/// Atomic initialization flag for thread-safe access
/// Uses acquire/release semantics to ensure all interface fields are visible
var initialized: std.atomic.Value(bool) = .{ .raw = false };

/// Initialize the loopback interface
/// Returns pointer to the interface for registration
pub fn init() *Interface {
    // Create interface with null MAC (loopback has no L2 address)
    loopback_interface = Interface.init("lo0", [_]u8{0} ** 6);

    // Configure with standard loopback address
    loopback_interface.configure(
        0x7F000001, // 127.0.0.1
        0xFF000000, // 255.0.0.0 (/8 netmask)
        0, // No gateway needed for loopback
    );

    // Set transmit function
    loopback_interface.setTransmitFn(&loopbackTransmit);

    // Mark as up
    loopback_interface.is_up = true;
    loopback_interface.link_up = true;

    // Loopback doesn't need multicast MAC filtering
    loopback_interface.accept_all_multicast = false;

    // Release semantics: ensure all interface fields are visible before marking initialized
    initialized.store(true, .release);
    return &loopback_interface;
}

/// Get the loopback interface (if initialized)
/// Uses acquire semantics to synchronize with init()'s release store
pub fn getInterface() ?*Interface {
    return if (initialized.load(.acquire)) &loopback_interface else null;
}

/// Loopback transmit function
/// Instead of sending to hardware, inject directly into receive path
///
/// OWNERSHIP: This function allocates packet_data and pkt, passes them to processPacket
/// for SYNCHRONOUS processing, then frees both. Protocol handlers MUST copy any data
/// they need before returning - they cannot retain references to the PacketBuffer.
fn loopbackTransmit(data: []const u8) bool {
    // Skip Ethernet header (14 bytes) to get IP packet
    // Loopback doesn't really need Ethernet, but sendPacket adds it
    const eth_header_size: usize = 14;

    if (data.len <= eth_header_size) {
        return false;
    }

    const ip_data = data[eth_header_size..];

    // Validate minimum IPv4 header length to prevent OOB reads in protocol handlers
    if (ip_data.len < packet.IP_HEADER_SIZE) {
        return false;
    }

    // Allocate buffer for packet data
    const allocator = heap.allocator();
    const packet_data = allocator.alloc(u8, ip_data.len) catch return false;
    // Note: No defer - we explicitly manage lifetime after synchronous processPacket
    @memcpy(packet_data, ip_data);

    // Allocate new PacketBuffer
    var pkt = allocator.create(PacketBuffer) catch {
        allocator.free(packet_data);
        return false;
    };

    // Initialize PacketBuffer
    pkt.* = PacketBuffer.init(packet_data, ip_data.len);
    pkt.eth_offset = 0; // No Ethernet header
    pkt.ip_offset = 0;  // IP starts at 0

    // Process as incoming IP packet (SYNCHRONOUS - handlers must copy data)
    const result = ipv4.processPacket(&loopback_interface, pkt);

    // Clean up - safe because processPacket is synchronous and handlers copy data
    allocator.destroy(pkt);
    allocator.free(packet_data);

    return result;
}

/// Check if an IP address belongs to the loopback range (127.x.x.x)
pub fn isLoopbackAddress(ip: u32) bool {
    return (ip >> 24) == 127;
}
