//! IOMMU-Aware DMA Buffer Allocation
//!
//! Provides a unified DMA allocation API that transparently handles IOMMU
//! integration. When IOMMU is available, allocates IOVAs and creates mappings.
//! When IOMMU is unavailable, falls back to raw physical addresses.
//!
//! Security: This module enforces DMA isolation by default when IOMMU
//! hardware is present, preventing devices from accessing arbitrary memory.
//!
//! Usage:
//! ```zig
//! const dma = @import("dma");
//! const iommu = @import("iommu");
//!
//! // Get device BDF from PCI device
//! const bdf = iommu.DeviceBdf{ .bus = dev.bus, .device = dev.device, .func = dev.func };
//!
//! // Allocate IOMMU-aware buffer
//! const buf = try dma.allocBuffer(bdf, 4096, true);
//! defer dma.freeBuffer(&buf);
//!
//! // For CPU access: use buf.getVirt() or buf.slice()
//! // For hardware registers: use buf.device_addr
//! ```

const std = @import("std");
const pmm = @import("pmm");
const hal = @import("hal");
const iommu = @import("iommu");
const console = @import("console");
const init_hw = @import("../core/init_hw.zig");

/// Error types for DMA allocation
pub const DmaError = error{
    /// Physical memory allocation failed
    OutOfMemory,
    /// IOMMU mapping failed (falls back to physical)
    IommuError,
    /// Device address exceeds 32-bit limit (for 32-bit controllers)
    AddressTooHigh,
    /// Integer overflow in size calculation
    Overflow,
};

/// Represents a DMA buffer that can be used by hardware devices
pub const DmaBuffer = struct {
    /// Physical address of the buffer (for CPU access via HHDM)
    phys_addr: u64,

    /// Device address (IOVA if IOMMU enabled, else same as phys_addr)
    /// THIS is what you program into hardware registers/descriptors
    device_addr: u64,

    /// Size in bytes (as requested)
    size: u64,

    /// Number of pages allocated
    page_count: usize,

    /// Device BDF (for IOMMU domain lookup on free)
    bdf: ?iommu.DeviceBdf,

    /// Whether IOMMU mapping was used
    iommu_mapped: bool,

    const Self = @This();

    /// Get virtual address for CPU access (via HHDM)
    pub fn getVirt(self: *const Self) [*]u8 {
        return @ptrCast(hal.paging.physToVirt(self.phys_addr));
    }

    /// Get typed pointer for CPU access
    pub fn getTypedPtr(self: *const Self, comptime T: type) *T {
        return @ptrCast(@alignCast(self.getVirt()));
    }

    /// Get typed volatile pointer for hardware descriptor access
    pub fn getVolatilePtr(self: *const Self, comptime T: type) *volatile T {
        return @ptrCast(@alignCast(self.getVirt()));
    }

    /// Get slice for CPU access
    pub fn slice(self: *const Self) []u8 {
        return self.getVirt()[0..@intCast(self.size)];
    }

    /// Get the lower 32 bits of device address (for hardware registers)
    pub fn deviceAddrLo(self: *const Self) u32 {
        return @truncate(self.device_addr);
    }

    /// Get the upper 32 bits of device address (for hardware registers)
    pub fn deviceAddrHi(self: *const Self) u32 {
        return @truncate(self.device_addr >> 32);
    }
};

/// Allocate a DMA buffer for a specific PCI device
///
/// Parameters:
///   - bdf: PCI Bus/Device/Function of the device that will use this buffer
///   - size: Minimum size in bytes (rounded up to page boundary)
///   - writable: Whether device can write to this buffer
///
/// Returns: DmaBuffer on success, error otherwise
///
/// The returned `device_addr` should be programmed into hardware descriptors.
/// The `phys_addr` can be used with physToVirt() for CPU access.
///
/// Security: When IOMMU is enabled, the device can only access this specific
/// buffer. Without IOMMU, the device has unrestricted DMA access (legacy mode).
pub fn allocBuffer(
    bdf: iommu.DeviceBdf,
    size: u64,
    writable: bool,
) DmaError!DmaBuffer {
    // Calculate pages needed
    const page_size: u64 = pmm.PAGE_SIZE;
    const aligned_size = std.math.add(u64, size, page_size - 1) catch return DmaError.Overflow;
    const page_count: usize = @intCast(aligned_size / page_size);

    // Allocate physical memory (always zero-initialized for security)
    const phys = pmm.allocZeroedPages(page_count) orelse return DmaError.OutOfMemory;

    errdefer pmm.freePages(phys, page_count);

    // Check if IOMMU is enabled
    if (init_hw.iommu_enabled) {
        // Allocate IOVA and create mapping
        if (iommu.allocDmaBuffer(bdf, phys, size, writable)) |iova| {
            return DmaBuffer{
                .phys_addr = phys,
                .device_addr = iova,
                .size = size,
                .page_count = page_count,
                .bdf = bdf,
                .iommu_mapped = true,
            };
        }

        // IOMMU mapping failed - fall back to physical address with warning
        console.warn("DMA: IOMMU mapping failed for {x:0>2}:{x:0>2}.{d}, using phys fallback", .{
            bdf.bus,
            bdf.device,
            bdf.func,
        });
    }

    // No IOMMU or mapping failed - use raw physical address
    return DmaBuffer{
        .phys_addr = phys,
        .device_addr = phys,
        .size = size,
        .page_count = page_count,
        .bdf = null,
        .iommu_mapped = false,
    };
}

/// Allocate DMA buffer without BDF (for boot-time allocations before PCI is ready)
/// WARNING: This bypasses IOMMU isolation - only use during early boot
pub fn allocBufferUnsafe(size: u64) DmaError!DmaBuffer {
    const page_size: u64 = pmm.PAGE_SIZE;
    const aligned_size = std.math.add(u64, size, page_size - 1) catch return DmaError.Overflow;
    const page_count: usize = @intCast(aligned_size / page_size);

    const phys = pmm.allocZeroedPages(page_count) orelse return DmaError.OutOfMemory;

    return DmaBuffer{
        .phys_addr = phys,
        .device_addr = phys,
        .size = size,
        .page_count = page_count,
        .bdf = null,
        .iommu_mapped = false,
    };
}

/// Free a DMA buffer
pub fn freeBuffer(buf: *const DmaBuffer) void {
    // Unmap from IOMMU if it was mapped
    if (buf.iommu_mapped) {
        if (buf.bdf) |bdf| {
            iommu.freeDmaBuffer(bdf, buf.device_addr, buf.size);
        }
    }

    // Free physical pages
    pmm.freePages(buf.phys_addr, buf.page_count);
}

/// Allocate DMA buffer for 32-bit only controllers
/// Returns error.AddressTooHigh if the allocated address exceeds 4GB
pub fn allocBuffer32(
    bdf: iommu.DeviceBdf,
    size: u64,
    writable: bool,
) DmaError!DmaBuffer {
    const buf = try allocBuffer(bdf, size, writable);

    if (buf.device_addr > 0xFFFFFFFF) {
        freeBuffer(&buf);
        return DmaError.AddressTooHigh;
    }

    return buf;
}

/// Check if IOMMU DMA isolation is available
pub fn isIommuAvailable() bool {
    return init_hw.iommu_enabled;
}
