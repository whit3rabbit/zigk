// Virtual PCI Device UAPI Root Module
//
// User API types for the virtual PCI device emulation framework.
// Allows userspace processes to create software-defined PCI devices
// for driver testing and development.

pub const types = @import("types.zig");
pub const events = @import("events.zig");

// Re-export commonly used types
pub const VPciConfigHeader = types.VPciConfigHeader;
pub const VPciBarConfig = types.VPciBarConfig;
pub const VPciBarInfo = types.VPciBarInfo;
pub const VPciCapConfig = types.VPciCapConfig;
pub const VPciCapType = types.VPciCapType;
pub const VPciMsiConfig = types.VPciMsiConfig;
pub const VPciMsixConfig = types.VPciMsixConfig;
pub const VPciPmConfig = types.VPciPmConfig;
pub const VPciDmaOp = types.VPciDmaOp;
pub const VPciDmaDir = types.VPciDmaDir;
pub const VPciIrqConfig = types.VPciIrqConfig;
pub const VPciIrqType = types.VPciIrqType;
pub const VPciDeviceState = types.VPciDeviceState;
pub const VPciDeviceInfo = types.VPciDeviceInfo;
pub const BarFlags = types.BarFlags;

// Re-export event types
pub const VPciEvent = events.VPciEvent;
pub const VPciEventType = events.VPciEventType;
pub const VPciResponse = events.VPciResponse;
pub const VPciRingHeader = events.VPciRingHeader;
pub const VPciWaitResult = events.VPciWaitResult;

// Re-export constants
pub const MAX_DEVICES_PER_PROCESS = types.MAX_DEVICES_PER_PROCESS;
pub const MAX_DEVICES = types.MAX_DEVICES;
pub const MAX_BAR_SIZE = types.MAX_BAR_SIZE;
pub const MIN_BAR_SIZE = types.MIN_BAR_SIZE;
pub const MAX_MSIX_VECTORS = types.MAX_MSIX_VECTORS;
pub const VIRTUAL_BUS_NUMBER = types.VIRTUAL_BUS_NUMBER;

pub const DEFAULT_RING_ENTRIES = events.DEFAULT_RING_ENTRIES;
pub const MAX_RING_ENTRIES = events.MAX_RING_ENTRIES;
pub const MIN_RING_ENTRIES = events.MIN_RING_ENTRIES;
pub const RING_FLAG_ACTIVE = events.RING_FLAG_ACTIVE;
pub const RING_FLAG_CLOSING = events.RING_FLAG_CLOSING;

// Re-export helpers
pub const isPowerOf2 = events.isPowerOf2;
pub const ringPageCount = events.ringPageCount;
