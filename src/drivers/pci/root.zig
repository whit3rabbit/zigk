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

// Re-export commonly used types
pub const Ecam = ecam.Ecam;
pub const PciDevice = device.PciDevice;
pub const DeviceList = device.DeviceList;
pub const Bar = device.Bar;
pub const VendorId = device.VendorId;
pub const IntelDeviceId = device.IntelDeviceId;
pub const ClassCode = device.ClassCode;
pub const Command = device.Command;
pub const ConfigReg = device.ConfigReg;

// Re-export functions
pub const enumerate = enumeration.enumerate;
pub const initFromAcpi = enumeration.initFromAcpi;
