// Kernel IOMMU Subsystem Root
//
// High-level IOMMU domain and DMA management for the kernel.
// This module builds on the HAL-level VT-d implementation to provide
// device isolation and secure DMA buffer management.
//
// Key components:
//   - domain: Per-device IOVA namespace management
//   - Secure DMA allocation returning IOVAs instead of physical addresses
//
// Usage:
//   1. Call init() during kernel boot (after HAL init)
//   2. Use allocDmaBuffer() instead of raw physical allocation for device DMA
//   3. Devices receive IOVAs that are translated by IOMMU hardware

pub const domain = @import("domain.zig");

// Re-export commonly used types and functions
pub const Domain = domain.Domain;
pub const DomainManager = domain.DomainManager;
pub const DeviceBdf = domain.DeviceBdf;
pub const IovaAllocator = domain.IovaAllocator;

// Re-export public functions
pub const init = domain.init;
pub const initHardware = domain.initHardware;
pub const allocDmaBuffer = domain.allocDmaBuffer;
pub const freeDmaBuffer = domain.freeDmaBuffer;
pub const isAvailable = domain.isAvailable;

// Access to global domain manager
pub const domain_manager = &domain.domain_manager;
