// E1000e Descriptor Structures
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet (316080)

/// Legacy RX Descriptor (16 bytes)
/// Reference: 82574L Datasheet Section 3.2.3
pub const RxDesc = extern struct {
    buffer_addr: u64, // Physical address of receive buffer
    length: u16, // Received packet length
    checksum: u16, // Packet checksum
    status: u8, // Status bits
    errors: u8, // Error bits
    special: u16, // VLAN tag

    pub const STATUS_DD: u8 = 1 << 0; // Descriptor Done
    pub const STATUS_EOP: u8 = 1 << 1; // End of Packet

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("RxDesc must be 16 bytes");
    }
};

/// RX Descriptor Error bits
/// Reference: 82574L Datasheet Section 3.2.3.2
pub const RXERR = struct {
    pub const CE: u8 = 1 << 0; // CRC Error or Alignment Error
    pub const SE: u8 = 1 << 1; // Symbol Error (invalid symbol)
    pub const SEQ: u8 = 1 << 2; // Sequence Error
    pub const RSV: u8 = 1 << 3; // Reserved
    pub const CXE: u8 = 1 << 4; // Carrier Extension Error
    pub const TCPE: u8 = 1 << 5; // TCP/UDP Checksum Error
    pub const IPE: u8 = 1 << 6; // IP Checksum Error
    pub const RXE: u8 = 1 << 7; // RX Data Error (FIFO overrun)
};

/// Legacy TX Descriptor (16 bytes)
/// Reference: 82574L Datasheet Section 3.3.3
pub const TxDesc = extern struct {
    buffer_addr: u64, // Physical address of transmit buffer
    length: u16, // Packet length
    cso: u8, // Checksum Offset
    cmd: u8, // Command bits
    status: u8, // Status bits
    css: u8, // Checksum Start
    special: u16, // VLAN tag

    pub const CMD_EOP: u8 = 1 << 0; // End of Packet
    pub const CMD_IFCS: u8 = 1 << 1; // Insert FCS/CRC
    pub const CMD_IC: u8 = 1 << 2; // Insert Checksum
    pub const CMD_RS: u8 = 1 << 3; // Report Status
    pub const STATUS_DD: u8 = 1 << 0; // Descriptor Done

    comptime {
        if (@sizeOf(@This()) != 16) @compileError("TxDesc must be 16 bytes");
    }
};
