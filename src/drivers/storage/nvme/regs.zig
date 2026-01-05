// NVMe Controller Register Definitions
//
// Defines all NVMe controller registers as packed structs for type-safe MMIO access.
// Based on NVM Express Base Specification 2.0.
//
// Reference: https://nvmexpress.org/specifications/

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");

// ============================================================================
// Register Offsets
// ============================================================================

/// NVMe Controller Register offsets (BAR0 MMIO)
pub const Reg = enum(u64) {
    /// Controller Capabilities (64-bit, RO)
    cap = 0x00,
    /// Version (32-bit, RO)
    vs = 0x08,
    /// Interrupt Mask Set (32-bit, RW)
    intms = 0x0C,
    /// Interrupt Mask Clear (32-bit, RW)
    intmc = 0x10,
    /// Controller Configuration (32-bit, RW)
    cc = 0x14,
    /// Reserved
    _reserved0 = 0x18,
    /// Controller Status (32-bit, RO)
    csts = 0x1C,
    /// NVM Subsystem Reset (32-bit, RW, optional)
    nssr = 0x20,
    /// Admin Queue Attributes (32-bit, RW)
    aqa = 0x24,
    /// Admin Submission Queue Base Address (64-bit, RW)
    asq = 0x28,
    /// Admin Completion Queue Base Address (64-bit, RW)
    acq = 0x30,
    /// Controller Memory Buffer Location (32-bit, RO, optional)
    cmbloc = 0x38,
    /// Controller Memory Buffer Size (32-bit, RO, optional)
    cmbsz = 0x3C,
    /// Boot Partition Info (32-bit, RO, optional)
    bpinfo = 0x40,
    /// Boot Partition Read Select (32-bit, RW, optional)
    bprsel = 0x44,
    /// Boot Partition Memory Buffer Location (64-bit, RW, optional)
    bpmbl = 0x48,
    /// Controller Memory Buffer Memory Space Control (64-bit, RW, optional)
    cmbmsc = 0x50,
    /// Controller Memory Buffer Status (32-bit, RO, optional)
    cmbsts = 0x58,
    /// Persistent Memory Capabilities (32-bit, RO, optional)
    pmrcap = 0xE00,
    /// Persistent Memory Region Control (32-bit, RW, optional)
    pmrctl = 0xE04,
    /// Persistent Memory Region Status (32-bit, RO, optional)
    pmrsts = 0xE08,
    /// Persistent Memory Region Elasticity Buffer Size (32-bit, RO, optional)
    pmrebs = 0xE0C,
    /// Persistent Memory Region Sustained Write Throughput (32-bit, RO, optional)
    pmrswtp = 0xE10,
    /// Persistent Memory Region Memory Space Control (64-bit, RW, optional)
    pmrmsc = 0xE14,
};

// ============================================================================
// Controller Capabilities (CAP) - Offset 0x00
// ============================================================================

/// Controller Capabilities register (64-bit, read-only)
pub const Capabilities = packed struct(u64) {
    /// Maximum Queue Entries Supported (0-based, so +1 for actual count)
    /// Indicates the maximum individual queue size that the controller supports
    mqes: u16,

    /// Contiguous Queues Required
    /// If set, requires physically contiguous queues
    cqr: bool,

    /// Arbitration Mechanism Supported
    /// Bit 0: Weighted Round Robin with Urgent Priority Class
    /// Bit 1: Vendor Specific
    ams: u2,

    /// Reserved
    _reserved0: u5,

    /// Timeout (in 500ms units)
    /// Worst case time controller may take to transition between states
    to: u8,

    /// Doorbell Stride
    /// Stride between doorbell registers: 2^(2+DSTRD) bytes
    dstrd: u4,

    /// NVM Subsystem Reset Supported
    nssrs: bool,

    /// Command Sets Supported
    /// Bit 0: NVM Command Set
    /// Bit 6: I/O Command Set (NVMe 1.3+)
    /// Bit 7: No I/O Command Set (NVMe 1.3+)
    css: u8,

    /// Boot Partition Support
    bps: bool,

    /// Reserved
    _reserved1: u2,

    /// Memory Page Size Minimum (2^(12+MPSMIN) bytes)
    mpsmin: u4,

    /// Memory Page Size Maximum (2^(12+MPSMAX) bytes)
    mpsmax: u4,

    /// Persistent Memory Region Supported
    pmrs: bool,

    /// Controller Memory Buffer Supported
    cmbs: bool,

    /// Reserved
    _reserved2: u6,

    /// Maximum queue entries (actual count, not 0-based)
    pub fn maxQueueEntries(self: Capabilities) u17 {
        return @as(u17, self.mqes) + 1;
    }

    /// Doorbell stride in bytes
    pub fn doorbellStride(self: Capabilities) u32 {
        return @as(u32, 4) << self.dstrd;
    }

    /// Timeout in milliseconds
    pub fn timeoutMs(self: Capabilities) u32 {
        return @as(u32, self.to) * 500;
    }

    /// Minimum page size in bytes
    pub fn minPageSize(self: Capabilities) u32 {
        return @as(u32, 1) << (@as(u5, 12) + self.mpsmin);
    }

    /// Maximum page size in bytes
    pub fn maxPageSize(self: Capabilities) u32 {
        return @as(u32, 1) << (@as(u5, 12) + self.mpsmax);
    }

    /// Check if NVM command set is supported
    pub fn supportsNvmCommandSet(self: Capabilities) bool {
        return (self.css & 0x01) != 0;
    }
};

