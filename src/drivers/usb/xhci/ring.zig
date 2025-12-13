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

const trb = @import("trb.zig");
const Trb = trb.Trb;
const TrbType = trb.TrbType;
const LinkTrb = trb.LinkTrb;
const ErstEntry = trb.ErstEntry;
const CompletionCode = trb.CompletionCode;

const hal = @import("hal");
const pmm = @import("pmm");

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
    /// Physical address of ring buffer (for hardware)
    phys_base: u64,
    /// Current enqueue index
    enqueue_idx: usize,
    /// Producer cycle state (toggled on wrap)
    pcs: bool,
    /// Ring size in TRBs
    size: usize,

    const Self = @This();

    /// Allocate and initialize a producer ring
    pub fn init() !Self {
        // Allocate one page for ring (4KB = 256 TRBs)
        const phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const virt = @intFromPtr(hal.paging.physToVirt(phys));
        const trbs: [*]Trb = @ptrFromInt(virt);

        var ring = Self{
            .trbs = trbs,
            .phys_base = phys,
            .enqueue_idx = 0,
            .pcs = true, // Start with cycle bit = 1
            .size = DEFAULT_RING_SIZE,
        };

        // Initialize Link TRB at end to wrap back to start
        ring.setupLinkTrb();

        return ring;
    }

    /// Set up the Link TRB at the end of the ring
    fn setupLinkTrb(self: *Self) void {
        const link_idx = self.size - 1;
        const link: *LinkTrb = @ptrCast(&self.trbs[link_idx]);
        link.* = LinkTrb.init(self.phys_base, true, self.pcs);
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
        const ctrl = @as(*u32, @ptrCast(&trb_copy.control));
        if (self.pcs) {
            ctrl.* |= 1; // Set cycle bit
        } else {
            ctrl.* &= ~@as(u32, 1); // Clear cycle bit
        }

        // Write to ring
        self.trbs[self.enqueue_idx] = trb_copy;

        // Memory barrier to ensure TRB is visible before doorbell
        asm volatile ("mfence"
            :
            :
            : .{ .memory = true }
        );

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
        const ctrl = @as(*u32, @ptrCast(&link.control));
        if (self.pcs) {
            ctrl.* |= 1;
        } else {
            ctrl.* &= ~@as(u32, 1);
        }

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
    /// Physical address of ring buffer
    phys_base: u64,
    /// Current dequeue index
    dequeue_idx: usize,
    /// Consumer cycle state (expected cycle bit value)
    ccs: bool,
    /// Ring size in TRBs
    size: usize,
    /// Event Ring Segment Table
    erst: *ErstEntry,
    /// Physical address of ERST
    erst_phys: u64,

    const Self = @This();

    /// Allocate and initialize an event ring with ERST
    pub fn init() !Self {
        // Allocate ring segment (one page)
        const ring_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const ring_virt = @intFromPtr(hal.paging.physToVirt(ring_phys));
        const trbs: [*]Trb = @ptrFromInt(ring_virt);

        // Allocate ERST (one entry, but needs 64-byte alignment)
        // Use a full page for simplicity
        const erst_phys = pmm.allocZeroedPages(1) orelse {
            pmm.freePages(ring_phys, 1);
            return error.OutOfMemory;
        };
        const erst_virt = @intFromPtr(hal.paging.physToVirt(erst_phys));
        const erst: *ErstEntry = @ptrFromInt(erst_virt);

        // Initialize ERST entry
        erst.* = ErstEntry.init(ring_phys, DEFAULT_RING_SIZE);

        return Self{
            .trbs = trbs,
            .phys_base = ring_phys,
            .dequeue_idx = 0,
            .ccs = true, // Expect cycle bit = 1 initially
            .size = DEFAULT_RING_SIZE,
            .erst = erst,
            .erst_phys = erst_phys,
        };
    }

    /// Check if there's a pending event to process
    pub fn hasPending(self: *const Self) bool {
        const current_trb = &self.trbs[self.dequeue_idx];
        const ctrl = @as(*const u32, @ptrCast(&current_trb.control));
        const cycle_bit = (ctrl.* & 1) != 0;
        return cycle_bit == self.ccs;
    }

    /// Dequeue the next event TRB
    /// Returns null if no event pending
    pub fn dequeue(self: *Self) ?*const Trb {
        if (!self.hasPending()) {
            return null;
        }

        const current = &self.trbs[self.dequeue_idx];

        // Advance dequeue pointer
        self.dequeue_idx += 1;
        if (self.dequeue_idx >= self.size) {
            self.dequeue_idx = 0;
            self.ccs = !self.ccs; // Toggle expected cycle bit on wrap
        }

        return current;
    }

    /// Get current dequeue pointer physical address for ERDP register
    pub fn getDequeuePointer(self: *const Self) u64 {
        return self.phys_base + @as(u64, self.dequeue_idx) * @sizeOf(Trb);
    }

    /// Get ERST physical address for ERSTBA register
    pub fn getErstBase(self: *const Self) u64 {
        return self.erst_phys;
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

    /// Initialize a transfer ring
    pub fn init() !Self {
        return Self{
            .ring = try ProducerRing.init(),
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

    /// Get physical address for endpoint context
    pub fn getPhysicalAddress(self: *const Self) u64 {
        return self.ring.getPhysicalAddress();
    }

    /// Get cycle state for endpoint context
    pub fn getCycleState(self: *const Self) bool {
        return self.ring.getCycleState();
    }

    /// Check if ring has space
    pub fn hasSpace(self: *const Self) bool {
        return self.ring.hasSpace();
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
