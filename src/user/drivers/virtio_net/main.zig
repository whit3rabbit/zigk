// VirtIO-Net Userspace Driver
//
// A pure userspace network driver for VirtIO network devices.
// Uses capability-based syscalls for MMIO mapping, DMA allocation, and PCI config.
//
// Architecture:
//   - Main process handles device initialization and coordination
//   - RX process handles receive virtqueue and incoming packets
//   - TX process handles transmit virtqueue and outgoing packets
//
// Reference: VirtIO Specification 1.1 (OASIS)

const std = @import("std");
const syscall = @import("syscall");

const SyscallError = syscall.uapi.errno.SyscallError;
const PciDeviceInfo = syscall.PciDeviceInfo;
const DmaAllocResult = syscall.DmaAllocResult;

// VirtIO device status bits
const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
const VIRTIO_STATUS_DRIVER: u8 = 2;
const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
const VIRTIO_STATUS_FAILED: u8 = 128;

// VirtIO net device features
const VIRTIO_NET_F_MAC: u32 = 1 << 5;
const VIRTIO_NET_F_STATUS: u32 = 1 << 16;
const VIRTIO_NET_F_MRG_RXBUF: u32 = 1 << 15;

// Virtqueue descriptor flags
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

// Queue indices for VirtIO-Net
const RX_QUEUE_IDX: u16 = 0;
const TX_QUEUE_IDX: u16 = 1;

// Buffer sizes
const RX_BUFFER_SIZE: usize = 2048;
const TX_BUFFER_SIZE: usize = 2048;
const QUEUE_SIZE: u16 = 256;

// VirtIO PCI capability types
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

// Syscall numbers
const SYS_FORK: usize = 57;
const SYS_WAIT_INTERRUPT: usize = 1022;
const SYS_SEND: usize = 1020;
const SYS_RECV: usize = 1021;

// IPC message structure for network packets
// IPC message structure for network packets
const uapi = syscall.uapi;
const net_ipc = uapi.net_ipc;
const MAX_PACKET_SIZE = net_ipc.MAX_PACKET_SIZE;

// Virtqueue descriptor
const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

// Virtqueue available ring header
const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
    // ring[QUEUE_SIZE] follows
    // used_event follows ring if EVENT_IDX enabled
};

// Virtqueue used element
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

// Virtqueue used ring header
const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
    // ring[QUEUE_SIZE] of VirtqUsedElem follows
    // avail_event follows ring if EVENT_IDX enabled
};

// VirtIO PCI common configuration
const VirtioPciCommonCfg = extern struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    msix_config: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_avail: u64,
    queue_used: u64,
};

// VirtIO net device config
const VirtioNetConfig = extern struct {
    mac: [6]u8,
    status: u16,
};

// Driver state
const DriverState = struct {
    // PCI device info
    pci_device: PciDeviceInfo,

    // MMIO mapped regions
    common_cfg: *volatile VirtioPciCommonCfg,
    notify_base: u64,
    notify_off_multiplier: u32,
    device_cfg: *volatile VirtioNetConfig,

    // DMA allocations for queues
    rx_queue_dma: DmaAllocResult,
    tx_queue_dma: DmaAllocResult,
    rx_buffers_dma: DmaAllocResult,
    tx_buffers_dma: DmaAllocResult,

    // Queue state
    rx_last_used_idx: u16,
    tx_last_used_idx: u16,

    // MAC address
    mac: [6]u8,

    // IRQ for interrupt handling
    irq: u8,
    
    // Netstack PID
    netstack_pid: u32,
};

var driver_state: DriverState = undefined;
var driver_initialized: bool = false;

