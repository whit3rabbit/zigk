// ACPI Module Root
//
// Re-exports ACPI table parsing functionality for use by kernel and drivers.
// This module is part of the HAL layer - it abstracts ACPI table access.
//
// Main entry points:
//   - rsdp.findTable() - Find any ACPI table by signature
//   - mcfg.findEcamBase() - Get PCIe ECAM base address for PCI enumeration

pub const rsdp = @import("rsdp.zig");
pub const mcfg = @import("mcfg.zig");
pub const madt = @import("madt.zig");

// Re-export commonly used types
pub const Rsdp = rsdp.Rsdp;
pub const Rsdp2 = rsdp.Rsdp2;
pub const SdtHeader = rsdp.SdtHeader;
pub const McfgHeader = mcfg.McfgHeader;
pub const McfgEntry = mcfg.McfgEntry;
pub const EcamInfo = mcfg.EcamInfo;
pub const MadtInfo = madt.MadtInfo;
pub const IoApicInfo = madt.IoApicInfo;

// Re-export commonly used functions
pub const findTable = rsdp.findTable;
pub const findEcamBase = mcfg.findEcamBase;
pub const logRsdpInfo = rsdp.logRsdpInfo;
pub const logMcfgInfo = mcfg.logMcfgInfo;
pub const parseMadt = madt.parse;
pub const logMadtInfo = madt.logMadtInfo;
