// IDE/ATA Register Definitions and Access Functions
//
// Provides low-level register access for IDE controllers using port I/O.
// This is the foundation layer for all IDE driver operations.
//
// Reference: ATA/ATAPI-7 Specification

const std = @import("std");
const hal = @import("hal");

// ============================================================================
// I/O Port Base Addresses
// ============================================================================

/// Primary IDE channel I/O base
pub const PRIMARY_IO_BASE: u16 = 0x1F0;
/// Primary IDE channel control base
pub const PRIMARY_CTRL_BASE: u16 = 0x3F6;
/// Primary IDE channel IRQ
pub const PRIMARY_IRQ: u8 = 14;

/// Secondary IDE channel I/O base
pub const SECONDARY_IO_BASE: u16 = 0x170;
/// Secondary IDE channel control base
pub const SECONDARY_CTRL_BASE: u16 = 0x376;
/// Secondary IDE channel IRQ
pub const SECONDARY_IRQ: u8 = 15;

// ============================================================================
// Register Offsets (from I/O base)
// ============================================================================

pub const Reg = enum(u16) {
    /// Data register (read/write)
    data = 0,
    /// Error register (read) / Features register (write)
    error_features = 1,
    /// Sector count register
    sector_count = 2,
    /// LBA Low (bits 0-7)
    lba_low = 3,
    /// LBA Mid (bits 8-15)
    lba_mid = 4,
    /// LBA High (bits 16-23)
    lba_high = 5,
    /// Drive/Head register (drive select + LBA bits 24-27)
    drive_head = 6,
    /// Status register (read) / Command register (write)
    status_command = 7,
};

/// Control register offset from control base
pub const CTRL_REG_OFFSET: u16 = 0;

// ============================================================================
// Status Register Bits
// ============================================================================

pub const Status = packed struct(u8) {
    /// Error occurred
    err: bool,
    /// Index (obsolete)
    idx: bool,
    /// Corrected data (obsolete)
    corr: bool,
    /// Data request ready
    drq: bool,
    /// Drive seek complete (obsolete)
    dsc: bool,
    /// Drive write fault (obsolete)
    dwf: bool,
    /// Drive ready
    drdy: bool,
    /// Busy
    bsy: bool,
};

// Status bit masks for raw access
pub const STATUS_ERR: u8 = 0x01;
pub const STATUS_DRQ: u8 = 0x08;
pub const STATUS_DRDY: u8 = 0x40;
pub const STATUS_BSY: u8 = 0x80;

// ============================================================================
// Error Register Bits
// ============================================================================

pub const Error = packed struct(u8) {
    /// Address mark not found
    amnf: bool,
    /// Track 0 not found
    tk0nf: bool,
    /// Command aborted
    abrt: bool,
    /// Media change request
    mcr: bool,
    /// ID not found
    idnf: bool,
    /// Media changed
    mc: bool,
    /// Uncorrectable data error
    unc: bool,
    /// Bad block detected
    bbk: bool,
};

// ============================================================================
// Device Control Register Bits
// ============================================================================

pub const DeviceControl = packed struct(u8) {
    /// Reserved (must be 0)
    _reserved0: bool = false,
    /// Disable interrupts (nIEN)
    nien: bool = false,
    /// Software reset
    srst: bool = false,
    /// Reserved (must be 0)
    _reserved1: bool = false,
    /// Reserved (must be 1 for some controllers)
    _reserved2: u4 = 0,
};

// ============================================================================
// Drive/Head Register
// ============================================================================

pub const DriveHead = packed struct(u8) {
    /// LBA bits 24-27 (LBA28) or head number (CHS)
    lba_head: u4,
    /// Drive select: 0 = master, 1 = slave
    drv: u1,
    /// Reserved (must be 1)
    _reserved1: u1 = 1,
    /// LBA mode (1) vs CHS mode (0)
    lba: bool = true,
    /// Reserved (must be 1)
    _reserved2: u1 = 1,
};

// ============================================================================
// ATA Commands
// ============================================================================

