// VirtIO Common Structures and Virtqueue Implementation
// Reference: VirtIO Specification 1.1 (OASIS)
//
// This module provides the low-level virtqueue primitives used by all
// VirtIO device drivers (GPU, block, network, etc.).

const std = @import("std");
const pmm = @import("pmm");
const hal = @import("hal");

// Virtqueue descriptor flags
pub const VIRTQ_DESC_F_NEXT: u16 = 1; // Descriptor continues via next field
pub const VIRTQ_DESC_F_WRITE: u16 = 2; // Device writes (vs reads) the buffer
pub const VIRTQ_DESC_F_INDIRECT: u16 = 4; // Buffer contains descriptor table

// Feature bits common to all devices
pub const VIRTIO_F_RING_INDIRECT_DESC: u32 = 28;
pub const VIRTIO_F_RING_EVENT_IDX: u32 = 29;
pub const VIRTIO_F_VERSION_1: u32 = 32; // VirtIO 1.0 compliance

/// Virtqueue descriptor - points to a buffer segment
pub const VirtqDesc = extern struct {
    /// Physical address of buffer
    addr: u64,
    /// Length of buffer in bytes
    len: u32,
    /// VIRTQ_DESC_F_* flags
    flags: u16,
    /// Index of next descriptor if NEXT flag set
    next: u16,
};

/// Virtqueue available ring - driver writes, device reads
pub const VirtqAvail = extern struct {
    flags: u16,
    /// Next available entry (wraps)
    idx: u16,
    /// Ring of descriptor head indices (variable size, 256 max)
    ring: [256]u16,
    // used_event follows ring if EVENT_IDX enabled (not included here)
};

/// Element in the used ring
pub const VirtqUsedElem = extern struct {
    /// Index of descriptor chain head
    id: u32,
    /// Total bytes written by device
    len: u32,
};

/// Virtqueue used ring - device writes, driver reads
pub const VirtqUsed = extern struct {
    flags: u16,
    /// Next used entry (wraps)
    idx: u16,
    /// Ring of used elements (variable size, 256 max)
    ring: [256]VirtqUsedElem,
    // avail_event follows ring if EVENT_IDX enabled (not included here)
};