pub fn main() void {
    syscall.print("VirtIO-Net Driver Starting...\n");
    
    // Register as service
    syscall.register_service("virtio_net") catch |err| {
         printError("Failed to register virtio_net service", err);
         return;
    };
    syscall.print("Registered 'virtio_net' service\n");

    // Lookup netstack
    // Retry loop in case netstack is starting up
    var netstack_pid: u32 = 0;
    while (true) {
        netstack_pid = syscall.lookup_service("netstack") catch 0;
        if (netstack_pid != 0) break;
        syscall.print("Waiting for netstack...\n");
         _ = syscall.nanosleep(&.{ .tv_sec = 1, .tv_nsec = 0 }, null) catch {};
    }
    
    driver_state.netstack_pid = netstack_pid;
    syscall.print("Found netstack at PID ");
    printDec(netstack_pid);
    syscall.print("\n");


    // Step 1: Find VirtIO-Net device
    var pci_devices: [32]PciDeviceInfo = undefined;
    const device_count = syscall.pci_enumerate(&pci_devices) catch |err| {
        printError("Failed to enumerate PCI devices", err);
        return;
    };

    var virtio_net_dev: ?*PciDeviceInfo = null;
    for (pci_devices[0..device_count]) |*dev| {
        if (dev.isVirtioNet()) {
            virtio_net_dev = dev;
            break;
        }
    }

    const dev = virtio_net_dev orelse {
        syscall.print("No VirtIO-Net device found\n");
        return;
    };

    syscall.print("Found VirtIO-Net: ");
    printHex16(dev.vendor_id);
    syscall.print(":");
    printHex16(dev.device_id);
    syscall.print(" at ");
    printDec(dev.bus);
    syscall.print(":");
    printDec(dev.device);
    syscall.print(".");
    printDec(dev.func);
    syscall.print("\n");

    // Store device info
    driver_state.pci_device = dev.*;
    driver_state.irq = dev.irq_line;

    // Step 2: Map MMIO regions
    if (!mapMmioRegions(dev)) {
        syscall.print("Failed to map MMIO regions\n");
        return;
    }

    // Step 3: Allocate DMA memory for queues
    if (!allocateQueueMemory()) {
        syscall.print("Failed to allocate queue memory\n");
        return;
    }

    // Step 4: Initialize VirtIO device
    if (!initVirtioDevice()) {
        syscall.print("Failed to initialize VirtIO device\n");
        return;
    }

    driver_initialized = true;

    // Print MAC address
    syscall.print("MAC Address: ");
    for (driver_state.mac, 0..) |byte, i| {
        printHex8(byte);
        if (i < 5) syscall.print(":");
    }
    syscall.print("\n");

    syscall.print("VirtIO-Net initialized successfully. Forking...\n");

    // Step 5: Fork into RX and TX processes
    const pid = syscall.syscall1(SYS_FORK, 0);

    if (pid == 0) {
        // Child: RX handler
        rxLoop();
    } else {
        // Parent: TX handler
        txLoop();
    }
}

fn mapMmioRegions(dev: *const PciDeviceInfo) bool {
    // For modern VirtIO-PCI, we need to find capabilities
    // For now, assume BAR0 is the main MMIO region (legacy mode)
    // Modern VirtIO uses PCI capabilities to locate regions

    const bar0 = dev.bar[0];
    if (bar0.base == 0 or bar0.size == 0) {
        syscall.print("BAR0 not configured\n");
        return false;
    }

    if (bar0.is_mmio == 0) {
        syscall.print("BAR0 is not MMIO (I/O port mode not supported)\n");
        return false;
    }

    syscall.print("Mapping BAR0: ");
    printHex64(bar0.base);
    syscall.print(" size ");
    printHex64(bar0.size);
    syscall.print("\n");

    // Map the MMIO region
    const mmio_base = syscall.mmap_phys(bar0.base, @intCast(bar0.size)) catch |err| {
        printError("mmap_phys failed", err);
        return false;
    };

    // For modern VirtIO PCI, the common config is at the start
    // This is a simplification - real driver would parse capabilities
    driver_state.common_cfg = @ptrCast(@alignCast(mmio_base));
    driver_state.notify_base = @intFromPtr(mmio_base) + @sizeOf(VirtioPciCommonCfg);
    driver_state.notify_off_multiplier = 2; // Typical value

    // Device config follows common config (simplified)
    const device_cfg_offset = @sizeOf(VirtioPciCommonCfg) + 0x100;
    driver_state.device_cfg = @ptrFromInt(@intFromPtr(mmio_base) + device_cfg_offset);

    return true;
}

