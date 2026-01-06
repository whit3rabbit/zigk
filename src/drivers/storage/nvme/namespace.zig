// NVMe Namespace and Identify Structures
//
// Defines the Identify Controller and Identify Namespace data structures
// returned by the Identify command (Admin opcode 0x06).
//
// Reference: NVM Express Base Specification 2.0, Section 5.17

const std = @import("std");

// Helper function for trimRight (Zig 0.16.x: std.mem.trimRight removed)
fn trimRight(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var end: usize = slice.len;
    while (end > 0) {
        var found = false;
        for (values_to_strip) |c| {
            if (slice[end - 1] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        end -= 1;
    }
    return slice[0..end];
}

// ============================================================================
// Identify Controller Data Structure (4096 bytes)
// ============================================================================

/// Identify Controller data structure
/// Returned by Identify command with CNS = 01h
pub const IdentifyController = extern struct {
    // Controller Capabilities and Features
    /// PCI Vendor ID
    vid: u16,
    /// PCI Subsystem Vendor ID
    ssvid: u16,
    /// Serial Number (20 ASCII bytes, space-padded)
    sn: [20]u8,
    /// Model Number (40 ASCII bytes, space-padded)
    mn: [40]u8,
    /// Firmware Revision (8 ASCII bytes)
    fr: [8]u8,
    /// Recommended Arbitration Burst
    rab: u8,
    /// IEEE OUI Identifier
    ieee: [3]u8,
    /// Controller Multi-Path I/O and Namespace Sharing Capabilities
    cmic: u8,
    /// Maximum Data Transfer Size (in units of 2^n * min page size)
    mdts: u8,
    /// Controller ID
    cntlid: u16,
    /// Version (same format as VS register)
    ver: u32,
    /// RTD3 Resume Latency (microseconds)
    rtd3r: u32,
    /// RTD3 Entry Latency (microseconds)
    rtd3e: u32,
    /// Optional Asynchronous Events Supported
    oaes: u32,
    /// Controller Attributes
    ctratt: u32,
    /// Read Recovery Levels Supported
    rrls: u16,
    /// Reserved
    _reserved0: [9]u8,
    /// Controller Type
    cntrltype: u8,
    /// FRU Globally Unique Identifier
    fguid: [16]u8,
    /// Command Retry Delay Time 1/2/3
    crdt1: u16,
    crdt2: u16,
    crdt3: u16,
    /// Reserved
    _reserved1: [106]u8,
    /// Reserved (NVMe-MI)
    _reserved_mi: [16]u8,

    // Admin Command Set Attributes & Optional Controller Capabilities
    /// Optional Admin Command Support
    oacs: u16,
    /// Abort Command Limit (0-based)
    acl: u8,
    /// Asynchronous Event Request Limit (0-based)
    aerl: u8,
    /// Firmware Updates
    frmw: u8,
    /// Log Page Attributes
    lpa: u8,
    /// Error Log Page Entries (0-based)
    elpe: u8,
    /// Number of Power States Support (0-based)
    npss: u8,
    /// Admin Vendor Specific Command Configuration
    avscc: u8,
    /// Autonomous Power State Transition Attributes
    apsta: u8,
    /// Warning Composite Temperature Threshold (Kelvin)
    wctemp: u16,
    /// Critical Composite Temperature Threshold (Kelvin)
    cctemp: u16,
    /// Maximum Time for Firmware Activation (ms * 100)
    mtfa: u16,
    /// Host Memory Buffer Preferred Size (4KB units)
    hmpre: u32,
    /// Host Memory Buffer Minimum Size (4KB units)
    hmmin: u32,
    /// Total NVM Capacity (bytes, stored as [16]u8 to avoid alignment padding)
    tnvmcap: [16]u8,
    /// Unallocated NVM Capacity (bytes, stored as [16]u8 to avoid alignment padding)
    unvmcap: [16]u8,
    /// Replay Protected Memory Block Support
    rpmbs: u32,
    /// Extended Device Self-test Time (minutes)
    edstt: u16,
    /// Device Self-test Options
    dsto: u8,
    /// Firmware Update Granularity (4KB units)
    fwug: u8,
    /// Keep Alive Support (100ms units)
    kas: u16,
    /// Host Controlled Thermal Management Attributes
    hctma: u16,
    /// Minimum Thermal Management Temperature
    mntmt: u16,
    /// Maximum Thermal Management Temperature
    mxtmt: u16,
    /// Sanitize Capabilities
    sanicap: u32,
    /// Host Memory Buffer Min/Max Descriptor Entry Size
    hmminds: u32,
    hmmaxd: u16,
    /// NVM Set Identifier Maximum
    nsetidmax: u16,
    /// Endurance Group Identifier Maximum
    endgidmax: u16,
    /// ANA Transition Time (seconds)
    anatt: u8,
    /// Asymmetric Namespace Access Capabilities
    anacap: u8,
    /// ANA Group Identifier Maximum
    anagrpmax: u32,
    /// Number of ANA Group Identifiers
    nanagrpid: u32,
    /// Persistent Event Log Size (64KB units)
    pels: u32,
    /// Domain Identifier
    domainid: u16,
    /// Reserved
    _reserved2: [10]u8,
    /// Max Endurance Group Capacity (bytes, stored as [16]u8 to avoid alignment padding)
    megcap: [16]u8,
    /// Reserved
    _reserved3: [128]u8,

    // NVM Command Set Attributes
    /// Submission Queue Entry Size
    sqes: SqesField,
    /// Completion Queue Entry Size
    cqes: CqesField,
    /// Maximum Outstanding Commands
    maxcmd: u16,
    /// Number of Namespaces
    nn: u32,
    /// Optional NVM Command Support
    oncs: u16,
    /// Fused Operation Support
    fuses: u16,
    /// Format NVM Attributes
    fna: u8,
    /// Volatile Write Cache
    vwc: u8,
    /// Atomic Write Unit Normal
    awun: u16,
    /// Atomic Write Unit Power Fail
    awupf: u16,
    /// NVM Vendor Specific Command Configuration
    nvscc: u8,
    /// Namespace Write Protection Capabilities
    nwpc: u8,
    /// Atomic Compare & Write Unit
    acwu: u16,
    /// Copy Descriptor Formats Supported
    cdfs: u16,
    /// SGL Support
    sgls: u32,
    /// Maximum Number of Allowed Namespaces
    mnan: u32,
    /// Maximum Domain Namespace Attachments (stored as [16]u8 to avoid alignment padding)
    maxdna: [16]u8,
    /// Maximum I/O Controller Namespace Attachments
    maxcna: u32,
    /// Reserved (bytes 564-703)
    _reserved4: [140]u8,

    // Reserved (bytes 704-2047)
    _reserved_middle: [1344]u8,

    // Power State Descriptors (bytes 2048-3071)
    _power_states: [1024]u8,

    // Vendor Specific (bytes 3072-4095)
    _vendor: [1024]u8,

    pub const SqesField = packed struct(u8) {
        /// Minimum SQ Entry Size (2^n bytes)
        min: u4,
        /// Maximum SQ Entry Size (2^n bytes)
        max: u4,
    };

    pub const CqesField = packed struct(u8) {
        /// Minimum CQ Entry Size (2^n bytes)
        min: u4,
        /// Maximum CQ Entry Size (2^n bytes)
        max: u4,
    };

    /// Get serial number as string (trimmed)
    pub fn serialNumber(self: *const IdentifyController) []const u8 {
        return trimRight(u8, &self.sn, " ");
    }

    /// Get model number as string (trimmed)
    pub fn modelNumber(self: *const IdentifyController) []const u8 {
        return trimRight(u8, &self.mn, " ");
    }

    /// Get firmware revision as string (trimmed)
    pub fn firmwareRevision(self: *const IdentifyController) []const u8 {
        return trimRight(u8, &self.fr, " ");
    }

    /// Get max data transfer size in bytes
    /// Returns null if no limit (MDTS = 0)
    pub fn maxDataTransferBytes(self: *const IdentifyController, min_page_size: u32) ?u64 {
        if (self.mdts == 0) return null;
        return @as(u64, min_page_size) << self.mdts;
    }

    /// Check if volatile write cache is present
    pub fn hasVolatileWriteCache(self: *const IdentifyController) bool {
        return (self.vwc & 0x01) != 0;
    }

    /// Check if Dataset Management (TRIM) is supported
    pub fn supportsDatasetManagement(self: *const IdentifyController) bool {
        return (self.oncs & 0x04) != 0;
    }

    /// Check if Write Zeros is supported
    pub fn supportsWriteZeros(self: *const IdentifyController) bool {
        return (self.oncs & 0x08) != 0;
    }
};

comptime {
    if (@sizeOf(IdentifyController) != 4096) {
        @compileError("IdentifyController must be exactly 4096 bytes");
    }
}

// ============================================================================
// Identify Namespace Data Structure (4096 bytes)
// ============================================================================

/// Identify Namespace data structure
/// Returned by Identify command with CNS = 00h
pub const IdentifyNamespace = extern struct {
    /// Namespace Size (total LBAs in namespace)
    nsze: u64,
    /// Namespace Capacity (max LBAs that can be allocated)
    ncap: u64,
    /// Namespace Utilization (currently allocated LBAs)
    nuse: u64,
    /// Namespace Features
    nsfeat: u8,
    /// Number of LBA Formats (0-based)
    nlbaf: u8,
    /// Formatted LBA Size
    flbas: FlbasField,
    /// Metadata Capabilities
    mc: u8,
    /// End-to-End Data Protection Capabilities
    dpc: u8,
    /// End-to-End Data Protection Type Settings
    dps: u8,
    /// Namespace Multi-Path I/O and Namespace Sharing Capabilities
    nmic: u8,
    /// Reservation Capabilities
    rescap: u8,
    /// Format Progress Indicator
    fpi: u8,
    /// Deallocate Logical Block Features
    dlfeat: u8,
    /// Namespace Atomic Write Unit Normal
    nawun: u16,
    /// Namespace Atomic Write Unit Power Fail
    nawupf: u16,
    /// Namespace Atomic Compare & Write Unit
    nacwu: u16,
    /// Namespace Atomic Boundary Size Normal
    nabsn: u16,
    /// Namespace Atomic Boundary Offset
    nabo: u16,
    /// Namespace Atomic Boundary Size Power Fail
    nabspf: u16,
    /// Namespace Optimal I/O Boundary
    noiob: u16,
    /// NVM Capacity (bytes, stored as [16]u8 to avoid alignment padding)
    nvmcap: [16]u8,
    /// Namespace Preferred Write Granularity
    npwg: u16,
    /// Namespace Preferred Write Alignment
    npwa: u16,
    /// Namespace Preferred Deallocate Granularity
    npdg: u16,
    /// Namespace Preferred Deallocate Alignment
    npda: u16,
    /// Namespace Optimal Write Size
    nows: u16,
    /// Maximum Single Source Range Length (Copy)
    mssrl: u16,
    /// Maximum Copy Length
    mcl: u32,
    /// Maximum Source Range Count (Copy)
    msrc: u8,
    /// Reserved
    _reserved0: [11]u8,
    /// ANA Group Identifier
    anagrpid: u32,
    /// Reserved
    _reserved1: [3]u8,
    /// Namespace Attributes
    nsattr: u8,
    /// NVM Set Identifier
    nvmsetid: u16,
    /// Endurance Group Identifier
    endgid: u16,
    /// Namespace Globally Unique Identifier
    nguid: [16]u8,
    /// IEEE Extended Unique Identifier
    eui64: [8]u8,

    /// LBA Format Support (up to 64 formats, only lower 16 commonly used)
    lbaf: [64]LbaFormat,

    /// Vendor Specific
    _vendor: [3712]u8,

    pub const FlbasField = packed struct(u8) {
        /// LBA Format index (0-15 for basic, 16-63 for extended)
        format: u4,
        /// Metadata at end of LBA (0) or separate buffer (1)
        meta_extended: bool,
        /// Reserved
        _reserved: u3,
    };

    /// LBA Format entry (4 bytes)
    pub const LbaFormat = packed struct(u32) {
        /// Metadata Size (bytes)
        ms: u16,
        /// LBA Data Size (2^n bytes)
        lbads: u8,
        /// Relative Performance (0=Best, 1=Better, 2=Good, 3=Degraded)
        rp: u2,
        /// Reserved
        _reserved: u6,

        /// Get LBA data size in bytes
        pub fn lbaSize(self: LbaFormat) u32 {
            if (self.lbads == 0) return 0;
            // Clamp to max 31 bits shift (valid LBA sizes are 9-31 for 512B-2GB)
            const shift: u5 = @intCast(@min(self.lbads, 31));
            return @as(u32, 1) << shift;
        }
    };

    /// Get the current LBA format
    pub fn currentFormat(self: *const IdentifyNamespace) LbaFormat {
        const idx = self.flbas.format;
        return self.lbaf[idx];
    }

    /// Get LBA size in bytes for current format
    pub fn lbaSize(self: *const IdentifyNamespace) u32 {
        return self.currentFormat().lbaSize();
    }

    /// Get metadata size for current format
    pub fn metadataSize(self: *const IdentifyNamespace) u16 {
        return self.currentFormat().ms;
    }

    /// Get total capacity in bytes (returns null on overflow)
    pub fn capacityBytes(self: *const IdentifyNamespace) u64 {
        // Use checked arithmetic to handle hardware-provided values safely
        return std.math.mul(u64, self.nsze, @as(u64, self.lbaSize())) catch 0;
    }

    /// Check if namespace is thin-provisioned
    pub fn isThinProvisioned(self: *const IdentifyNamespace) bool {
        return (self.nsfeat & 0x01) != 0;
    }

    /// Check if deallocate returns zeros
    pub fn deallocateReturnsZeros(self: *const IdentifyNamespace) bool {
        return (self.dlfeat & 0x01) != 0;
    }
};

comptime {
    if (@sizeOf(IdentifyNamespace) != 4096) {
        @compileError("IdentifyNamespace must be exactly 4096 bytes");
    }
}

// ============================================================================
// Namespace State
// ============================================================================

/// Per-namespace state tracked by the driver
pub const NamespaceInfo = struct {
    /// Namespace ID (1-based)
    nsid: u32,
    /// Whether namespace is active
    active: bool,
    /// LBA size in bytes
    lba_size: u32,
    /// Total number of LBAs
    total_lbas: u64,
    /// Total capacity in bytes
    capacity_bytes: u64,
    /// Metadata size per LBA
    metadata_size: u16,
    /// Formatted LBA size index
    format_idx: u4,
    /// Supports TRIM/Deallocate
    supports_trim: bool,

    /// Initialize from Identify Namespace data
    pub fn fromIdentify(nsid: u32, id: *const IdentifyNamespace, ctrl: *const IdentifyController) NamespaceInfo {
        return NamespaceInfo{
            .nsid = nsid,
            .active = id.nsze > 0,
            .lba_size = id.lbaSize(),
            .total_lbas = id.nsze,
            .capacity_bytes = id.capacityBytes(),
            .metadata_size = id.metadataSize(),
            .format_idx = id.flbas.format,
            .supports_trim = ctrl.supportsDatasetManagement(),
        };
    }
};

// ============================================================================
// Active Namespace List (4096 bytes)
// ============================================================================

/// Active Namespace ID List
/// Returned by Identify command with CNS = 02h
/// Contains up to 1024 32-bit NSIDs (list terminated by 0)
pub const ActiveNamespaceList = extern struct {
    nsids: [1024]u32,

    /// Iterator over active namespace IDs
    pub fn iterator(self: *const ActiveNamespaceList) Iterator {
        return Iterator{ .list = self, .index = 0 };
    }

    pub const Iterator = struct {
        list: *const ActiveNamespaceList,
        index: usize,

        pub fn next(self: *Iterator) ?u32 {
            if (self.index >= 1024) return null;
            const nsid = self.list.nsids[self.index];
            if (nsid == 0) return null;
            self.index += 1;
            return nsid;
        }
    };

    /// Count active namespaces
    pub fn count(self: *const ActiveNamespaceList) usize {
        var n: usize = 0;
        for (self.nsids) |nsid| {
            if (nsid == 0) break;
            n += 1;
        }
        return n;
    }
};

comptime {
    if (@sizeOf(ActiveNamespaceList) != 4096) {
        @compileError("ActiveNamespaceList must be exactly 4096 bytes");
    }
}
