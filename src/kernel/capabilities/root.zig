const std = @import("std");

pub const InterruptCapability = struct {
    irq: u8,
};

pub const MmioCapability = struct {
    /// Physical address of MMIO region
    phys_addr: u64,
    /// Size of MMIO region in bytes
    size: u64,
};

pub const DmaCapability = struct {
    /// Maximum pages this process can allocate for DMA
    max_pages: u32,
};

pub const PciConfigCapability = struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u5,
    /// PCI function number (0-7)
    func: u3,
};

pub const CapabilityType = enum {
    Interrupt,
    IoPort,
    Mmio,
    DmaMemory,
    PciConfig,
};

pub const Capability = union(CapabilityType) {
    Interrupt: InterruptCapability,
    IoPort: struct { port: u16, len: u16 },
    Mmio: MmioCapability,
    DmaMemory: DmaCapability,
    PciConfig: PciConfigCapability,
};
