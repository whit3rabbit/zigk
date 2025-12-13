// PCI Subsystem Root Module
//
// Re-exports PCI enumeration, ECAM access, and device types.
// Use this module for PCI device discovery and driver initialization.
//
// Usage:
//   const pci = @import("pci");
//   const result = try pci.initFromAcpi(rsdp_ptr);
//   if (result.devices.findE1000()) |nic| {
//       // Initialize NIC driver with nic device
//   }

pub const ecam = @import("ecam.zig");
pub const device = @import("device.zig");
pub const enumeration = @import("enumeration.zig");
pub const capabilities = @import("capabilities.zig");
pub const msi = @import("msi.zig");

// Re-export commonly used types
pub const Ecam = ecam.Ecam;
pub const PciDevice = device.PciDevice;
pub const DeviceList = device.DeviceList;
pub const Bar = device.Bar;
pub const VendorId = device.VendorId;
pub const IntelDeviceId = device.IntelDeviceId;
pub const VirtioDeviceId = device.VirtioDeviceId;
pub const ClassCode = device.ClassCode;
pub const Command = device.Command;
pub const ConfigReg = device.ConfigReg;

// Re-export capability types
pub const CapabilityId = capabilities.CapabilityId;
pub const MsiCapability = capabilities.MsiCapability;
pub const MsixCapability = capabilities.MsixCapability;
pub const findCapability = capabilities.findCapability;
pub const findMsi = capabilities.findMsi;
pub const findMsix = capabilities.findMsix;

// Re-export MSI functions
pub const enableMsi = msi.enableMsi;
pub const disableMsi = msi.disableMsi;
pub const enableMsix = msi.enableMsix;
pub const configureMsixEntry = msi.configureMsixEntry;
pub const enableMsixVectors = msi.enableMsixVectors;
pub const disableMsix = msi.disableMsix;
pub const MsixAllocation = msi.MsixAllocation;

// Re-export functions
pub const enumerate = enumeration.enumerate;
pub const initFromAcpi = enumeration.initFromAcpi;
