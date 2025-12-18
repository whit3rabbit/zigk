const std = @import("std");
const syscall = @import("syscall");
const net = @import("net");
const heap = @import("heap");

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
    // TODO: Use a proper userspace allocator (e.g. gpa)
    // Use FixedBufferAllocator for freestanding environment to avoid std.os dependencies
    var fba = std.heap.FixedBufferAllocator.init(&heap_buffer);
    const allocator = fba.allocator();

    // Register service
    try syscall.register_service("netstack");
    syscall.print("Netstack Service Registered\n");

    const uapi = syscall.uapi;
    const net_ipc = uapi.net_ipc;

    // Interface setup
    // 02:00:00:00:00:02 is the default QEMU user net MAC
    var iface = net.Interface.init("eth0", [_]u8{0x02, 0x00, 0x00, 0x00, 0x00, 0x02});
    iface.setTransmitFn(transmitPacket);
    
    // Configure IP (Static for now - QEMU user net is usually 10.0.2.15)
    // IP: 10.0.2.15
    // Mask: 255.255.255.0
    // Gateway: 10.0.2.2
    iface.configure(
        net.parseIp("10.0.2.15").?,
        net.parseIp("255.255.255.0").?,
        net.parseIp("10.0.2.2").?
    );

    net.init(&iface, allocator, 100); // 100 ticks per sec (10ms)

    syscall.print("Netstack Initialized: 10.0.2.15/24\n");

    // IPC message buffer - must match kernel's Message struct exactly (2064 bytes)
    var msg: syscall.IpcMessage align(16) = undefined;

    while (true) {
        // Wait for IPC message (blocking)
        // TODO: Implement sys_recv_timeout or use io_uring for non-blocking/timeout support
        const sender_pid = syscall.recv(&msg) catch continue;

        // Auto-discover virtio_net PID from first sender
        if (virtio_net_pid == 0) {
            virtio_net_pid = sender_pid;
            syscall.print("Discovered virtio_net PID: ");
            var pid_buf: [32]u8 = undefined;
            if (std.fmt.bufPrint(&pid_buf, "{d}", .{sender_pid})) |s| {
                syscall.print(s);
            } else |_| {}
            syscall.print("!\n");
        }

        // PacketHeader is at the start of msg.payload (not the Message struct itself)
        const header: *const net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));

        // Tick the network stack
        net.tick();

        if (header.type == .RX_PACKET) {
            const data_len = header.len;
            if (data_len > net.MAX_PACKET_SIZE) continue;

            // Packet data follows PacketHeader within the payload
            const payload = msg.payload[@sizeOf(net_ipc.PacketHeader)..][0..data_len];

            // Copy to PacketBuffer for processing
            var pkt_buf: net.PacketBuffer = undefined;
            @memcpy(pkt_buf.data[0..data_len], payload);
            pkt_buf.len = @intCast(data_len);

            _ = net.processFrame(&iface, &pkt_buf);
        }
    }
}

var virtio_net_pid: u32 = 0;

fn transmitPacket(data: []const u8) bool {
    if (virtio_net_pid == 0) return false;
    if (data.len > net.MAX_PACKET_SIZE) return false;

    const uapi = syscall.uapi;
    const net_ipc = uapi.net_ipc;

    // Construct IPC message with proper Message struct
    var msg: syscall.IpcMessage = undefined;
    msg.sender_pid = 0; // Filled by kernel
    msg.payload_len = @sizeOf(net_ipc.PacketHeader) + data.len;

    // Write PacketHeader at start of payload
    const header: *net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));
    header.type = .TX_PACKET;
    header.len = @intCast(data.len);
    header._pad = 0;

    // Copy packet data after header
    const payload_dest = msg.payload[@sizeOf(net_ipc.PacketHeader)..];
    @memcpy(payload_dest[0..data.len], data);

    // Send the properly formatted message
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
