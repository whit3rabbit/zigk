// AHCI Command Structures
//
// AHCI uses a ring buffer of command headers (Command List) pointing to
// Command Tables containing the actual FIS and data descriptors.
//
// Memory Layout:
// - Command List: 32 command headers (32 bytes each) = 1KB, 1KB aligned
// - Command Table: Variable size (128 bytes + PRDTs), 128-byte aligned
// - PRD Table: Array of Physical Region Descriptors for scatter/gather
//
// Reference: AHCI Specification 1.3.1, Section 4

const std = @import("std");
const fis = @import("fis.zig");

// ============================================================================
// Command List Entry (Command Header)
// ============================================================================

/// Command Header Flags (first word)
pub const CommandFlags = packed struct(u16) {
    /// Command FIS Length (in DWORDs, 2-16)
    cfl: u5, // Bits 4:0

    /// ATAPI command
    a: bool, // Bit 5

    /// Write (1) or Read (0)
    w: bool, // Bit 6

    /// Prefetchable
    p: bool, // Bit 7

    /// Reset
    r: bool, // Bit 8

    /// BIST
    b: bool, // Bit 9

    /// Clear Busy upon R_OK
    c: bool, // Bit 10

    /// Reserved
    _reserved0: u1 = 0, // Bit 11

    /// Port Multiplier Port
    pmp: u4, // Bits 15:12

    comptime {
        if (@sizeOf(@This()) != 2) @compileError("CommandFlags must be 2 bytes");
    }
};

/// Command Header (32 bytes)
/// One of 32 entries in the Command List
pub const CommandHeader = extern struct {
    /// Command flags
    flags: CommandFlags,

    /// Physical Region Descriptor Table Length (entries)
    prdtl: u16,

    /// Physical Region Descriptor Byte Count (set by HBA after transfer)
    prdbc: u32,

    /// Command Table Base Address (low)
    ctba: u32,

    /// Command Table Base Address (high)
    ctbau: u32,

    /// Reserved
    _reserved: [4]u32,

    comptime {
        if (@sizeOf(@This()) != 32) @compileError("CommandHeader must be 32 bytes");
    }

    /// Set the command table address (128-byte aligned)
    pub fn setCommandTableAddr(self: *CommandHeader, addr: u64) void {
        self.ctba = @truncate(addr);
        self.ctbau = @truncate(addr >> 32);
    }

    /// Get the command table address
    pub fn getCommandTableAddr(self: *const CommandHeader) u64 {
        return (@as(u64, self.ctbau) << 32) | self.ctba;
    }

    /// Initialize for a non-data command
    pub fn initNonData(self: *CommandHeader, table_addr: u64) void {
        self.flags = .{
            .cfl = 5, // FIS_REG_H2D is 5 DWORDs (20 bytes)
            .a = false,
            .w = false,
            .p = false,
            .r = false,
            .b = false,
            .c = true, // Clear BSY on success
            .pmp = 0,
        };
        self.prdtl = 0;
        self.prdbc = 0;
        self.setCommandTableAddr(table_addr);
        self._reserved = [_]u32{0} ** 4;
    }

    /// Initialize for a read command
    pub fn initRead(self: *CommandHeader, table_addr: u64, prdt_count: u16) void {
        self.flags = .{
            .cfl = 5,
            .a = false,
            .w = false, // Read
            .p = true, // Prefetchable
            .r = false,
            .b = false,
            .c = true,
            .pmp = 0,
        };
        self.prdtl = prdt_count;
        self.prdbc = 0;
        self.setCommandTableAddr(table_addr);
        self._reserved = [_]u32{0} ** 4;
    }

    /// Initialize for a write command
    pub fn initWrite(self: *CommandHeader, table_addr: u64, prdt_count: u16) void {
        self.flags = .{
            .cfl = 5,
            .a = false,
            .w = true, // Write
            .p = true,
            .r = false,
            .b = false,
            .c = true,
            .pmp = 0,
        };
        self.prdtl = prdt_count;
        self.prdbc = 0;
        self.setCommandTableAddr(table_addr);
        self._reserved = [_]u32{0} ** 4;
    }
};

/// Command List (array of 32 command headers = 1KB)
pub const CommandList = [32]CommandHeader;

// ============================================================================
// Physical Region Descriptor (PRDT Entry)
// ============================================================================

/// Physical Region Descriptor Table Entry (16 bytes)
/// Describes a contiguous physical memory region for DMA
pub const PrdtEntry = extern struct {
    /// Data Base Address (low)
    dba: u32,

    /// Data Base Address (high)
    dbau: u32,

    /// Reserved
    _reserved: u32,

    /// Data Byte Count and Interrupt flag
    dbc_i: packed struct(u32) {
        /// Data Byte Count - 1 (max 4MB, must be even)
        dbc: u22, // Bits 21:0

        /// Reserved
        _reserved: u9 = 0, // Bits 30:22

        /// Interrupt on Completion
        i: bool, // Bit 31

        comptime {
            if (@sizeOf(@This()) != 4) @compileError("dbc_i must be 4 bytes");
        }
    },

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("PrdtEntry must be 16 bytes");
    }

    /// Set the data buffer address (2-byte aligned)
    pub fn setDataAddr(self: *PrdtEntry, addr: u64) void {
        self.dba = @truncate(addr);
        self.dbau = @truncate(addr >> 32);
    }

    /// Get the data buffer address
    pub fn getDataAddr(self: *const PrdtEntry) u64 {
        return (@as(u64, self.dbau) << 32) | self.dba;
    }

    /// Set byte count and interrupt flag
    /// count is actual byte count (will store count - 1)
    pub fn setByteCount(self: *PrdtEntry, count: u32, interrupt: bool) void {
        self.dbc_i = .{
            .dbc = @truncate(count - 1),
            .i = interrupt,
        };
    }

    /// Get actual byte count (stored value + 1)
    pub fn getByteCount(self: *const PrdtEntry) u32 {
        return @as(u32, self.dbc_i.dbc) + 1;
    }

    /// Initialize a PRDT entry
    pub fn init(addr: u64, byte_count: u32, interrupt: bool) PrdtEntry {
        var entry: PrdtEntry = undefined;
        entry.setDataAddr(addr);
        entry._reserved = 0;
        entry.setByteCount(byte_count, interrupt);
        return entry;
    }
};

