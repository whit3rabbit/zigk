// SCSI Command Descriptor Block (CDB) Builders
//
// Builders for common SCSI commands used by block devices.
// All CDBs use big-endian byte ordering per SCSI specifications.
//
// Reference: SPC-5, SBC-4 (SCSI Block Commands)

const std = @import("std");
const config = @import("config.zig");

// ============================================================================
// SCSI Operation Codes
// ============================================================================

/// SCSI command operation codes
pub const Opcode = enum(u8) {
    // 6-byte commands
    TEST_UNIT_READY = 0x00,
    REQUEST_SENSE = 0x03,
    READ_6 = 0x08,
    WRITE_6 = 0x0A,
    INQUIRY = 0x12,
    MODE_SENSE_6 = 0x1A,
    START_STOP_UNIT = 0x1B,
    SEND_DIAGNOSTIC = 0x1D,

    // 10-byte commands
    READ_CAPACITY_10 = 0x25,
    READ_10 = 0x28,
    WRITE_10 = 0x2A,
    SYNCHRONIZE_CACHE_10 = 0x35,

    // 12-byte commands
    REPORT_LUNS = 0xA0,

    // 16-byte commands
    READ_CAPACITY_16 = 0x9E, // Service action 0x10
    READ_16 = 0x88,
    WRITE_16 = 0x8A,
    SYNCHRONIZE_CACHE_16 = 0x91,
};

// ============================================================================
// CDB Builders
// ============================================================================

/// Build TEST UNIT READY CDB (6 bytes)
/// Checks if the device is ready for I/O
pub fn buildTestUnitReady(cdb: *[config.Limits.MAX_CDB_SIZE]u8) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.TEST_UNIT_READY);
    // Bytes 1-5: Reserved (0)
}

/// Build INQUIRY CDB (6 bytes)
/// Returns device identification information
pub fn buildInquiry(cdb: *[config.Limits.MAX_CDB_SIZE]u8, alloc_len: u8) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.INQUIRY);
    // Byte 1: EVPD (0 = standard inquiry)
    // Byte 2: Page code (0 for standard inquiry)
    // Bytes 3-4: Allocation length (big-endian)
    cdb[4] = alloc_len;
}

/// Build INQUIRY for VPD page (6 bytes)
/// Returns Vital Product Data page
pub fn buildInquiryVpd(cdb: *[config.Limits.MAX_CDB_SIZE]u8, page_code: u8, alloc_len: u16) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.INQUIRY);
    cdb[1] = 0x01; // EVPD = 1
    cdb[2] = page_code;
    cdb[3] = @truncate(alloc_len >> 8);
    cdb[4] = @truncate(alloc_len);
}

/// Build REQUEST SENSE CDB (6 bytes)
/// Retrieves sense data from previous CHECK CONDITION
pub fn buildRequestSense(cdb: *[config.Limits.MAX_CDB_SIZE]u8, alloc_len: u8) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.REQUEST_SENSE);
    cdb[4] = alloc_len;
}

/// Build READ CAPACITY (10) CDB (10 bytes)
/// Returns device capacity and block size (up to 2TB)
pub fn buildReadCapacity10(cdb: *[config.Limits.MAX_CDB_SIZE]u8) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.READ_CAPACITY_10);
    // All other bytes are 0 (no specific LBA requested)
}

/// Build READ CAPACITY (16) CDB (16 bytes)
/// Returns device capacity and block size for large devices
pub fn buildReadCapacity16(cdb: *[config.Limits.MAX_CDB_SIZE]u8, alloc_len: u32) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.READ_CAPACITY_16);
    cdb[1] = 0x10; // Service action: READ CAPACITY (16)
    // Allocation length (bytes 10-13, big-endian)
    cdb[10] = @truncate(alloc_len >> 24);
    cdb[11] = @truncate(alloc_len >> 16);
    cdb[12] = @truncate(alloc_len >> 8);
    cdb[13] = @truncate(alloc_len);
}

