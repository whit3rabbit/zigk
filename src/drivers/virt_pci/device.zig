// Virtual PCI Device Structure
//
// Implements a software-defined PCI device that can be controlled from userspace.
// Provides MMIO interception, interrupt injection, and DMA operations.
//
// Reference: pciem framework (github.com/cakehonolulu/pciem)

const std = @import("std");
const uapi = @import("uapi");
const virt_pci_uapi = uapi.virt_pci;
const sync = @import("sync");
const pmm = @import("pmm");
const console = @import("console");

const VPciDeviceState = virt_pci_uapi.VPciDeviceState;
const VPciConfigHeader = virt_pci_uapi.VPciConfigHeader;
const BarFlags = virt_pci_uapi.BarFlags;

// =============================================================================
// Virtual BAR
// =============================================================================

/// Virtual BAR structure
pub const VirtualBar = struct {
    /// Size in bytes (must be power of 2, >= 4KB)
    size: u64 = 0,
    /// BAR flags
    flags: BarFlags = .{},
    /// Base address (set during enumeration/registration)
    base_addr: u64 = 0,
    /// Physical address of backing memory
    backing_phys: u64 = 0,
    /// Kernel virtual address (via HHDM)
    backing_virt: u64 = 0,
    /// Number of pages allocated
    page_count: usize = 0,
    /// True if this BAR is configured
    configured: bool = false,

    /// Check if BAR is valid and configured
    pub fn isValid(self: *const VirtualBar) bool {
        return self.configured and self.size > 0;
    }

    /// Check if this BAR intercepts MMIO
    pub fn interceptsMmio(self: *const VirtualBar) bool {
        return self.configured and self.flags.intercept_mmio;
    }
};

// =============================================================================
// Capability Manager
// =============================================================================

/// Maximum capabilities per device
pub const MAX_CAPABILITIES: usize = 8;

/// Capability entry in the chain
pub const CapabilityEntry = struct {
    /// Capability ID
    cap_id: u8 = 0,
    /// Offset in config space
    offset: u8 = 0,
    /// Size in bytes
    size: u8 = 0,
    /// Is this entry used
    used: bool = false,
    /// Capability-specific data
    data: [16]u8 = [_]u8{0} ** 16,
};

/// Manages the capability chain for a virtual device
pub const CapabilityManager = struct {
    /// Capability entries
    entries: [MAX_CAPABILITIES]CapabilityEntry = [_]CapabilityEntry{.{}} ** MAX_CAPABILITIES,
    /// Number of capabilities
    count: u8 = 0,
    /// Next free offset in config space (starts at 0x40)
    next_offset: u8 = 0x40,

    /// Add a capability
    pub fn add(self: *CapabilityManager, cap_id: u8, size: u8, data: []const u8) ?u8 {
        if (self.count >= MAX_CAPABILITIES) return null;
        if (self.next_offset > 0xF0) return null; // No more space

        const offset = self.next_offset;
        const entry = &self.entries[self.count];
        entry.cap_id = cap_id;
        entry.offset = offset;
        entry.size = size;
        entry.used = true;
        @memset(&entry.data, 0);
        const copy_len = @min(data.len, entry.data.len);
        @memcpy(entry.data[0..copy_len], data[0..copy_len]);

        self.count += 1;
        // Align next offset to 4 bytes, minimum cap size is 8 bytes
        self.next_offset = @intCast((@as(u16, offset) + @max(size, 8) + 3) & ~@as(u16, 3));

        return offset;
    }

    /// Find capability by ID
    pub fn find(self: *const CapabilityManager, cap_id: u8) ?*const CapabilityEntry {
        for (&self.entries) |*entry| {
            if (entry.used and entry.cap_id == cap_id) {
                return entry;
            }
        }
        return null;
    }

    /// Get capability by offset
    pub fn getByOffset(self: *const CapabilityManager, offset: u8) ?*const CapabilityEntry {
        for (&self.entries) |*entry| {
            if (entry.used and offset >= entry.offset and offset < entry.offset + entry.size) {
                return entry;
            }
        }
        return null;
    }
};

// =============================================================================
// Virtual PCI Device
// =============================================================================

/// Maximum BARs per device
pub const MAX_BARS: usize = 6;

