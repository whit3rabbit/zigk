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

const sync = @import("sync");

pub const ecam = @import("ecam.zig");
pub const legacy = @import("legacy.zig");
pub const access = @import("access.zig");
pub const device = @import("device.zig");
pub const enumeration = @import("enumeration.zig");
pub const capabilities = @import("capabilities.zig");
pub const msi = @import("msi.zig");

// Re-export commonly used types
pub const Ecam = ecam.Ecam;
pub const Legacy = legacy.Legacy;
pub const PciAccess = access.PciAccess;
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

// Re-export SMP safety functions (see enumeration.zig for invariant documentation)
pub const isEnumerationComplete = enumeration.isEnumerationComplete;
pub const assertEnumerationComplete = enumeration.assertEnumerationComplete;

// =============================================================================
// Global PCI State (set during kernel init, read by syscalls)
// =============================================================================

/// RwLock protecting global PCI state for SMP-safe access.
/// Writers (setGlobalState) acquire exclusive lock.
/// Readers (getDevices, getEcam) acquire shared lock.
var pci_state_lock: sync.RwLock = .{};

/// Global PCI device list (set by init_hw.initNetwork)
var global_devices: ?*const DeviceList = null;

/// Global PCI ECAM accessor (set by init_hw.initNetwork)
var global_ecam: ?Ecam = null;

/// Tracks whether global state has been initialized.
/// SECURITY: Prevents setGlobalState from being called multiple times,
/// which would invalidate pointers returned by getDevices/getEcam.
var global_state_initialized: bool = false;

/// Set global PCI state (called by init_hw during boot)
/// Acquires exclusive write lock to prevent TOCTOU races on SMP systems.
///
/// SECURITY INVARIANT: This function MUST only be called once during boot.
/// Calling it again would invalidate pointers previously returned by
/// getDevices()/getEcam(), creating use-after-free or stale-data bugs.
/// Hot-plug support would require a redesign (RCU pattern or copy-on-read).
pub fn setGlobalState(devices: *const DeviceList, ecam_opt: ?Ecam) void {
    const held = pci_state_lock.acquireWrite();
    defer held.release();

    // SECURITY: Prevent double-initialization which would invalidate
    // previously returned pointers. This is a hard invariant.
    if (global_state_initialized) {
        @import("console").err("PCI: SECURITY - setGlobalState called twice!", .{});
        return;
    }

    global_devices = devices;
    global_ecam = ecam_opt;
    global_state_initialized = true;
}

/// Get global PCI device list
/// Acquires shared read lock for SMP-safe access.
///
/// SAFETY: The returned pointer remains valid for the lifetime of the kernel
/// because setGlobalState is only called once during boot.
pub fn getDevices() ?*const DeviceList {
    const held = pci_state_lock.acquireRead();
    defer held.release();
    return global_devices;
}

/// Get global PCI ECAM accessor
/// Acquires shared read lock for SMP-safe access.
///
/// SAFETY: Returns by value (copy), so the caller owns the copy and
/// there are no lifetime concerns even if global state were to change.
pub fn getEcam() ?Ecam {
    const held = pci_state_lock.acquireRead();
    defer held.release();
    return global_ecam;
}
