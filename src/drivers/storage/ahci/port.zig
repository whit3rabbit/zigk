// AHCI Port Registers
//
// Each AHCI port has 128 bytes (0x80) of registers starting at:
//   HBA_BASE + 0x100 + (port_number * 0x80)
//
// Port registers control individual SATA ports including:
// - Command list and FIS receive buffers
// - Device detection and interface control
// - SATA status (speed, device presence)
// - Command execution
//
// Reference: AHCI Specification 1.3.1, Section 3.3

const std = @import("std");
const hal = @import("hal");
const hba = @import("hba.zig");
const fis = @import("fis.zig");
const MmioDevice = hal.mmio_device.MmioDevice;

const term = @import("std").os.linux; // Not used here directly but good practice to keep std imports clean
// We need assembly for memory barriers
fn memoryBarrier() void {
    hal.mmio.memoryBarrier();
}

const timing = hal.timing;

// Port Timeout Constants (milliseconds)
// Based on Linux kernel libahci.c best practices
const ENGINE_STOP_MS: u32 = 1000; // CR/FR clear timeout (Linux uses 500-1000ms)
const DEVICE_DETECT_MS: u32 = 2000; // PHY establishment (2s for slow devices)
const POST_RESET_MS: u32 = 150; // Post-reset stability delay

// ============================================================================
// Port Register Offsets (relative to port base)
// ============================================================================

pub const PortReg = enum(usize) {
    clb = 0x00, // Command List Base Address (low)
    clbu = 0x04, // Command List Base Address (high)
    fb = 0x08, // FIS Base Address (low)
    fbu = 0x0C, // FIS Base Address (high)
    is = 0x10, // Interrupt Status
    ie = 0x14, // Interrupt Enable
    cmd = 0x18, // Command and Status
    tfd = 0x20, // Task File Data
    sig = 0x24, // Signature
    ssts = 0x28, // SATA Status (SCR0)
    sctl = 0x2C, // SATA Control (SCR2)
    serr = 0x30, // SATA Error (SCR1)
    sact = 0x34, // SATA Active
    ci = 0x38, // Command Issue
    sntf = 0x3C, // SNotification
    fbs = 0x40, // FIS-based Switching Control
    devslp = 0x44, // Device Sleep
};

const PortDevice = MmioDevice(PortReg);

// ============================================================================
// Port Command Register (CMD)
// ============================================================================

/// Port Command and Status Register (32-bit)
pub const PortCmd = packed struct(u32) {
    /// Start (command processing enabled)
    st: bool, // Bit 0

    /// Spin-Up Device
    sud: bool, // Bit 1

    /// Power On Device
    pod: bool, // Bit 2

    /// Command List Override
    clo: bool, // Bit 3

    /// FIS Receive Enable
    fre: bool, // Bit 4

    /// Reserved
    _reserved0: u3 = 0, // Bits 7:5

    /// Current Command Slot (read-only)
    ccs: u5, // Bits 12:8

    /// Mechanical Presence Switch State (read-only)
    mpss: bool, // Bit 13

    /// FIS Receive Running (read-only)
    fr: bool, // Bit 14

    /// Command List Running (read-only)
    cr: bool, // Bit 15

    /// Cold Presence State (read-only)
    cps: bool, // Bit 16

    /// Port Multiplier Attached
    pma: bool, // Bit 17

    /// Hot Plug Capable (read-only)
    hpcp: bool, // Bit 18

    /// Mechanical Presence Switch Attached (read-only)
    mpsp: bool, // Bit 19

    /// Cold Presence Detection (read-only)
    cpd: bool, // Bit 20

    /// External SATA Port
    esp: bool, // Bit 21

    /// FIS-based Switching Capable Port (read-only)
    fbscp: bool, // Bit 22

    /// Automatic Partial to Slumber Transitions Enabled
    apste: bool, // Bit 23

    /// ATAPI Device
    atapi: bool, // Bit 24

    /// Drive LED on ATAPI Enable
    dlae: bool, // Bit 25

    /// Aggressive Link Power Management Enable
    alpe: bool, // Bit 26

    /// Aggressive Slumber / Partial
    asp: bool, // Bit 27

    /// Interface Communication Control (0=idle, 1=active, 2=partial, 6=slumber)
    icc: u4, // Bits 31:28

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("PortCmd must be 4 bytes");
    }
};