fn allocateQueueMemory() bool {
    // Calculate sizes
    const desc_size = @as(usize, QUEUE_SIZE) * @sizeOf(VirtqDesc);
    const avail_size = 6 + @as(usize, QUEUE_SIZE) * 2;
    const used_size = 6 + @as(usize, QUEUE_SIZE) * @sizeOf(VirtqUsedElem);

    // Total per queue (page-aligned)
    const queue_pages = 4; // 16KB per queue should be plenty

    // Allocate RX queue
    driver_state.rx_queue_dma = syscall.alloc_dma(queue_pages) catch |err| {
        printError("alloc_dma for RX queue failed", err);
        return false;
    };

    // Allocate TX queue
    driver_state.tx_queue_dma = syscall.alloc_dma(queue_pages) catch |err| {
        printError("alloc_dma for TX queue failed", err);
        return false;
    };

    // Allocate RX buffers
    const rx_buffer_pages = (QUEUE_SIZE * RX_BUFFER_SIZE + 4095) / 4096;
    driver_state.rx_buffers_dma = syscall.alloc_dma(@intCast(rx_buffer_pages)) catch |err| {
        printError("alloc_dma for RX buffers failed", err);
        return false;
    };

    // Allocate TX buffers
    const tx_buffer_pages = (QUEUE_SIZE * TX_BUFFER_SIZE + 4095) / 4096;
    driver_state.tx_buffers_dma = syscall.alloc_dma(@intCast(tx_buffer_pages)) catch |err| {
        printError("alloc_dma for TX buffers failed", err);
        return false;
    };

    syscall.print("Queue memory allocated\n");
    _ = desc_size;
    _ = avail_size;
    _ = used_size;
    return true;
}

fn initVirtioDevice() bool {
    const cfg = driver_state.common_cfg;

    // Step 1: Reset device
    cfg.device_status = 0;

    // Memory barrier
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );

    // Step 2: Set ACKNOWLEDGE status
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE;

    // Step 3: Set DRIVER status
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;

    // Step 4: Negotiate features
    // Read device features (select low 32 bits)
    cfg.device_feature_select = 0;
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
    var device_features: u64 = cfg.device_feature;

    cfg.device_feature_select = 1;
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
    device_features |= @as(u64, cfg.device_feature) << 32;

    // We want: MAC, maybe merge rxbuf
    var driver_features: u32 = 0;
    if ((device_features & VIRTIO_NET_F_MAC) != 0) {
        driver_features |= VIRTIO_NET_F_MAC;
    }

    // Write driver features
    cfg.driver_feature_select = 0;
    cfg.driver_feature = driver_features;
    cfg.driver_feature_select = 1;
    cfg.driver_feature = 0;

    // Step 5: Set FEATURES_OK
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK;

    // Verify FEATURES_OK is still set
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
    if ((cfg.device_status & VIRTIO_STATUS_FEATURES_OK) == 0) {
        syscall.print("Device did not accept features\n");
        cfg.device_status = VIRTIO_STATUS_FAILED;
        return false;
    }

    // Step 6: Setup queues
    if (!setupQueue(RX_QUEUE_IDX, driver_state.rx_queue_dma)) {
        syscall.print("Failed to setup RX queue\n");
        return false;
    }

    if (!setupQueue(TX_QUEUE_IDX, driver_state.tx_queue_dma)) {
        syscall.print("Failed to setup TX queue\n");
        return false;
    }

    // Step 7: Read MAC address
    const dev_cfg = driver_state.device_cfg;
    for (0..6) |i| {
        driver_state.mac[i] = dev_cfg.mac[i];
    }

    // Step 8: Set DRIVER_OK
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
        VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK;

    syscall.print("VirtIO device initialized\n");
    return true;
}

fn setupQueue(queue_idx: u16, dma: DmaAllocResult) bool {
    const cfg = driver_state.common_cfg;

    // Select queue
    cfg.queue_select = queue_idx;
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );

    // Check queue size
    const max_size = cfg.queue_size;
    if (max_size == 0) {
        syscall.print("Queue ");
        printDec(queue_idx);
        syscall.print(" not available\n");
        return false;
    }

    // Use minimum of requested and max
    const actual_size = if (QUEUE_SIZE < max_size) QUEUE_SIZE else max_size;
    cfg.queue_size = actual_size;

    // Calculate offsets within DMA region
    const desc_size = @as(u64, actual_size) * @sizeOf(VirtqDesc);
    const avail_offset = alignUp64(desc_size, 2);
    const avail_size = 6 + @as(u64, actual_size) * 2;
    const used_offset = alignUp64(avail_offset + avail_size, 4096);

    // Set queue addresses (physical)
    cfg.queue_desc = dma.phys_addr;
    cfg.queue_avail = dma.phys_addr + avail_offset;
    cfg.queue_used = dma.phys_addr + used_offset;

    // Initialize descriptor free list
    const desc_virt: [*]VirtqDesc = @ptrFromInt(dma.virt_addr);
    for (0..actual_size) |i| {
        desc_virt[i].next = @intCast(i + 1);
        desc_virt[i].flags = 0;
        desc_virt[i].addr = 0;
        desc_virt[i].len = 0;
    }

    // Enable queue
    cfg.queue_enable = 1;

    return true;
}

