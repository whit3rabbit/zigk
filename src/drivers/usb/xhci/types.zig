const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const interrupts = hal.interrupts;

const context = @import("context.zig");
const ring = @import("ring.zig");
const regs = @import("regs.zig");

/// XHCI Controller instance
/// Contains all state for an XHCI controller.
/// Methods are implemented in `controller.zig` and other submodules to separate concerns,
/// but these accessors are kept here for convenience and to avoid circular deps.
pub const Controller = struct {
    /// PCI device
    pci_dev: *const pci.PciDevice,
    /// PCI access method (ECAM or Legacy)
    pci_access: pci.PciAccess,

    /// BAR0 base virtual address
    bar0_virt: u64,
    /// BAR0 size (for unmapping)
    bar0_size: usize,

    /// Register set base addresses
    cap_base: u64, // Capability registers
    op_base: u64, // Operational registers
    runtime_base: u64, // Runtime registers
    doorbell_base: u64, // Doorbell registers

    /// Controller capabilities
    max_slots: u8,
    max_ports: u8,
    context_size: u8, // 32 or 64 bytes
    scratchpad_count: u16,

    /// Data structures
    dcbaa: context.Dcbaa,
    command_ring: ring.ProducerRing,
    event_ring: ring.ConsumerRing,

    /// MSI-X allocation
    msix_vectors: ?interrupts.MsixVectorAllocation,

    /// Polling function for non-MSI mode (breaks dependency cycle)
    poll_events_fn: ?*const fn () usize = null,

    /// Controller state
    running: bool,

    const Self = @This();

    /// Ring the doorbell for a specific slot and target
    /// Target: 0=Command Ring, 1=EP0, 2..31=EPs (DCI)
    pub fn ringDoorbell(self: *Self, slot_id: u8, target: u8) void {
        const db_base = self.doorbell_base + (@as(u64, slot_id) * @sizeOf(u32));
        // Write to doorbell register directly
        const ptr = @as(*volatile u32, @ptrFromInt(db_base));
        ptr.* = @as(u32, target);
    }

    /// Update Event Ring Dequeue Pointer (ERDP)
    /// Notifies hardware that we have processed events
    pub fn updateErdp(self: *Self) void {
        const intr0_base = self.runtime_base + regs.intrSetOffset(0);
        const intr_dev = hal.mmio_device.MmioDevice(regs.IntrReg).init(intr0_base, 0x20);

        const erdp = regs.Erdp.init(self.event_ring.getDequeuePointer(), 0);
        intr_dev.write64(.erdp, @bitCast(erdp));
    }
};
