// Intel VT-d Register Definitions
//
// Defines the memory-mapped registers for Intel VT-d IOMMU hardware units.
// Each DRHD (DMA Remapping Hardware Unit) has its own register set at
// the base address specified in the ACPI DMAR table.
//
// Reference: Intel VT-d Specification 3.0+, Section 10 (Register Descriptions)
// See: https://cdrdv2-public.intel.com/671081/vt-directed-io-spec.pdf

const std = @import("std");

/// VT-d Register Offsets (VT-d Spec Section 10.4)
pub const Offset = struct {
    pub const VER: u32 = 0x00; // Version Register
    pub const CAP: u32 = 0x08; // Capability Register
    pub const ECAP: u32 = 0x10; // Extended Capability Register
    pub const GCMD: u32 = 0x18; // Global Command Register
    pub const GSTS: u32 = 0x1C; // Global Status Register
    pub const RTADDR: u32 = 0x20; // Root Table Address Register
    pub const CCMD: u32 = 0x28; // Context Command Register
    pub const FSTS: u32 = 0x34; // Fault Status Register
    pub const FECTL: u32 = 0x38; // Fault Event Control Register
    pub const FEDATA: u32 = 0x3C; // Fault Event Data Register
    pub const FEADDR: u32 = 0x40; // Fault Event Address Register
    pub const FEUADDR: u32 = 0x44; // Fault Event Upper Address Register
    pub const AFLOG: u32 = 0x58; // Advanced Fault Log Register
    pub const PMEN: u32 = 0x64; // Protected Memory Enable Register
    pub const PLMBASE: u32 = 0x68; // Protected Low Memory Base Register
    pub const PLMLIMIT: u32 = 0x6C; // Protected Low Memory Limit Register
    pub const PHMBASE: u32 = 0x70; // Protected High Memory Base Register
    pub const PHMLIMIT: u32 = 0x78; // Protected High Memory Limit Register
    pub const IQH: u32 = 0x80; // Invalidation Queue Head Register
    pub const IQT: u32 = 0x88; // Invalidation Queue Tail Register
    pub const IQA: u32 = 0x90; // Invalidation Queue Address Register
    pub const ICS: u32 = 0x9C; // Invalidation Completion Status Register
    pub const IRTA: u32 = 0xB8; // Interrupt Remapping Table Address Register
    pub const PQH: u32 = 0xC0; // Page Request Queue Head Register
    pub const PQT: u32 = 0xC8; // Page Request Queue Tail Register
    pub const PQA: u32 = 0xD0; // Page Request Queue Address Register
    pub const PRS: u32 = 0xDC; // Page Request Status Register
    pub const PECTL: u32 = 0xE0; // Page Request Event Control Register
    pub const PEDATA: u32 = 0xE4; // Page Request Event Data Register
    pub const PEADDR: u32 = 0xE8; // Page Request Event Address Register
    pub const PEUADDR: u32 = 0xEC; // Page Request Event Upper Address Register

    // IOTLB register offset is dynamic based on IRO field in ECAP
    // Default offset when IRO=0 is 0x108, but typically at CAP.FRO * 16 + 0x08
    pub const IOTLB_BASE: u32 = 0x108; // Base IOTLB Invalidate Register

    // Fault Recording Registers base offset (FRO field in CAP * 16)
    pub const FRCD_BASE: u32 = 0x220; // Typical base for Fault Recording Registers
};

/// Version Register (VER) - Offset 0x00
/// Read-only register indicating the architecture version
pub const VersionReg = packed struct(u32) {
    minor: u4, // Bits 0-3: Minor version
    major: u4, // Bits 4-7: Major version
    _reserved: u24 = 0, // Bits 8-31: Reserved
};

