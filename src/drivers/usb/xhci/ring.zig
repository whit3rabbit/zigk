// XHCI Ring Management
//
// Manages the three types of rings used by XHCI:
//   - Command Ring: Software enqueues commands, controller dequeues
//   - Event Ring: Controller enqueues events, software dequeues
//   - Transfer Rings: Per-endpoint data transfer queues
//
// Rings use a producer/consumer model with cycle bit toggling to indicate
// ownership. When the producer wraps around via a Link TRB, it toggles
// its cycle state.
//
// Reference: xHCI Specification 1.2, Chapter 4.9

const std = @import("std");
const builtin = @import("builtin");

const trb = @import("trb.zig");
const Trb = trb.Trb;
const TrbType = trb.TrbType;
const LinkTrb = trb.LinkTrb;
const ErstEntry = trb.ErstEntry;
const CompletionCode = trb.CompletionCode;

const hal = @import("hal");
const pmm = @import("pmm");
const dma = @import("dma");
const iommu = @import("iommu");

// =============================================================================
// Ring Configuration
// =============================================================================

/// Default number of TRBs per ring segment (must fit in one page)
/// 256 TRBs * 16 bytes = 4096 bytes = 1 page
pub const DEFAULT_RING_SIZE: usize = 256;

/// Maximum TRBs usable (last slot reserved for Link TRB)
pub const USABLE_RING_SIZE: usize = DEFAULT_RING_SIZE - 1;

// =============================================================================
// Producer Ring (Command Ring, Transfer Rings)
// =============================================================================

/// Producer ring - software enqueues, controller dequeues
/// Used for Command Ring and Transfer Rings
pub const ProducerRing = struct {
    /// Virtual address of ring buffer
    trbs: [*]Trb,
    /// Physical address of ring buffer (for CPU access via HHDM)
    phys_base: u64,
    /// Device address (IOVA or physical, for hardware registers)
    device_addr: u64,
    /// DMA buffer tracking for IOMMU cleanup
    dma_buf: dma.DmaBuffer,
    /// Current enqueue index
    enqueue_idx: usize,
    /// Producer cycle state (toggled on wrap)
    pcs: bool,
    /// Ring size in TRBs
    size: usize,

    const Self = @This();

    /// Allocate and initialize a producer ring using IOMMU-aware DMA
    pub fn init(bdf: iommu.DeviceBdf) !Self {
        // Allocate one page for ring (4KB = 256 TRBs) using IOMMU-aware DMA
        const buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return error.OutOfMemory;
        const virt = @intFromPtr(hal.paging.physToVirt(buf.phys_addr));
        const trbs: [*]Trb = @ptrFromInt(virt);

        var ring = Self{
            .trbs = trbs,
            .phys_base = buf.phys_addr,
            .device_addr = buf.device_addr,
            .dma_buf = buf,
            .enqueue_idx = 0,
            .pcs = true, // Start with cycle bit = 1
            .size = DEFAULT_RING_SIZE,
        };

        // Initialize Link TRB at end to wrap back to start (use device address)
        ring.setupLinkTrb();

        return ring;
    }

    /// Set up the Link TRB at the end of the ring
    fn setupLinkTrb(self: *Self) void {
        const link_idx = self.size - 1;
        const link: *LinkTrb = @ptrCast(&self.trbs[link_idx]);
        // Link TRB points to device address (IOVA) for hardware to follow
        link.* = LinkTrb.init(self.device_addr, true, self.pcs);
    }

    /// Get device address for hardware registers (IOVA or physical)
    pub fn getDeviceAddress(self: *const Self) u64 {
        return self.device_addr;
    }

    /// Enqueue a TRB to the ring
    /// Returns physical address of enqueued TRB, or null if ring is full
    pub fn enqueue(self: *Self, new_trb: Trb) ?u64 {
        // Check if we're at the Link TRB (ring full)
        if (self.enqueue_idx >= self.size - 1) {
            return null; // Ring full
        }

        // Copy TRB with correct cycle bit
        var trb_copy = new_trb;
        trb_copy.control.cycle = self.pcs;

        // Write to ring
        self.trbs[self.enqueue_idx] = trb_copy;

        // Memory barrier to ensure TRB is visible before doorbell
        hal.mmio.memoryBarrier();

        // Calculate physical address of this TRB
        const trb_phys = self.phys_base + @as(u64, self.enqueue_idx) * @sizeOf(Trb);

        // Advance index
        self.enqueue_idx += 1;

        // Check if we need to wrap
        if (self.enqueue_idx >= self.size - 1) {
            self.wrap();
        }

        return trb_phys;
    }

    /// Wrap the ring back to start via Link TRB
    fn wrap(self: *Self) void {
        // Update Link TRB with current cycle state before wrapping
        const link_idx = self.size - 1;
        const link: *LinkTrb = @ptrCast(&self.trbs[link_idx]);

        // Set cycle bit on Link TRB
        link.control.cycle = self.pcs;

        // Toggle producer cycle state (Link TRB has TC=1)
        self.pcs = !self.pcs;
        self.enqueue_idx = 0;
    }

    /// Get physical address of ring for CRCR register
    pub fn getPhysicalAddress(self: *const Self) u64 {
        return self.phys_base;
    }

    /// Get current producer cycle state for CRCR register
    pub fn getCycleState(self: *const Self) bool {
        return self.pcs;
    }

    /// Check if ring has space for more TRBs
    pub fn hasSpace(self: *const Self) bool {
        return self.enqueue_idx < self.size - 1;
    }

    /// Get number of free slots
    pub fn freeSlots(self: *const Self) usize {
        return (self.size - 1) - self.enqueue_idx;
    }

    /// Free the ring memory
    pub fn deinit(self: *Self) void {
        const page_addr = hal.paging.virtToPhys(@intFromPtr(self.trbs));
        pmm.freePages(page_addr, 1);
        self.trbs = undefined;
    }
};

