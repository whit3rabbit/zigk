const std = @import("std");
const syscall = @import("syscall");
const net = @import("net");
const heap = @import("heap");
const ring = @import("ring");

const Ring = ring.Ring;
const RingSet = ring.RingSet;

// Configure std options for freestanding
// Configure std options for freestanding
pub const std_options: std.Options = .{
    .page_size_min = 4096,
    .page_size_max = 4096,
};

// 1MB static heap buffer
var heap_buffer: [1024 * 1024]u8 = undefined;

pub fn main() !void {
    syscall.print("Netstack Process Starting...\n");

    // Initialize allocator
    var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);
    const allocator = fba.allocator();

    // Register service
    try syscall.register_service("netstack");
    syscall.print("Netstack Service Registered\n");

    // Interface setup
    // 02:00:00:00:00:02 is the default QEMU user net MAC
    var iface = net.Interface.init("eth0", [_]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    iface.setTransmitFn(transmitPacket);

    // Configure IP (Static for now - QEMU user net is usually 10.0.2.15)
    iface.configure(
        net.parseIp("10.0.2.15").?,
        net.parseIp("255.255.255.0").?,
        net.parseIp("10.0.2.2").?,
    );

    net.init(&iface, allocator, 100); // 100 ticks per sec (10ms)

    syscall.print("Netstack Initialized: 10.0.2.15/24\n");

    // Try to set up TX ring for outbound packets (netstack is producer)
    // VirtIO-Net will attach as consumer
    if (Ring.create(256, "virtio_net")) |r| {
        tx_ring = r;
        use_ring_ipc = true;
        syscall.print("Ring IPC: TX ring created\n");
    } else |_| {
        syscall.print("Ring IPC: TX ring failed, using legacy IPC\n");
    }

    // Main packet processing loop
    if (use_ring_ipc) {
        runRingLoop(&iface);
    } else {
        runLegacyLoop(&iface);
    }
}

/// Ring-based MPSC packet processing loop
fn runRingLoop(iface: *net.Interface) void {
    syscall.print("Netstack: Running ring IPC loop\n");

    while (true) {
        var processed: usize = 0;

        // Poll all RX rings (MPSC pattern)
        // VirtIO-Net drivers will register their rings with us
        if (rx_ring_set.pollAny()) |idx| {
            if (rx_ring_set.get(idx)) |rx_ring| {
                while (rx_ring.peek()) |entry| {
                    if (entry.len > 0 and entry.len <= net.MAX_PACKET_SIZE) {
                        // Zero-copy: process directly from ring buffer
                        const data = @as([*]const u8, @volatileCast(&entry.data));
                        var pkt_buf: net.PacketBuffer = undefined;
                        @memcpy(pkt_buf.data[0..entry.len], data[0..entry.len]);
                        pkt_buf.len = @intCast(entry.len);
                        _ = net.processFrame(iface, &pkt_buf);
                        processed += 1;
                    }
                    rx_ring.advance();
                }
            }
        }

        // Tick the network stack
        net.tick();

        // If no packets processed, wait on rings
        if (processed == 0 and rx_ring_set.count > 0) {
            _ = rx_ring_set.waitAny(1, 100_000_000) catch {}; // 100ms timeout
        } else if (rx_ring_set.count == 0) {
            // No rings attached yet, yield CPU
            syscall.sched_yield() catch {};
        }
    }
}

/// Legacy IPC packet processing loop
fn runLegacyLoop(iface: *net.Interface) void {
    syscall.print("Netstack: Running legacy IPC loop\n");

    const uapi = syscall.uapi;
    const net_ipc = uapi.net_ipc;

    var msg: syscall.IpcMessage align(16) = undefined;

    while (true) {
        const sender_pid = syscall.recv(&msg) catch continue;

        // Auto-discover virtio_net PID from first sender
        if (virtio_net_pid == 0) {
            virtio_net_pid = sender_pid;
            syscall.print("Discovered virtio_net PID\n");
        }

        const header: *const net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));

        net.tick();

        if (header.type == .RX_PACKET) {
            const data_len = header.len;
            if (data_len > net.MAX_PACKET_SIZE) continue;

            const payload = msg.payload[@sizeOf(net_ipc.PacketHeader)..][0..data_len];
            var pkt_buf: net.PacketBuffer = undefined;
            @memcpy(pkt_buf.data[0..data_len], payload);
            pkt_buf.len = @intCast(data_len);

            _ = net.processFrame(iface, &pkt_buf);
        }
    }
}

/// Called by VirtIO-Net to register an RX ring with netstack
pub fn attachRxRing(ring_id: u32) !void {
    const rx_ring = try Ring.attach(ring_id);
    try rx_ring_set.add(rx_ring);
    syscall.print("Netstack: Attached RX ring\n");
}

var virtio_net_pid: u32 = 0;

// Ring-based IPC state
var use_ring_ipc: bool = false;
var rx_ring_set: RingSet = RingSet.init();
var tx_ring: ?Ring = null;

fn transmitPacket(data: []const u8) bool {
    if (data.len > net.MAX_PACKET_SIZE) return false;

    // Try ring-based TX first
    if (tx_ring) |*ring_ptr| {
        if (ring_ptr.reserve()) |entry| {
            const dest = @as([*]u8, @volatileCast(&entry.data));
            @memcpy(dest[0..data.len], data);
            entry.len = @intCast(data.len);
            entry.flags = ring.uapi.ring.PACKET_FLAG_TX;
            ring_ptr.commit();
            _ = ring_ptr.notify() catch {};
            return true;
        }
        // Ring full, fall through to legacy IPC
    }

    // Legacy IPC fallback
    if (virtio_net_pid == 0) return false;

    const uapi = syscall.uapi;
    const net_ipc = uapi.net_ipc;

    var msg: syscall.IpcMessage = undefined;
    msg.sender_pid = 0;
    msg.payload_len = @sizeOf(net_ipc.PacketHeader) + data.len;

    const header: *net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));
    header.type = .TX_PACKET;
    header.len = @intCast(data.len);
    header._pad = 0;

    const payload_dest = msg.payload[@sizeOf(net_ipc.PacketHeader)..];
    @memcpy(payload_dest[0..data.len], data);

    syscall.send(virtio_net_pid, &msg) catch return false;

    return true;
}

export fn _start() noreturn {
    main() catch |err| {
        syscall.print("Netstack crashed: ");
        syscall.print(@errorName(err));
        syscall.print("\n");
    };
    syscall.exit(1);
}
