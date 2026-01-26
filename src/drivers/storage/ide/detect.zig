// IDE Device Detection
//
// Implements device detection using ATA IDENTIFY command.
// Parses drive capabilities and capacity information.
//
// Reference: ATA/ATAPI-7 Specification, Section 7.16 (IDENTIFY DEVICE)

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const registers = @import("registers.zig");

// ============================================================================
// IDENTIFY Data Structure (512 bytes)
// ============================================================================

/// ATA IDENTIFY DEVICE data structure
/// Words are 16-bit, little-endian
pub const IdentifyData = extern struct {
    /// Word 0: General configuration
    general_config: u16,
    /// Word 1: Obsolete (logical cylinders)
    _obsolete1: u16,
    /// Word 2: Specific configuration
    specific_config: u16,
    /// Word 3: Obsolete (logical heads)
    _obsolete3: u16,
    /// Words 4-5: Retired
    _retired4_5: [2]u16,
    /// Word 6: Obsolete (sectors per track)
    _obsolete6: u16,
    /// Words 7-8: Reserved for CompactFlash
    _reserved7_8: [2]u16,
    /// Word 9: Retired
    _retired9: u16,
    /// Words 10-19: Serial number (20 ASCII characters)
    serial_number: [20]u8,
    /// Words 20-21: Retired
    _retired20_21: [2]u16,
    /// Word 22: Obsolete
    _obsolete22: u16,
    /// Words 23-26: Firmware revision (8 ASCII characters)
    firmware_revision: [8]u8,
    /// Words 27-46: Model number (40 ASCII characters)
    model_number: [40]u8,
    /// Word 47: Max sectors per multiple command (bits 7:0)
    max_multiple_sectors: u16,
    /// Word 48: Trusted computing feature set
    trusted_computing: u16,
    /// Word 49: Capabilities
    capabilities: Capabilities,
    /// Word 50: Capabilities (continued)
    capabilities2: u16,
    /// Words 51-52: Obsolete (PIO/DMA timing)
    _obsolete51_52: [2]u16,
    /// Word 53: Field validity
    field_validity: u16,
    /// Words 54-58: Obsolete (CHS translation)
    _obsolete54_58: [5]u16,
    /// Word 59: Current multiple sector setting
    current_multiple: u16,
    /// Words 60-61: Total addressable sectors (LBA28)
    total_sectors_28: u32,
    /// Word 62: Obsolete
    _obsolete62: u16,
    /// Word 63: Multiword DMA modes
    multiword_dma: u16,
    /// Word 64: PIO modes supported
    pio_modes: u16,
    /// Word 65: Minimum multiword DMA cycle time
    min_mwdma_cycle: u16,
    /// Word 66: Recommended multiword DMA cycle time
    rec_mwdma_cycle: u16,
    /// Word 67: Minimum PIO cycle time without IORDY
    min_pio_cycle_no_iordy: u16,
    /// Word 68: Minimum PIO cycle time with IORDY
    min_pio_cycle_iordy: u16,
    /// Words 69-74: Reserved
    _reserved69_74: [6]u16,
    /// Word 75: Queue depth
    queue_depth: u16,
    /// Words 76-79: Serial ATA capabilities
    sata_caps: [4]u16,
    /// Word 80: Major version number
    major_version: u16,
    /// Word 81: Minor version number
    minor_version: u16,
    /// Word 82: Command set supported (part 1)
    command_set_1: CommandSet1,
    /// Word 83: Command set supported (part 2)
    command_set_2: CommandSet2,
    /// Word 84: Command set supported (part 3)
    command_set_3: u16,
    /// Word 85: Command set enabled (part 1)
    command_enabled_1: u16,
    /// Word 86: Command set enabled (part 2)
    command_enabled_2: u16,
    /// Word 87: Command set enabled (part 3)
    command_enabled_3: u16,
    /// Word 88: Ultra DMA modes
    ultra_dma: u16,
    /// Words 89-99: Reserved/times
    _reserved89_99: [11]u16,
    /// Words 100-103: Total addressable sectors (LBA48)
    total_sectors_48: u64,
    /// Words 104-126: Reserved
    _reserved104_126: [23]u16,
    /// Word 127: Removable media status notification
    removable_media: u16,
    /// Word 128: Security status
    security_status: u16,
    /// Words 129-159: Vendor specific
    _vendor129_159: [31]u16,
    /// Word 160: CFA power mode
    cfa_power: u16,
    /// Words 161-175: Reserved for CompactFlash
    _reserved161_175: [15]u16,
    /// Words 176-205: Current media serial number
    media_serial: [60]u8,
    /// Words 206-254: Reserved
    _reserved206_254: [49]u16,
    /// Word 255: Integrity word
    integrity: u16,

    comptime {
        if (@sizeOf(IdentifyData) != 512) {
            @compileError("IdentifyData must be exactly 512 bytes");
        }
    }
};

