// E1000e Control Register Packed Structs
//
// Reference: Intel 82574L Gigabit Ethernet Controller Datasheet (316080)

/// Device Control Register (CTRL) bit layout
/// Reference: 82574L Datasheet Section 13.4.1
pub const DeviceCtl = packed struct(u32) {
    full_duplex: bool = false, // Bit 0: FD
    _reserved_1_2: u2 = 0, // Bits 1-2: Reserved
    link_reset: bool = false, // Bit 3: LRST
    _reserved_4: bool = false, // Bit 4: Reserved
    auto_speed_detect: bool = false, // Bit 5: ASDE
    set_link_up: bool = false, // Bit 6: SLU
    invert_loss_of_signal: bool = false, // Bit 7: ILOS
    speed_selection: u2 = 0, // Bits 8-9: Speed selection
    _reserved_10: bool = false, // Bit 10: Reserved
    force_speed: bool = false, // Bit 11: Force Speed
    force_duplex: bool = false, // Bit 12: Force Duplex
    _reserved_13_17: u5 = 0, // Bits 13-17: Reserved
    sdp0_data: bool = false, // Bit 18: SDP0 Data
    sdp1_data: bool = false, // Bit 19: SDP1 Data
    sdp0_iodir: bool = false, // Bit 20: SDP0 I/O Direction
    sdp1_iodir: bool = false, // Bit 21: SDP1 I/O Direction
    _reserved_22_25: u4 = 0, // Bits 22-25: Reserved
    device_reset: bool = false, // Bit 26: RST
    rx_flow_control: bool = false, // Bit 27: RFCE
    tx_flow_control: bool = false, // Bit 28: TFCE
    _reserved_29: bool = false, // Bit 29: Reserved
    vlan_mode: bool = false, // Bit 30: VME
    phy_reset: bool = false, // Bit 31: PHY_RST

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("DeviceCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) DeviceCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: DeviceCtl) u32 {
        return @bitCast(self);
    }
};

/// Receive Control Register (RCTL) bit layout
/// Reference: 82574L Datasheet Section 13.4.22
pub const ReceiveCtl = packed struct(u32) {
    _reserved_0: bool = false, // Bit 0: Reserved
    enable: bool = false, // Bit 1: EN - Receiver Enable
    store_bad_packets: bool = false, // Bit 2: SBP - Store Bad Packets
    unicast_promisc: bool = false, // Bit 3: UPE - Unicast Promiscuous
    multicast_promisc: bool = false, // Bit 4: MPE - Multicast Promiscuous
    long_packet: bool = false, // Bit 5: LPE - Long Packet Enable
    loopback_mode: u2 = 0, // Bits 6-7: LBM - Loopback Mode
    rdmts: u2 = 0, // Bits 8-9: RDMTS - RX Desc Min Threshold
    _reserved_10_11: u2 = 0, // Bits 10-11: Reserved
    multicast_offset: u2 = 0, // Bits 12-13: MO - Multicast Offset
    _reserved_14: bool = false, // Bit 14: Reserved
    broadcast_accept: bool = false, // Bit 15: BAM - Broadcast Accept Mode
    buffer_size: u2 = 0, // Bits 16-17: BSIZE - Buffer Size
    vlan_filter: bool = false, // Bit 18: VFE - VLAN Filter Enable
    cfien: bool = false, // Bit 19: CFIEN - CFI Enable
    cfi: bool = false, // Bit 20: CFI - Canonical Form Indicator
    _reserved_21_22: u2 = 0, // Bits 21-22: Reserved
    dpf: bool = false, // Bit 23: DPF - Discard Pause Frames
    pmcf: bool = false, // Bit 24: PMCF - Pass MAC Control Frames
    _reserved_25: bool = false, // Bit 25: Reserved
    strip_crc: bool = false, // Bit 26: SECRC - Strip Ethernet CRC
    _reserved_27_31: u5 = 0, // Bits 27-31: Reserved

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("ReceiveCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) ReceiveCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: ReceiveCtl) u32 {
        return @bitCast(self);
    }

    /// Buffer size in bytes based on BSIZE field
    pub fn getBufferSize(self: ReceiveCtl) u16 {
        return switch (self.buffer_size) {
            0 => 2048,
            1 => 1024,
            2 => 512,
            3 => 256,
        };
    }
};

/// Transmit Control Register (TCTL) bit layout
/// Reference: 82574L Datasheet Section 13.4.37
pub const TransmitCtl = packed struct(u32) {
    _reserved_0: bool = false, // Bit 0: Reserved
    enable: bool = false, // Bit 1: EN - Transmitter Enable
    _reserved_2: bool = false, // Bit 2: Reserved
    pad_short_packets: bool = false, // Bit 3: PSP - Pad Short Packets
    collision_threshold: u8 = 0, // Bits 4-11: CT - Collision Threshold
    collision_distance: u10 = 0, // Bits 12-21: COLD - Collision Distance
    swxoff: bool = false, // Bit 22: SWXOFF - Software XOFF
    _reserved_23: bool = false, // Bit 23: Reserved
    retransmit_late_coll: bool = false, // Bit 24: RTLC - Retransmit on Late Collision
    _reserved_25: bool = false, // Bit 25: Reserved
    unortx: bool = false, // Bit 26: UNORTX - Underrun No Retransmit
    _reserved_27_31: u5 = 0, // Bits 27-31: Reserved

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("TransmitCtl must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) TransmitCtl {
        return @bitCast(raw);
    }

    pub fn toRaw(self: TransmitCtl) u32 {
        return @bitCast(self);
    }
};

/// Interrupt Cause Register (ICR) bit layout
/// Reference: 82574L Datasheet Section 13.4.17
/// Type-safe packed struct for cleaner interrupt handling
pub const InterruptCause = packed struct(u32) {
    tx_desc_written: bool = false, // Bit 0: TXDW
    tx_queue_empty: bool = false, // Bit 1: TXQE
    link_status_change: bool = false, // Bit 2: LSC
    rx_seq_error: bool = false, // Bit 3: RXSEQ
    rx_desc_min_threshold: bool = false, // Bit 4: RXDMT0
    _reserved_5: bool = false, // Bit 5: reserved
    rx_overrun: bool = false, // Bit 6: RXO
    rx_timer: bool = false, // Bit 7: RXT0
    _reserved_8_31: u24 = 0, // Bits 8-31: reserved/other causes

    comptime {
        if (@sizeOf(@This()) != 4) @compileError("InterruptCause must be 4 bytes");
    }

    pub fn fromRaw(raw: u32) InterruptCause {
        return @bitCast(raw);
    }

    pub fn toRaw(self: InterruptCause) u32 {
        return @bitCast(self);
    }

    /// Check if any RX interrupt is pending
    pub fn hasRxInterrupt(self: InterruptCause) bool {
        return self.rx_timer or self.rx_desc_min_threshold;
    }
};
