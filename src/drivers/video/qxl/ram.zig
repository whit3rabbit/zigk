//! QXL RAM Manager
//!
//! Manages the QXL RAM region (BAR2) which contains:
//! - Command ring: for submitting draw commands to the device
//! - Cursor ring: for cursor updates
//! - Release ring: device returns completed command IDs
//! - Memory slots: describe guest memory regions to the device
//!
//! Reference: QEMU hw/display/qxl.c, spice-protocol/spice/qxl_dev.h

const std = @import("std");
const hal = @import("hal");
const pmm = @import("pmm");
const sync = @import("sync");
const hw = @import("hardware.zig");
const console = @import("console");

/// QXL RAM Header structure (at start of BAR2)
/// This structure is shared with the device for command ring communication
pub const QxlRamHeader = extern struct {
    /// Magic number - must be RAM_MAGIC (0x41525851 "QXRA")
    magic: u32,
    /// QXL protocol version
    version: u32,
    /// Number of memory slots (typically 8)
    num_memslots: u32,
    /// Bits per memslot generation (for slot invalidation)
    memslot_gen_bits: u32,
    /// Bits for memslot ID
    memslot_id_bits: u32,
    /// Log level for debugging
    log_level: u32,
    /// Reserved for future use
    _reserved: [6]u32 = .{0} ** 6,

    /// Command ring descriptor
    cmd_ring: RingDescriptor,
    /// Cursor ring descriptor
    cursor_ring: RingDescriptor,
    /// Release ring descriptor
    release_ring: RingDescriptor,

    /// Memory slot configuration (placed after rings)
    memslot_config: MemslotConfig,

    /// Update area rect (for IO_UPDATE_AREA)
    update_rect: hw.QxlRect,
    /// Update surface ID
    update_surface: u32,
};

/// Ring descriptor - describes a producer/consumer ring
pub const RingDescriptor = extern struct {
    /// Producer index (device writes for release, guest writes for cmd/cursor)
    prod: u32,
    /// Notify on wrap flag
    notify_on_wrap: u32,
    /// Consumer index
    cons: u32,
    /// Notify on prod flag
    notify_on_prod: u32,
};

/// Memory slot configuration
pub const MemslotConfig = extern struct {
    /// Slot ID bits in address
    slot_id_bits: u32,
    /// Generation bits
    slot_gen_bits: u32,
    /// Slots start address
    slots_start: u64,
    /// Slots end address
    slots_end: u64,
};

/// Memory slot descriptor
pub const MemslotDescriptor = extern struct {
    /// Slot generation
    generation: u8,
    /// Slot ID
    slot_id: u8,
    /// Reserved padding
    _reserved: [6]u8 = .{0} ** 6,
    /// Virtual start address
    virt_start: u64,
    /// Virtual end address
    virt_end: u64,
};

/// Command ring entry
pub const CmdRingEntry = extern struct {
    /// Command data pointer (physical address)
    data: u64,
    /// Command type (CmdType)
    cmd_type: u8,
    /// Padding
    _pad: [7]u8 = .{0} ** 7,
};

/// Maximum number of ring entries
pub const CMD_RING_SIZE: usize = 32;
pub const CURSOR_RING_SIZE: usize = 32;
pub const RELEASE_RING_SIZE: usize = 64;

