// AHCI Frame Information Structures (FIS)
//
// FIS are the fundamental communication units between host and SATA device.
// Each FIS type has a specific format and purpose.
//
// Common FIS types:
// - Register H2D (Host to Device): Send ATA commands
// - Register D2H (Device to Host): Command completion status
// - DMA Setup: DMA transfer configuration
// - PIO Setup: PIO transfer configuration
// - Data: Payload transfer
// - Set Device Bits: NCQ completion
//
// Reference: SATA 3.0 Specification, Chapter 10

const std = @import("std");

// ============================================================================
// FIS Type Identifiers
// ============================================================================

pub const FisType = enum(u8) {
    reg_h2d = 0x27, // Register FIS - Host to Device
    reg_d2h = 0x34, // Register FIS - Device to Host
    dma_activate = 0x39, // DMA Activate FIS
    dma_setup = 0x41, // DMA Setup FIS - bidirectional
    data = 0x46, // Data FIS - bidirectional
    bist_activate = 0x58, // BIST Activate FIS
    pio_setup = 0x5F, // PIO Setup FIS - Device to Host
    set_device_bits = 0xA1, // Set Device Bits FIS - Device to Host
};

// ============================================================================
// Register FIS - Host to Device (H2D)
// ============================================================================

/// Register FIS - Host to Device (20 bytes)
/// Used to send ATA commands to the device
pub const FisRegH2D = extern struct {
    /// FIS type (0x27)
    fis_type: u8,

    /// Port multiplier, bit 7 = command (1) or control (0)
    pm_and_c: u8,

    /// ATA Command register
    command: u8,

    /// Features register (7:0)
    features_lo: u8,

    /// LBA Low register (7:0)
    lba0: u8,

    /// LBA Mid register (15:8)
    lba1: u8,

    /// LBA High register (23:16)
    lba2: u8,

    /// Device register
    device: u8,

    /// LBA register (31:24)
    lba3: u8,

    /// LBA register (39:32)
    lba4: u8,

    /// LBA register (47:40)
    lba5: u8,

    /// Features register (15:8)
    features_hi: u8,

    /// Sector Count (7:0)
    count_lo: u8,

    /// Sector Count (15:8)
    count_hi: u8,

    /// ICC (Isochronous Command Completion)
    icc: u8,

    /// Control register
    control: u8,

    /// Reserved
    _reserved: [4]u8,

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("FisRegH2D must be 20 bytes");
    }

    /// Create a new H2D FIS for an ATA command
    pub fn init(command: AtaCommand) FisRegH2D {
        return FisRegH2D{
            .fis_type = @intFromEnum(FisType.reg_h2d),
            .pm_and_c = 0x80, // Command bit set
            .command = @intFromEnum(command),
            .features_lo = 0,
            .lba0 = 0,
            .lba1 = 0,
            .lba2 = 0,
            .device = 0,
            .lba3 = 0,
            .lba4 = 0,
            .lba5 = 0,
            .features_hi = 0,
            .count_lo = 0,
            .count_hi = 0,
            .icc = 0,
            .control = 0,
            ._reserved = [_]u8{0} ** 4,
        };
    }

    /// Set LBA48 address
    pub fn setLba(self: *FisRegH2D, lba: u48) void {
        self.lba0 = @truncate(lba);
        self.lba1 = @truncate(lba >> 8);
        self.lba2 = @truncate(lba >> 16);
        self.lba3 = @truncate(lba >> 24);
        self.lba4 = @truncate(lba >> 32);
        self.lba5 = @truncate(lba >> 40);
        self.device = 0x40; // LBA mode
    }

    /// Set sector count
    pub fn setCount(self: *FisRegH2D, count: u16) void {
        self.count_lo = @truncate(count);
        self.count_hi = @truncate(count >> 8);
    }
};

// ============================================================================
// Register FIS - Device to Host (D2H)
// ============================================================================