pub const Command = enum(u8) {
    /// Identify device
    identify = 0xEC,
    /// Identify ATAPI device
    identify_packet = 0xA1,
    /// Read sectors (LBA28)
    read_sectors = 0x20,
    /// Read sectors (LBA48)
    read_sectors_ext = 0x24,
    /// Write sectors (LBA28)
    write_sectors = 0x30,
    /// Write sectors (LBA48)
    write_sectors_ext = 0x34,
    /// Read DMA (LBA28)
    read_dma = 0xC8,
    /// Read DMA (LBA48)
    read_dma_ext = 0x25,
    /// Write DMA (LBA28)
    write_dma = 0xCA,
    /// Write DMA (LBA48)
    write_dma_ext = 0x35,
    /// Flush cache
    cache_flush = 0xE7,
    /// Flush cache (LBA48)
    cache_flush_ext = 0xEA,
    /// Set features
    set_features = 0xEF,
    /// PACKET command (ATAPI)
    packet = 0xA0,
};

// ============================================================================
// Timeouts (microseconds)
// ============================================================================

pub const Timeouts = struct {
    // Real hardware timeouts
    pub const BSY_CLEAR_US: u64 = 30_000_000; // 30s - ATA spec allows up to 30s
    pub const DRQ_US: u64 = 5_000_000; // 5s - Data request timeout
    pub const IDENTIFY_US: u64 = 5_000_000; // 5s - IDENTIFY command
    pub const COMMAND_US: u64 = 7_000_000; // 7s - Standard command
    pub const FLUSH_US: u64 = 30_000_000; // 30s - Cache flush
    pub const RESET_US: u64 = 31_000_000; // 31s - Software reset

    // Emulator timeouts (QEMU responds quickly or not at all)
    pub const BSY_CLEAR_US_EMU: u64 = 500_000; // 500ms
    pub const DRQ_US_EMU: u64 = 500_000; // 500ms
    pub const IDENTIFY_US_EMU: u64 = 500_000; // 500ms
    pub const COMMAND_US_EMU: u64 = 1_000_000; // 1s
};

// ============================================================================
// Channel State
// ============================================================================

pub const Channel = struct {
    io_base: u16,
    ctrl_base: u16,
    irq: u8,

    pub fn primary() Channel {
        return .{
            .io_base = PRIMARY_IO_BASE,
            .ctrl_base = PRIMARY_CTRL_BASE,
            .irq = PRIMARY_IRQ,
        };
    }

    pub fn secondary() Channel {
        return .{
            .io_base = SECONDARY_IO_BASE,
            .ctrl_base = SECONDARY_CTRL_BASE,
            .irq = SECONDARY_IRQ,
        };
    }

    pub fn fromPciBar(bar0: u16, bar1: u16, bar2: u16, bar3: u16, is_primary: bool) Channel {
        if (is_primary) {
            return .{
                .io_base = if (bar0 != 0 and bar0 != 1) bar0 else PRIMARY_IO_BASE,
                .ctrl_base = if (bar1 != 0 and bar1 != 1) bar1 else PRIMARY_CTRL_BASE,
                .irq = PRIMARY_IRQ,
            };
        } else {
            return .{
                .io_base = if (bar2 != 0 and bar2 != 1) bar2 else SECONDARY_IO_BASE,
                .ctrl_base = if (bar3 != 0 and bar3 != 1) bar3 else SECONDARY_CTRL_BASE,
                .irq = SECONDARY_IRQ,
            };
        }
    }
};

// ============================================================================
// Register Access Functions
// ============================================================================

/// Read from a register
pub inline fn read(channel: Channel, reg: Reg) u8 {
    return hal.io.inb(channel.io_base + @intFromEnum(reg));
}

/// Write to a register
pub inline fn write(channel: Channel, reg: Reg, value: u8) void {
    hal.io.outb(channel.io_base + @intFromEnum(reg), value);
}