// ============================================================================
// Command Table
// ============================================================================

/// Maximum PRDT entries per command (limited by prdtl field = 16 bits)
/// Practical limit is often 65535, but we use a smaller default
pub const MAX_PRDT_ENTRIES: usize = 168; // ~64KB typical, enough for 2MB with 4KB pages

/// Command Table size calculation
/// Base: 128 bytes (CFIS + ACMD + reserved)
/// Plus: PRDT entries (16 bytes each)
pub fn commandTableSize(prdt_count: usize) usize {
    return 128 + (prdt_count * 16);
}

/// Command Table base structure (without PRDT)
/// Total 128 bytes minimum, 128-byte aligned
pub const CommandTableBase = extern struct {
    /// Command FIS (64 bytes max, typically 20 bytes used)
    cfis: [64]u8,

    /// ATAPI Command (16 bytes)
    acmd: [16]u8,

    /// Reserved (48 bytes)
    _reserved: [48]u8,

    comptime {
        if (@sizeOf(@This()) != 128) @compileError("CommandTableBase must be 128 bytes");
    }

    /// Get pointer to Command FIS as H2D FIS
    pub fn getH2dFis(self: *CommandTableBase) *fis.FisRegH2D {
        return @ptrCast(@alignCast(&self.cfis));
    }

    /// Clear the command table base
    pub fn clear(self: *CommandTableBase) void {
        @memset(&self.cfis, 0);
        @memset(&self.acmd, 0);
        @memset(&self._reserved, 0);
    }
};

/// Command Table with PRDT (variable size)
/// This structure is for documentation; actual allocation must account for PRDT size
pub fn CommandTable(comptime prdt_count: usize) type {
    return extern struct {
        base: CommandTableBase,
        prdt: [prdt_count]PrdtEntry,

        pub fn size() usize {
            return commandTableSize(prdt_count);
        }
    };
}

// ============================================================================
// Memory Allocation Requirements
// ============================================================================

pub const Alignment = struct {
    /// Command List must be 1KB aligned
    pub const COMMAND_LIST: usize = 1024;

    /// Received FIS buffer must be 256-byte aligned
    pub const RECEIVED_FIS: usize = 256;

    /// Command Table must be 128-byte aligned
    pub const COMMAND_TABLE: usize = 128;

    /// Data buffer must be 2-byte aligned (word aligned)
    pub const DATA_BUFFER: usize = 2;
};

pub const Size = struct {
    /// Command List size (32 headers x 32 bytes)
    pub const COMMAND_LIST: usize = 1024;

    /// Received FIS buffer size
    pub const RECEIVED_FIS: usize = 256;

    /// Minimum Command Table size (no PRDT)
    pub const COMMAND_TABLE_MIN: usize = 128;

    /// Command Table size with 8 PRDT entries (256 bytes, common case)
    pub const COMMAND_TABLE_8PRDT: usize = 128 + (8 * 16);

    /// Command Table size with maximum PRDT entries
    pub const COMMAND_TABLE_MAX: usize = commandTableSize(MAX_PRDT_ENTRIES);
};

// ============================================================================
// Command Building Helpers
// ============================================================================

/// Build an IDENTIFY DEVICE command
pub fn buildIdentify(table: *CommandTableBase, buffer_phys: u64) void {
    table.clear();

    var h2d = table.getH2dFis();
    h2d.* = fis.FisRegH2D.init(.identify_device);

    // PRDT will be set up separately
    _ = buffer_phys;
}

/// Build a READ DMA EXT command
pub fn buildReadDmaExt(table: *CommandTableBase, lba: u48, sector_count: u16) void {
    table.clear();

    var h2d = table.getH2dFis();
    h2d.* = fis.FisRegH2D.init(.read_dma_ext);
    h2d.setLba(lba);
    h2d.setCount(sector_count);
}

/// Build a WRITE DMA EXT command
pub fn buildWriteDmaExt(table: *CommandTableBase, lba: u48, sector_count: u16) void {
    table.clear();

    var h2d = table.getH2dFis();
    h2d.* = fis.FisRegH2D.init(.write_dma_ext);
    h2d.setLba(lba);
    h2d.setCount(sector_count);
}

/// Build a FLUSH CACHE EXT command
pub fn buildFlushCacheExt(table: *CommandTableBase) void {
    table.clear();

    var h2d = table.getH2dFis();
    h2d.* = fis.FisRegH2D.init(.flush_cache_ext);
}