/// Build READ (10) CDB (10 bytes)
/// Reads blocks from device (up to 65535 blocks per command)
pub fn buildRead10(cdb: *[config.Limits.MAX_CDB_SIZE]u8, lba: u32, block_count: u16) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.READ_10);
    // Byte 1: DPO, FUA, reserved, RARC bits (0 = normal caching)
    // LBA (bytes 2-5, big-endian)
    cdb[2] = @truncate(lba >> 24);
    cdb[3] = @truncate(lba >> 16);
    cdb[4] = @truncate(lba >> 8);
    cdb[5] = @truncate(lba);
    // Byte 6: Group number (0)
    // Transfer length (bytes 7-8, big-endian)
    cdb[7] = @truncate(block_count >> 8);
    cdb[8] = @truncate(block_count);
}

/// Build READ (16) CDB (16 bytes)
/// Reads blocks from device (large LBA addressing)
pub fn buildRead16(cdb: *[config.Limits.MAX_CDB_SIZE]u8, lba: u64, block_count: u32) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.READ_16);
    // Byte 1: DPO, FUA bits (0 = normal)
    // LBA (bytes 2-9, big-endian)
    cdb[2] = @truncate(lba >> 56);
    cdb[3] = @truncate(lba >> 48);
    cdb[4] = @truncate(lba >> 40);
    cdb[5] = @truncate(lba >> 32);
    cdb[6] = @truncate(lba >> 24);
    cdb[7] = @truncate(lba >> 16);
    cdb[8] = @truncate(lba >> 8);
    cdb[9] = @truncate(lba);
    // Transfer length (bytes 10-13, big-endian)
    cdb[10] = @truncate(block_count >> 24);
    cdb[11] = @truncate(block_count >> 16);
    cdb[12] = @truncate(block_count >> 8);
    cdb[13] = @truncate(block_count);
}

/// Build WRITE (10) CDB (10 bytes)
/// Writes blocks to device (up to 65535 blocks per command)
pub fn buildWrite10(cdb: *[config.Limits.MAX_CDB_SIZE]u8, lba: u32, block_count: u16) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.WRITE_10);
    // Byte 1: WP, DPO, FUA bits (0 = normal)
    // LBA (bytes 2-5, big-endian)
    cdb[2] = @truncate(lba >> 24);
    cdb[3] = @truncate(lba >> 16);
    cdb[4] = @truncate(lba >> 8);
    cdb[5] = @truncate(lba);
    // Byte 6: Group number (0)
    // Transfer length (bytes 7-8, big-endian)
    cdb[7] = @truncate(block_count >> 8);
    cdb[8] = @truncate(block_count);
}

/// Build WRITE (16) CDB (16 bytes)
/// Writes blocks to device (large LBA addressing)
pub fn buildWrite16(cdb: *[config.Limits.MAX_CDB_SIZE]u8, lba: u64, block_count: u32) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.WRITE_16);
    // Byte 1: WP, DPO, FUA bits (0 = normal)
    // LBA (bytes 2-9, big-endian)
    cdb[2] = @truncate(lba >> 56);
    cdb[3] = @truncate(lba >> 48);
    cdb[4] = @truncate(lba >> 40);
    cdb[5] = @truncate(lba >> 32);
    cdb[6] = @truncate(lba >> 24);
    cdb[7] = @truncate(lba >> 16);
    cdb[8] = @truncate(lba >> 8);
    cdb[9] = @truncate(lba);
    // Transfer length (bytes 10-13, big-endian)
    cdb[10] = @truncate(block_count >> 24);
    cdb[11] = @truncate(block_count >> 16);
    cdb[12] = @truncate(block_count >> 8);
    cdb[13] = @truncate(block_count);
}

