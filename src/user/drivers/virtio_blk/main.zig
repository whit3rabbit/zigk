// VirtIO-Blk Userspace Driver
//
// A pure userspace block device driver for VirtIO block devices.
// Uses capability-based syscalls for MMIO mapping, DMA allocation, and PCI config.
//
// Architecture:
//   - Single request queue for read/write operations
//   - IPC server that accepts BlockRequest messages
//   - Returns BlockResponse with data and status
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

// VirtIO block device features
const VIRTIO_BLK_F_SIZE_MAX: u32 = 1 << 1;
const VIRTIO_BLK_F_SEG_MAX: u32 = 1 << 2;
const VIRTIO_BLK_F_GEOMETRY: u32 = 1 << 4;
const VIRTIO_BLK_F_RO: u32 = 1 << 5;
const VIRTIO_BLK_F_BLK_SIZE: u32 = 1 << 6;

// VirtIO block request types
const VIRTIO_BLK_T_IN: u32 = 0;  // Read
const VIRTIO_BLK_T_OUT: u32 = 1; // Write
const VIRTIO_BLK_T_FLUSH: u32 = 4;
const VIRTIO_BLK_T_GET_ID: u32 = 8;

// VirtIO block status codes
const VIRTIO_BLK_S_OK: u8 = 0;
const VIRTIO_BLK_S_IOERR: u8 = 1;
const VIRTIO_BLK_S_UNSUPP: u8 = 2;

// Virtqueue descriptor flags
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

// Queue configuration
const QUEUE_SIZE: u16 = 128;
const SECTOR_SIZE: usize = 512;
const MAX_SECTORS_PER_REQUEST: usize = 256;

// Syscall numbers
const SYS_WAIT_INTERRUPT: usize = 1022;
const SYS_SEND: usize = 1020;
const SYS_RECV: usize = 1021;

// IPC message structures for block operations
const BlockRequest = extern struct {
    sender_pid: u64,
    request_type: u32, // VIRTIO_BLK_T_IN or VIRTIO_BLK_T_OUT
    _pad: u32,
    sector: u64,
    sector_count: u32,
    _pad2: u32,
    data: [SECTOR_SIZE * 4]u8, // Up to 4 sectors for write
};

const BlockResponse = extern struct {
    status: u32,
    bytes_transferred: u32,
    data: [SECTOR_SIZE * 4]u8, // Up to 4 sectors for read
};

// VirtIO block request header
const VirtioBlkReqHeader = extern struct {
    type_: u32,
    reserved: u32,
    sector: u64,
};

// Virtqueue structures
const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const VirtqAvail = extern struct {
    flags: u16,
    idx: u16,
};

const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};

