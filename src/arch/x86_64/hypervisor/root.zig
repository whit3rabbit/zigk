//! Hypervisor Support Module
//!
//! Provides hypervisor detection and platform-specific optimizations.

pub const detect = @import("detect.zig");

// Re-export commonly used types
pub const HypervisorType = detect.HypervisorType;
pub const HypervisorInfo = detect.HypervisorInfo;

// Re-export commonly used functions
pub const getHypervisor = detect.getHypervisor;
pub const isVirtualized = detect.isVirtualized;