// ============================================================================
// Version (VS) - Offset 0x08
// ============================================================================

/// NVMe Version register (32-bit, read-only)
pub const Version = packed struct(u32) {
    /// Tertiary Version Number
    ter: u8,
    /// Minor Version Number
    mnr: u8,
    /// Major Version Number
    mjr: u16,

    pub fn format(self: Version) struct { major: u16, minor: u8, tertiary: u8 } {
        return .{ .major = self.mjr, .minor = self.mnr, .tertiary = self.ter };
    }

    pub fn isAtLeast(self: Version, major: u16, minor: u8) bool {
        if (self.mjr > major) return true;
        if (self.mjr < major) return false;
        return self.mnr >= minor;
    }
};

// ============================================================================
// Controller Configuration (CC) - Offset 0x14
// ============================================================================

/// Controller Configuration register (32-bit, read-write)
pub const ControllerConfig = packed struct(u32) {
    /// Enable
    /// Setting to 1 causes controller to process commands
    en: bool,

    /// Reserved
    _reserved0: u3,

    /// I/O Command Set Selected
    /// 0 = NVM Command Set, 6 = Admin only, 7 = All supported
    css: u3,

    /// Memory Page Size (2^(12+MPS) bytes)
    mps: u4,

    /// Arbitration Mechanism Selected
    ams: u3,

    /// Shutdown Notification
    /// 00b = No notification, 01b = Normal, 10b = Abrupt
    shn: u2,

    /// I/O Submission Queue Entry Size (2^IOSQES bytes)
    /// Must be set to 6 (64 bytes) for NVM command set
    iosqes: u4,

    /// I/O Completion Queue Entry Size (2^IOCQES bytes)
    /// Must be set to 4 (16 bytes) for NVM command set
    iocqes: u4,

    /// Reserved
    _reserved1: u8,

    /// Create a default configuration for NVM command set
    pub fn defaultNvm() ControllerConfig {
        return ControllerConfig{
            .en = false,
            ._reserved0 = 0,
            .css = 0, // NVM Command Set
            .mps = 0, // 4KB pages (2^12)
            .ams = 0, // Round Robin
            .shn = 0, // No shutdown
            .iosqes = 6, // 64 bytes (required for NVM)
            .iocqes = 4, // 16 bytes (required for NVM)
            ._reserved1 = 0,
        };
    }

    pub fn withEnable(self: ControllerConfig, enabled: bool) ControllerConfig {
        var cc = self;
        cc.en = enabled;
        return cc;
    }

    pub fn withShutdown(self: ControllerConfig, shn: u2) ControllerConfig {
        var cc = self;
        cc.shn = shn;
        return cc;
    }
};

// ============================================================================
// Controller Status (CSTS) - Offset 0x1C
// ============================================================================

/// Controller Status register (32-bit, read-only)
pub const ControllerStatus = packed struct(u32) {
    /// Ready
    /// Set to 1 when controller is ready to process commands
    rdy: bool,

    /// Controller Fatal Status
    /// Set to 1 when a fatal controller error occurred
    cfs: bool,

    /// Shutdown Status
    /// 00b = Normal, 01b = Shutdown processing occurring, 10b = Shutdown complete
    shst: u2,

    /// NVM Subsystem Reset Occurred
    nssro: bool,

    /// Processing Paused
    pp: bool,

    /// Reserved
    _reserved: u26,

    pub fn isReady(self: ControllerStatus) bool {
        return self.rdy;
    }

    pub fn hasFatalError(self: ControllerStatus) bool {
        return self.cfs;
    }

    pub fn shutdownComplete(self: ControllerStatus) bool {
        return self.shst == 0b10;
    }

    pub fn shutdownProcessing(self: ControllerStatus) bool {
        return self.shst == 0b01;
    }
};

// ============================================================================
// Admin Queue Attributes (AQA) - Offset 0x24
// ============================================================================

/// Admin Queue Attributes register (32-bit, read-write)
pub const AdminQueueAttrs = packed struct(u32) {
    /// Admin Submission Queue Size (0-based)
    asqs: u12,

    /// Reserved
    _reserved0: u4,

    /// Admin Completion Queue Size (0-based)
    acqs: u12,

    /// Reserved
    _reserved1: u4,

    pub fn init(sq_size: u12, cq_size: u12) AdminQueueAttrs {
        return AdminQueueAttrs{
            .asqs = sq_size,
            ._reserved0 = 0,
            .acqs = cq_size,
            ._reserved1 = 0,
        };
    }
};

// ============================================================================
// Doorbell Registers - Offset 0x1000+
// ============================================================================

