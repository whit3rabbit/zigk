const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const dma = @import("dma");
const iommu = @import("iommu");

const regs = @import("regs.zig");
const context = @import("context.zig");
const ring = @import("ring.zig");
const types = @import("types.zig");

const MmioDevice = hal.mmio_device.MmioDevice;
const Controller = types.Controller;

/// Helper to get IOMMU DeviceBdf from controller
fn getDeviceBdf(ctrl: *const Controller) iommu.DeviceBdf {
    return .{
        .bus = ctrl.pci_dev.bus,
        .device = ctrl.pci_dev.device,
        .func = ctrl.pci_dev.func,
    };
}

/// Initialize controller data structures
pub fn initDataStructures(ctrl: *Controller) !void {
    const op_dev = MmioDevice(regs.OpReg).init(ctrl.op_base, 0x1000);
    const bdf = getDeviceBdf(ctrl);

    // Set MaxSlotsEnabled
    var config = op_dev.readTyped(.config, regs.Config);
    config.max_slots_en = ctrl.max_slots;
    op_dev.writeTyped(.config, config);

    // Allocate DCBAA (IOMMU-aware)
    ctrl.dcbaa = try context.Dcbaa.alloc(ctrl.max_slots, bdf);
    op_dev.write64(.dcbaap, ctrl.dcbaa.getDeviceAddress());
    console.info("XHCI: DCBAA at device addr {x:0>16}", .{ctrl.dcbaa.getDeviceAddress()});

    // Allocate scratchpad buffers if needed
    if (ctrl.scratchpad_count > 0) {
        try allocScratchpads(ctrl);
    }

    // Allocate Command Ring (IOMMU-aware)
    ctrl.command_ring = try ring.ProducerRing.init(bdf);
    const crcr = regs.Crcr.init(
        ctrl.command_ring.getDeviceAddress(),
        ctrl.command_ring.getCycleState(),
    );
    op_dev.write64(.crcr, @bitCast(crcr));
    console.info("XHCI: Command Ring at device addr {x:0>16}", .{ctrl.command_ring.getDeviceAddress()});

    // Allocate Event Ring (IOMMU-aware)
    ctrl.event_ring = try ring.ConsumerRing.init(bdf);

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

    console.info("XHCI: Event Ring at device addr {x:0>16}", .{ctrl.event_ring.phys_base});
}

/// Maximum scratchpad buffers that fit in one page (4096 bytes / 8 bytes per entry)
const MAX_SCRATCHPAD_ENTRIES: u16 = 512;

/// Allocate scratchpad buffers using IOMMU-aware DMA
/// Security: Validates scratchpad count to prevent heap overflow
/// Security: Uses errdefer to clean up partial allocations on failure
pub fn allocScratchpads(ctrl: *Controller) !void {
    console.info("XHCI: Allocating {} scratchpad buffers", .{ctrl.scratchpad_count});
    const bdf = getDeviceBdf(ctrl);

    // Security: Validate scratchpad count against array capacity
    // A malicious controller could report an excessive count
    if (ctrl.scratchpad_count > MAX_SCRATCHPAD_ENTRIES) {
        console.err("XHCI: Scratchpad count {} exceeds max {} (single page limit)", .{
            ctrl.scratchpad_count,
            MAX_SCRATCHPAD_ENTRIES,
        });
        return error.InvalidHardwareConfig;
    }

    // Allocate scratchpad buffer array (IOMMU-aware, writable by device)
    const array_dma = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
        console.err("XHCI: Failed to allocate scratchpad array", .{});
        return error.OutOfMemory;
    };
    errdefer dma.freeBuffer(&array_dma);

    const array: [*]u64 = @ptrCast(@alignCast(hal.paging.physToVirt(array_dma.phys_addr)));

    // Security: Track allocated buffers for cleanup on partial failure
    // Using static array since scratchpad_count is bounded by MAX_SCRATCHPAD_ENTRIES
    var allocated_bufs: [MAX_SCRATCHPAD_ENTRIES]?dma.DmaBuffer = [_]?dma.DmaBuffer{null} ** MAX_SCRATCHPAD_ENTRIES;
    var allocated_count: u16 = 0;

    // errdefer: Free all successfully allocated scratchpad buffers on failure
    errdefer {
        var j: u16 = 0;
        while (j < allocated_count) : (j += 1) {
            if (allocated_bufs[j]) |*buf| {
                dma.freeBuffer(buf);
            }
        }
    }

    // Allocate each scratchpad buffer (one page each, IOMMU-aware)
    var i: u16 = 0;
    while (i < ctrl.scratchpad_count) : (i += 1) {
        const buf_dma = dma.allocBuffer(bdf, pmm.PAGE_SIZE, true) catch {
            console.err("XHCI: Failed to allocate scratchpad buffer {}", .{i});
            return error.OutOfMemory;
        };
        // Track for cleanup and store device address
        allocated_bufs[i] = buf_dma;
        allocated_count = i + 1;
        array[i] = buf_dma.device_addr;
    }

    // Set DCBAA[0] to scratchpad array device address
    ctrl.dcbaa.setScratchpadArray(array_dma.device_addr);
}