/// Capability Register (CAP) - Offset 0x08
/// Read-only register indicating hardware capabilities
pub const CapabilityReg = packed struct(u64) {
    nd: u3, // Bits 0-2: Number of domains supported (2^(nd+4+1) - 1)
    afl: bool, // Bit 3: Advanced Fault Logging supported
    rwbf: bool, // Bit 4: Required Write-Buffer Flushing
    plmr: bool, // Bit 5: Protected Low-Memory Region supported
    phmr: bool, // Bit 6: Protected High-Memory Region supported
    cm: bool, // Bit 7: Caching Mode
    sagaw: u5, // Bits 8-12: Supported Adjusted Guest Address Widths
    _reserved0: u3 = 0, // Bits 13-15: Reserved
    mgaw: u6, // Bits 16-21: Maximum Guest Address Width
    zlr: bool, // Bit 22: Zero Length Read supported
    deprecated: bool, // Bit 23: Deprecated (was FLR)
    fro: u10, // Bits 24-33: Fault-recording Register Offset (16-byte aligned)
    sllps: u4, // Bits 34-37: Second Level Large Page Support
    _reserved1: bool = false, // Bit 38: Reserved
    psi: bool, // Bit 39: Page Selective Invalidation supported
    nfr: u8, // Bits 40-47: Number of Fault-recording Registers (minus 1)
    mamv: u6, // Bits 48-53: Maximum Address Mask Value
    dwd: bool, // Bit 54: Write Draining supported
    drd: bool, // Bit 55: Read Draining supported
    fl1gp: bool, // Bit 56: First Level 1-GByte Page support
    _reserved2: u2 = 0, // Bits 57-58: Reserved
    pi: bool, // Bit 59: Posted Interrupts supported
    fl5lp: bool, // Bit 60: First Level 5-level Paging support
    _reserved3: bool = false, // Bit 61: Reserved
    esirtps: bool, // Bit 62: Enhanced Set Interrupt Remap Table Pointer Support
    esrtps: bool, // Bit 63: Enhanced Set Root Table Pointer Support

    /// Get maximum number of domains supported
    pub fn getMaxDomains(self: CapabilityReg) u32 {
        // Number of domains = 2^(ND+4+1) - 1, capped at 65535
        const shift: u5 = @as(u5, self.nd) + 5;
        return (@as(u32, 1) << shift) - 1;
    }

    /// Get fault recording register offset in bytes
    pub fn getFaultRecordOffset(self: CapabilityReg) u32 {
        return @as(u32, self.fro) * 16;
    }

    /// Get number of fault recording registers
    pub fn getNumFaultRecords(self: CapabilityReg) u8 {
        return self.nfr + 1;
    }

    /// Check if 48-bit guest address width is supported (4-level paging)
    pub fn supports48BitGaw(self: CapabilityReg) bool {
        return (self.sagaw & 0x04) != 0; // Bit 2 of SAGAW
    }

    /// Check if 39-bit guest address width is supported (3-level paging)
    pub fn supports39BitGaw(self: CapabilityReg) bool {
        return (self.sagaw & 0x02) != 0; // Bit 1 of SAGAW
    }

    /// Get maximum guest address width in bits
    pub fn getMaxGuestAddrWidth(self: CapabilityReg) u8 {
        return self.mgaw + 1;
    }
};

/// Extended Capability Register (ECAP) - Offset 0x10
/// Read-only register indicating extended capabilities
pub const ExtCapabilityReg = packed struct(u64) {
    c: bool, // Bit 0: Page-walk Coherency
    qi: bool, // Bit 1: Queued Invalidation support
    dt: bool, // Bit 2: Device-TLB support
    ir: bool, // Bit 3: Interrupt Remapping support
    eim: bool, // Bit 4: Extended Interrupt Mode
    deprecated0: bool, // Bit 5: Deprecated
    pt: bool, // Bit 6: Pass Through
    sc: bool, // Bit 7: Snoop Control
    iro: u10, // Bits 8-17: IOTLB Register Offset (16-byte aligned)
    _reserved0: u2 = 0, // Bits 18-19: Reserved
    mhmv: u4, // Bits 20-23: Maximum Handle Mask Value
    deprecated1: bool, // Bit 24: Deprecated
    mts: bool, // Bit 25: Memory Type Support
    nest: bool, // Bit 26: Nested Translation support
    deprecated2: bool, // Bit 27: Deprecated
    deprecated3: bool, // Bit 28: Deprecated
    prs: bool, // Bit 29: Page Request support
    ers: bool, // Bit 30: Execute Request support
    srs: bool, // Bit 31: Supervisor Request support
    _reserved1: u1 = 0, // Bit 32: Reserved
    nwfs: bool, // Bit 33: No Write Flag support
    eafs: bool, // Bit 34: Extended Accessed Flag support
    pss: u5, // Bits 35-39: PASID Size Supported
    pasid: bool, // Bit 40: Process Address Space ID support
    dit: bool, // Bit 41: Device-TLB Invalidation Throttle
    pds: bool, // Bit 42: Page-request Drain support
    smts: bool, // Bit 43: Scalable Mode Translation support
    vcs: bool, // Bit 44: Virtual Command support
    slads: bool, // Bit 45: Second Level Access/Dirty support
    slts: bool, // Bit 46: Second Level Translation support
    flts: bool, // Bit 47: First Level Translation support
    smpwcs: bool, // Bit 48: Scalable-mode Page-walk Coherency support
    rps: bool, // Bit 49: RID-PASID support
    _reserved2: u14 = 0, // Bits 50-63: Reserved

    /// Get IOTLB register offset in bytes
    pub fn getIotlbOffset(self: ExtCapabilityReg) u32 {
        return @as(u32, self.iro) * 16;
    }
};

