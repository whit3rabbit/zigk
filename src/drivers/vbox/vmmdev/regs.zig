//! VMMDev MMIO Register Definitions
//!
//! VirtualBox VMMDev device (Vendor 0x80EE, Device 0xCAFE) uses MMIO for
//! request/response communication. BAR0 contains the MMIO registers.
//!
//! Reference: VirtualBox source - src/VBox/Devices/VMMDev/VMMDev.cpp

const std = @import("std");

/// VMMDev PCI identifiers
pub const PCI_VENDOR_VBOX: u16 = 0x80EE;
pub const PCI_DEVICE_VMMDEV: u16 = 0xCAFE;

/// MMIO Register offsets
pub const Reg = enum(u32) {
    /// Request physical address (write to submit request)
    REQUEST = 0x00,
    /// Pending events (read to get, write to ack)
    EVENTS_STATUS = 0x04,
    /// Request submission result
    REQUEST_RC = 0x08,
    /// IRQ acknowledge
    IRQ_ACK = 0x0C,
    /// Test register (for diagnosis)
    TEST = 0x10,
    /// Capabilities query
    CAPS_QUERY = 0x14,
    /// Capabilities set
    CAPS_SET = 0x18,
    /// Host version (read-only)
    HOST_VERSION = 0x1C,
};

/// VMMDev MMIO BAR size
pub const MMIO_SIZE: u64 = 0x1000; // 4KB

/// VMMDev capability flags (from CAPS_QUERY)
pub const Caps = struct {
    /// HGCM (Host-Guest Communication Manager) is available
    pub const HGCM: u32 = 1 << 0;
    /// Graphics extensions available
    pub const GRAPHICS: u32 = 1 << 2;
    /// Seamless mode available
    pub const SEAMLESS: u32 = 1 << 3;
    /// Guest property query/set available
    pub const GUEST_PROPS: u32 = 1 << 4;
    /// Memory balloon available
    pub const BALLOON: u32 = 1 << 5;
    /// Heartbeat available
    pub const HEARTBEAT: u32 = 1 << 6;
};

/// IRQ status bits
pub const IrqStatus = struct {
    /// An event is pending
    pub const EVENT_PENDING: u32 = 1 << 0;
    /// HGCM request completed
    pub const HGCM_DONE: u32 = 1 << 1;
};