fn rxLoop() noreturn {
    syscall.print("[RX] RX loop started\n");

    // Fill RX queue with buffers
    fillRxQueue();

    while (true) {
        // Wait for interrupt
        const ret = syscall.syscall1(SYS_WAIT_INTERRUPT, driver_state.irq);
        if (ret != 0) {
            continue;
        }

        // Process received packets
        processRxCompletions();

        // Refill RX queue
        fillRxQueue();
    }
}

fn txLoop() noreturn {
    syscall.print("[TX] TX loop started\n");

    // IPC message buffer - must match kernel's Message struct exactly (2064 bytes)
    var msg: syscall.IpcMessage = undefined;

    while (true) {
        // Wait for packet to send via IPC
        _ = syscall.recv(&msg) catch continue;

        // PacketHeader is at the start of msg.payload
        const header: *const net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));

        if (header.type != .TX_PACKET) continue;

        if (header.len > MAX_PACKET_SIZE) {
            continue;
        }

        // Packet data follows PacketHeader within payload
        const data_ptr = msg.payload[@sizeOf(net_ipc.PacketHeader)..];

        // Send packet
        sendPacket(data_ptr[0..header.len]);

        // Process TX completions
        processTxCompletions();
    }
}

fn fillRxQueue() void {
    // Add receive buffers to RX queue
    // Each buffer is a VirtIO net header followed by packet data

    const cfg = driver_state.common_cfg;
    cfg.queue_select = RX_QUEUE_IDX;
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );

    const avail_ptr: *volatile VirtqAvail = @ptrFromInt(driver_state.rx_queue_dma.virt_addr +
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2));
    const desc_ptr: [*]volatile VirtqDesc = @ptrFromInt(driver_state.rx_queue_dma.virt_addr);

    // Add buffers
    var added: u16 = 0;
    var idx = avail_ptr.idx;
    while (added < 16) { // Add up to 16 buffers at a time
        const buf_idx = idx % QUEUE_SIZE;

        // Calculate buffer physical address
        const buf_phys = driver_state.rx_buffers_dma.phys_addr + @as(u64, buf_idx) * RX_BUFFER_SIZE;

        // Setup descriptor
        desc_ptr[buf_idx].addr = buf_phys;
        desc_ptr[buf_idx].len = RX_BUFFER_SIZE;
        desc_ptr[buf_idx].flags = VIRTQ_DESC_F_WRITE;
        desc_ptr[buf_idx].next = 0;

        // Add to avail ring
        const ring_ptr: [*]volatile u16 = @ptrFromInt(@intFromPtr(avail_ptr) + 4);
        ring_ptr[idx % QUEUE_SIZE] = buf_idx;

        idx +%= 1;
        added += 1;
    }

    // Update avail idx
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
    avail_ptr.idx = idx;

    // Notify device
    notifyQueue(RX_QUEUE_IDX);
}

fn processRxCompletions() void {
    const used_offset = alignUp64(
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2) + 6 + @as(u64, QUEUE_SIZE) * 2,
        4096,
    );
    const used_ptr: *volatile VirtqUsed = @ptrFromInt(driver_state.rx_queue_dma.virt_addr + used_offset);

    asm volatile ("lfence"
        :
        :
        : .{ .memory = true }
    );

    while (driver_state.rx_last_used_idx != used_ptr.idx) {
        const ring_idx = driver_state.rx_last_used_idx % QUEUE_SIZE;
        const used_ring: [*]volatile VirtqUsedElem = @ptrFromInt(@intFromPtr(used_ptr) + 4);
        const elem = used_ring[ring_idx];

        // Process received packet
        const buf_idx = elem.id;
        const len = elem.len;

        const buf_virt = driver_state.rx_buffers_dma.virt_addr + @as(u64, buf_idx) * RX_BUFFER_SIZE;
        const packet: [*]u8 = @ptrFromInt(buf_virt);

        // Skip VirtIO net header (12 bytes typically)
        if (len > 12) {
            // Send packet to network stack via IPC
            const data_len = len - 12;
            if (data_len <= MAX_PACKET_SIZE) {
                // Construct proper IPC Message
                var msg: syscall.IpcMessage = undefined;
                msg.sender_pid = 0; // Filled by kernel
                msg.payload_len = @sizeOf(net_ipc.PacketHeader) + data_len;

                // Write PacketHeader at start of payload
                const header: *net_ipc.PacketHeader = @ptrCast(@alignCast(&msg.payload));
                header.type = .RX_PACKET;
                header.len = @intCast(data_len);
                header._pad = 0;

                // Copy packet data from DMA buffer to payload after header
                const data_dest = msg.payload[@sizeOf(net_ipc.PacketHeader)..];
                const payload_src = packet[12..len];
                @memcpy(data_dest[0..data_len], payload_src);

                // Send to netstack
                _ = syscall.send(driver_state.netstack_pid, &msg) catch {};
            }
        }

        driver_state.rx_last_used_idx +%= 1;
    }
}

