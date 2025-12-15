// E1000e Register Definitions (MMIO offsets)
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet (316080)

/// E1000e MMIO register offsets as enum for use with MmioDevice.
/// Using enum enables compile-time offset validation and typo detection.
pub const Reg = enum(u64) {
    // Device Control
    ctrl = 0x0000, // Device Control
    status = 0x0008, // Device Status
    ctrl_ext = 0x0018, // Extended Device Control

    // EEPROM
    eerd = 0x0014, // EEPROM Read

    // Interrupt
    icr = 0x00C0, // Interrupt Cause Read
    itr = 0x00C4, // Interrupt Throttle Rate
    ics = 0x00C8, // Interrupt Cause Set
    ims = 0x00D0, // Interrupt Mask Set
    imc = 0x00D8, // Interrupt Mask Clear

    // Receive
    rctl = 0x0100, // Receive Control
    rdbal = 0x2800, // RX Descriptor Base Low
    rdbah = 0x2804, // RX Descriptor Base High
    rdlen = 0x2808, // RX Descriptor Length
    rdh = 0x2810, // RX Descriptor Head
    rdt = 0x2818, // RX Descriptor Tail
    rdtr = 0x2820, // RX Delay Timer
    radv = 0x282C, // RX Interrupt Absolute Delay

    // Receive Checksum Control
    rxcsum = 0x5000, // Receive Checksum Control

    // Transmit
    tctl = 0x0400, // Transmit Control
    tipg = 0x0410, // TX Inter-Packet Gap
    tdbal = 0x3800, // TX Descriptor Base Low
    tdbah = 0x3804, // TX Descriptor Base High
    tdlen = 0x3808, // TX Descriptor Length
    tdh = 0x3810, // TX Descriptor Head
    tdt = 0x3818, // TX Descriptor Tail
    txdctl = 0x3828, // TX Descriptor Control
    tadv = 0x382C, // TX Interrupt Absolute Delay

    // Statistics
    mpc = 0x4010, // Missed Packets Count (cleared on read)

    // Receive Address (MAC)
    ral0 = 0x5400, // Receive Address Low (MAC bytes 0-3)
    rah0 = 0x5404, // Receive Address High (MAC bytes 4-5)

    // MSI-X Registers (82574L specific)
    ivar = 0x00E4, // Interrupt Vector Allocation
    eitr0 = 0x00E8, // Extended Interrupt Throttle Rate 0
    eitr1 = 0x00EC, // Extended Interrupt Throttle Rate 1
    eitr2 = 0x00F0, // Extended Interrupt Throttle Rate 2
    eims = 0x00D4, // Extended Interrupt Mask Set (read-only set)
    // Note: EIAC/EIAM/EIMC share offsets with legacy interrupt registers
    // Use legacy IMC (0x00D8) for interrupt mask clear

    // Note: MTA_BASE (0x5200) is an array base, use MTA_BASE constant below
};

/// Multicast Table Array base (128 entries, 4 bytes each)
/// Use with MmioDevice.readRaw/writeRaw for indexed access
pub const MTA_BASE: u64 = 0x5200;

/// Device Status Register bits
/// Reference: 82574L Datasheet Section 13.4.2
pub const STATUS = struct {
    pub const FD: u32 = 1 << 0; // Full Duplex indication
    pub const LU: u32 = 1 << 1; // Link Up indication
    pub const SPEED_SHIFT: u5 = 6; // Speed bits [7:6]
    pub const SPEED_MASK: u32 = 0b11 << 6;
    // Speed values: 00=10Mb/s, 01=100Mb/s, 10=1000Mb/s, 11=reserved
};

/// Interrupt bits (legacy constants)
pub const INT = struct {
    pub const TXDW: u32 = 1 << 0; // TX Descriptor Written Back
    pub const TXQE: u32 = 1 << 1; // TX Queue Empty
    pub const LSC: u32 = 1 << 2; // Link Status Change
    pub const RXSEQ: u32 = 1 << 3; // RX Sequence Error
    pub const RXDMT0: u32 = 1 << 4; // RX Descriptor Min Threshold
    pub const RXO: u32 = 1 << 6; // RX Overrun
    pub const RXT0: u32 = 1 << 7; // RX Timer Interrupt
};

/// Receive Checksum Control bits
pub const RXCSUM = struct {
    pub const IPOFL: u32 = 1 << 8; // IP Checksum Offload Enable
    pub const TUOFL: u32 = 1 << 9; // TCP/UDP Checksum Offload Enable
};
