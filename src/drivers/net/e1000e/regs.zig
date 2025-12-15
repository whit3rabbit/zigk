// E1000e Register Definitions (MMIO offsets)
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet (316080)

/// E1000e MMIO register offsets
pub const Reg = struct {
    // Device Control
    pub const CTRL: u64 = 0x0000; // Device Control
    pub const STATUS: u64 = 0x0008; // Device Status
    pub const CTRL_EXT: u64 = 0x0018; // Extended Device Control

    // EEPROM
    pub const EERD: u64 = 0x0014; // EEPROM Read

    // Interrupt
    pub const ICR: u64 = 0x00C0; // Interrupt Cause Read
    pub const ITR: u64 = 0x00C4; // Interrupt Throttle Rate
    pub const ICS: u64 = 0x00C8; // Interrupt Cause Set
    pub const IMS: u64 = 0x00D0; // Interrupt Mask Set
    pub const IMC: u64 = 0x00D8; // Interrupt Mask Clear

    // Receive
    pub const RCTL: u64 = 0x0100; // Receive Control
    pub const RDBAL: u64 = 0x2800; // RX Descriptor Base Low
    pub const RDBAH: u64 = 0x2804; // RX Descriptor Base High
    pub const RDLEN: u64 = 0x2808; // RX Descriptor Length
    pub const RDH: u64 = 0x2810; // RX Descriptor Head
    pub const RDT: u64 = 0x2818; // RX Descriptor Tail
    pub const RDTR: u64 = 0x2820; // RX Delay Timer
    pub const RADV: u64 = 0x282C; // RX Interrupt Absolute Delay

    // Receive Checksum Control
    pub const RXCSUM: u64 = 0x5000; // Receive Checksum Control

    // Transmit
    pub const TCTL: u64 = 0x0400; // Transmit Control
    pub const TIPG: u64 = 0x0410; // TX Inter-Packet Gap
    pub const TDBAL: u64 = 0x3800; // TX Descriptor Base Low
    pub const TDBAH: u64 = 0x3804; // TX Descriptor Base High
    pub const TDLEN: u64 = 0x3808; // TX Descriptor Length
    pub const TDH: u64 = 0x3810; // TX Descriptor Head
    pub const TDT: u64 = 0x3818; // TX Descriptor Tail
    pub const TXDCTL: u64 = 0x3828; // TX Descriptor Control
    pub const TADV: u64 = 0x382C; // TX Interrupt Absolute Delay

    // Statistics
    pub const MPC: u64 = 0x4010; // Missed Packets Count (cleared on read)

    // Receive Address (MAC)
    pub const RAL0: u64 = 0x5400; // Receive Address Low (MAC bytes 0-3)
    pub const RAH0: u64 = 0x5404; // Receive Address High (MAC bytes 4-5)

    // Multicast Table Array
    pub const MTA_BASE: u64 = 0x5200; // Multicast Table Array (128 entries)

    // MSI-X Registers (82574L specific)
    pub const IVAR: u64 = 0x00E4; // Interrupt Vector Allocation
    pub const EITR0: u64 = 0x00E8; // Extended Interrupt Throttle Rate 0
    pub const EITR1: u64 = 0x00EC; // Extended Interrupt Throttle Rate 1
    pub const EITR2: u64 = 0x00F0; // Extended Interrupt Throttle Rate 2
    pub const EIAC: u64 = 0x00DC; // Extended Interrupt Auto Clear
    pub const EIAM: u64 = 0x00E0; // Extended Interrupt Auto Mask
    pub const EICS: u64 = 0x00E8; // Extended Interrupt Cause Set
    pub const EIMS: u64 = 0x00D4; // Extended Interrupt Mask Set (read-only set)
    pub const EIMC: u64 = 0x00D8; // Extended Interrupt Mask Clear (write-only clear)
};

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