/// Build SYNCHRONIZE CACHE (10) CDB (10 bytes)
/// Flushes volatile write cache to media
pub fn buildSyncCache10(cdb: *[config.Limits.MAX_CDB_SIZE]u8, lba: u32, block_count: u16, immed: bool) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.SYNCHRONIZE_CACHE_10);
    cdb[1] = if (immed) 0x02 else 0; // IMMED bit
    // LBA (bytes 2-5, big-endian)
    cdb[2] = @truncate(lba >> 24);
    cdb[3] = @truncate(lba >> 16);
    cdb[4] = @truncate(lba >> 8);
    cdb[5] = @truncate(lba);
    // Block count (bytes 7-8, big-endian) - 0 means all
    cdb[7] = @truncate(block_count >> 8);
    cdb[8] = @truncate(block_count);
}

/// Build REPORT LUNS CDB (12 bytes)
/// Returns list of available LUNs
pub fn buildReportLuns(cdb: *[config.Limits.MAX_CDB_SIZE]u8, alloc_len: u32) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.REPORT_LUNS);
    // Byte 2: Select report (0 = all LUNs)
    // Allocation length (bytes 6-9, big-endian)
    cdb[6] = @truncate(alloc_len >> 24);
    cdb[7] = @truncate(alloc_len >> 16);
    cdb[8] = @truncate(alloc_len >> 8);
    cdb[9] = @truncate(alloc_len);
}

/// Build START STOP UNIT CDB (6 bytes)
/// Controls device power state and media ejection
pub fn buildStartStopUnit(cdb: *[config.Limits.MAX_CDB_SIZE]u8, start: bool, load_eject: bool, immed: bool) void {
    @memset(cdb, 0);
    cdb[0] = @intFromEnum(Opcode.START_STOP_UNIT);
    cdb[1] = if (immed) 0x01 else 0; // IMMED bit
    // Byte 4: LoEj (bit 1), Start (bit 0)
    var byte4: u8 = 0;
    if (start) byte4 |= 0x01;
    if (load_eject) byte4 |= 0x02;
    cdb[4] = byte4;
}

// ============================================================================
// Response Parsing Helpers
// ============================================================================

/// Standard INQUIRY data structure (36 bytes minimum)
pub const InquiryData = extern struct {
    /// Peripheral device type (bits 4-0), Peripheral qualifier (bits 7-5)
    peripheral: u8 align(1),
    /// RMB (bit 7)
    rmb: u8 align(1),
    /// Version (SPC version)
    version: u8 align(1),
    /// Response data format (bits 3-0), additional flags
    response_format: u8 align(1),
    /// Additional length
    additional_length: u8 align(1),
    /// Various flags (SCCS, ACC, TPGS, 3PC, etc.)
    flags1: u8 align(1),
    flags2: u8 align(1),
    flags3: u8 align(1),
    /// Vendor identification (8 bytes, ASCII)
    vendor: [8]u8 align(1),
    /// Product identification (16 bytes, ASCII)
    product: [16]u8 align(1),
    /// Product revision (4 bytes, ASCII)
    revision: [4]u8 align(1),

    /// Get peripheral device type
    pub fn deviceType(self: *const InquiryData) DeviceType {
        return @enumFromInt(self.peripheral & 0x1F);
    }

    /// Check if device is present (not "not connected")
    pub fn isPresent(self: *const InquiryData) bool {
        return self.deviceType() != .NOT_PRESENT;
    }

    /// Check if removable media
    pub fn isRemovable(self: *const InquiryData) bool {
        return (self.rmb & 0x80) != 0;
    }
};

comptime {
    if (@sizeOf(InquiryData) != 36) {
        @compileError("InquiryData size mismatch - expected 36 bytes");
    }
}

