// XHCI Register Definitions
//
// Defines all register sets and bit fields for the Extensible Host Controller Interface.
// XHCI has four register sets accessed via offsets from BAR0:
//   - Capability Registers (at BAR0)
//   - Operational Registers (at BAR0 + CAPLENGTH)
//   - Runtime Registers (at BAR0 + RTSOFF)
//   - Doorbell Registers (at BAR0 + DBOFF)
//
// Reference: xHCI Specification 1.2

// =============================================================================
// Capability Registers (read-only, at BAR0)
// =============================================================================

/// Capability Register Offsets
pub const Cap = struct {
    pub const CAPLENGTH: u64 = 0x00; // Capability Register Length (1 byte)
    pub const HCIVERSION: u64 = 0x02; // Host Controller Interface Version (2 bytes)
    pub const HCSPARAMS1: u64 = 0x04; // Structural Parameters 1 (4 bytes)
    pub const HCSPARAMS2: u64 = 0x08; // Structural Parameters 2 (4 bytes)
    pub const HCSPARAMS3: u64 = 0x0C; // Structural Parameters 3 (4 bytes)
    pub const HCCPARAMS1: u64 = 0x10; // Capability Parameters 1 (4 bytes)
    pub const DBOFF: u64 = 0x14; // Doorbell Offset (4 bytes)
    pub const RTSOFF: u64 = 0x18; // Runtime Register Space Offset (4 bytes)
    pub const HCCPARAMS2: u64 = 0x1C; // Capability Parameters 2 (4 bytes)
};

/// HCSPARAMS1 - Structural Parameters 1
pub const HcsParams1 = packed struct(u32) {
    max_slots: u8, // Maximum Device Slots (N)
    max_intrs: u11, // Maximum Interrupters
    _rsvd: u5,
    max_ports: u8, // Maximum Ports
};

/// HCSPARAMS2 - Structural Parameters 2
pub const HcsParams2 = packed struct(u32) {
    ist: u4, // Isochronous Scheduling Threshold
    erst_max: u4, // Event Ring Segment Table Max
    _rsvd: u13,
    max_scratchpad_hi: u5, // Max Scratchpad Buffers (high)
    spr: bool, // Scratchpad Restore
    max_scratchpad_lo: u5, // Max Scratchpad Buffers (low)

    /// Get total scratchpad buffer count
    pub fn scratchpadCount(self: HcsParams2) u10 {
        return (@as(u10, self.max_scratchpad_hi) << 5) | @as(u10, self.max_scratchpad_lo);
    }
};

/// HCCPARAMS1 - Capability Parameters 1
pub const HccParams1 = packed struct(u32) {
    ac64: bool, // 64-bit Addressing Capability
    bnc: bool, // BW Negotiation Capability
    csz: bool, // Context Size (0=32 bytes, 1=64 bytes)
    ppc: bool, // Port Power Control
    pind: bool, // Port Indicators
    lhrc: bool, // Light HC Reset Capability
    ltc: bool, // Latency Tolerance Messaging Capability
    nss: bool, // No Secondary SID Support
    pae: bool, // Parse All Event Data
    spc: bool, // Stopped - Short Packet Capability
    sec: bool, // Stopped EDTLA Capability
    cfc: bool, // Contiguous Frame ID Capability
    max_psa_size: u4, // Maximum Primary Stream Array Size
    xecp: u16, // xHCI Extended Capabilities Pointer
};

// =============================================================================
// Operational Registers (at BAR0 + CAPLENGTH)
// =============================================================================

/// Operational Register Offsets (relative to op_base)
pub const Op = struct {
    pub const USBCMD: u64 = 0x00; // USB Command (4 bytes)
    pub const USBSTS: u64 = 0x04; // USB Status (4 bytes)
    pub const PAGESIZE: u64 = 0x08; // Page Size (4 bytes)
    pub const DNCTRL: u64 = 0x14; // Device Notification Control (4 bytes)
    pub const CRCR: u64 = 0x18; // Command Ring Control (8 bytes)
    pub const DCBAAP: u64 = 0x30; // Device Context Base Address Array Pointer (8 bytes)
    pub const CONFIG: u64 = 0x38; // Configure (4 bytes)
    pub const PORTSC_BASE: u64 = 0x400; // Port Status and Control base
    pub const PORTPMSC_BASE: u64 = 0x404; // Port Power Management base
    pub const PORTLI_BASE: u64 = 0x408; // Port Link Info base
    pub const PORTHLPMC_BASE: u64 = 0x40C; // Port Hardware LPM Control base

    /// Get PORTSC offset for a specific port (1-based)
    pub fn portsc(port: u8) u64 {
        return PORTSC_BASE + (@as(u64, port - 1) * 0x10);
    }
};