/// Calculate Submission Queue y Tail Doorbell offset
/// Formula: 0x1000 + ((2y) * (4 << CAP.DSTRD))
pub fn sqTailDoorbellOffset(queue_id: u16, doorbell_stride: u32) u64 {
    return 0x1000 + (@as(u64, queue_id) * 2 * doorbell_stride);
}

/// Calculate Completion Queue y Head Doorbell offset
/// Formula: 0x1000 + ((2y + 1) * (4 << CAP.DSTRD))
pub fn cqHeadDoorbellOffset(queue_id: u16, doorbell_stride: u32) u64 {
    return 0x1000 + ((@as(u64, queue_id) * 2 + 1) * doorbell_stride);
}

// ============================================================================
// MMIO Access Wrapper
// ============================================================================

/// Type-safe MMIO access for NVMe registers
pub const NvmeRegs = struct {
    base: u64,
    size: u64,

    const Self = @This();

    pub fn init(base_addr: u64, bar_size: u64) Self {
        return Self{
            .base = base_addr,
            .size = bar_size,
        };
    }

    /// Read a 32-bit register
    pub fn read32(self: Self, reg: Reg) u32 {
        const offset = @intFromEnum(reg);
        if (offset + 4 > self.size) {
            @panic("NVMe: Register read out of bounds");
        }
        return hal.mmio.read32(self.base + offset);
    }

    /// Read a 64-bit register
    pub fn read64(self: Self, reg: Reg) u64 {
        const offset = @intFromEnum(reg);
        if (offset + 8 > self.size) {
            @panic("NVMe: Register read out of bounds");
        }
        return hal.mmio.read64(self.base + offset);
    }

    /// Write a 32-bit register
    pub fn write32(self: Self, reg: Reg, value: u32) void {
        const offset = @intFromEnum(reg);
        if (offset + 4 > self.size) {
            @panic("NVMe: Register write out of bounds");
        }
        hal.mmio.write32(self.base + offset, value);
    }

    /// Write a 64-bit register
    pub fn write64(self: Self, reg: Reg, value: u64) void {
        const offset = @intFromEnum(reg);
        if (offset + 8 > self.size) {
            @panic("NVMe: Register write out of bounds");
        }
        hal.mmio.write64(self.base + offset, value);
    }

    /// Read capabilities register
    pub fn readCapabilities(self: Self) Capabilities {
        return @bitCast(self.read64(.cap));
    }

    /// Read version register
    pub fn readVersion(self: Self) Version {
        return @bitCast(self.read32(.vs));
    }

    /// Read controller configuration
    pub fn readConfig(self: Self) ControllerConfig {
        return @bitCast(self.read32(.cc));
    }

    /// Write controller configuration
    pub fn writeConfig(self: Self, cc: ControllerConfig) void {
        self.write32(.cc, @bitCast(cc));
    }

    /// Read controller status
    pub fn readStatus(self: Self) ControllerStatus {
        return @bitCast(self.read32(.csts));
    }

    /// Read admin queue attributes
    pub fn readAdminQueueAttrs(self: Self) AdminQueueAttrs {
        return @bitCast(self.read32(.aqa));
    }

    /// Write admin queue attributes
    pub fn writeAdminQueueAttrs(self: Self, aqa: AdminQueueAttrs) void {
        self.write32(.aqa, @bitCast(aqa));
    }

    /// Write admin submission queue base address
    pub fn writeAdminSqBase(self: Self, addr: u64) void {
        self.write64(.asq, addr);
    }

    /// Write admin completion queue base address
    pub fn writeAdminCqBase(self: Self, addr: u64) void {
        self.write64(.acq, addr);
    }

    /// Write a doorbell value at a specific offset
    pub fn writeDoorbell(self: Self, offset: u64, value: u32) void {
        if (offset + 4 > self.size) {
            @panic("NVMe: Doorbell write out of bounds");
        }
        hal.mmio.write32(self.base + offset, value);
        // Memory barrier after doorbell write
        hal.mmio.writeBarrier();
    }

    /// Ring submission queue tail doorbell
    pub fn ringSqTailDoorbell(self: Self, queue_id: u16, doorbell_stride: u32, tail: u16) void {
        const offset = sqTailDoorbellOffset(queue_id, doorbell_stride);
        self.writeDoorbell(offset, @as(u32, tail));
    }

    /// Ring completion queue head doorbell
    pub fn ringCqHeadDoorbell(self: Self, queue_id: u16, doorbell_stride: u32, head: u16) void {
        const offset = cqHeadDoorbellOffset(queue_id, doorbell_stride);
        self.writeDoorbell(offset, @as(u32, head));
    }
};

// ============================================================================
// Compile-time Verification
// ============================================================================

comptime {
    // Verify packed struct sizes match NVMe spec
    if (@sizeOf(Capabilities) != 8) @compileError("CAP must be 64 bits");
    if (@sizeOf(Version) != 4) @compileError("VS must be 32 bits");
    if (@sizeOf(ControllerConfig) != 4) @compileError("CC must be 32 bits");
    if (@sizeOf(ControllerStatus) != 4) @compileError("CSTS must be 32 bits");
    if (@sizeOf(AdminQueueAttrs) != 4) @compileError("AQA must be 32 bits");
}
