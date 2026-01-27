//! VirtualBox Guest Additions Driver Suite
//!
//! Provides VirtualBox-specific guest integration:
//! - VMMDev: PCI device for host-guest communication (0x80EE:0xCAFE)
//! - VBoxSF: Shared folder access via HGCM (future)
//!
//! Note: vmmdev is imported separately by the kernel as "vmmdev" module.
//! This facade provides convenience functions and will host VBoxSF when ready.
//!
//! Usage:
//!   const vbox = @import("vbox");
//!   const vmmdev = @import("vmmdev");
//!   if (vbox.isVirtualBox() and vmmdev.isVmmDev(pci_dev)) {
//!       const device = try vmmdev.initFromPci(pci_dev, access);
//!   }

const hal = @import("hal");

// VBoxSF will be added when implemented
// pub const sf = @import("sf/root.zig");

/// Check if running under VirtualBox hypervisor
/// Convenience wrapper for hal.hypervisor.detect
pub fn isVirtualBox() bool {
    const info = hal.hypervisor.detect.detect();
    return info.hypervisor == .virtualbox;
}

/// PCI vendor ID for VirtualBox devices
pub const PCI_VENDOR_VBOX: u16 = 0x80EE;

/// PCI device ID for VMMDev
pub const PCI_DEVICE_VMMDEV: u16 = 0xCAFE;
