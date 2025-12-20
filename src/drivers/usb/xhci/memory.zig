const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");

const regs = @import("regs.zig");
const context = @import("context.zig");
const ring = @import("ring.zig");
const types = @import("types.zig");

const MmioDevice = hal.mmio_device.MmioDevice;
const Controller = types.Controller;

/// Initialize controller data structures
pub fn initDataStructures(ctrl: *Controller) !void {
    const op_dev = MmioDevice(regs.OpReg).init(ctrl.op_base, 0x1000);

    // Set MaxSlotsEnabled
    var config = op_dev.readTyped(.config, regs.Config);
    config.max_slots_en = ctrl.max_slots;
    op_dev.writeTyped(.config, config);

    // Allocate DCBAA
    ctrl.dcbaa = try context.Dcbaa.alloc(ctrl.max_slots);
    op_dev.write64(.dcbaap, ctrl.dcbaa.getPhysicalAddress());
    console.info("XHCI: DCBAA at physical {x:0>16}", .{ctrl.dcbaa.getPhysicalAddress()});

    // Allocate scratchpad buffers if needed
    if (ctrl.scratchpad_count > 0) {
        try allocScratchpads(ctrl);
    }

    // Allocate Command Ring
    ctrl.command_ring = try ring.ProducerRing.init();
    const crcr = regs.Crcr.init(
        ctrl.command_ring.getPhysicalAddress(),
        ctrl.command_ring.getCycleState(),
    );
    op_dev.write64(.crcr, @bitCast(crcr));
    console.info("XHCI: Command Ring at physical {x:0>16}", .{ctrl.command_ring.getPhysicalAddress()});

    // Allocate Event Ring
    ctrl.event_ring = try ring.ConsumerRing.init();

    // Configure Interrupter 0
    const intr0_base = ctrl.runtime_base + regs.intrSetOffset(0);
    const intr_dev = MmioDevice(regs.IntrReg).init(intr0_base, 0x20);

    // Set ERSTSZ (Event Ring Segment Table Size)
    intr_dev.write32(.erstsz, ctrl.event_ring.getErstSize());

    // Set ERDP (Event Ring Dequeue Pointer)
    const erdp = regs.Erdp.init(ctrl.event_ring.getDequeuePointer(), 0);
    intr_dev.writeTyped64(.erdp, erdp);

    // Set ERSTBA (Event Ring Segment Table Base Address)
    intr_dev.write64(.erstba, ctrl.event_ring.getErstBase());

    console.info("XHCI: Event Ring at physical {x:0>16}", .{ctrl.event_ring.phys_base});
}

/// Maximum scratchpad buffers that fit in one page (4096 bytes / 8 bytes per entry)
const MAX_SCRATCHPAD_ENTRIES: u16 = 512;

/// Allocate scratchpad buffers
/// Security: Validates scratchpad count to prevent heap overflow
pub fn allocScratchpads(ctrl: *Controller) !void {
    console.info("XHCI: Allocating {} scratchpad buffers", .{ctrl.scratchpad_count});

    // Security: Validate scratchpad count against array capacity
    // A malicious controller could report an excessive count
    if (ctrl.scratchpad_count > MAX_SCRATCHPAD_ENTRIES) {
        console.err("XHCI: Scratchpad count {} exceeds max {} (single page limit)", .{
            ctrl.scratchpad_count,
            MAX_SCRATCHPAD_ENTRIES,
        });
        return error.InvalidHardwareConfig;
    }

    // Allocate scratchpad buffer array
    const array_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
    const array_virt = @intFromPtr(hal.paging.physToVirt(array_phys));
    const array: [*]u64 = @ptrFromInt(array_virt);

    // Allocate each scratchpad buffer (one page each)
    var i: u16 = 0;
    while (i < ctrl.scratchpad_count) : (i += 1) {
        const buf_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        array[i] = buf_phys;
    }

    // Set DCBAA[0] to scratchpad array
    ctrl.dcbaa.setScratchpadArray(array_phys);
}
