const std = @import("std");

pub const InterruptCapability = struct {
    irq: u8,
};

pub const CapabilityType = enum {
    Interrupt,
    IoPort,
};

pub const Capability = union(CapabilityType) {
    Interrupt: InterruptCapability,
    IoPort: struct { port: u16, len: u16 },
};