// ============================================================================
// Port Interrupt Status/Enable Registers
// ============================================================================

/// Port Interrupt Status/Enable bits
pub const PortInterrupt = packed struct(u32) {
    /// Device to Host Register FIS Interrupt
    dhrs: bool, // Bit 0

    /// PIO Setup FIS Interrupt
    pss: bool, // Bit 1

    /// DMA Setup FIS Interrupt
    dss: bool, // Bit 2

    /// Set Device Bits Interrupt
    sdbs: bool, // Bit 3

    /// Unknown FIS Interrupt
    ufs: bool, // Bit 4

    /// Descriptor Processed
    dps: bool, // Bit 5

    /// Port Connect Change Status
    pcs: bool, // Bit 6

    /// Device Mechanical Presence Status
    dmps: bool, // Bit 7

    /// Reserved
    _reserved0: u14 = 0, // Bits 21:8

    /// PhyRdy Change Status
    prcs: bool, // Bit 22

    /// Incorrect Port Multiplier Status
    ipms: bool, // Bit 23

    /// Overflow Status
    ofs: bool, // Bit 24

    /// Reserved
    _reserved1: u1 = 0, // Bit 25

    /// Interface Non-fatal Error Status
    infs: bool, // Bit 26

    /// Interface Fatal Error Status
    ifs: bool, // Bit 27

    /// Host Bus Data Error Status
    hbds: bool, // Bit 28

    /// Host Bus Fatal Error Status
    hbfs: bool, // Bit 29

    /// Task File Error Status
    tfes: bool, // Bit 30

    /// Cold Port Detect Status
    cpds: bool, // Bit 31

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("PortInterrupt must be 4 bytes");
    }

    /// Check if any error bits are set
    pub fn hasError(self: PortInterrupt) bool {
        return self.ifs or self.hbds or self.hbfs or self.tfes or self.infs;
    }
};

// ============================================================================
// SATA Status Register (SSTS)
// ============================================================================

/// SATA Status Register (SCR0)
pub const SataStatus = packed struct(u32) {
    /// Device Detection (DET)
    det: u4, // Bits 3:0

    /// Current Interface Speed (SPD)
    spd: u4, // Bits 7:4

    /// Interface Power Management (IPM)
    ipm: u4, // Bits 11:8

    /// Reserved
    _reserved: u20 = 0, // Bits 31:12

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("SataStatus must be 4 bytes");
    }

    /// Device detection states
    pub const DetState = enum(u4) {
        no_device = 0, // No device detected
        present_no_phy = 1, // Device present, no PHY communication
        present_phy = 3, // Device present and PHY established
        phy_offline = 4, // PHY in offline mode
        _,
    };

    /// Get device detection state
    pub fn detState(self: SataStatus) DetState {
        return @enumFromInt(self.det);
    }

    /// Check if device is present and communication established
    pub fn isConnected(self: SataStatus) bool {
        return self.det == 3 and self.ipm == 1;
    }

    /// Get interface speed string
    pub fn speedString(self: SataStatus) []const u8 {
        return switch (self.spd) {
            0 => "No device",
            1 => "Gen1 (1.5 Gbps)",
            2 => "Gen2 (3.0 Gbps)",
            3 => "Gen3 (6.0 Gbps)",
            else => "Unknown",
        };
    }
};

// ============================================================================
// SATA Control Register (SCTL)
// ============================================================================

/// SATA Control Register (SCR2)
pub const SataControl = packed struct(u32) {
    /// Device Detection Initialization (DET)
    det: u4, // Bits 3:0

    /// Speed Allowed (SPD)
    spd: u4, // Bits 7:4

    /// Interface Power Management Transitions Disabled (IPM)
    ipm: u4, // Bits 11:8

    /// Reserved
    _reserved: u20 = 0, // Bits 31:12

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("SataControl must be 4 bytes");
    }
};

// ============================================================================
// Task File Data Register
// ============================================================================