const VirtqUsed = extern struct {
    flags: u16,
    idx: u16,
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

// VirtIO block device config
const VirtioBlkConfig = extern struct {
    capacity: u64,          // Number of 512-byte sectors
    size_max: u32,          // Max segment size
    seg_max: u32,           // Max segments
    geometry: extern struct {
        cylinders: u16,
        heads: u8,
        sectors: u8,
    },
    blk_size: u32,          // Block size (typically 512)
};

// Driver state
const DriverState = struct {
    // PCI device info
    pci_device: PciDeviceInfo,

    // MMIO mapped regions
    common_cfg: *volatile VirtioPciCommonCfg,
    notify_base: u64,
    notify_off_multiplier: u32,
    device_cfg: *volatile VirtioBlkConfig,

    // DMA allocations
    queue_dma: DmaAllocResult,
    request_dma: DmaAllocResult,

    // Queue state
    last_used_idx: u16,
    free_head: u16,
    num_free: u16,

    // Device info
    capacity: u64,
    block_size: u32,
    read_only: bool,

    // IRQ
    irq: u8,
};

var driver_state: DriverState = undefined;
var driver_initialized: bool = false;

pub fn main() void {
    syscall.print("VirtIO-Blk Driver Starting...\n");

    // Step 1: Find VirtIO-Blk device
    var pci_devices: [32]PciDeviceInfo = undefined;
    const device_count = syscall.pci_enumerate(&pci_devices) catch |err| {
        printError("Failed to enumerate PCI devices", err);
        return;
    };

    var virtio_blk_dev: ?*PciDeviceInfo = null;
    for (pci_devices[0..device_count]) |*dev| {
        if (dev.isVirtioBlk()) {
            virtio_blk_dev = dev;
            break;
        }
    }

    const dev = virtio_blk_dev orelse {
        syscall.print("No VirtIO-Blk device found\n");
        return;
    };

    syscall.print("Found VirtIO-Blk: ");
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

    // Step 3: Allocate DMA memory
    if (!allocateDmaMemory()) {
        syscall.print("Failed to allocate DMA memory\n");
        return;
    }

    // Step 4: Initialize VirtIO device
    if (!initVirtioDevice()) {
        syscall.print("Failed to initialize VirtIO device\n");
        return;
    }

    driver_initialized = true;

    // Print device capacity
    syscall.print("Block device capacity: ");
    printDec(driver_state.capacity);
    syscall.print(" sectors (");
    printDec(driver_state.capacity * 512 / 1024 / 1024);
    syscall.print(" MB)\n");

    if (driver_state.read_only) {
        syscall.print("Device is READ-ONLY\n");
    }

    syscall.print("VirtIO-Blk initialized. Starting request loop...\n");

    // Step 5: Main request loop
    requestLoop();
}

fn mapMmioRegions(dev: *const PciDeviceInfo) bool {
    const bar0 = dev.bar[0];
    if (bar0.base == 0 or bar0.size == 0) {
        syscall.print("BAR0 not configured\n");
        return false;
    }

    if (bar0.is_mmio == 0) {
        syscall.print("BAR0 is not MMIO\n");
        return false;
    }

    syscall.print("Mapping BAR0: ");
    printHex64(bar0.base);
    syscall.print("\n");

    const mmio_base = syscall.mmap_phys(bar0.base, @intCast(bar0.size)) catch |err| {
        printError("mmap_phys failed", err);
        return false;
    };

    driver_state.common_cfg = @ptrCast(@alignCast(mmio_base));
    driver_state.notify_base = @intFromPtr(mmio_base) + @sizeOf(VirtioPciCommonCfg);
    driver_state.notify_off_multiplier = 2;

    const device_cfg_offset = @sizeOf(VirtioPciCommonCfg) + 0x100;
    driver_state.device_cfg = @ptrFromInt(@intFromPtr(mmio_base) + device_cfg_offset);

    return true;
}

fn allocateDmaMemory() bool {
    // Allocate queue memory (16KB)
    driver_state.queue_dma = syscall.alloc_dma(4) catch |err| {
        printError("alloc_dma for queue failed", err);
        return false;
    };

    // Allocate request/response buffer memory (64KB for data + headers)
    driver_state.request_dma = syscall.alloc_dma(16) catch |err| {
        printError("alloc_dma for requests failed", err);
        return false;
    };

    syscall.print("DMA memory allocated\n");
    return true;
}

fn initVirtioDevice() bool {
    const cfg = driver_state.common_cfg;

    // Reset device
    cfg.device_status = 0;
    memoryBarrier();

    // ACKNOWLEDGE
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE;

    // DRIVER
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER;

    // Read device features
    cfg.device_feature_select = 0;
    memoryBarrier();
    var device_features: u64 = cfg.device_feature;

    cfg.device_feature_select = 1;
    memoryBarrier();
    device_features |= @as(u64, cfg.device_feature) << 32;

    // Check if read-only
    driver_state.read_only = (device_features & VIRTIO_BLK_F_RO) != 0;

    // Negotiate features (accept RO if set)
    var driver_features: u32 = 0;
    if (driver_state.read_only) {
        driver_features |= VIRTIO_BLK_F_RO;
    }

    cfg.driver_feature_select = 0;
    cfg.driver_feature = driver_features;
    cfg.driver_feature_select = 1;
    cfg.driver_feature = 0;

    // FEATURES_OK
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK;

    memoryBarrier();
    if ((cfg.device_status & VIRTIO_STATUS_FEATURES_OK) == 0) {
        syscall.print("Device did not accept features\n");
        cfg.device_status = VIRTIO_STATUS_FAILED;
        return false;
    }

    // Setup queue
    if (!setupQueue()) {
        syscall.print("Failed to setup queue\n");
        return false;
    }

    // Read device config
    const dev_cfg = driver_state.device_cfg;
    driver_state.capacity = dev_cfg.capacity;
    driver_state.block_size = if (dev_cfg.blk_size != 0) dev_cfg.blk_size else 512;

    // DRIVER_OK
    cfg.device_status = VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER |
        VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK;

    syscall.print("VirtIO device initialized\n");
    return true;
}

fn setupQueue() bool {
    const cfg = driver_state.common_cfg;

    cfg.queue_select = 0;
    memoryBarrier();

    const max_size = cfg.queue_size;
    if (max_size == 0) {
        syscall.print("Queue not available\n");
        return false;
    }

    const actual_size = if (QUEUE_SIZE < max_size) QUEUE_SIZE else max_size;
    cfg.queue_size = actual_size;

    // Calculate offsets
    const desc_size = @as(u64, actual_size) * @sizeOf(VirtqDesc);
    const avail_offset = alignUp64(desc_size, 2);
    const avail_size = 6 + @as(u64, actual_size) * 2;
    const used_offset = alignUp64(avail_offset + avail_size, 4096);

    cfg.queue_desc = driver_state.queue_dma.phys_addr;
    cfg.queue_avail = driver_state.queue_dma.phys_addr + avail_offset;
    cfg.queue_used = driver_state.queue_dma.phys_addr + used_offset;

    // Initialize descriptor free list
    const desc_virt: [*]VirtqDesc = @ptrFromInt(driver_state.queue_dma.virt_addr);
    for (0..actual_size) |i| {
        desc_virt[i].next = @intCast(i + 1);
        desc_virt[i].flags = 0;
        desc_virt[i].addr = 0;
        desc_virt[i].len = 0;
    }

    driver_state.free_head = 0;
    driver_state.num_free = actual_size;
    driver_state.last_used_idx = 0;

    cfg.queue_enable = 1;

    return true;
}

fn requestLoop() noreturn {
    var req: BlockRequest = undefined;
    var resp: BlockResponse = undefined;

    while (true) {
        // Wait for IPC request
        const sender = syscall.syscall2(SYS_RECV, @intFromPtr(&req), @sizeOf(BlockRequest));

        if (sender < 0) {
            continue;
        }

        // Validate request
        if (req.sector_count == 0 or req.sector_count > 4) {
            resp.status = VIRTIO_BLK_S_UNSUPP;
            resp.bytes_transferred = 0;
            _ = syscall.syscall3(SYS_SEND, @intCast(sender), @intFromPtr(&resp), @sizeOf(BlockResponse));
            continue;
        }

        // Check bounds
        if (req.sector >= driver_state.capacity) {
            resp.status = VIRTIO_BLK_S_IOERR;
            resp.bytes_transferred = 0;
            _ = syscall.syscall3(SYS_SEND, @intCast(sender), @intFromPtr(&resp), @sizeOf(BlockResponse));
            continue;
        }

        // Check read-only for writes
        if (req.request_type == VIRTIO_BLK_T_OUT and driver_state.read_only) {
            resp.status = VIRTIO_BLK_S_IOERR;
            resp.bytes_transferred = 0;
            _ = syscall.syscall3(SYS_SEND, @intCast(sender), @intFromPtr(&resp), @sizeOf(BlockResponse));
            continue;
        }

        // Perform I/O
        const status = doBlockIo(&req, &resp);
        resp.status = status;

        // Send response
        _ = syscall.syscall3(SYS_SEND, @intCast(sender), @intFromPtr(&resp), @sizeOf(BlockResponse));
    }
}

fn doBlockIo(req: *const BlockRequest, resp: *BlockResponse) u32 {
    const cfg = driver_state.common_cfg;
    cfg.queue_select = 0;

    const desc_ptr: [*]volatile VirtqDesc = @ptrFromInt(driver_state.queue_dma.virt_addr);
    const avail_ptr: *volatile VirtqAvail = @ptrFromInt(driver_state.queue_dma.virt_addr +
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2));

    // Setup request in DMA buffer
    const hdr_phys = driver_state.request_dma.phys_addr;
    const data_phys = hdr_phys + @sizeOf(VirtioBlkReqHeader);
    const status_phys = data_phys + @as(u64, req.sector_count) * SECTOR_SIZE;

    const hdr_virt: *VirtioBlkReqHeader = @ptrFromInt(driver_state.request_dma.virt_addr);
    const data_virt: [*]u8 = @ptrFromInt(driver_state.request_dma.virt_addr + @sizeOf(VirtioBlkReqHeader));
    const status_virt: *volatile u8 = @ptrFromInt(driver_state.request_dma.virt_addr +
        @sizeOf(VirtioBlkReqHeader) + @as(usize, req.sector_count) * SECTOR_SIZE);

    // Fill request header
    hdr_virt.type_ = req.request_type;
    hdr_virt.reserved = 0;
    hdr_virt.sector = req.sector;

    // For writes, copy data to DMA buffer
    if (req.request_type == VIRTIO_BLK_T_OUT) {
        const copy_len = @as(usize, req.sector_count) * SECTOR_SIZE;
        for (0..copy_len) |i| {
            data_virt[i] = req.data[i];
        }
    }

    // Initialize status
    status_virt.* = 0xFF; // Invalid status

    // Allocate 3 descriptors: header, data, status
    const head = driver_state.free_head;
    var desc_idx = head;

    // Descriptor 0: Header (device reads)
    desc_ptr[desc_idx].addr = hdr_phys;
    desc_ptr[desc_idx].len = @sizeOf(VirtioBlkReqHeader);
    desc_ptr[desc_idx].flags = VIRTQ_DESC_F_NEXT;
    desc_ptr[desc_idx].next = desc_idx + 1;
    desc_idx += 1;

    // Descriptor 1: Data
    desc_ptr[desc_idx].addr = data_phys;
    desc_ptr[desc_idx].len = @intCast(req.sector_count * SECTOR_SIZE);
    if (req.request_type == VIRTIO_BLK_T_IN) {
        desc_ptr[desc_idx].flags = VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_NEXT;
    } else {
        desc_ptr[desc_idx].flags = VIRTQ_DESC_F_NEXT;
    }
    desc_ptr[desc_idx].next = desc_idx + 1;
    desc_idx += 1;

    // Descriptor 2: Status (device writes)
    desc_ptr[desc_idx].addr = status_phys;
    desc_ptr[desc_idx].len = 1;
    desc_ptr[desc_idx].flags = VIRTQ_DESC_F_WRITE;
    desc_ptr[desc_idx].next = 0;

    // Update free list
    driver_state.free_head = desc_idx + 1;
    driver_state.num_free -= 3;

    // Add to available ring
    const ring_ptr: [*]volatile u16 = @ptrFromInt(@intFromPtr(avail_ptr) + 4);
    const avail_idx = avail_ptr.idx;
    ring_ptr[avail_idx % QUEUE_SIZE] = head;

    memoryBarrier();
    avail_ptr.idx = avail_idx +% 1;

    // Notify device
    notifyQueue(0);

    // Wait for completion
    const used_offset = alignUp64(
        alignUp64(@as(u64, QUEUE_SIZE) * @sizeOf(VirtqDesc), 2) + 6 + @as(u64, QUEUE_SIZE) * 2,
        4096,
    );
    const used_ptr: *volatile VirtqUsed = @ptrFromInt(driver_state.queue_dma.virt_addr + used_offset);

    // Poll for completion (or use interrupt)
    var timeout: u32 = 1000000;
    while (driver_state.last_used_idx == used_ptr.idx and timeout > 0) {
        timeout -= 1;
        loadBarrier();
    }

    if (timeout == 0) {
        syscall.print("Block I/O timeout\n");
        return VIRTIO_BLK_S_IOERR;
    }

    driver_state.last_used_idx +%= 1;

    // Return descriptors to free list
    driver_state.free_head = head;
    driver_state.num_free += 3;

    // Get status
    const status = status_virt.*;

    // For reads, copy data back
    if (req.request_type == VIRTIO_BLK_T_IN and status == VIRTIO_BLK_S_OK) {
        const copy_len = @as(usize, req.sector_count) * SECTOR_SIZE;
        for (0..copy_len) |i| {
            resp.data[i] = data_virt[i];
        }
        resp.bytes_transferred = @intCast(copy_len);
    } else {
        resp.bytes_transferred = 0;
    }

    return status;
}

fn notifyQueue(queue_idx: u16) void {
    const notify_addr = driver_state.notify_base + @as(u64, queue_idx) * driver_state.notify_off_multiplier;
    const notify_ptr: *volatile u16 = @ptrFromInt(notify_addr);
    notify_ptr.* = queue_idx;
}

// Memory barrier helpers
fn memoryBarrier() void {
    asm volatile ("mfence"
        :
        :
        : .{ .memory = true }
    );
}

fn loadBarrier() void {
    asm volatile ("lfence"
        :
        :
        : .{ .memory = true }
    );
}

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
