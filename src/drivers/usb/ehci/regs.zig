// EHCI Register Definitions
//
// Reference: Enhanced Host Controller Interface Specification for Universal Serial Bus
// Revision 1.0

const std = @import("std");

// =============================================================================
// Capability Registers
// =============================================================================

pub const Cap = struct {
    pub const CAPLENGTH: u64 = 0x00;
    pub const HCIVERSION: u64 = 0x02;
    pub const HCSPARAMS: u64 = 0x04;
    pub const HCCPARAMS: u64 = 0x08;
    pub const HCSPPORTROUTE: u64 = 0x0C;
};

pub const HcsParams = packed struct(u32) {
    n_ports: u4,        // Number of physical downstream ports
    ppc: bool,          // Port Power Control
    _rsvd0: u2 = 0,
    prr: bool,          // Port Routing Rules
    n_pcc: u4,          // Number of Ports per Companion Controller
    n_cc: u4,           // Number of Companion Controllers
    p_indicator: bool,  // Port Indicator
    _rsvd1: u3 = 0,
    dbg_port_num: u4,   // Debug Port Number
    _rsvd2: u8 = 0,
};

pub const HccParams = packed struct(u32) {
    addr_64_bit: bool,  // 64-bit Addressing Capability
    pfl_flag: bool,     // Programmable Frame List Flag
    async_park: bool,   // Asynchronous Schedule Park Capability
    _rsvd0: u1 = 0,
    iso_sched_threshold: u4, // Isochronous Scheduling Threshold
    eecp: u8,           // EHCI Extended Capabilities Pointer
    _rsvd1: u16 = 0,
};

// =============================================================================
// Operational Registers
// =============================================================================

pub const Op = struct {
    pub const USBCMD: u64 = 0x00;
    pub const USBSTS: u64 = 0x04;
    pub const USBINTR: u64 = 0x08;
    pub const FRINDEX: u64 = 0x0C;
    pub const CTRLDSSEGMENT: u64 = 0x10;
    pub const PERIODICLISTBASE: u64 = 0x14;
    pub const ASYNCLISTADDR: u64 = 0x18;
    pub const CONFIGFLAG: u64 = 0x40;

    pub fn portsc(port: u8) u64 {
        return 0x44 + @as(u64, port - 1) * 4;
    }
};

pub const UsbCmd = packed struct(u32) {
    rs: bool,           // Run/Stop
    hcreset: bool,      // Host Controller Reset
    fls: u2,            // Frame List Size
    pse: bool,          // Periodic Schedule Enable
    ase: bool,          // Asynchronous Schedule Enable
    iaad: bool,         // Interrupt on Async Advance Doorbell
    lhcr: bool,         // Light Host Controller Reset
    park_count: u2,     // Asynchronous Schedule Park Mode Count
    _rsvd0: u1 = 0,
    park_enable: bool,  // Asynchronous Schedule Park Mode Enable
    _rsvd1: u4 = 0,
    itc: u8,            // Interrupt Threshold Control
    _rsvd2: u8 = 0,
};

pub const UsbSts = packed struct(u32) {
    usbint: bool,       // USB Interrupt
    usberrint: bool,    // USB Error Interrupt
    pcd: bool,          // Port Change Detect
    flr: bool,          // Frame List Rollover
    hse: bool,          // Host System Error
    iaa: bool,          // Interrupt on Async Advance
    _rsvd0: u6 = 0,
    hchalted: bool,     // HCHalted
    reclamation: bool,  // Reclamation
    pss: bool,          // Periodic Schedule Status
    ass: bool,          // Asynchronous Schedule Status
    _rsvd1: u16 = 0,
};

pub const UsbIntr = packed struct(u32) {
    usbint_en: bool,    // USB Interrupt Enable
    usberr_en: bool,    // USB Error Interrupt Enable
    pcd_en: bool,       // Port Change Detect Enable
    flr_en: bool,       // Frame List Rollover Enable
    hse_en: bool,       // Host System Error Enable
    iaa_en: bool,       // Interrupt on Async Advance Enable
    _rsvd0: u26 = 0,
};

pub const PortSc = packed struct(u32) {
    ccs: bool,          // Current Connect Status
    csc: bool,          // Connect Status Change
    ped: bool,          // Port Enable/Disable
    pedc: bool,         // Port Enable/Disable Change
    oca: bool,          // Over-current Active
    occ: bool,          // Over-current Change
    fpr: bool,          // Force Port Resume
    @"suspend": bool,   // Suspend
    reset: bool,        // Port Reset
    _rsvd0: u1 = 0,
    line_status: u2,    // Line Status
    pp: bool,           // Port Power
    owner: bool,        // Port Owner
    led: u2,            // Port Indicator Control
    tst: u4,            // Port Test Control
    wkc: bool,          // Wake on Connect Enable
    wkd: bool,          // Wake on Disconnect Enable
    wko: bool,          // Wake on Over-current Enable
    _rsvd1: u9 = 0,
};

// =============================================================================
// Transfer Descriptors (Legacy Support)
// =============================================================================

// Basic structure for Link Pointer
pub const LinkPointer = packed struct(u32) {
    terminate: bool,
    type: u2,           // 0=iTD, 1=QH, 2=siTD, 3=FSTN
    _rsvd: u2 = 0,
    address: u27,       // Upper 27 bits of physical address (32-byte aligned)

    pub fn getAddress(self: LinkPointer) u64 {
        return @as(u64, self.address) << 5;
    }
};

// Queue Element Transfer Descriptor (qTD)
pub const Qtd = packed struct {
    next_qtd: u32,      // Next qTD Pointer
    alt_next_qtd: u32,  // Alternate Next qTD Pointer
    token: QtdToken,
    buffer_pointers: [5]u32, // Buffer Page Pointers (4KB aligned)
    extended_buffer: [5]u32, // Extended Buffer Pointers (64-bit support)
};

pub const QtdToken = packed struct(u32) {
    ping_state: bool,   // Ping State / Error Counter (bit 0)
    split_state: bool,  // Split Transaction State (bit 1)
    missed_uframe: bool,// Missed Micro-Frame (bit 2)
    xact_err: bool,     // Transaction Error (bit 3)
    babble: bool,       // Babble Detected (bit 4)
    data_buffer: bool,  // Data Buffer Error (bit 5)
    halted: bool,       // Halted (bit 6)
    active: bool,       // Active (bit 7)
    pid: u2,            // PID Code (0=OUT, 1=IN, 2=SETUP)
    cerr: u2,           // Error Counter
    c_page: u3,         // Current Page
    ioc: bool,          // Interrupt On Complete
    total_bytes: u15,   // Total Bytes to Transfer
    data_toggle: bool,  // Data Toggle
};

// Queue Head (QH)
pub const Qh = packed struct {
    horizontal_link: u32, // Horizontal Link Pointer
    endpoint_chars: u32,  // Endpoint Characteristics
    endpoint_caps: u32,   // Endpoint Capabilities
    current_qtd: u32,     // Current qTD Pointer

    // Overlay area (updated by HC)
    next_qtd: u32,
    alt_next_qtd: u32,
    token: u32,
    buffer_pointers: [5]u32,
    extended_buffer: [5]u32,
};