/// USBCMD - USB Command Register
pub const UsbCmd = packed struct(u32) {
    rs: bool, // Run/Stop
    hcrst: bool, // Host Controller Reset
    inte: bool, // Interrupter Enable
    hsee: bool, // Host System Error Enable
    _rsvd0: u3,
    lhcrst: bool, // Light Host Controller Reset
    css: bool, // Controller Save State
    crs: bool, // Controller Restore State
    ewe: bool, // Enable Wrap Event
    eu3s: bool, // Enable U3 MFINDEX Stop
    _rsvd1: u1,
    cme: bool, // CEM Enable
    ete: bool, // Extended TBC Enable
    tsc_en: bool, // Extended TBC TRB Status Enable
    vtioe: bool, // VTIO Enable
    _rsvd2: u15,
};

/// USBSTS - USB Status Register
pub const UsbSts = packed struct(u32) {
    hch: bool, // Host Controller Halted
    _rsvd0: u1,
    hse: bool, // Host System Error
    eint: bool, // Event Interrupt
    pcd: bool, // Port Change Detect
    _rsvd1: u3,
    sss: bool, // Save State Status
    rss: bool, // Restore State Status
    sre: bool, // Save/Restore Error
    cnr: bool, // Controller Not Ready
    hce: bool, // Host Controller Error
    _rsvd2: u19,
};

/// CRCR - Command Ring Control Register
pub const Crcr = packed struct(u64) {
    rcs: bool, // Ring Cycle State
    cs: bool, // Command Stop
    ca: bool, // Command Abort
    crr: bool, // Command Ring Running
    _rsvd: u2,
    ptr: u58, // Command Ring Pointer (64-byte aligned)

    /// Get the physical address of the command ring
    pub fn address(self: Crcr) u64 {
        return @as(u64, self.ptr) << 6;
    }

    /// Build CRCR value from physical address and cycle state
    pub fn init(phys_addr: u64, rcs: bool) Crcr {
        return Crcr{
            .rcs = rcs,
            .cs = false,
            .ca = false,
            .crr = false,
            ._rsvd = 0,
            .ptr = @truncate(phys_addr >> 6),
        };
    }
};

/// CONFIG - Configure Register
pub const Config = packed struct(u32) {
    max_slots_en: u8, // Max Device Slots Enabled
    u3_entry: bool, // U3 Entry Enable
    cie: bool, // Configuration Information Enable
    _rsvd: u22,
};

/// PORTSC - Port Status and Control Register
pub const PortSc = packed struct(u32) {
    ccs: bool, // Current Connect Status
    ped: bool, // Port Enabled/Disabled
    _rsvd0: u1,
    oca: bool, // Over-current Active
    pr: bool, // Port Reset
    pls: u4, // Port Link State
    pp: bool, // Port Power
    speed: u4, // Port Speed
    pic: u2, // Port Indicator Control
    lws: bool, // Port Link State Write Strobe
    csc: bool, // Connect Status Change
    pec: bool, // Port Enabled/Disabled Change
    wrc: bool, // Warm Port Reset Change
    occ: bool, // Over-current Change
    prc: bool, // Port Reset Change
    plc: bool, // Port Link State Change
    cec: bool, // Port Config Error Change
    cas: bool, // Cold Attach Status
    wce: bool, // Wake on Connect Enable
    wde: bool, // Wake on Disconnect Enable
    woe: bool, // Wake on Over-current Enable
    _rsvd1: u2,
    dr: bool, // Device Removable
    wpr: bool, // Warm Port Reset

    /// Port Link State values
    pub const LinkState = enum(u4) {
        u0 = 0, // USB 3.0: Normal operation
        u1 = 1, // USB 3.0: Suspended
        u2 = 2, // USB 3.0: Low Power
        u3 = 3, // USB 3.0: Suspended (USB 2.0: L2)
        disabled = 4,
        rx_detect = 5,
        inactive = 6,
        polling = 7,
        recovery = 8,
        hot_reset = 9,
        compliance = 10,
        test_mode = 11,
        link_resume = 15, // 'resume' is a Zig keyword
        _,
    };

    /// Port Speed values
    pub const SpeedId = enum(u4) {
        invalid = 0,
        full = 1, // 12 Mbps
        low = 2, // 1.5 Mbps
        high = 3, // 480 Mbps
        super = 4, // 5 Gbps
        super_plus = 5, // 10 Gbps
        _,
    };
};