/// Virtqueue state - manages descriptor ring communication
pub const Virtqueue = struct {
    /// Queue size (power of 2, typically 256)
    size: u16,
    /// Descriptor table
    desc: [*]VirtqDesc,
    /// Available ring
    avail: *volatile VirtqAvail,
    /// Used ring
    used: *volatile VirtqUsed,

    /// Head of free descriptor list
    free_head: u16,
    /// Number of free descriptors
    num_free: u16,
    /// Last seen used index (for detecting new entries)
    last_used_idx: u16,

    /// Physical addresses for device configuration
    desc_phys: u64,
    avail_phys: u64,
    used_phys: u64,

    const Self = @This();

    /// Allocate and initialize a virtqueue with the given size
    /// Returns null if allocation fails
    pub fn init(queue_size: u16) ?Self {
        if (queue_size == 0 or queue_size > 256) return null;

        // Calculate sizes (aligned as per VirtIO spec)
        const desc_size = @as(usize, queue_size) * @sizeOf(VirtqDesc);
        const avail_size = 6 + @as(usize, queue_size) * 2; // flags + idx + ring[n] + used_event
        const used_size = 6 + @as(usize, queue_size) * @sizeOf(VirtqUsedElem); // flags + idx + ring[n] + avail_event

        // Total size with alignment
        const desc_avail_size = std.mem.alignForward(usize, desc_size + avail_size, 4096);
        const total_size = desc_avail_size + std.mem.alignForward(usize, used_size, 4096);
        const pages_needed = (total_size + 4095) / 4096;

        // Allocate contiguous physical pages
        const phys_addr = pmm.allocZeroedPages(pages_needed) orelse return null;
        const virt_addr = @intFromPtr(hal.paging.physToVirt(phys_addr));

        // Set up pointers
        const desc_ptr: [*]VirtqDesc = @ptrFromInt(virt_addr);
        const avail_ptr: *volatile VirtqAvail = @ptrFromInt(virt_addr + desc_size);
        const used_ptr: *volatile VirtqUsed = @ptrFromInt(virt_addr + desc_avail_size);

        // Initialize free descriptor chain
        var i: u16 = 0;
        while (i < queue_size - 1) : (i += 1) {
            desc_ptr[i].next = i + 1;
        }
        desc_ptr[queue_size - 1].next = 0; // Sentinel

        return Self{
            .size = queue_size,
            .desc = desc_ptr,
            .avail = avail_ptr,
            .used = used_ptr,
            .free_head = 0,
            .num_free = queue_size,
            .last_used_idx = 0,
            .desc_phys = phys_addr,
            .avail_phys = phys_addr + desc_size,
            .used_phys = phys_addr + desc_avail_size,
        };
    }

    /// Allocate a descriptor from the free list
    fn allocDesc(self: *Self) ?u16 {
        if (self.num_free == 0) return null;

        const idx = self.free_head;
        self.free_head = self.desc[idx].next;
        self.num_free -= 1;
        return idx;
    }

    /// Return a descriptor to the free list
    fn freeDesc(self: *Self, idx: u16) void {
        self.desc[idx].next = self.free_head;
        self.desc[idx].flags = 0;
        self.free_head = idx;
        self.num_free += 1;
    }

    /// Free a chain of descriptors starting at head
    /// Security: Validates device-provided indices to prevent OOB access and infinite loops
    fn freeDescChain(self: *Self, head: u16) void {
        // Validate head index before starting
        if (head >= self.size) {
            // Invalid descriptor index from device - log and abort
            return;
        }

        var idx = head;
        var count: u16 = 0;

        // Limit iterations to queue size to prevent infinite loops from circular chains
        while (count < self.size) : (count += 1) {
            const flags = self.desc[idx].flags;
            const next = self.desc[idx].next;
            self.freeDesc(idx);

            if (flags & VIRTQ_DESC_F_NEXT == 0) break;

            // Validate next index before following chain
            if (next >= self.size) {
                // Invalid next index from device - stop chain traversal
                break;
            }
            idx = next;
        }
    }

    /// Add a buffer chain to the available ring
    /// out_bufs: device-readable buffers (driver -> device)
    /// in_bufs: device-writable buffers (device -> driver)
    /// Returns the descriptor head index, or null if no space
    pub fn addBuf(
        self: *Self,
        out_bufs: []const []const u8,
        in_bufs: []const []u8,
    ) ?u16 {
        const total_bufs = out_bufs.len + in_bufs.len;
        if (total_bufs == 0) return null;
        if (self.num_free < total_bufs) return null;

        var head: ?u16 = null;
        var prev: ?u16 = null;

        // Add device-readable (out) buffers
        for (out_bufs) |buf| {
            const idx = self.allocDesc() orelse unreachable;
            if (head == null) head = idx;

            self.desc[idx].addr = hal.paging.virtToPhys(@intFromPtr(buf.ptr));
            self.desc[idx].len = @intCast(buf.len);
            self.desc[idx].flags = 0;

            if (prev) |p| {
                self.desc[p].next = idx;
                self.desc[p].flags |= VIRTQ_DESC_F_NEXT;
            }
            prev = idx;
        }

        // Add device-writable (in) buffers
        for (in_bufs) |buf| {
            const idx = self.allocDesc() orelse unreachable;
            if (head == null) head = idx;

            self.desc[idx].addr = hal.paging.virtToPhys(@intFromPtr(buf.ptr));
            self.desc[idx].len = @intCast(buf.len);
            self.desc[idx].flags = VIRTQ_DESC_F_WRITE;

            if (prev) |p| {
                self.desc[p].next = idx;
                self.desc[p].flags |= VIRTQ_DESC_F_NEXT;
            }
            prev = idx;
        }

        // Add to available ring
        const avail_idx = self.avail.idx % self.size;
        self.avail.ring[avail_idx] = head.?;

        // Memory barrier before updating idx
        hal.mmio.memoryBarrier();

        self.avail.idx +%= 1;

        return head;
    }

    /// Check for and return the next used buffer
    /// Returns (head_idx, bytes_written) or null if no new entries
    /// Security: Validates device-provided elem.id before use
    pub fn getUsed(self: *Self) ?struct { head: u16, len: u32 } {
        // Memory barrier to ensure we see device writes
        hal.mmio.memoryBarrier();

        if (self.last_used_idx == self.used.idx) {
            return null;
        }

        const used_idx = self.last_used_idx % self.size;
        const elem = self.used.ring[used_idx];
        self.last_used_idx +%= 1;

        // Validate device-provided descriptor ID before use
        // elem.id is u32 from device; must be < queue size (which is u16)
        if (elem.id >= self.size) {
            // Invalid descriptor ID from device - skip this entry
            // Do not free descriptors as we don't know which chain it refers to
            return null;
        }

        const head_id: u16 = @intCast(elem.id);

        // Free the descriptor chain
        self.freeDescChain(head_id);

        return .{ .head = head_id, .len = elem.len };
    }

    /// Notify device that new buffers are available
    /// notify_addr is the MMIO address of the queue notify register
    pub fn kick(self: *Self, notify_addr: u64) void {
        _ = self;
        // Memory barrier before notify
        hal.mmio.memoryBarrier();

        // Write queue index to notify register (16-bit write)
        const ptr: *volatile u16 = @ptrFromInt(notify_addr);
        ptr.* = 0; // Queue index 0 for simplicity
    }

    /// Check if there are pending used buffers
    pub fn hasPending(self: *Self) bool {
        hal.mmio.memoryBarrier();
        return self.last_used_idx != self.used.idx;
    }

    /// Reset virtqueue state after a device reset
    pub fn reset(self: *Self) void {
        const desc_slice = self.desc[0..self.size];
        @memset(desc_slice, VirtqDesc{
            .addr = 0,
            .len = 0,
            .flags = 0,
            .next = 0,
        });

        if (self.size > 0) {
            var i: u16 = 0;
            while (i < self.size - 1) : (i += 1) {
                self.desc[i].next = i + 1;
            }
            self.desc[self.size - 1].next = 0;
        }

        self.free_head = 0;
        self.num_free = self.size;
        self.last_used_idx = 0;

        self.avail.flags = 0;
        self.avail.idx = 0;
        @memset(self.avail.ring[0..self.size], 0);

        self.used.flags = 0;
        self.used.idx = 0;
        @memset(self.used.ring[0..self.size], VirtqUsedElem{ .id = 0, .len = 0 });
    }
};

// VirtIO PCI capability types
pub const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
pub const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
pub const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
pub const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;
pub const VIRTIO_PCI_CAP_PCI_CFG: u8 = 5;

/// VirtIO PCI common configuration structure
pub const VirtioPciCommonCfg = extern struct {
    // Device/driver feature bits
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    // Configuration
    msix_config: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    // Queue configuration
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_avail: u64,
    queue_used: u64,
};

// Device status bits
pub const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
pub const VIRTIO_STATUS_DRIVER: u8 = 2;
pub const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
pub const VIRTIO_STATUS_FEATURES_OK: u8 = 8;
pub const VIRTIO_STATUS_DEVICE_NEEDS_RESET: u8 = 64;
pub const VIRTIO_STATUS_FAILED: u8 = 128;