fn sendPacket(data: []const u8) void {
    const cfg = driver_state.common_cfg;
    cfg.queue_select = TX_QUEUE_IDX;
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );

    const avail_ptr: *volatile VirtqAvail = @ptrFromInt(driver_state.tx_queue_dma.virt_addr +
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2));
    const desc_ptr: [*]volatile VirtqDesc = @ptrFromInt(driver_state.tx_queue_dma.virt_addr);

    const idx = avail_ptr.idx;
    const buf_idx = idx % QUEUE_SIZE;

    // Calculate buffer addresses
    const hdr_phys = driver_state.tx_buffers_dma.phys_addr + @as(u64, buf_idx) * TX_BUFFER_SIZE;

    // Copy data to TX buffer
    const buf_virt: [*]u8 = @ptrFromInt(driver_state.tx_buffers_dma.virt_addr + @as(u64, buf_idx) * TX_BUFFER_SIZE);

    // Zero the header
    for (0..12) |i| {
        buf_virt[i] = 0;
    }

    // Copy packet data
    for (data, 0..) |byte, i| {
        buf_virt[12 + i] = byte;
    }

    // Setup descriptors: header + data in one descriptor for simplicity
    desc_ptr[buf_idx].addr = hdr_phys;
    desc_ptr[buf_idx].len = @intCast(12 + data.len);
    desc_ptr[buf_idx].flags = 0;
    desc_ptr[buf_idx].next = 0;

    // Add to avail ring
    const ring_ptr: [*]volatile u16 = @ptrFromInt(@intFromPtr(avail_ptr) + 4);
    ring_ptr[idx % QUEUE_SIZE] = buf_idx;

    // Update avail idx
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
    avail_ptr.idx = idx +% 1;

    // Notify device
    notifyQueue(TX_QUEUE_IDX);
}

fn processTxCompletions() void {
    const used_offset = alignUp64(
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2) + 6 + @as(u64, QUEUE_SIZE) * 2,
        4096,
    );
    const used_ptr: *volatile VirtqUsed = @ptrFromInt(driver_state.tx_queue_dma.virt_addr + used_offset);

    asm volatile ("lfence"
        :
        :
        : .{ .memory = true }
    );

    while (driver_state.tx_last_used_idx != used_ptr.idx) {
        // TX completion - buffer can be reused
        driver_state.tx_last_used_idx +%= 1;
    }
}

fn notifyQueue(queue_idx: u16) void {
    const notify_addr = driver_state.notify_base + @as(u64, queue_idx) * driver_state.notify_off_multiplier;
    const notify_ptr: *volatile u16 = @ptrFromInt(notify_addr);
    notify_ptr.* = queue_idx;
}

// Helper functions

fn alignUp64(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printHex8(value: u8) void {
    const hex = "0123456789ABCDEF";
    var buf: [2]u8 = undefined;
    buf[0] = hex[(value >> 4) & 0xF];
    buf[1] = hex[value & 0xF];
    syscall.print(&buf);
}

fn printHex16(value: u16) void {
    printHex8(@truncate(value >> 8));
    printHex8(@truncate(value));
}

fn printHex64(value: u64) void {
    printHex16(@truncate(value >> 48));
    printHex16(@truncate(value >> 32));
    printHex16(@truncate(value >> 16));
    printHex16(@truncate(value));
}

fn printDec(value: u64) void {
    if (value == 0) {
        syscall.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    syscall.print(buf[i..]);
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}