/// Word 49: Capabilities
pub const Capabilities = packed struct(u16) {
    _reserved0_7: u8,
    /// DMA supported
    dma_supported: bool,
    /// LBA supported
    lba_supported: bool,
    /// IORDY may be disabled
    iordy_disable: bool,
    /// IORDY supported
    iordy_supported: bool,
    _reserved12: bool,
    /// Standby timer values as specified
    standby_timer: bool,
    _reserved14_15: u2,
};

/// Word 82: Command set supported (part 1)
pub const CommandSet1 = packed struct(u16) {
    /// SMART supported
    smart: bool,
    /// Security mode supported
    security: bool,
    /// Removable media supported
    removable: bool,
    /// Power management supported
    power_mgmt: bool,
    /// PACKET command supported
    packet: bool,
    /// Write cache supported
    write_cache: bool,
    /// Look-ahead supported
    look_ahead: bool,
    /// Release interrupt supported
    release_int: bool,
    /// SERVICE interrupt supported
    service_int: bool,
    /// DEVICE RESET supported
    device_reset: bool,
    /// Host protected area supported
    hpa: bool,
    _obsolete11: bool,
    /// WRITE BUFFER supported
    write_buffer: bool,
    /// READ BUFFER supported
    read_buffer: bool,
    /// NOP supported
    nop: bool,
    _obsolete15: bool,
};

/// Word 83: Command set supported (part 2)
pub const CommandSet2 = packed struct(u16) {
    /// DOWNLOAD MICROCODE supported
    download_microcode: bool,
    /// READ/WRITE DMA QUEUED supported
    dma_queued: bool,
    /// CFA supported
    cfa: bool,
    /// APM supported
    apm: bool,
    /// Removable media status notification supported
    removable_notification: bool,
    /// PUIS supported
    puis: bool,
    /// SET FEATURES subcommand required for spinup
    spinup_required: bool,
    _reserved7: bool,
    /// SET MAX security extension supported
    set_max: bool,
    /// Automatic acoustic management supported
    aam: bool,
    /// 48-bit LBA supported
    lba48: bool,
    /// Device configuration overlay supported
    dco: bool,
    /// Mandatory FLUSH CACHE supported
    flush_cache: bool,
    /// FLUSH CACHE EXT supported
    flush_cache_ext: bool,
    _reserved14: bool,
    /// Words 82-84 are valid
    words_valid: bool,
};

// ============================================================================
// Drive Information
// ============================================================================

pub const DriveType = enum {
    none,
    ata,
    atapi,
};

pub const DriveInfo = struct {
    drive_type: DriveType,
    supports_lba: bool,
    supports_lba48: bool,
    supports_dma: bool,
    total_sectors: u64,
    model: [40]u8,
    serial: [20]u8,
    firmware: [8]u8,

    pub fn init() DriveInfo {
        return .{
            .drive_type = .none,
            .supports_lba = false,
            .supports_lba48 = false,
            .supports_dma = false,
            .total_sectors = 0,
            .model = [_]u8{0} ** 40,
            .serial = [_]u8{0} ** 20,
            .firmware = [_]u8{0} ** 8,
        };
    }

    /// Get model as null-terminated string
    pub fn getModel(self: *const DriveInfo) []const u8 {
        var len: usize = 40;
        while (len > 0 and (self.model[len - 1] == 0 or self.model[len - 1] == ' ')) {
            len -= 1;
        }
        return self.model[0..len];
    }

    /// Get capacity in MB
    pub fn getCapacityMB(self: *const DriveInfo) u64 {
        return (self.total_sectors * 512) / (1024 * 1024);
    }
};

// ============================================================================
// Detection Functions
// ============================================================================

pub const DetectError = error{
    Timeout,
    DeviceError,
    NotPresent,
    InvalidSignature,
};

/// Swap bytes in ATA string (ATA strings are byte-swapped)
fn swapAtaString(dest: []u8, src: []const u8) void {
    var i: usize = 0;
    while (i + 1 < src.len and i + 1 < dest.len) {
        dest[i] = src[i + 1];
        dest[i + 1] = src[i];
        i += 2;
    }
}