// =============================================================================
// Runtime Registers (at BAR0 + RTSOFF)
// =============================================================================

/// Runtime Register Offsets (relative to runtime_base)
pub const Runtime = struct {
    pub const MFINDEX: u64 = 0x00; // Microframe Index (4 bytes)
    pub const IR0: u64 = 0x20; // Interrupter Register Set 0

    /// Get interrupter register set offset
    pub fn interrupter(n: u32) u64 {
        return IR0 + (@as(u64, n) * 0x20);
    }
};

/// Interrupter Register Set offsets (relative to interrupter base)
pub const Intr = struct {
    pub const IMAN: u64 = 0x00; // Interrupter Management (4 bytes)
    pub const IMOD: u64 = 0x04; // Interrupter Moderation (4 bytes)
    pub const ERSTSZ: u64 = 0x08; // Event Ring Segment Table Size (4 bytes)
    pub const _RSVD: u64 = 0x0C;
    pub const ERSTBA: u64 = 0x10; // Event Ring Segment Table Base Address (8 bytes)
    pub const ERDP: u64 = 0x18; // Event Ring Dequeue Pointer (8 bytes)
};

/// IMAN - Interrupter Management Register
pub const Iman = packed struct(u32) {
    ip: bool, // Interrupt Pending
    ie: bool, // Interrupt Enable
    _rsvd: u30,
};

/// IMOD - Interrupter Moderation Register
pub const Imod = packed struct(u32) {
    imodi: u16, // Interrupt Moderation Interval (250ns units)
    imodc: u16, // Interrupt Moderation Counter
};

/// ERDP - Event Ring Dequeue Pointer
pub const Erdp = packed struct(u64) {
    desi: u3, // Dequeue ERST Segment Index
    ehb: bool, // Event Handler Busy
    ptr: u60, // Event Ring Dequeue Pointer (16-byte aligned)

    /// Get the physical address
    pub fn address(self: Erdp) u64 {
        return @as(u64, self.ptr) << 4;
    }

    /// Build ERDP value from physical address
    pub fn init(phys_addr: u64, segment_index: u3) Erdp {
        return Erdp{
            .desi = segment_index,
            .ehb = false,
            .ptr = @truncate(phys_addr >> 4),
        };
    }
};

// =============================================================================
// Doorbell Registers (at BAR0 + DBOFF)
// =============================================================================

/// Doorbell Register value
pub const Doorbell = packed struct(u32) {
    db_target: u8, // Doorbell Target (endpoint ID)
    _rsvd: u8,
    db_stream_id: u16, // Doorbell Stream ID

    /// Doorbell for host controller (Command Ring)
    pub fn hostController() Doorbell {
        return .{ .db_target = 0, ._rsvd = 0, .db_stream_id = 0 };
    }

    /// Doorbell for device slot endpoint
    pub fn endpoint(ep_dci: u8, stream_id: u16) Doorbell {
        return .{ .db_target = ep_dci, ._rsvd = 0, .db_stream_id = stream_id };
    }
};

// =============================================================================
// Extended Capabilities
// =============================================================================

/// Extended Capability IDs
pub const ExtCapId = struct {
    pub const USB_LEGACY: u8 = 1;
    pub const SUPPORTED_PROTOCOL: u8 = 2;
    pub const EXTENDED_POWER_MGMT: u8 = 3;
    pub const IO_VIRTUALIZATION: u8 = 4;
    pub const MESSAGE_INTERRUPT: u8 = 5;
    pub const LOCAL_MEMORY: u8 = 6;
    pub const USB_DEBUG: u8 = 10;
    pub const EXTENDED_MESSAGE_INTERRUPT: u8 = 17;
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Calculate offset for a specific port's PORTSC register
pub fn portScOffset(port_num: u8) u64 {
    return Op.PORTSC_BASE + (@as(u64, port_num - 1) * 0x10);
}

/// Calculate doorbell register offset for a slot
pub fn doorbellOffset(slot_id: u8) u64 {
    return @as(u64, slot_id) * 4;
}