/// Read 16-bit data from data register
pub inline fn readData16(channel: Channel) u16 {
    return hal.io.inw(channel.io_base + @intFromEnum(Reg.data));
}

/// Write 16-bit data to data register
pub inline fn writeData16(channel: Channel, value: u16) void {
    hal.io.outw(channel.io_base + @intFromEnum(Reg.data), value);
}

/// Read status register
pub inline fn readStatus(channel: Channel) Status {
    return @bitCast(hal.io.inb(channel.io_base + @intFromEnum(Reg.status_command)));
}

/// Read alternate status (doesn't clear interrupt)
pub inline fn readAltStatus(channel: Channel) Status {
    return @bitCast(hal.io.inb(channel.ctrl_base + CTRL_REG_OFFSET));
}

/// Write command register
pub inline fn writeCommand(channel: Channel, cmd: Command) void {
    hal.io.outb(channel.io_base + @intFromEnum(Reg.status_command), @intFromEnum(cmd));
}

/// Write device control register
pub inline fn writeControl(channel: Channel, ctrl: DeviceControl) void {
    hal.io.outb(channel.ctrl_base + CTRL_REG_OFFSET, @bitCast(ctrl));
}

/// Read error register
pub inline fn readError(channel: Channel) Error {
    return @bitCast(hal.io.inb(channel.io_base + @intFromEnum(Reg.error_features)));
}

/// Select drive (master=0, slave=1)
pub fn selectDrive(channel: Channel, drive: u1) void {
    const dh = DriveHead{
        .lba_head = 0,
        .drv = drive,
        .lba = true,
    };
    write(channel, .drive_head, @bitCast(dh));
    // Allow 400ns for drive select to take effect (4 I/O port reads)
    _ = readAltStatus(channel);
    _ = readAltStatus(channel);
    _ = readAltStatus(channel);
    _ = readAltStatus(channel);
}

// ============================================================================
// Wait Functions
// ============================================================================

/// Check if running on emulator platform
fn isEmulatorPlatform() bool {
    const hv = hal.hypervisor.getHypervisor();
    return hv == .qemu_tcg or hv == .unknown;
}

/// Get BSY clear timeout based on platform
pub fn getBsyTimeout() u64 {
    return if (isEmulatorPlatform()) Timeouts.BSY_CLEAR_US_EMU else Timeouts.BSY_CLEAR_US;
}

/// Get DRQ timeout based on platform
pub fn getDrqTimeout() u64 {
    return if (isEmulatorPlatform()) Timeouts.DRQ_US_EMU else Timeouts.DRQ_US;
}

/// Get command timeout based on platform
pub fn getCommandTimeout() u64 {
    return if (isEmulatorPlatform()) Timeouts.COMMAND_US_EMU else Timeouts.COMMAND_US;
}

pub const WaitError = error{
    Timeout,
    DeviceError,
};

/// Wait for BSY to clear
pub fn waitNotBusy(channel: Channel, timeout_us: u64) WaitError!void {
    const start = hal.timing.rdtsc();
    const ticks_per_us = hal.timing.getTscFrequency() / 1_000_000;
    const timeout_ticks = timeout_us * ticks_per_us;

    while (true) {
        const status = readAltStatus(channel);
        if (!status.bsy) return;

        const elapsed = hal.timing.rdtsc() - start;
        if (elapsed >= timeout_ticks) return error.Timeout;

        // Small delay to avoid hammering the port
        hal.io.ioWait();
    }
}

/// Wait for DRQ to be set (data ready)
pub fn waitDrq(channel: Channel, timeout_us: u64) WaitError!void {
    const start = hal.timing.rdtsc();
    const ticks_per_us = hal.timing.getTscFrequency() / 1_000_000;
    const timeout_ticks = timeout_us * ticks_per_us;

    while (true) {
        const status = readAltStatus(channel);
        if (status.err) return error.DeviceError;
        if (!status.bsy and status.drq) return;

        const elapsed = hal.timing.rdtsc() - start;
        if (elapsed >= timeout_ticks) return error.Timeout;

        hal.io.ioWait();
    }
}

