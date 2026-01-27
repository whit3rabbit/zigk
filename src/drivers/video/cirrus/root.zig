//! Cirrus Logic CL-GD5446 VGA Driver Module
//!
//! Public exports for the Cirrus VGA driver.
//! Use CirrusDriver.init() to initialize the driver if a Cirrus device is present.

pub const driver = @import("driver.zig");
pub const hardware = @import("hardware.zig");
pub const regs = @import("regs.zig");

/// Main driver type
pub const CirrusDriver = driver.CirrusDriver;

// Re-export commonly used hardware constants
pub const PCI_VENDOR_ID = hardware.PCI_VENDOR_ID_CIRRUS;
pub const PCI_DEVICE_ID = hardware.PCI_DEVICE_ID_GD5446;