/// Register FIS - Device to Host (20 bytes)
/// Sent by device to indicate command completion
pub const FisRegD2H = extern struct {
    /// FIS type (0x34)
    fis_type: u8,

    /// Port multiplier, bit 6 = interrupt
    pm_and_i: u8,

    /// Status register
    status: u8,

    /// Error register
    err: u8,

    /// LBA Low register (7:0)
    lba0: u8,

    /// LBA Mid register (15:8)
    lba1: u8,

    /// LBA High register (23:16)
    lba2: u8,

    /// Device register
    device: u8,

    /// LBA register (31:24)
    lba3: u8,

    /// LBA register (39:32)
    lba4: u8,

    /// LBA register (47:40)
    lba5: u8,

    /// Reserved
    _reserved0: u8,

    /// Sector Count (7:0)
    count_lo: u8,

    /// Sector Count (15:8)
    count_hi: u8,

    /// Reserved
    _reserved1: [6]u8,

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("FisRegD2H must be 20 bytes");
    }

    /// Check if command completed successfully
    pub fn isSuccess(self: *const FisRegD2H) bool {
        // BSY (bit 7) and DRQ (bit 3) should be clear, ERR (bit 0) should be clear
        return (self.status & 0x89) == 0;
    }

    /// Check if device is busy
    pub fn isBusy(self: *const FisRegD2H) bool {
        return (self.status & 0x80) != 0;
    }

    /// Check if error occurred
    pub fn hasError(self: *const FisRegD2H) bool {
        return (self.status & 0x01) != 0;
    }
};

// ============================================================================
// PIO Setup FIS - Device to Host
// ============================================================================

/// PIO Setup FIS (20 bytes)
/// Sent by device before a PIO data transfer
pub const FisPioSetup = extern struct {
    /// FIS type (0x5F)
    fis_type: u8,

    /// Port multiplier, direction, interrupt
    pm_d_i: u8,

    /// Status register
    status: u8,

    /// Error register
    err: u8,

    /// LBA Low (7:0)
    lba0: u8,

    /// LBA Mid (15:8)
    lba1: u8,

    /// LBA High (23:16)
    lba2: u8,

    /// Device register
    device: u8,

    /// LBA (31:24)
    lba3: u8,

    /// LBA (39:32)
    lba4: u8,

    /// LBA (47:40)
    lba5: u8,

    /// Reserved
    _reserved0: u8,

    /// Sector Count (7:0)
    count_lo: u8,

    /// Sector Count (15:8)
    count_hi: u8,

    /// Reserved
    _reserved1: u8,

    /// Ending Status
    e_status: u8,

    /// Transfer Count
    transfer_count: u16 align(1),

    /// Reserved
    _reserved2: [2]u8,

    comptime {
        if (@sizeOf(@This()) != 20) @compileError("FisPioSetup must be 20 bytes");
    }
};

// ============================================================================
// DMA Setup FIS
// ============================================================================

/// DMA Setup FIS (28 bytes)
/// Used for First-party DMA transfers
pub const FisDmaSetup = extern struct {
    /// FIS type (0x41)
    fis_type: u8,

    /// Port multiplier, direction, interrupt, auto-activate
    pm_flags: u8,

    /// Reserved
    _reserved0: [2]u8,

    /// DMA Buffer Identifier Low
    dma_buf_id_lo: u32 align(1),

    /// DMA Buffer Identifier High
    dma_buf_id_hi: u32 align(1),

    /// Reserved
    _reserved1: u32 align(1),

    /// DMA Buffer Offset
    dma_buf_offset: u32 align(1),

    /// DMA Transfer Count
    transfer_count: u32 align(1),

    /// Reserved
    _reserved2: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 28) @compileError("FisDmaSetup must be 28 bytes");
    }
};

// ============================================================================
// Set Device Bits FIS
// ============================================================================

/// Set Device Bits FIS (8 bytes)
/// Used for NCQ completion notification
pub const FisSetDeviceBits = extern struct {
    /// FIS type (0xA1)
    fis_type: u8,

    /// Port multiplier, notification, interrupt
    pm_flags: u8,

    /// Status Low (bits 6:4, 2:0)
    status_lo: u8,

    /// Status High (error)
    status_hi: u8,

    /// SActive (completed NCQ tags)
    sactive: u32 align(1),

    comptime {
        if (@sizeOf(@This()) != 8) @compileError("FisSetDeviceBits must be 8 bytes");
    }
};

// ============================================================================
// Received FIS Structure
// ============================================================================