// =============================================================================
// Consumer Ring (Event Ring)
// =============================================================================

/// Consumer ring - controller enqueues, software dequeues
/// Used for Event Ring
pub const ConsumerRing = struct {
    /// Virtual address of ring buffer
    trbs: [*]Trb,
    /// Physical address of ring buffer (for CPU access via HHDM)
    phys_base: u64,
    /// Device address of ring buffer (IOVA or physical, for hardware)
    device_addr: u64,
    /// DMA buffer tracking for ring
    ring_dma: dma.DmaBuffer,
    /// Current dequeue index
    dequeue_idx: usize,
    /// Consumer cycle state (expected cycle bit value)
    ccs: bool,
    /// Ring size in TRBs
    size: usize,
    /// Event Ring Segment Table
    erst: *ErstEntry,
    /// Device address of ERST (for ERSTBA register)
    erst_device_addr: u64,
    /// DMA buffer tracking for ERST
    erst_dma: dma.DmaBuffer,

    const Self = @This();

    /// Allocate and initialize an event ring with ERST using IOMMU-aware DMA
    pub fn init(bdf: iommu.DeviceBdf) !Self {
        // Allocate ring segment (one page) using IOMMU-aware DMA
        const ring_buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch return error.OutOfMemory;
        const ring_virt = @intFromPtr(hal.paging.physToVirt(ring_buf.phys_addr));
        const trbs: [*]Trb = @ptrFromInt(ring_virt);

        // Allocate ERST (one entry, but needs 64-byte alignment)
        // Use a full page for simplicity
        const erst_buf = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
            dma.freeBuffer(&ring_buf);
            return error.OutOfMemory;
        };
        const erst_virt = @intFromPtr(hal.paging.physToVirt(erst_buf.phys_addr));
        const erst: *ErstEntry = @ptrFromInt(erst_virt);

        // Initialize ERST entry (use device address for hardware)
        erst.* = ErstEntry.init(ring_buf.device_addr, DEFAULT_RING_SIZE);

        return Self{
            .trbs = trbs,
            .phys_base = ring_buf.phys_addr,
            .device_addr = ring_buf.device_addr,
            .ring_dma = ring_buf,
            .dequeue_idx = 0,
            .ccs = true, // Expect cycle bit = 1 initially
            .size = DEFAULT_RING_SIZE,
            .erst = erst,
            .erst_device_addr = erst_buf.device_addr,
            .erst_dma = erst_buf,
        };
    }

    /// Check if there's a pending event to process
    /// Security: Returns false if ring state is corrupted
    /// Note: Uses memory barrier on aarch64 to ensure CPU sees hardware's writes
    pub fn hasPending(self: *const Self) bool {
        // Memory barrier to ensure we see hardware's writes to Event Ring.
        // On aarch64, DSB (Data Synchronization Barrier) ensures all prior
        // memory accesses complete before we read the TRB cycle bit.
        // On x86_64, PCIe snooping handles this automatically, but we still
        // use a compiler barrier to prevent reordering.
        if (builtin.cpu.arch == .aarch64) {
            asm volatile ("dsb sy" ::: "memory");
        } else {
            asm volatile ("" ::: "memory");
        }

        // Security: Validate bounds before accessing trbs array
        if (self.dequeue_idx >= self.size or self.dequeue_idx >= DEFAULT_RING_SIZE) {
            return false;
        }
        const current_trb = &self.trbs[self.dequeue_idx];
        return current_trb.control.cycle == self.ccs;
    }

    /// Dequeue the next event TRB
    /// Returns null if no event pending or ring corruption detected
    /// Security: Validates index bounds to detect ring corruption from malicious hardware
    pub fn dequeue(self: *Self) ?*const Trb {
        // Security: Validate dequeue_idx is within bounds before any access
        // This detects corruption from malicious hardware or memory corruption
        if (self.dequeue_idx >= self.size or self.dequeue_idx >= DEFAULT_RING_SIZE) {
            // Ring corruption detected - reset to safe state
            self.dequeue_idx = 0;
            return null;
        }

        if (!self.hasPending()) {
            return null;
        }

        const current = &self.trbs[self.dequeue_idx];

        // Security: Use wrapping arithmetic to prevent overflow, then bounds check
        const next_idx = self.dequeue_idx +% 1;
        if (next_idx >= self.size) {
            self.dequeue_idx = 0;
            self.ccs = !self.ccs; // Toggle expected cycle bit on wrap
        } else {
            self.dequeue_idx = next_idx;
        }

        return current;
    }

    /// Get current dequeue pointer device address for ERDP register
    pub fn getDequeuePointer(self: *const Self) u64 {
        return self.device_addr + @as(u64, self.dequeue_idx) * @sizeOf(Trb);
    }

    /// Get ERST device address for ERSTBA register
    pub fn getErstBase(self: *const Self) u64 {
        return self.erst_device_addr;
    }

    /// Get ERST size (number of segments) for ERSTSZ register
    pub fn getErstSize(_: *const Self) u16 {
        return 1; // Single segment
    }

    /// Process all pending events with a callback
    pub fn processEvents(self: *Self, comptime callback: fn (*const Trb) void) usize {
        var count: usize = 0;
        while (self.dequeue()) |event| {
            callback(event);
            count += 1;
        }
        return count;
    }

    /// Free ring memory
    pub fn deinit(self: *Self) void {
        // Free ERST
        const erst_page = hal.paging.virtToPhys(@intFromPtr(self.erst));
        pmm.freePages(erst_page, 1);

        // Free ring
        const ring_page = hal.paging.virtToPhys(@intFromPtr(self.trbs));
        pmm.freePages(ring_page, 1);

        self.trbs = undefined;
        self.erst = undefined;
    }
};

