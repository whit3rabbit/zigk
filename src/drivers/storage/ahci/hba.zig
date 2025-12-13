// AHCI Host Bus Adapter (HBA) Generic Registers
//
// Defines the memory-mapped register layout at the base of AHCI memory.
// The HBA generic registers control overall controller behavior and
// provide capability information.
//
// Memory Layout:
//   0x00-0x2B  - Generic Host Control registers
//   0x2C-0x9F  - Reserved
//   0xA0-0xFF  - Vendor-specific registers
//   0x100+     - Port registers (0x80 bytes per port)
//
// Reference: AHCI Specification 1.3.1, Section 3.1

const std = @import("std");

// ============================================================================
// Register Offsets
// ============================================================================

pub const Regs = struct {
    pub const CAP: usize = 0x00; // HBA Capabilities
    pub const GHC: usize = 0x04; // Global HBA Control
    pub const IS: usize = 0x08; // Interrupt Status
    pub const PI: usize = 0x0C; // Ports Implemented
    pub const VS: usize = 0x10; // AHCI Version
    pub const CCC_CTL: usize = 0x14; // Command Completion Coalescing Control
    pub const CCC_PORTS: usize = 0x18; // CCC Ports
    pub const EM_LOC: usize = 0x1C; // Enclosure Management Location
    pub const EM_CTL: usize = 0x20; // Enclosure Management Control
    pub const CAP2: usize = 0x24; // HBA Capabilities Extended
    pub const BOHC: usize = 0x28; // BIOS/OS Handoff Control

    // Port registers start at offset 0x100
    pub const PORT_BASE: usize = 0x100;
    pub const PORT_SIZE: usize = 0x80; // 128 bytes per port
};

// ============================================================================
// HBA Capabilities Register (CAP)
// ============================================================================

/// HBA Capabilities (32-bit, read-only)
pub const HbaCap = packed struct(u32) {
    /// Number of Ports (0-based, actual = NP + 1)
    np: u5, // Bits 4:0

    /// Supports External SATA
    sxs: bool, // Bit 5

    /// Enclosure Management Supported
    ems: bool, // Bit 6

    /// Command Completion Coalescing Supported
    cccs: bool, // Bit 7

    /// Number of Command Slots (0-based, actual = NCS + 1)
    ncs: u5, // Bits 12:8

    /// Partial State Capable
    psc: bool, // Bit 13

    /// Slumber State Capable
    ssc: bool, // Bit 14

    /// PIO Multiple DRQ Block
    pmd: bool, // Bit 15

    /// FIS-based Switching Supported
    fbss: bool, // Bit 16

    /// Supports Port Multiplier
    spm: bool, // Bit 17

    /// Supports AHCI Mode Only (no legacy IDE)
    sam: bool, // Bit 18

    /// Reserved
    _reserved0: u1 = 0, // Bit 19

    /// Interface Speed Support (1=Gen1, 2=Gen2, 3=Gen3)
    iss: u4, // Bits 23:20

    /// Supports Command List Override
    sclo: bool, // Bit 24

    /// Supports Activity LED
    sal: bool, // Bit 25

    /// Supports Aggressive Link Power Management
    salp: bool, // Bit 26

    /// Supports Staggered Spin-up
    sss: bool, // Bit 27

    /// Supports Mechanical Presence Switch
    smps: bool, // Bit 28

    /// Supports SNotification Register
    ssntf: bool, // Bit 29

    /// Supports Native Command Queuing
    sncq: bool, // Bit 30

    /// Supports 64-bit Addressing
    s64a: bool, // Bit 31

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("HbaCap must be 4 bytes");
    }

    /// Get actual number of ports (1-32)
    pub fn numPorts(self: HbaCap) u8 {
        return @as(u8, self.np) + 1;
    }

    /// Get actual number of command slots (1-32)
    pub fn numCommandSlots(self: HbaCap) u8 {
        return @as(u8, self.ncs) + 1;
    }

    /// Get interface speed as string
    pub fn speedString(self: HbaCap) []const u8 {
        return switch (self.iss) {
            1 => "Gen1 (1.5 Gbps)",
            2 => "Gen2 (3.0 Gbps)",
            3 => "Gen3 (6.0 Gbps)",
            else => "Unknown",
        };
    }
};

// ============================================================================
// Global HBA Control Register (GHC)
// ============================================================================

/// Global HBA Control (32-bit, read-write)
pub const HbaGhc = packed struct(u32) {
    /// HBA Reset (write 1 to reset, self-clearing)
    hr: bool, // Bit 0

    /// Interrupt Enable
    ie: bool, // Bit 1

    /// MSI Revert to Single Message (read-only)
    mrsm: bool, // Bit 2

    /// Reserved
    _reserved: u28 = 0, // Bits 30:3

    /// AHCI Enable (must be set for AHCI operation)
    ae: bool, // Bit 31

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("HbaGhc must be 4 bytes");
    }
};