/// Received FIS buffer (256 bytes, 256-byte aligned)
/// Contains FIS received from device, organized by type
pub const ReceivedFis = extern struct {
    /// DMA Setup FIS (offset 0x00)
    dma_setup: FisDmaSetup,

    /// Reserved
    _reserved0: [4]u8,

    /// PIO Setup FIS (offset 0x20)
    pio_setup: FisPioSetup,

    /// Reserved
    _reserved1: [12]u8,

    /// D2H Register FIS (offset 0x40)
    reg_d2h: FisRegD2H,

    /// Reserved
    _reserved2: [4]u8,

    /// Set Device Bits FIS (offset 0x58)
    set_device_bits: FisSetDeviceBits,

    /// Unknown FIS (offset 0x60, 64 bytes)
    unknown: [64]u8,

    /// Reserved (offset 0xA0 to 0xFF)
    _reserved3: [96]u8,

    comptime {
        if (@sizeOf(@This()) != 256) @compileError("ReceivedFis must be 256 bytes");
    }
};

// ============================================================================
// ATA Commands
// ============================================================================

/// Common ATA commands
pub const AtaCommand = enum(u8) {
    // Identify
    identify_device = 0xEC,
    identify_packet_device = 0xA1,

    // Read/Write (LBA48)
    read_dma_ext = 0x25,
    write_dma_ext = 0x35,
    read_fpdma_queued = 0x60, // NCQ Read
    write_fpdma_queued = 0x61, // NCQ Write

    // Read/Write (LBA28) - legacy
    read_dma = 0xC8,
    write_dma = 0xCA,

    // Cache
    flush_cache = 0xE7,
    flush_cache_ext = 0xEA,

    // Power
    standby_immediate = 0xE0,
    idle_immediate = 0xE1,
    sleep = 0xE6,

    // SMART
    smart = 0xB0,

    // Other
    set_features = 0xEF,
    read_native_max_address_ext = 0x27,
    security_set_password = 0xF1,
    security_unlock = 0xF2,
    security_erase_prepare = 0xF3,
    security_erase_unit = 0xF4,
    security_freeze_lock = 0xF5,
    security_disable_password = 0xF6,
};

// ============================================================================
// ATA Status Register Bits
// ============================================================================

pub const AtaStatus = struct {
    pub const ERR: u8 = 1 << 0; // Error
    pub const IDX: u8 = 1 << 1; // Index (obsolete)
    pub const CORR: u8 = 1 << 2; // Corrected data (obsolete)
    pub const DRQ: u8 = 1 << 3; // Data Request
    pub const SRV: u8 = 1 << 4; // Service (PACKET)
    pub const DF: u8 = 1 << 5; // Device Fault
    pub const RDY: u8 = 1 << 6; // Device Ready
    pub const BSY: u8 = 1 << 7; // Busy
};

// ============================================================================
// IDENTIFY DEVICE Data
// ============================================================================