// =============================================================================
// Transfer Ring (extends ProducerRing with TD tracking)
// =============================================================================

/// Transfer ring for endpoint data transfers
/// Tracks Transfer Descriptors (TDs) which may span multiple TRBs
pub const TransferRing = struct {
    /// Underlying producer ring
    ring: ProducerRing,
    /// Number of pending TDs (transfers in flight)
    pending_tds: usize,

    const Self = @This();

    /// Initialize a transfer ring using IOMMU-aware DMA
    pub fn init(bdf: iommu.DeviceBdf) !Self {
        return Self{
            .ring = try ProducerRing.init(bdf),
            .pending_tds = 0,
        };
    }

    /// Enqueue a single-TRB transfer
    pub fn enqueueSingle(self: *Self, transfer_trb: Trb) ?u64 {
        const result = self.ring.enqueue(transfer_trb);
        if (result != null) {
            self.pending_tds += 1;
        }
        return result;
    }

    /// Enqueue a multi-TRB transfer descriptor
    /// All TRBs except the last should have chain=1
    pub fn enqueueTd(self: *Self, td_trbs: []const Trb) ?u64 {
        if (td_trbs.len == 0) return null;
        if (self.ring.freeSlots() < td_trbs.len) return null;

        var first_phys: ?u64 = null;
        for (td_trbs) |t| {
            const phys = self.ring.enqueue(t);
            if (first_phys == null) {
                first_phys = phys;
            }
        }

        self.pending_tds += 1;
        return first_phys;
    }

    /// Mark a TD as completed
    pub fn completeTd(self: *Self) void {
        if (self.pending_tds > 0) {
            self.pending_tds -= 1;
        }
    }

    /// Get device address for endpoint context (IOVA or physical)
    pub fn getDeviceAddress(self: *const Self) u64 {
        return self.ring.getDeviceAddress();
    }

    /// Get physical address (legacy, for debugging)
    pub fn getPhysicalAddress(self: *const Self) u64 {
        return self.ring.phys_base;
    }

    /// Get cycle state for endpoint context
    pub fn getCycleState(self: *const Self) bool {
        return self.ring.getCycleState();
    }

    /// Check if ring has space
    pub fn hasSpace(self: *const Self) bool {
        return self.ring.hasSpace();
    }

    /// Get physical address of the current enqueue position
    /// Used for tracking async transfers before enqueueing
    pub fn getEnqueuePhysAddr(self: *const Self) u64 {
        return self.ring.phys_base + @as(u64, self.ring.enqueue_idx) * @sizeOf(trb.Trb);
    }

    /// Free ring resources
    pub fn deinit(self: *Self) void {
        self.ring.deinit();
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Extract TRB type from a generic TRB
pub fn getTrbType(t: *const Trb) TrbType {
    return t.control.trb_type;
}

/// Check if TRB is an event TRB
pub fn isEventTrb(t: *const Trb) bool {
    const type_val = @intFromEnum(t.control.trb_type);
    return type_val >= 32 and type_val <= 39;
}

/// Check if TRB is a command TRB
pub fn isCommandTrb(t: *const Trb) bool {
    const type_val = @intFromEnum(t.control.trb_type);
    return type_val >= 9 and type_val <= 25;
}

/// Check if TRB is a transfer TRB
pub fn isTransferTrb(t: *const Trb) bool {
    const type_val = @intFromEnum(t.control.trb_type);
    return type_val >= 1 and type_val <= 8;
}