/// Virtual PCI device structure
pub const VirtualPciDevice = struct {
    /// Device ID (assigned on creation)
    id: u32 = 0,
    /// Owner process PID
    owner_pid: u32 = 0,
    /// Current device state
    state: VPciDeviceState = .created,
    /// Lock for concurrent access
    lock: sync.Spinlock = .{},

    /// Full 256-byte PCI configuration space
    config_space: [256]u8 = [_]u8{0} ** 256,

    /// Virtual BARs
    bars: [MAX_BARS]VirtualBar = [_]VirtualBar{.{}} ** MAX_BARS,

    /// Capability manager
    cap_mgr: CapabilityManager = .{},

    /// Event ring ID (valid after registration)
    ring_id: u32 = 0,
    /// Event ring physical address
    ring_phys: u64 = 0,
    /// Event ring kernel virtual address
    ring_virt: u64 = 0,
    /// Event ring page count
    ring_page_count: usize = 0,

    /// Sequence number for events
    next_seq: u64 = 1,

    /// MSI configuration (captured from config space writes)
    msi_address: u64 = 0,
    msi_data: u32 = 0,
    msi_enabled: bool = false,

    /// MSI-X table base (in BAR memory)
    msix_table_base: u64 = 0,
    msix_table_size: u16 = 0,
    msix_enabled: bool = false,

    /// Total BAR size in bytes (for limit checking)
    total_bar_size: u64 = 0,

    const Self = @This();

    /// Initialize device with defaults
    pub fn init(id: u32, owner_pid: u32) Self {
        var dev = Self{
            .id = id,
            .owner_pid = owner_pid,
            .state = .created,
        };

        // Initialize config space with defaults
        // Vendor/Device ID = 0xFFFF (invalid until set)
        dev.config_space[0] = 0xFF;
        dev.config_space[1] = 0xFF;
        dev.config_space[2] = 0xFF;
        dev.config_space[3] = 0xFF;

        // Status register: Capabilities list present
        dev.config_space[6] = 0x10;

        // Header type 0 (normal device)
        dev.config_space[0x0E] = 0x00;

        // Capabilities pointer (will point to 0x40 if caps are added)
        dev.config_space[0x34] = 0x00;

        return dev;
    }

    /// Set configuration header
    pub fn setConfigHeader(self: *Self, header: *const VPciConfigHeader) void {
        const held = self.lock.acquire();
        defer held.release();

        // Only allow in created or configuring state
        if (self.state != .created and self.state != .configuring) return;

        // Copy header fields to config space
        self.config_space[0] = @truncate(header.vendor_id);
        self.config_space[1] = @truncate(header.vendor_id >> 8);
        self.config_space[2] = @truncate(header.device_id);
        self.config_space[3] = @truncate(header.device_id >> 8);
        self.config_space[4] = @truncate(header.command);
        self.config_space[5] = @truncate(header.command >> 8);
        self.config_space[6] = @truncate(header.status);
        self.config_space[7] = @truncate(header.status >> 8);
        self.config_space[8] = header.revision_id;
        self.config_space[9] = header.prog_if;
        self.config_space[10] = header.subclass;
        self.config_space[11] = header.class_code;
        self.config_space[12] = header.cache_line_size;
        self.config_space[13] = header.latency_timer;
        self.config_space[14] = header.header_type;
        self.config_space[15] = header.bist;
        self.config_space[0x2C] = @truncate(header.subsystem_vendor_id);
        self.config_space[0x2D] = @truncate(header.subsystem_vendor_id >> 8);
        self.config_space[0x2E] = @truncate(header.subsystem_id);
        self.config_space[0x2F] = @truncate(header.subsystem_id >> 8);
        self.config_space[0x3C] = header.interrupt_line;
        self.config_space[0x3D] = header.interrupt_pin;
        self.config_space[0x3E] = header.min_grant;
        self.config_space[0x3F] = header.max_latency;

        if (self.state == .created) {
            self.state = .configuring;
        }
    }

    /// Add a BAR
    pub fn addBar(self: *Self, bar_index: u8, size: u64, flags: BarFlags) !void {
        if (bar_index >= MAX_BARS) return error.InvalidBarIndex;
        if (size < virt_pci_uapi.MIN_BAR_SIZE) return error.BarTooSmall;
        if (size > virt_pci_uapi.MAX_BAR_SIZE) return error.BarTooLarge;
        if (!isPowerOf2(size)) return error.NotPowerOfTwo;

        const held = self.lock.acquire();
        defer held.release();

        if (self.state != .created and self.state != .configuring) {
            return error.InvalidState;
        }

        // Check if 64-bit BAR would overflow
        if (flags.is_64bit and bar_index >= 5) {
            return error.InvalidBarIndex;
        }

        const bar = &self.bars[bar_index];
        if (bar.configured) {
            return error.BarAlreadyConfigured;
        }

        // For 64-bit BARs, check next slot is free
        if (flags.is_64bit) {
            if (self.bars[bar_index + 1].configured) {
                return error.BarAlreadyConfigured;
            }
        }

        // Allocate backing memory
        const page_count = (size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
        const phys = pmm.allocZeroedPages(page_count) orelse {
            return error.OutOfMemory;
        };
        errdefer pmm.freePages(phys, page_count);

        const hal = @import("hal");
        const virt: u64 = @intFromPtr(hal.paging.physToVirt(phys));

        // Configure BAR
        bar.size = size;
        bar.flags = flags;
        bar.backing_phys = phys;
        bar.backing_virt = virt;
        bar.page_count = page_count;
        bar.configured = true;

        // Update total BAR size
        self.total_bar_size += size;

        // For 64-bit BARs, mark next slot as used
        if (flags.is_64bit) {
            self.bars[bar_index + 1].configured = true;
            self.bars[bar_index + 1].size = 0; // Upper 32 bits
        }

        // Update config space BAR register
        const bar_offset: usize = 0x10 + @as(usize, bar_index) * 4;
        var bar_value: u32 = 0;

        if (flags.is_mmio) {
            // Memory BAR
            bar_value |= 0; // Bit 0 = 0 for memory
            if (flags.is_64bit) {
                bar_value |= 0x04; // Type = 64-bit
            }
            if (flags.prefetchable) {
                bar_value |= 0x08;
            }
        } else {
            // I/O BAR
            bar_value |= 0x01; // Bit 0 = 1 for I/O
        }

        // Write BAR to config space (will be updated with actual address during registration)
        self.config_space[bar_offset] = @truncate(bar_value);
        self.config_space[bar_offset + 1] = @truncate(bar_value >> 8);
        self.config_space[bar_offset + 2] = @truncate(bar_value >> 16);
        self.config_space[bar_offset + 3] = @truncate(bar_value >> 24);

        if (self.state == .created) {
            self.state = .configuring;
        }

        console.debug("VirtPCI[{}]: Added BAR{} size=0x{x} flags={}", .{ self.id, bar_index, size, @as(u16, @bitCast(flags)) });
    }

    /// Add a capability
    pub fn addCapability(self: *Self, cap_type: virt_pci_uapi.VPciCapType, data: []const u8) !u8 {
        const held = self.lock.acquire();
        defer held.release();

        if (self.state != .created and self.state != .configuring) {
            return error.InvalidState;
        }

        const cap_id: u8 = @intFromEnum(cap_type);
        const cap_size: u8 = switch (cap_type) {
            .msi => 14, // MSI: ID(1) + Next(1) + MsgCtrl(2) + Addr(4) + AddrHi(4) + Data(2)
            .msix => 12, // MSI-X: ID(1) + Next(1) + MsgCtrl(2) + Table(4) + PBA(4)
            .pm => 8, // PM: ID(1) + Next(1) + Caps(2) + Status(2) + Bridge(2)
            .pcie => 60, // PCIe: Full capability
            .vendor => @intCast(@min(data.len + 2, 255)),
        };

        const offset = self.cap_mgr.add(cap_id, cap_size, data) orelse {
            return error.TooManyCapabilities;
        };

        // Update capabilities pointer if this is the first capability
        if (self.cap_mgr.count == 1) {
            self.config_space[0x34] = offset;
            // Set capabilities list bit in status
            self.config_space[6] |= 0x10;
        } else {
            // Link from previous capability
            const prev_idx = self.cap_mgr.count - 2;
            const prev_entry = &self.cap_mgr.entries[prev_idx];
            // Write next pointer at offset+1
            self.config_space[prev_entry.offset + 1] = offset;
        }

        // Write capability header
        self.config_space[offset] = cap_id;
        self.config_space[offset + 1] = 0; // Next pointer (will be updated if more caps added)

        if (self.state == .created) {
            self.state = .configuring;
        }

        console.debug("VirtPCI[{}]: Added capability type={} offset=0x{x}", .{ self.id, cap_id, offset });
        return offset;
    }

    /// Read config space
    pub fn readConfig(self: *Self, offset: u12, size: u8) u32 {
        const held = self.lock.acquire();
        defer held.release();

        if (offset >= 256) return 0xFFFFFFFF;

        var value: u32 = 0;
        const start: usize = offset;
        const end: usize = @min(start + size, 256);

        for (start..end) |i| {
            value |= @as(u32, self.config_space[i]) << @intCast((i - start) * 8);
        }

        return value;
    }

    /// Write config space
    pub fn writeConfig(self: *Self, offset: u12, size: u8, value: u32) void {
        const held = self.lock.acquire();
        defer held.release();

        if (offset >= 256) return;

        // Handle special registers
        switch (offset) {
            0x04 => {
                // Command register - allow memory/IO space enable
                self.config_space[4] = @truncate(value);
                if (size > 1) self.config_space[5] = @truncate(value >> 8);
            },
            0x10...0x27 => {
                // BAR writes - handle address assignment
                // In real hardware this would trigger BAR sizing
                // For virtual devices, we accept the address
                const bar_idx = (offset - 0x10) / 4;
                if (bar_idx < MAX_BARS and self.bars[bar_idx].configured) {
                    // Store the assigned base address
                    const bar = &self.bars[bar_idx];
                    const masked = value & ~@as(u32, @intCast(bar.size - 1));
                    bar.base_addr = masked;
                }
            },
            else => {
                // Generic write
                const start: usize = offset;
                const end: usize = @min(start + size, 256);
                for (start..end, 0..) |i, j| {
                    self.config_space[i] = @truncate(value >> @intCast(j * 8));
                }
            },
        }

        // Check for MSI/MSI-X configuration changes
        if (self.cap_mgr.getByOffset(@truncate(offset))) |cap| {
            if (cap.cap_id == 0x05) {
                // MSI capability write
                self.handleMsiWrite(cap.offset, offset, value);
            } else if (cap.cap_id == 0x11) {
                // MSI-X capability write
                self.handleMsixWrite(cap.offset, offset, value);
            }
        }
    }

    /// Handle MSI configuration write
    fn handleMsiWrite(self: *Self, cap_offset: u8, write_offset: u12, value: u32) void {
        const rel_offset = write_offset - cap_offset;

        switch (rel_offset) {
            2 => {
                // Message Control
                self.msi_enabled = (value & 0x01) != 0;
            },
            4 => {
                // Message Address Low
                self.msi_address = (self.msi_address & 0xFFFFFFFF00000000) | value;
            },
            8 => {
                // Message Address High (64-bit) or Data (32-bit)
                // Check if 64-bit capable by reading message control
                const msg_ctrl = self.config_space[cap_offset + 2];
                if ((msg_ctrl & 0x80) != 0) {
                    // 64-bit capable, this is address high
                    self.msi_address = (self.msi_address & 0x00000000FFFFFFFF) | (@as(u64, value) << 32);
                } else {
                    // 32-bit, this is data
                    self.msi_data = @truncate(value);
                }
            },
            12 => {
                // Message Data (64-bit) or Mask (32-bit with PVM)
                const msg_ctrl = self.config_space[cap_offset + 2];
                if ((msg_ctrl & 0x80) != 0) {
                    // 64-bit, this is data
                    self.msi_data = @truncate(value);
                }
            },
            else => {},
        }
    }

    /// Handle MSI-X configuration write
    fn handleMsixWrite(self: *Self, cap_offset: u8, write_offset: u12, value: u32) void {
        const rel_offset = write_offset - cap_offset;

        if (rel_offset == 2) {
            // Message Control
            self.msix_enabled = (value & 0x8000) != 0;
        }
    }

    /// Allocate event ring
    pub fn allocateEventRing(self: *Self, entry_count: u32) !void {
        if (!virt_pci_uapi.isPowerOf2(entry_count)) {
            return error.NotPowerOfTwo;
        }

        const total_size = virt_pci_uapi.VPciRingHeader.totalSize(entry_count);
        const page_count = (total_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

        const phys = pmm.allocZeroedPages(page_count) orelse {
            return error.OutOfMemory;
        };
        errdefer pmm.freePages(phys, page_count);

        const hal = @import("hal");
        const virt: u64 = @intFromPtr(hal.paging.physToVirt(phys));

        // Initialize ring header
        const header: *volatile virt_pci_uapi.VPciRingHeader = @ptrFromInt(virt);
        header.prod_idx = 0;
        header.cons_idx = 0;
        header.ring_mask = entry_count - 1;
        header.entry_count = entry_count;
        header.device_id = self.id;
        header.flags = virt_pci_uapi.RING_FLAG_ACTIVE;
        header.pending_responses = 0;

        self.ring_phys = phys;
        self.ring_virt = virt;
        self.ring_page_count = page_count;

        console.debug("VirtPCI[{}]: Allocated event ring entries={} pages={}", .{ self.id, entry_count, page_count });
    }

    /// Free all resources
    pub fn destroy(self: *Self) void {
        const held = self.lock.acquire();
        defer held.release();

        self.state = .closing;

        // Free BAR backing memory
        for (&self.bars) |*bar| {
            if (bar.configured and bar.page_count > 0 and bar.backing_phys != 0) {
                pmm.freePages(bar.backing_phys, bar.page_count);
                bar.backing_phys = 0;
                bar.backing_virt = 0;
                bar.page_count = 0;
            }
            bar.configured = false;
        }

        // Free event ring
        if (self.ring_phys != 0) {
            pmm.freePages(self.ring_phys, self.ring_page_count);
            self.ring_phys = 0;
            self.ring_virt = 0;
            self.ring_page_count = 0;
        }

        console.debug("VirtPCI[{}]: Destroyed", .{self.id});
    }

    /// Get next sequence number
    pub fn nextSequence(self: *Self) u64 {
        const seq = @atomicRmw(u64, &self.next_seq, .Add, 1, .monotonic);
        return seq;
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn isPowerOf2(n: u64) bool {
    return n > 0 and (n & (n - 1)) == 0;
}