/// Wait for DRDY to be set (drive ready)
pub fn waitReady(channel: Channel, timeout_us: u64) WaitError!void {
    const start = hal.timing.rdtsc();
    const ticks_per_us = hal.timing.getTscFrequency() / 1_000_000;
    const timeout_ticks = timeout_us * ticks_per_us;

    while (true) {
        const status = readAltStatus(channel);
        if (status.err) return error.DeviceError;
        if (!status.bsy and status.drdy) return;

        const elapsed = hal.timing.rdtsc() - start;
        if (elapsed >= timeout_ticks) return error.Timeout;

        hal.io.ioWait();
    }
}

// ============================================================================
// LBA Setup Functions
// ============================================================================

/// Set LBA28 address and sector count
pub fn setLba28(channel: Channel, drive: u1, lba: u28, count: u8) void {
    const dh = DriveHead{
        .lba_head = @truncate(lba >> 24),
        .drv = drive,
        .lba = true,
    };
    write(channel, .sector_count, count);
    write(channel, .lba_low, @truncate(lba));
    write(channel, .lba_mid, @truncate(lba >> 8));
    write(channel, .lba_high, @truncate(lba >> 16));
    write(channel, .drive_head, @bitCast(dh));
}

/// Set LBA48 address and sector count
pub fn setLba48(channel: Channel, drive: u1, lba: u48, count: u16) void {
    const dh = DriveHead{
        .lba_head = 0,
        .drv = drive,
        .lba = true,
    };

    // Write high bytes first (LBA48 protocol)
    write(channel, .sector_count, @truncate(count >> 8));
    write(channel, .lba_low, @truncate(lba >> 24));
    write(channel, .lba_mid, @truncate(lba >> 32));
    write(channel, .lba_high, @truncate(lba >> 40));

    // Then low bytes
    write(channel, .sector_count, @truncate(count));
    write(channel, .lba_low, @truncate(lba));
    write(channel, .lba_mid, @truncate(lba >> 8));
    write(channel, .lba_high, @truncate(lba >> 16));

    write(channel, .drive_head, @bitCast(dh));
}

// ============================================================================
// Sector Data Transfer
// ============================================================================

/// Read a sector (512 bytes) from data port
/// Uses std.mem.writeInt for safe unaligned access
pub fn readSector(channel: Channel, buffer: *[512]u8) void {
    var i: usize = 0;
    while (i < 512) : (i += 2) {
        const word = readData16(channel);
        std.mem.writeInt(u16, buffer[i..][0..2], word, .little);
    }
}

/// Write a sector (512 bytes) to data port
/// Uses std.mem.readInt for safe unaligned access
pub fn writeSector(channel: Channel, buffer: *const [512]u8) void {
    var i: usize = 0;
    while (i < 512) : (i += 2) {
        const word = std.mem.readInt(u16, buffer[i..][0..2], .little);
        writeData16(channel, word);
    }
}

// ============================================================================
// Software Reset
// ============================================================================

/// Perform software reset on channel
pub fn softwareReset(channel: Channel) WaitError!void {
    // Set SRST bit
    writeControl(channel, .{ .srst = true, .nien = true });

    // Wait at least 5us
    for (0..10) |_| {
        hal.io.ioWait();
    }

    // Clear SRST bit
    writeControl(channel, .{ .srst = false, .nien = true });

    // Wait for BSY to clear (up to 31 seconds per ATA spec)
    const timeout = if (isEmulatorPlatform()) 1_000_000 else Timeouts.RESET_US;
    try waitNotBusy(channel, timeout);
}

// ============================================================================
// Channel Presence Detection
// ============================================================================

/// Check if a channel appears to be present by probing the status register
pub fn isChannelPresent(channel: Channel) bool {
    const status = hal.io.inb(channel.io_base + @intFromEnum(Reg.status_command));
    // 0xFF typically means no device (floating bus)
    // 0x00 with BSY clear might mean no device or unpowered
    return status != 0xFF;
}
