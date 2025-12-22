// IOMMU Module Root
//
// Re-exports IOMMU functionality for use by kernel and drivers.
// This module is part of the HAL layer for Intel VT-d IOMMU support.
//
// Main components:
//   - regs: VT-d register definitions
//   - vtd: Hardware unit abstraction (VtdUnit)
//   - page_table: IOMMU page table structures

pub const regs = @import("regs.zig");
pub const vtd = @import("vtd.zig");
pub const page_table = @import("page_table.zig");
pub const fault = @import("fault.zig");

// Re-export commonly used types
pub const RootEntry = regs.RootEntry;
pub const ContextEntry = regs.ContextEntry;

// Re-export page table types
pub const RootTable = page_table.RootTable;
pub const ContextTable = page_table.ContextTable;
pub const SlPageEntry = page_table.SlPageEntry;
pub const SecondLevelPageTable = page_table.SecondLevelPageTable;
pub const DomainPageTables = page_table.DomainPageTables;
pub const IommuTables = page_table.IommuTables;
pub const IovaAddress = page_table.IovaAddress;
pub const CapabilityReg = regs.CapabilityReg;
pub const ExtCapabilityReg = regs.ExtCapabilityReg;
pub const GlobalCmdReg = regs.GlobalCmdReg;
pub const GlobalStsReg = regs.GlobalStsReg;
pub const Offset = regs.Offset;
pub const VtdUnit = vtd.VtdUnit;

// Re-export unit management functions
pub const registerUnit = vtd.registerUnit;
pub const getUnitCount = vtd.getUnitCount;
pub const getUnit = vtd.getUnit;
pub const findUnitForDevice = vtd.findUnitForDevice;
