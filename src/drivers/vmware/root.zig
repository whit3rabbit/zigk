//! VMware Guest Tools Driver Suite
//!
//! Provides VMware-specific guest integration:
//! - HGFS: Host-Guest File System for shared folders
//!
//! The VMware backdoor/hypercall interface is in hal (src/arch/x86_64/hypervisor/vmware.zig).
//! This module provides higher-level services built on top of that interface.
//!
//! Usage:
//!   const vmware = @import("vmware");
//!   if (vmware.isVMware() and vmware.isBackdoorAvailable()) {
//!       try vmware.hgfs.initAndMount();
//!   }

const hal = @import("hal");

// Re-export submodules
pub const hgfs = @import("hgfs/root.zig");

// Re-export protocol types for direct access
pub const protocol = @import("hgfs/protocol.zig");

/// Check if running under VMware hypervisor
/// Convenience wrapper for hal.hypervisor.detect
pub fn isVMware() bool {
    const info = hal.hypervisor.detect.detect();
    return info.hypervisor == .vmware;
}

/// Check if VMware backdoor interface is available
/// This verifies the hypercall port responds correctly
pub fn isBackdoorAvailable() bool {
    return hal.hypervisor.vmware.detect();
}

/// VMware hypercall port
pub const HYPERCALL_PORT: u16 = hal.hypervisor.vmware.HYPERCALL_PORT;

/// VMware magic value for hypercalls
pub const HYPERCALL_MAGIC: u32 = hal.hypervisor.vmware.HYPERCALL_MAGIC;