// ============================================================================
// HBA Capabilities Extended Register (CAP2)
// ============================================================================

/// HBA Capabilities Extended (32-bit, read-only)
pub const HbaCap2 = packed struct(u32) {
    /// BIOS/OS Handoff Supported
    boh: bool, // Bit 0

    /// NVMHCI Present
    nvmp: bool, // Bit 1

    /// Automatic Partial to Slumber Transitions
    apst: bool, // Bit 2

    /// Supports Device Sleep
    sds: bool, // Bit 3

    /// Supports Aggressive Device Sleep Management
    sadm: bool, // Bit 4

    /// DevSleep Entrance from Slumber Only
    deso: bool, // Bit 5

    /// Reserved
    _reserved: u26 = 0, // Bits 31:6

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("HbaCap2 must be 4 bytes");
    }
};

// ============================================================================
// BIOS/OS Handoff Control Register (BOHC)
// ============================================================================

/// BIOS/OS Handoff Control (32-bit, read-write)
pub const HbaBohc = packed struct(u32) {
    /// BIOS Owned Semaphore
    bos: bool, // Bit 0

    /// OS Owned Semaphore
    oos: bool, // Bit 1

    /// SMI on OS Ownership Change Enable
    sooe: bool, // Bit 2

    /// OS Ownership Change
    ooc: bool, // Bit 3

    /// BIOS Busy
    bb: bool, // Bit 4

    /// Reserved
    _reserved: u27 = 0, // Bits 31:5

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("HbaBohc must be 4 bytes");
    }
};

// ============================================================================
// AHCI Version Register
// ============================================================================

/// AHCI Version (32-bit, read-only)
pub const HbaVersion = packed struct(u32) {
    /// Minor version number
    minor: u16, // Bits 15:0

    /// Major version number
    major: u16, // Bits 31:16

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("HbaVersion must be 4 bytes");
    }

    /// Format version as "major.minor" string representation
    pub fn majorNum(self: HbaVersion) u16 {
        return self.major;
    }

    pub fn minorNum(self: HbaVersion) u16 {
        return self.minor;
    }
};

// ============================================================================
// PCI Configuration
// ============================================================================

/// AHCI controller PCI class/subclass/prog-if for identification
pub const PciClass = struct {
    pub const CLASS: u8 = 0x01; // Mass Storage Controller
    pub const SUBCLASS: u8 = 0x06; // SATA Controller
    pub const PROG_IF_AHCI: u8 = 0x01; // AHCI 1.0
};

/// Get AHCI BAR (always BAR5 for AHCI controllers)
pub const ABAR_INDEX: u3 = 5;

// ============================================================================
// HBA Memory Register Access
// ============================================================================

/// Read a 32-bit HBA register
pub fn read32(base: u64, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

/// Write a 32-bit HBA register
pub fn write32(base: u64, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
}

/// Read HBA Capabilities
pub fn readCap(base: u64) HbaCap {
    return @bitCast(read32(base, Regs.CAP));
}

/// Read Global HBA Control
pub fn readGhc(base: u64) HbaGhc {
    return @bitCast(read32(base, Regs.GHC));
}

/// Write Global HBA Control
pub fn writeGhc(base: u64, ghc: HbaGhc) void {
    write32(base, Regs.GHC, @bitCast(ghc));
}

/// Read Ports Implemented bitmap
pub fn readPortsImplemented(base: u64) u32 {
    return read32(base, Regs.PI);
}

/// Read AHCI Version
pub fn readVersion(base: u64) HbaVersion {
    return @bitCast(read32(base, Regs.VS));
}

/// Read HBA Capabilities Extended
pub fn readCap2(base: u64) HbaCap2 {
    return @bitCast(read32(base, Regs.CAP2));
}

/// Read BIOS/OS Handoff Control
pub fn readBohc(base: u64) HbaBohc {
    return @bitCast(read32(base, Regs.BOHC));
}

/// Write BIOS/OS Handoff Control
pub fn writeBohc(base: u64, bohc: HbaBohc) void {
    write32(base, Regs.BOHC, @bitCast(bohc));
}

/// Read Interrupt Status (global)
pub fn readInterruptStatus(base: u64) u32 {
    return read32(base, Regs.IS);
}

/// Write Interrupt Status (write 1 to clear)
pub fn clearInterruptStatus(base: u64, mask: u32) void {
    write32(base, Regs.IS, mask);
}