/// Task File Data (read-only)
pub const TaskFileData = packed struct(u32) {
    /// Status register
    status: u8, // Bits 7:0

    /// Error register
    err: u8, // Bits 15:8

    /// Reserved
    _reserved: u16 = 0, // Bits 31:16

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("TaskFileData must be 4 bytes");
    }

    /// Check if device is busy
    pub fn isBusy(self: TaskFileData) bool {
        return (self.status & fis.AtaStatus.BSY) != 0;
    }

    /// Check if DRQ is set
    pub fn isDrq(self: TaskFileData) bool {
        return (self.status & fis.AtaStatus.DRQ) != 0;
    }

    /// Check if error occurred
    pub fn hasError(self: TaskFileData) bool {
        return (self.status & fis.AtaStatus.ERR) != 0 or
            (self.status & fis.AtaStatus.DF) != 0;
    }
};

// ============================================================================
// Device Signature
// ============================================================================

/// Device signature values (from Signature register after reset)
pub const DeviceSignature = enum(u32) {
    ata = 0x00000101, // ATA (disk)
    atapi = 0xEB140101, // ATAPI (CD/DVD)
    semb = 0xC33C0101, // Enclosure Management Bridge
    port_multiplier = 0x96690101, // Port Multiplier
    _,
};

// ============================================================================
// Port Register Access
// ============================================================================

/// Calculate port base address
pub fn portBase(hba_base: u64, port_num: u5) u64 {
    return hba_base + hba.Regs.PORT_BASE + (@as(u64, port_num) * hba.Regs.PORT_SIZE);
}
// Note: MmioDevice replaces raw read32/write32. We implement wrappers for compatibility.

// ============================================================================
// Port Register Accessors
// ============================================================================

/// Read Command List Base address
pub fn readClb(base: u64) u64 {
    const dev = PortDevice.init(base, 0x80);
    const lo = dev.read(.clb);
    const hi = dev.read(.clbu);
    return (@as(u64, hi) << 32) | lo;
}

/// Write Command List Base address
pub fn writeClb(base: u64, addr: u64) void {
    const dev = PortDevice.init(base, 0x80);
    dev.write(.clb, @truncate(addr));
    dev.write(.clbu, @truncate(addr >> 32));
}

/// Read FIS Base address
pub fn readFb(base: u64) u64 {
    const dev = PortDevice.init(base, 0x80);
    const lo = dev.read(.fb);
    const hi = dev.read(.fbu);
    return (@as(u64, hi) << 32) | lo;
}

/// Write FIS Base address
pub fn writeFb(base: u64, addr: u64) void {
    const dev = PortDevice.init(base, 0x80);
    dev.write(.fb, @truncate(addr));
    dev.write(.fbu, @truncate(addr >> 32));
}

/// Read Port Command register
pub fn readCmd(base: u64) PortCmd {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.cmd, PortCmd);
}

/// Write Port Command register
pub fn writeCmd(base: u64, cmd: PortCmd) void {
    const dev = PortDevice.init(base, 0x80);
    dev.writeTyped(.cmd, cmd);
}

/// Read Interrupt Status
pub fn readIs(base: u64) PortInterrupt {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.is, PortInterrupt);
}

/// Clear Interrupt Status (write 1 to clear)
pub fn clearIs(base: u64, mask: PortInterrupt) void {
    const dev = PortDevice.init(base, 0x80);
    dev.writeTyped(.is, mask);
}

/// Read Interrupt Enable
pub fn readIe(base: u64) PortInterrupt {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.ie, PortInterrupt);
}

/// Write Interrupt Enable
pub fn writeIe(base: u64, ie: PortInterrupt) void {
    const dev = PortDevice.init(base, 0x80);
    dev.writeTyped(.ie, ie);
}

/// Read Task File Data
pub fn readTfd(base: u64) TaskFileData {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.tfd, TaskFileData);
}

/// Read Device Signature
pub fn readSig(base: u64) DeviceSignature {
    const dev = PortDevice.init(base, 0x80);
    return @enumFromInt(dev.read(.sig));
}

/// Read SATA Status
pub fn readSsts(base: u64) SataStatus {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.ssts, SataStatus);
}

/// Read SATA Control
pub fn readSctl(base: u64) SataControl {
    const dev = PortDevice.init(base, 0x80);
    return dev.readTyped(.sctl, SataControl);
}

/// Write SATA Control
pub fn writeSctl(base: u64, sctl: SataControl) void {
    const dev = PortDevice.init(base, 0x80);
    dev.writeTyped(.sctl, sctl);
}

/// Read SATA Error (write 1 to clear)
pub fn readSerr(base: u64) u32 {
    const dev = PortDevice.init(base, 0x80);
    return dev.read(.serr);
}