/// Global Command Register (GCMD) - Offset 0x18
/// Write-only register for issuing global commands
pub const GlobalCmdReg = packed struct(u32) {
    _reserved0: u23 = 0, // Bits 0-22: Reserved
    cfi: bool = false, // Bit 23: Compatibility Format Interrupt
    sirtp: bool = false, // Bit 24: Set Interrupt Remap Table Pointer
    ire: bool = false, // Bit 25: Interrupt Remapping Enable
    qie: bool = false, // Bit 26: Queued Invalidation Enable
    wbf: bool = false, // Bit 27: Write Buffer Flush
    eafl: bool = false, // Bit 28: Enable Advanced Fault Logging
    sfl: bool = false, // Bit 29: Set Fault Log
    srtp: bool = false, // Bit 30: Set Root Table Pointer
    te: bool = false, // Bit 31: Translation Enable
};

/// Global Status Register (GSTS) - Offset 0x1C
/// Read-only register indicating global status
pub const GlobalStsReg = packed struct(u32) {
    _reserved0: u23 = 0, // Bits 0-22: Reserved
    cfis: bool, // Bit 23: Compatibility Format Interrupt Status
    irtps: bool, // Bit 24: Interrupt Remap Table Pointer Status
    ires: bool, // Bit 25: Interrupt Remapping Enable Status
    qies: bool, // Bit 26: Queued Invalidation Enable Status
    wbfs: bool, // Bit 27: Write Buffer Flush Status
    afls: bool, // Bit 28: Advanced Fault Logging Status
    fls: bool, // Bit 29: Fault Log Status
    rtps: bool, // Bit 30: Root Table Pointer Status
    tes: bool, // Bit 31: Translation Enable Status
};

/// Root Table Address Register (RTADDR) - Offset 0x20
/// Specifies the physical address of the root table
pub const RootTableAddrReg = packed struct(u64) {
    _reserved0: u10 = 0, // Bits 0-9: Reserved (address must be 4KB aligned)
    ttm: u2 = 0, // Bits 10-11: Translation Table Mode (0=legacy, 1=scalable)
    rta: u52 = 0, // Bits 12-63: Root Table Address (physical, 4KB aligned)

    /// Set root table physical address (must be 4KB aligned)
    pub fn setAddress(self: *RootTableAddrReg, phys_addr: u64) void {
        self.rta = @truncate(phys_addr >> 12);
    }

    /// Get root table physical address
    pub fn getAddress(self: RootTableAddrReg) u64 {
        return @as(u64, self.rta) << 12;
    }
};

/// Context Command Register (CCMD) - Offset 0x28
/// Used to invalidate context-cache entries
pub const ContextCmdReg = packed struct(u64) {
    did: u16 = 0, // Bits 0-15: Domain ID
    sid: u16 = 0, // Bits 16-31: Source ID (bus:dev:func)
    fm: u2 = 0, // Bits 32-33: Function Mask
    _reserved0: u25 = 0, // Bits 34-58: Reserved
    cirg: u2 = 0, // Bits 59-60: Context Invalidation Request Granularity
    icc: bool = false, // Bit 61: Invalidate Context-Cache
    _reserved1: u2 = 0, // Bits 62-63: Reserved

    pub const Granularity = enum(u2) {
        reserved = 0,
        global = 1, // Global invalidation
        domain = 2, // Domain-selective
        device = 3, // Device-selective
    };
};