/// RAM Manager for QXL 2D acceleration
pub const RamManager = struct {
    /// Virtual address of RAM header (mapped from BAR2)
    header: *volatile QxlRamHeader,

    /// Command ring entries (after header in RAM)
    cmd_ring: [*]volatile CmdRingEntry,

    /// Release ring entries (after cmd ring)
    release_ring: [*]volatile u64,

    /// Physical base address of BAR2
    phys_base: u64,

    /// Size of BAR2
    ram_size: u64,

    /// Lock for thread-safe access
    lock: sync.Spinlock,

    /// Producer index for command ring
    cmd_prod: u32,

    /// Consumer index for release ring
    release_cons: u32,

    const Self = @This();

    /// Initialize RAM manager from BAR2 address
    pub fn init(bar2_phys: u64, bar2_size: u64) ?Self {
        if (bar2_phys == 0 or bar2_size < @sizeOf(QxlRamHeader)) {
            console.debug("QXL RAM: Invalid BAR2 address or size", .{});
            return null;
        }

        // Map BAR2 to virtual address via HHDM
        const virt_ptr = hal.paging.physToVirt(bar2_phys);
        const virt_addr = @intFromPtr(virt_ptr);
        const header: *volatile QxlRamHeader = @ptrFromInt(virt_addr);

        // Verify magic
        if (header.magic != hw.RAM_MAGIC) {
            console.debug("QXL RAM: Invalid magic 0x{x}, expected 0x{x}", .{
                header.magic,
                hw.RAM_MAGIC,
            });
            return null;
        }

        console.info("QXL RAM: Magic verified, version={}", .{header.version});

        // Calculate ring locations (after header)
        const header_end = virt_addr + @sizeOf(QxlRamHeader);

        // Align to 16 bytes for ring entries
        const cmd_ring_addr = (header_end + 15) & ~@as(usize, 15);
        const cmd_ring_size = CMD_RING_SIZE * @sizeOf(CmdRingEntry);

        const release_ring_addr = cmd_ring_addr + cmd_ring_size;

        // Verify we have enough space
        const total_needed = release_ring_addr + (RELEASE_RING_SIZE * @sizeOf(u64)) - virt_addr;
        if (total_needed > bar2_size) {
            console.err("QXL RAM: BAR2 too small for rings ({} > {})", .{
                total_needed,
                bar2_size,
            });
            return null;
        }

        const cmd_ring: [*]volatile CmdRingEntry = @ptrFromInt(cmd_ring_addr);
        const release_ring: [*]volatile u64 = @ptrFromInt(release_ring_addr);

        // Initialize ring descriptors
        header.cmd_ring = .{
            .prod = 0,
            .notify_on_wrap = 0,
            .cons = 0,
            .notify_on_prod = 1,
        };

        header.release_ring = .{
            .prod = 0,
            .notify_on_wrap = 0,
            .cons = 0,
            .notify_on_prod = 1,
        };

        // Zero out ring memory
        const cmd_slice: [*]volatile u8 = @ptrCast(cmd_ring);
        for (0..cmd_ring_size) |i| {
            cmd_slice[i] = 0;
        }

        const release_slice: [*]volatile u8 = @ptrCast(release_ring);
        for (0..(RELEASE_RING_SIZE * @sizeOf(u64))) |i| {
            release_slice[i] = 0;
        }

        console.info("QXL RAM: Rings initialized at cmd=0x{x}, release=0x{x}", .{
            cmd_ring_addr,
            release_ring_addr,
        });

        return Self{
            .header = header,
            .cmd_ring = cmd_ring,
            .release_ring = release_ring,
            .phys_base = bar2_phys,
            .ram_size = bar2_size,
            .lock = .{},
            .cmd_prod = 0,
            .release_cons = 0,
        };
    }

    /// Setup a memory slot for guest memory access
    /// Slot 0 is typically used for the drawable/command buffer area
    pub fn setupMemSlot(self: *Self, slot_id: u8, phys_start: u64, size: u64) bool {
        if (slot_id >= 8) return false; // Max 8 slots

        const phys_end = std.math.add(u64, phys_start, size) catch return false;

        // Configure memslot in header
        self.header.memslot_config.slot_id_bits = 8;
        self.header.memslot_config.slot_gen_bits = 8;
        self.header.memslot_config.slots_start = phys_start;
        self.header.memslot_config.slots_end = phys_end;

        // Memory barrier to ensure writes are visible
        asm volatile ("" ::: "memory");

        console.info("QXL RAM: Memslot {} configured: 0x{x}-0x{x}", .{
            slot_id,
            phys_start,
            phys_end,
        });

        return true;
    }

    /// Push a command to the command ring
    /// Returns true if command was queued successfully
    pub fn pushCommand(self: *Self, cmd_phys: u64, cmd_type: hw.CmdType) bool {
        self.lock.lock();
        defer self.lock.unlock();

        // Check if ring is full
        const cons = self.header.cmd_ring.cons;
        const next_prod = (self.cmd_prod + 1) % CMD_RING_SIZE;

        if (next_prod == cons) {
            // Ring full
            return false;
        }

        // Write command entry
        self.cmd_ring[self.cmd_prod] = .{
            .data = cmd_phys,
            .cmd_type = @intFromEnum(cmd_type),
            ._pad = .{0} ** 7,
        };

        // Memory barrier before updating producer
        asm volatile ("" ::: "memory");

        // Update producer index
        self.cmd_prod = @intCast(next_prod);
        self.header.cmd_ring.prod = self.cmd_prod;

        return true;
    }

    /// Pop a release ID from the release ring
    /// Returns the physical address of the completed command, or null if ring empty
    pub fn popRelease(self: *Self) ?u64 {
        self.lock.lock();
        defer self.lock.unlock();

        const prod = self.header.release_ring.prod;

        if (self.release_cons == prod) {
            // Ring empty
            return null;
        }

        // Read release entry
        const addr = self.release_ring[self.release_cons];

        // Memory barrier after read
        asm volatile ("" ::: "memory");

        // Update consumer index
        self.release_cons = @intCast((self.release_cons + 1) % RELEASE_RING_SIZE);
        self.header.release_ring.cons = self.release_cons;

        return addr;
    }

    /// Check if command ring has space
    pub fn hasCommandSpace(self: *Self) bool {
        const cons = self.header.cmd_ring.cons;
        const next_prod = (self.cmd_prod + 1) % CMD_RING_SIZE;
        return next_prod != cons;
    }

    /// Get number of pending commands
    pub fn pendingCommands(self: *Self) u32 {
        const cons = self.header.cmd_ring.cons;
        if (self.cmd_prod >= cons) {
            return self.cmd_prod - cons;
        } else {
            return @as(u32, CMD_RING_SIZE) - cons + self.cmd_prod;
        }
    }

    /// Wait for all commands to complete
    pub fn waitIdle(self: *Self, max_polls: u32) bool {
        var polls: u32 = 0;
        while (polls < max_polls) : (polls += 1) {
            if (self.header.cmd_ring.cons == self.cmd_prod) {
                return true;
            }
            // CPU pause hint
            asm volatile ("pause");
        }
        return false;
    }
};
