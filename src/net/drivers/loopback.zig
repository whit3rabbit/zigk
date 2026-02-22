// Loopback Interface Implementation
//
// Virtual network interface for local (127.x.x.x) traffic.
// Packets transmitted on loopback are queued and processed asynchronously
// during the next net.tick() call, preventing re-entrant deadlocks.
//
// Design:
// - Implements standard Interface abstraction (no special casing in IP layer)
// - Transmit callback queues packet for deferred processing
// - drain() processes queued packets outside any caller lock context
// - No actual hardware, just memory copy + deferred inject
//
// Why async: Synchronous loopback re-enters the TCP/UDP RX path from within
// the TX path. TCP functions like connectIp() and close() hold state.lock
// while calling transmit. The RX path also acquires state.lock, causing
// deadlock on a non-reentrant spinlock. Deferring processing to drain()
// (called from the timer tick) breaks this lock cycle.

const std = @import("std");
const Interface = @import("../core/interface.zig").Interface;
const packet = @import("../core/packet.zig");
const PacketBuffer = packet.PacketBuffer;
const ipv4 = @import("../ipv4/root.zig").ipv4;
const sync = @import("../sync.zig");


/// Maximum IP packet size we'll queue (covers any standard MTU)
const MAX_QUEUED_PKT: usize = 2048;

/// Queue depth -- enough for typical request/response exchanges
const QUEUE_DEPTH: usize = 32;

/// Loopback interface instance
var loopback_interface: Interface = undefined;

/// Atomic initialization flag for thread-safe access
/// Uses acquire/release semantics to ensure all interface fields are visible
var initialized: std.atomic.Value(bool) = .{ .raw = false };

// ---------------------------------------------------------------------------
// Packet queue (static ring buffer, no heap allocation)
// ---------------------------------------------------------------------------

var pkt_bufs: [QUEUE_DEPTH][MAX_QUEUED_PKT]u8 = undefined;
var pkt_lens: [QUEUE_DEPTH]usize = [_]usize{0} ** QUEUE_DEPTH;
var q_head: usize = 0;
var q_tail: usize = 0;
var q_count: usize = 0;
var q_lock: sync.Spinlock = .{};

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
/// Strips Ethernet header and queues the IP packet for deferred processing.
/// Returns true on success (packet queued), false if queue is full or packet invalid.
fn loopbackTransmit(data: []const u8) bool {
    // Strip Ethernet header (14 bytes) to get IP packet
    const eth_header_size: usize = 14;

    if (data.len <= eth_header_size) {
        return false;
    }

    const ip_data = data[eth_header_size..];

    // Validate minimum IPv4 header length
    if (ip_data.len < packet.IP_HEADER_SIZE) {
        return false;
    }

    // Reject oversized packets
    if (ip_data.len > MAX_QUEUED_PKT) {
        return false;
    }

    const held = q_lock.acquire();
    defer held.release();

    if (q_count >= QUEUE_DEPTH) {
        return false; // Queue full, drop packet (TCP will retransmit)
    }

    @memcpy(pkt_bufs[q_tail][0..ip_data.len], ip_data);
    pkt_lens[q_tail] = ip_data.len;
    q_tail = (q_tail + 1) % QUEUE_DEPTH;
    q_count += 1;

    return true;
}

/// Process queued loopback packets.
/// Called from net.tick() in timer ISR context. Each dequeued packet is
/// injected into ipv4.processPacket as if it arrived from the network.
///
/// Re-entrant safe: if processPacket triggers another transmit on loopback
/// (e.g. RST reply), the new packet is appended to the tail while we
/// consume from the head. Limited to MAX_DRAIN_PER_TICK to prevent
/// infinite packet storms (e.g. ACK loops) from stalling the ISR.
pub fn drain() void {
    const MAX_DRAIN_PER_TICK: usize = 64;
    var processed: usize = 0;

    while (processed < MAX_DRAIN_PER_TICK) {
        var local_buf: [MAX_QUEUED_PKT]u8 = undefined;
        var local_len: usize = 0;

        {
            const held = q_lock.acquire();
            if (q_count == 0) {
                held.release();
                return;
            }
            local_len = pkt_lens[q_head];
            @memcpy(local_buf[0..local_len], pkt_bufs[q_head][0..local_len]);
            q_head = (q_head + 1) % QUEUE_DEPTH;
            q_count -= 1;
            held.release();
        }

        processed += 1;

        // Create stack-allocated PacketBuffer pointing to local data.
        // Safe because ipv4.processPacket is synchronous -- handlers
        // must copy any data they need before returning.
        const data_slice = local_buf[0..local_len];
        var pkt = PacketBuffer.init(data_slice, local_len);
        pkt.eth_offset = 0; // No Ethernet header
        pkt.ip_offset = 0; // IP starts at 0

        _ = ipv4.processPacket(&loopback_interface, &pkt);
    }
}

/// Check if an IP address belongs to the loopback range (127.x.x.x)
pub fn isLoopbackAddress(ip: u32) bool {
    return (ip >> 24) == 127;
}