/// IOTLB Invalidate Register - Offset varies (ECAP.IRO * 16)
/// Used to invalidate IOTLB entries
pub const IotlbInvReg = packed struct(u64) {
    _reserved0: u32 = 0, // Bits 0-31: Reserved
    did: u16 = 0, // Bits 32-47: Domain ID
    dw: bool = false, // Bit 48: Drain Writes
    dr: bool = false, // Bit 49: Drain Reads
    _reserved1: u7 = 0, // Bits 50-56: Reserved
    iia: bool = false, // Bit 57: Invalidation-desc Address
    _reserved2: u1 = 0, // Bit 58: Reserved
    iirg: u2 = 0, // Bits 59-60: IOTLB Invalidation Request Granularity
    ivt: bool = false, // Bit 61: Invalidate IOTLB
    _reserved3: u2 = 0, // Bits 62-63: Reserved

    pub const Granularity = enum(u2) {
        reserved = 0,
        global = 1, // Global invalidation
        domain = 2, // Domain-selective
        page = 3, // Page-selective
    };
};

/// Fault Status Register (FSTS) - Offset 0x34
/// Reports fault status
pub const FaultStsReg = packed struct(u32) {
    pfo: bool, // Bit 0: Primary Fault Overflow
    ppf: bool, // Bit 1: Primary Pending Fault
    afo: bool, // Bit 2: Advanced Fault Overflow
    apf: bool, // Bit 3: Advanced Pending Fault
    iqe: bool, // Bit 4: Invalidation Queue Error
    ice: bool, // Bit 5: Invalidation Completion Error
    ite: bool, // Bit 6: Invalidation Time-out Error
    pro: bool, // Bit 7: Page Request Overflow
    _reserved0: u8 = 0, // Bits 8-15: Reserved
    fri: u8, // Bits 16-23: Fault Record Index
    _reserved1: u8 = 0, // Bits 24-31: Reserved
};

/// Fault Event Control Register (FECTL) - Offset 0x38
/// Controls fault event signaling
pub const FaultEvtCtrlReg = packed struct(u32) {
    _reserved0: u30 = 0, // Bits 0-29: Reserved
    ip: bool, // Bit 30: Interrupt Pending
    im: bool, // Bit 31: Interrupt Mask
};

/// Fault Recording Register (high 64 bits)
/// Contains fault information
pub const FaultRecordHi = packed struct(u64) {
    sid: u16, // Bits 0-15: Source Identifier (bus:dev:func)
    _reserved0: u12 = 0, // Bits 16-27: Reserved
    t2: bool, // Bit 28: Type bit 2
    _reserved1: u1 = 0, // Bit 29: Reserved
    priv: bool, // Bit 30: Privilege Mode Requested
    exe: bool, // Bit 31: Execute Permission Requested
    pp: bool, // Bit 32: PASID Present
    fr: u8, // Bits 33-40: Fault Reason
    pv: u20, // Bits 41-60: PASID Value
    at: u2, // Bits 61-62: Address Type
    f: bool, // Bit 63: Fault (1=valid fault record)
};

/// Fault Recording Register (low 64 bits)
/// Contains the faulting address
pub const FaultRecordLo = packed struct(u64) {
    _reserved0: u12 = 0, // Bits 0-11: Reserved
    fi: u52, // Bits 12-63: Fault Info (address bits 63:12)

    /// Get the faulting address
    pub fn getFaultAddress(self: FaultRecordLo) u64 {
        return @as(u64, self.fi) << 12;
    }
};

/// Invalidation Queue Address Register (IQA) - Offset 0x90
/// Specifies the base address and size of the invalidation queue
pub const InvQueueAddrReg = packed struct(u64) {
    qs: u3 = 0, // Bits 0-2: Queue Size (2^(qs+8) entries)
    _reserved0: u9 = 0, // Bits 3-11: Reserved
    iqa: u52 = 0, // Bits 12-63: Invalidation Queue Address (4KB aligned)

    /// Set queue base address
    pub fn setAddress(self: *InvQueueAddrReg, phys_addr: u64) void {
        self.iqa = @truncate(phys_addr >> 12);
    }

    /// Get queue base address
    pub fn getAddress(self: InvQueueAddrReg) u64 {
        return @as(u64, self.iqa) << 12;
    }

    /// Get queue size in entries
    pub fn getQueueSize(self: InvQueueAddrReg) u32 {
        const shift: u5 = @as(u5, self.qs) + 8;
        return @as(u32, 1) << shift;
    }
};

