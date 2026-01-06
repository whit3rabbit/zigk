//! Hypervisor Support Module (AArch64)
//!
//! Provides hypervisor detection and platform-specific optimizations for ARM64.
//! Uses SMCCC (ARM Standard Service Calls) and system register probing.

pub const detect = @import("detect.zig");
pub const pvtime = @import("pvtime.zig");

// Re-export commonly used types
pub const HypervisorType = detect.HypervisorType;
pub const HypervisorInfo = detect.HypervisorInfo;

// Re-export commonly used functions
pub const getHypervisor = detect.getHypervisor;
pub const isVirtualized = detect.isVirtualized;
pub const hasPvtime = pvtime.hasPvtime;