/// Clear SATA Error
pub fn clearSerr(base: u64, mask: u32) void {
    const dev = PortDevice.init(base, 0x80);
    dev.write(.serr, mask);
}

/// Read SATA Active (NCQ tags)
pub fn readSact(base: u64) u32 {
    const dev = PortDevice.init(base, 0x80);
    return dev.read(.sact);
}

/// Write SATA Active
pub fn writeSact(base: u64, tags: u32) void {
    const dev = PortDevice.init(base, 0x80);
    dev.write(.sact, tags);
}

/// Read Command Issue
pub fn readCi(base: u64) u32 {
    const dev = PortDevice.init(base, 0x80);
    return dev.read(.ci);
}

/// Write Command Issue (issue commands)
pub fn writeCi(base: u64, slots: u32) void {
    const dev = PortDevice.init(base, 0x80);
    dev.write(.ci, slots);
}

// ============================================================================
// Port Control Functions
// ============================================================================

/// Stop port command engine
/// Clears ST, waits for CR to clear, then clears FRE and waits for FR to clear
pub fn stopEngine(base: u64) bool {
    var cmd = readCmd(base);

    // Clear ST
    cmd.st = false;
    // Clear ST
    cmd.st = false;
    writeCmd(base, cmd);
    memoryBarrier();

    // Wait for CR to clear (1s timeout per Linux kernel)
    var timeout_ms: u32 = ENGINE_STOP_MS;
    while (timeout_ms > 0) : (timeout_ms -= 1) {
        cmd = readCmd(base);
        if (!cmd.cr) break;
        hal.timing.delayUs(1000);
    }

    if (cmd.cr) {
        return false; // Timeout waiting for CR
    }

    // Clear FRE
    cmd.fre = false;
    // Clear FRE
    cmd.fre = false;
    writeCmd(base, cmd);
    memoryBarrier();

    // Wait for FR to clear (1s timeout)
    timeout_ms = ENGINE_STOP_MS;
    while (timeout_ms > 0) : (timeout_ms -= 1) {
        cmd = readCmd(base);
        if (!cmd.fr) break;
        hal.timing.delayUs(1000);
    }

    return !cmd.fr;
}

/// Start port command engine
/// Sets FRE, then ST
pub fn startEngine(base: u64) void {
    // Wait for CR to be clear before starting (1s timeout)
    var timeout_ms: u32 = ENGINE_STOP_MS;
    while (timeout_ms > 0) : (timeout_ms -= 1) {
        const cmd = readCmd(base);
        if (!cmd.cr) break;
        hal.timing.delayUs(1000);
    }

    var cmd = readCmd(base);
    cmd.fre = true;
    writeCmd(base, cmd);
    memoryBarrier();

    cmd = readCmd(base);
    cmd.st = true;
    writeCmd(base, cmd);
    memoryBarrier();
}

/// Perform a port reset (COMRESET)
pub fn portReset(base: u64) bool {
    // Set DET to 1 for COMRESET
    var sctl = readSctl(base);
    sctl.det = 1;
    writeSctl(base, sctl);

    // Wait at least 1ms for COMRESET to be delivered
    hal.timing.delayUs(1000);

    // Clear DET to return to normal operation
    sctl.det = 0;
    writeSctl(base, sctl);

    // Wait for device detection (2s timeout for slow devices per Linux kernel)
    var timeout_ms: u32 = DEVICE_DETECT_MS;
    while (timeout_ms > 0) : (timeout_ms -= 1) {
        const ssts = readSsts(base);
        if (ssts.det == 3) {
            // Device present and PHY established
            // Critical: wait 150ms after reset for device stability (Linux kernel best practice)
            hal.timing.delayMs(POST_RESET_MS);
            return true;
        }
        hal.timing.delayUs(1000);
    }

    return false;
}

/// Wait for device to become ready (BSY and DRQ clear)
pub fn waitReady(base: u64, timeout_us: u32) bool {
    var remaining = timeout_us;
    while (remaining > 0) {
        const tfd = readTfd(base);
        if (!tfd.isBusy() and !tfd.isDrq()) {
            return true;
        }
        hal.timing.delayUs(10);
        if (remaining >= 10) remaining -= 10 else remaining = 0;
    }
    return false;
}