/// Interrupt Remapping Table Address Register (IRTA) - Offset 0xB8
pub const IntRemapTableAddrReg = packed struct(u64) {
    s: u4 = 0, // Bits 0-3: Size (2^(s+1) entries)
    _reserved0: u7 = 0, // Bits 4-10: Reserved
    eime: bool = false, // Bit 11: Extended Interrupt Mode Enable
    irta: u52 = 0, // Bits 12-63: Interrupt Remapping Table Address

    /// Set table base address
    pub fn setAddress(self: *IntRemapTableAddrReg, phys_addr: u64) void {
        self.irta = @truncate(phys_addr >> 12);
    }
};

/// Root Entry (for legacy mode translation tables)
/// 128-bit structure, one per bus (256 total in root table)
pub const RootEntry = packed struct(u128) {
    p: bool = false, // Bit 0: Present
    _reserved0: u11 = 0, // Bits 1-11: Reserved
    ctp: u52 = 0, // Bits 12-63: Context Table Pointer (4KB aligned)
    _reserved1: u64 = 0, // Bits 64-127: Reserved (upper root entry for scalable mode)

    /// Set context table pointer
    pub fn setContextTable(self: *RootEntry, phys_addr: u64) void {
        self.ctp = @truncate(phys_addr >> 12);
        self.p = true;
    }

    /// Get context table pointer
    pub fn getContextTable(self: RootEntry) u64 {
        return @as(u64, self.ctp) << 12;
    }

    /// Check if entry is present
    pub fn isPresent(self: RootEntry) bool {
        return self.p;
    }
};

/// Context Entry (for legacy mode translation tables)
/// 128-bit structure, one per device:function (256 per context table)
pub const ContextEntry = packed struct(u128) {
    p: bool = false, // Bit 0: Present
    fpd: bool = false, // Bit 1: Fault Processing Disable
    t: u2 = 0, // Bits 2-3: Translation Type
    _reserved0: u8 = 0, // Bits 4-11: Reserved
    slptptr: u52 = 0, // Bits 12-63: Second Level Page Table Pointer
    aw: u3 = 0, // Bits 64-66: Address Width
    _reserved1: u4 = 0, // Bits 67-70: Reserved (IGN in some versions)
    _reserved2: u1 = 0, // Bit 71: Reserved
    did: u16 = 0, // Bits 72-87: Domain ID
    _reserved3: u40 = 0, // Bits 88-127: Reserved

    pub const TranslationType = enum(u2) {
        untranslated = 0, // Untranslated requests are blocked
        multilevel = 1, // Translated using second-level page table
        pass_through = 2, // Pass-through (identity mapping)
        reserved = 3,
    };

    pub const AddressWidth = enum(u3) {
        agaw_30 = 1, // 3-level (30-bit, 1GB max)
        agaw_39 = 2, // 4-level (39-bit, 512GB max)
        agaw_48 = 3, // 4-level (48-bit, 256TB max)
        agaw_57 = 4, // 5-level (57-bit, 128PB max)
        reserved0 = 0,
        reserved5 = 5,
        reserved6 = 6,
        reserved7 = 7,
    };

    /// Configure context entry for translation
    pub fn configure(
        self: *ContextEntry,
        domain_id: u16,
        page_table_phys: u64,
        addr_width: AddressWidth,
    ) void {
        self.p = true;
        self.t = @intFromEnum(TranslationType.multilevel);
        self.slptptr = @truncate(page_table_phys >> 12);
        self.aw = @intFromEnum(addr_width);
        self.did = domain_id;
    }

    /// Get second-level page table pointer
    pub fn getPageTablePtr(self: ContextEntry) u64 {
        return @as(u64, self.slptptr) << 12;
    }
};

// Compile-time size verification
comptime {
    if (@sizeOf(RootEntry) != 16) @compileError("RootEntry must be 16 bytes");
    if (@sizeOf(ContextEntry) != 16) @compileError("ContextEntry must be 16 bytes");
}