/// Detect drive on specified channel and position
pub fn detectDrive(channel: registers.Channel, drive: u1) DetectError!DriveInfo {
    var info = DriveInfo.init();

    // Select drive
    registers.selectDrive(channel, drive);

    // Wait for BSY to clear with short timeout
    registers.waitNotBusy(channel, 100_000) catch {
        return error.NotPresent;
    };

    // Check if drive is present by reading status
    const status = registers.readStatus(channel);
    if (@as(u8, @bitCast(status)) == 0xFF or @as(u8, @bitCast(status)) == 0x00) {
        return error.NotPresent;
    }

    // Issue IDENTIFY command
    registers.writeCommand(channel, .identify);

    // Wait a bit for command to be processed
    hal.io.ioWait();
    hal.io.ioWait();
    hal.io.ioWait();
    hal.io.ioWait();

    // Check status
    const post_status = registers.readAltStatus(channel);
    if (@as(u8, @bitCast(post_status)) == 0x00) {
        return error.NotPresent;
    }

    // Wait for BSY to clear
    registers.waitNotBusy(channel, registers.getBsyTimeout()) catch |err| {
        // Check if this is an ATAPI device
        const lba_mid = registers.read(channel, .lba_mid);
        const lba_high = registers.read(channel, .lba_high);

        if (lba_mid == 0x14 and lba_high == 0xEB) {
            // ATAPI signature detected
            return detectAtapiDrive(channel, drive);
        }
        if (lba_mid == 0x69 and lba_high == 0x96) {
            // SATA-ATAPI signature
            return detectAtapiDrive(channel, drive);
        }

        return err;
    };

    // Check for DRQ or error
    const drq_status = registers.readStatus(channel);
    if (drq_status.err) {
        // Check for ATAPI signature
        const lba_mid = registers.read(channel, .lba_mid);
        const lba_high = registers.read(channel, .lba_high);

        if (lba_mid == 0x14 and lba_high == 0xEB) {
            return detectAtapiDrive(channel, drive);
        }
        if (lba_mid == 0x69 and lba_high == 0x96) {
            return detectAtapiDrive(channel, drive);
        }

        return error.DeviceError;
    }

    // Wait for DRQ
    registers.waitDrq(channel, registers.getDrqTimeout()) catch |err| {
        return err;
    };

    // Read IDENTIFY data
    var identify_data: [512]u8 align(2) = [_]u8{0} ** 512;
    registers.readSector(channel, &identify_data);

    // Parse IDENTIFY data
    const identify: *const IdentifyData = @ptrCast(@alignCast(&identify_data));

    info.drive_type = .ata;
    info.supports_lba = identify.capabilities.lba_supported;
    info.supports_lba48 = identify.command_set_2.lba48;
    info.supports_dma = identify.capabilities.dma_supported;

    // Get sector count
    if (info.supports_lba48 and identify.total_sectors_48 != 0) {
        info.total_sectors = identify.total_sectors_48;
    } else if (info.supports_lba) {
        info.total_sectors = identify.total_sectors_28;
    } else {
        // CHS mode - not supported
        return error.InvalidSignature;
    }

    // Copy and swap strings
    swapAtaString(&info.model, &identify.model_number);
    swapAtaString(&info.serial, &identify.serial_number);
    swapAtaString(&info.firmware, &identify.firmware_revision);

    return info;
}

/// Detect ATAPI device
fn detectAtapiDrive(channel: registers.Channel, drive: u1) DetectError!DriveInfo {
    var info = DriveInfo.init();

    // Select drive
    registers.selectDrive(channel, drive);

    // Issue IDENTIFY PACKET command
    registers.writeCommand(channel, .identify_packet);

    // Wait for BSY to clear
    registers.waitNotBusy(channel, registers.getBsyTimeout()) catch |err| {
        return err;
    };

    // Wait for DRQ
    const status = registers.readStatus(channel);
    if (status.err) {
        return error.DeviceError;
    }

    registers.waitDrq(channel, registers.getDrqTimeout()) catch |err| {
        return err;
    };

    // Read IDENTIFY PACKET data
    var identify_data: [512]u8 align(2) = [_]u8{0} ** 512;
    registers.readSector(channel, &identify_data);

    const identify: *const IdentifyData = @ptrCast(@alignCast(&identify_data));

    info.drive_type = .atapi;
    info.supports_lba = true; // ATAPI always uses LBA
    info.supports_lba48 = false; // ATAPI uses SCSI-style addressing
    info.supports_dma = identify.capabilities.dma_supported;

    // ATAPI devices report capacity differently (via READ CAPACITY command)
    // For now, set to 0 - actual capacity requires SCSI commands
    info.total_sectors = 0;

    // Copy and swap strings
    swapAtaString(&info.model, &identify.model_number);
    swapAtaString(&info.serial, &identify.serial_number);
    swapAtaString(&info.firmware, &identify.firmware_revision);

    return info;
}

/// Scan all drives on a channel
pub fn scanChannel(channel: registers.Channel) [2]DriveInfo {
    var drives: [2]DriveInfo = .{ DriveInfo.init(), DriveInfo.init() };

    // Try master (drive 0)
    if (detectDrive(channel, 0)) |info| {
        drives[0] = info;
    } else |_| {}

    // Try slave (drive 1)
    if (detectDrive(channel, 1)) |info| {
        drives[1] = info;
    } else |_| {}

    return drives;
}

/// Log detected drive information
pub fn logDriveInfo(channel_name: []const u8, drive_num: u1, info: *const DriveInfo) void {
    const drive_name = if (drive_num == 0) "Master" else "Slave";

    switch (info.drive_type) {
        .none => {},
        .ata => {
            console.info("  {s} {s}: ATA {s}", .{
                channel_name,
                drive_name,
                info.getModel(),
            });
            console.info("    Capacity: {d} MB ({d} sectors)", .{
                info.getCapacityMB(),
                info.total_sectors,
            });
            console.info("    LBA48: {}, DMA: {}", .{
                info.supports_lba48,
                info.supports_dma,
            });
        },
        .atapi => {
            console.info("  {s} {s}: ATAPI {s}", .{
                channel_name,
                drive_name,
                info.getModel(),
            });
        },
    }
}