/// SCSI device types (peripheral device type field)
pub const DeviceType = enum(u5) {
    /// Direct access block device (disk)
    DISK = 0x00,
    /// Sequential access device (tape)
    TAPE = 0x01,
    /// Printer
    PRINTER = 0x02,
    /// Processor device
    PROCESSOR = 0x03,
    /// Write-once device
    WORM = 0x04,
    /// CD/DVD-ROM
    CDROM = 0x05,
    /// Scanner
    SCANNER = 0x06,
    /// Optical memory device
    OPTICAL = 0x07,
    /// Medium changer (jukebox)
    CHANGER = 0x08,
    /// Communications device
    COMM = 0x09,
    /// Storage array controller
    RAID = 0x0C,
    /// Enclosure services device
    ENCLOSURE = 0x0D,
    /// Simplified direct-access device
    RBC = 0x0E,
    /// Optical card reader/writer
    OCRW = 0x0F,
    /// Bridge controller
    BRIDGE = 0x10,
    /// Object-based storage device
    OSD = 0x11,
    /// Automation/drive interface
    ADC = 0x12,
    /// Security manager device
    SECURITY_MANAGER = 0x13,
    /// Well-known logical unit
    WELL_KNOWN = 0x1E,
    /// Device not present/connected
    NOT_PRESENT = 0x1F,
    _,
};

/// READ CAPACITY (10) response data (8 bytes)
pub const ReadCapacity10Data = extern struct {
    /// Last LBA (big-endian) - if 0xFFFFFFFF, use READ CAPACITY (16)
    last_lba_be: [4]u8 align(1),
    /// Block size in bytes (big-endian)
    block_size_be: [4]u8 align(1),

    /// Get last LBA
    pub fn lastLba(self: *const ReadCapacity10Data) u32 {
        return std.mem.readInt(u32, &self.last_lba_be, .big);
    }

    /// Get block size
    pub fn blockSize(self: *const ReadCapacity10Data) u32 {
        return std.mem.readInt(u32, &self.block_size_be, .big);
    }

    /// Check if device exceeds 2TB (need READ CAPACITY 16)
    pub fn needsCapacity16(self: *const ReadCapacity10Data) bool {
        return self.lastLba() == 0xFFFFFFFF;
    }
};

comptime {
    if (@sizeOf(ReadCapacity10Data) != 8) {
        @compileError("ReadCapacity10Data size mismatch - expected 8 bytes");
    }
}

/// READ CAPACITY (16) response data (32 bytes)
pub const ReadCapacity16Data = extern struct {
    /// Last LBA (big-endian)
    last_lba_be: [8]u8 align(1),
    /// Block size in bytes (big-endian)
    block_size_be: [4]u8 align(1),
    /// Protection info and other flags
    flags: u8 align(1),
    /// Reserved
    reserved: [19]u8 align(1),

    /// Get last LBA
    pub fn lastLba(self: *const ReadCapacity16Data) u64 {
        return std.mem.readInt(u64, &self.last_lba_be, .big);
    }

    /// Get block size
    pub fn blockSize(self: *const ReadCapacity16Data) u32 {
        return std.mem.readInt(u32, &self.block_size_be, .big);
    }
};

comptime {
    if (@sizeOf(ReadCapacity16Data) != 32) {
        @compileError("ReadCapacity16Data size mismatch - expected 32 bytes");
    }
}

/// REPORT LUNS response header
pub const ReportLunsHeader = extern struct {
    /// LUN list length in bytes (big-endian)
    lun_list_length_be: [4]u8 align(1),
    /// Reserved
    reserved: [4]u8 align(1),

    /// Get LUN list length
    pub fn lunListLength(self: *const ReportLunsHeader) u32 {
        return std.mem.readInt(u32, &self.lun_list_length_be, .big);
    }

    /// Get number of LUNs in response
    pub fn lunCount(self: *const ReportLunsHeader) u32 {
        return self.lunListLength() / 8; // Each LUN entry is 8 bytes
    }
};

comptime {
    if (@sizeOf(ReportLunsHeader) != 8) {
        @compileError("ReportLunsHeader size mismatch - expected 8 bytes");
    }
}