/// IDENTIFY DEVICE response (512 bytes)
/// Contains device information like model, serial, capacity
pub const IdentifyData = extern struct {
    config: u16 align(1), // Word 0: General config
    _obsolete0: [9]u16 align(1), // Words 1-9
    serial: [20]u8, // Words 10-19: Serial number
    _obsolete1: [3]u16 align(1), // Words 20-22
    firmware_rev: [8]u8, // Words 23-26: Firmware revision
    model: [40]u8, // Words 27-46: Model number
    max_sectors_per_int: u16 align(1), // Word 47
    trusted_computing: u16 align(1), // Word 48
    capabilities0: u16 align(1), // Word 49: Capabilities
    capabilities1: u16 align(1), // Word 50
    _obsolete2: [2]u16 align(1), // Words 51-52
    field_valid: u16 align(1), // Word 53
    _obsolete3: [5]u16 align(1), // Words 54-58
    multi_sector: u16 align(1), // Word 59
    total_sectors_28: u32 align(1), // Words 60-61: Total sectors (28-bit)
    _obsolete4: u16 align(1), // Word 62
    multiword_dma: u16 align(1), // Word 63
    pio_modes: u16 align(1), // Word 64
    min_multiword_dma_cycle: u16 align(1), // Word 65
    rec_multiword_dma_cycle: u16 align(1), // Word 66
    min_pio_cycle: u16 align(1), // Word 67
    min_pio_cycle_iordy: u16 align(1), // Word 68
    additional_supported: u16 align(1), // Word 69
    _reserved0: [6]u16 align(1), // Words 70-75
    sata_capabilities: u16 align(1), // Word 76
    sata_capabilities2: u16 align(1), // Word 77
    sata_features_supported: u16 align(1), // Word 78
    sata_features_enabled: u16 align(1), // Word 79
    major_version: u16 align(1), // Word 80
    minor_version: u16 align(1), // Word 81
    command_set0: u16 align(1), // Word 82: Command set supported
    command_set1: u16 align(1), // Word 83
    command_set_ext: u16 align(1), // Word 84
    command_set0_enabled: u16 align(1), // Word 85
    command_set1_enabled: u16 align(1), // Word 86
    command_set_ext_enabled: u16 align(1), // Word 87
    udma_modes: u16 align(1), // Word 88
    security_erase_time: u16 align(1), // Word 89
    enhanced_security_erase_time: u16 align(1), // Word 90
    current_apm: u16 align(1), // Word 91
    master_password_rev: u16 align(1), // Word 92
    hardware_reset_result: u16 align(1), // Word 93
    acoustic_management: u16 align(1), // Word 94
    stream_min_size: u16 align(1), // Word 95
    stream_transfer_time_dma: u16 align(1), // Word 96
    stream_access_latency: u16 align(1), // Word 97
    stream_perf_granularity: [2]u16 align(1), // Words 98-99
    total_sectors_48: u64 align(1), // Words 100-103: Total sectors (48-bit)
    stream_transfer_time_pio: u16 align(1), // Word 104
    max_data_set_mgmt_blocks: u16 align(1), // Word 105
    physical_logical_sector: u16 align(1), // Word 106
    inter_seek_delay: u16 align(1), // Word 107
    world_wide_name: [4]u16 align(1), // Words 108-111
    _reserved1: [4]u16 align(1), // Words 112-115
    _reserved2: u16 align(1), // Word 116
    logical_sector_size: u32 align(1), // Words 117-118
    command_set2: u16 align(1), // Word 119
    command_set2_enabled: u16 align(1), // Word 120
    _reserved3: [6]u16 align(1), // Words 121-126
    removable_media_status: u16 align(1), // Word 127
    security_status: u16 align(1), // Word 128
    _vendor_specific: [31]u16 align(1), // Words 129-159
    cfa_power_mode: u16 align(1), // Word 160
    _reserved4: [7]u16 align(1), // Words 161-167
    form_factor: u16 align(1), // Word 168
    data_set_mgmt: u16 align(1), // Word 169
    additional_product_id: [4]u16 align(1), // Words 170-173
    _reserved5: [2]u16 align(1), // Words 174-175
    current_media_serial: [30]u16 align(1), // Words 176-205
    sct_command_transport: u16 align(1), // Word 206
    _reserved6: [2]u16 align(1), // Words 207-208
    alignment_logical: u16 align(1), // Word 209
    write_read_verify_sector_mode3: [2]u16 align(1), // Words 210-211
    write_read_verify_sector_mode2: [2]u16 align(1), // Words 212-213
    nv_cache_capabilities: u16 align(1), // Word 214
    nv_cache_size: u32 align(1), // Words 215-216
    nominal_media_rotation_rate: u16 align(1), // Word 217
    _reserved7: u16 align(1), // Word 218
    nv_cache_options: u16 align(1), // Word 219
    write_read_verify_feature_set: u16 align(1), // Word 220
    _reserved8: u16 align(1), // Word 221
    transport_major_version: u16 align(1), // Word 222
    transport_minor_version: u16 align(1), // Word 223
    _reserved9: [6]u16 align(1), // Words 224-229
    extended_sectors: u64 align(1), // Words 230-233
    _reserved10: [22]u16 align(1), // Words 234-255

    comptime {
        if (@sizeOf(@This()) != 512) @compileError("IdentifyData must be 512 bytes");
    }

    /// Get total sector count (48-bit preferred, falls back to 28-bit)
    pub fn totalSectors(self: *const IdentifyData) u64 {
        if (self.total_sectors_48 > 0) {
            return self.total_sectors_48;
        }
        return self.total_sectors_28;
    }

    /// Get capacity in bytes
    pub fn capacityBytes(self: *const IdentifyData) u64 {
        return self.totalSectors() * 512;
    }

    /// Check if 48-bit LBA is supported
    pub fn supportsLba48(self: *const IdentifyData) bool {
        return (self.command_set1 & (1 << 10)) != 0;
    }

    /// Check if NCQ is supported
    pub fn supportsNcq(self: *const IdentifyData) bool {
        return (self.sata_capabilities & (1 << 8)) != 0;
    }

    /// Get NCQ queue depth (0-based)
    pub fn ncqQueueDepth(self: *const IdentifyData) u8 {
        if (!self.supportsNcq()) return 0;
        return @truncate(self.sata_capabilities & 0x1F);
    }
};
