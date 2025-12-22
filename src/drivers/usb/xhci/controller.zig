const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const pci = @import("pci");

const types = @import("types.zig");
const regs = @import("regs.zig");
const trb = @import("trb.zig");
const ring = @import("ring.zig");
const memory = @import("memory.zig");
const interrupts = @import("interrupts.zig");
const ports = @import("ports.zig");

const MmioDevice = hal.mmio_device.MmioDevice;
const Controller = types.Controller;

/// Initialize the XHCI controller from a PCI device
pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*Controller {
    console.info("XHCI: Initializing controller at PCI {x:0>2}:{x:0>2}.{}", .{
        pci_dev.bus,
        pci_dev.device,
        pci_dev.func,
    });

    // Verify this is an XHCI controller
    if (!pci_dev.isXhciController()) {
        console.err("XHCI: Device is not an XHCI controller", .{});
        return error.InvalidDevice;
    }

    // Enable bus mastering and memory space
    pci_access.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
    pci_access.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

    // Get BAR0 (MMIO base)
    const bar0 = pci_dev.bar[0];
    if (bar0.size == 0) {
        console.err("XHCI: BAR0 not present", .{});
        return error.NoBars;
    }

    if (!bar0.is_mmio) {
        console.err("XHCI: BAR0 is I/O space, expected memory", .{});
        return error.InvalidBar;
    }

    console.info("XHCI: BAR0 at physical {x:0>16}, size {x}", .{ bar0.base, bar0.size });

    // Map BAR0 into virtual address space using VMM
    const bar0_virt = vmm.mapMmioExplicit(bar0.base, bar0.size) catch |err| {
        console.err("XHCI: Failed to map BAR0 MMIO: {}", .{err});
        return error.MmioMapFailed;
    };

    // Read capability registers
    const cap_dev = MmioDevice(regs.CapReg).init(bar0_virt, 0x1000); 
    const caplength = cap_dev.read8(.caplength);
    const hciversion = cap_dev.read16(.hciversion);
    const hcsparams1 = cap_dev.readTyped(.hcsparams1, regs.HcsParams1);
    const hcsparams2 = cap_dev.readTyped(.hcsparams2, regs.HcsParams2);
    const hccparams1 = cap_dev.readTyped(.hccparams1, regs.HccParams1);
    const dboff = cap_dev.read(.dboff) & 0xFFFFFFFC;
    const rtsoff = cap_dev.read(.rtsoff) & 0xFFFFFFE0;

    console.info("XHCI: Version {x:0>4}, CAPLENGTH={}, MaxSlots={}, MaxPorts={}", .{
        hciversion,
        caplength,
        hcsparams1.max_slots,
        hcsparams1.max_ports,
    });

    const context_size: u8 = if (hccparams1.csz) 64 else 32;
    const scratchpad_count = hcsparams2.scratchpadCount();

    console.info("XHCI: Context size={}, Scratchpads={}, 64-bit={}", .{
        context_size,
        scratchpad_count,
        hccparams1.ac64,
    });

    // Validate offsets
    if (caplength >= bar0.size or rtsoff >= bar0.size or dboff >= bar0.size) {
        console.err("XHCI: Invalid register offsets vs BAR0 size", .{});
        return error.InvalidHardwareConfig;
    }

    const op_base = bar0_virt + caplength;
    const runtime_base = bar0_virt + rtsoff;
    const doorbell_base = bar0_virt + dboff;

    // Allocate controller structure
    const ctrl_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
    const ctrl_virt = @intFromPtr(hal.paging.physToVirt(ctrl_phys));
    const ctrl: *Controller = @ptrFromInt(ctrl_virt);

    ctrl.* = Controller{
        .pci_dev = pci_dev,
        .pci_access = pci_access,
        .bar0_virt = bar0_virt,
        .bar0_size = bar0.size,
        .cap_base = bar0_virt,
        .op_base = op_base,
        .runtime_base = runtime_base,
        .doorbell_base = doorbell_base,
        .max_slots = hcsparams1.max_slots,
        .max_ports = hcsparams1.max_ports,
        .context_size = context_size,
        .scratchpad_count = scratchpad_count,
        .dcbaa = undefined,
        .command_ring = undefined,
        .event_ring = undefined,
        .msix_vectors = null,
        .running = false,
    };

    // Reset and initialize the controller
    try reset(ctrl);
    try memory.initDataStructures(ctrl);
    try interrupts.setupInterrupts(ctrl);
    try start(ctrl);

    console.info("XHCI: Controller initialized successfully", .{});
    
    // Probe/Scan ports
    ports.scanPorts(ctrl);

    return ctrl;
}

/// Reset the host controller
pub fn reset(ctrl: *Controller) !void {
    console.info("XHCI: Resetting controller...", .{});
    
    const op_dev = MmioDevice(regs.OpReg).init(ctrl.op_base, 0x1000);

    // Stop controller if running
    var usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
    if (usbcmd.rs) {
        usbcmd.rs = false;
        op_dev.writeTyped(.usbcmd, usbcmd);

        // Wait for HCH (Halted) bit
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            const usbsts = op_dev.readTyped(.usbsts, regs.UsbSts);
            if (usbsts.hch) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            console.warn("XHCI: Timeout waiting for controller to halt", .{});
        }
    }

    // Assert HCRST
    usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
    usbcmd.hcrst = true;
    op_dev.writeTyped(.usbcmd, usbcmd);

    // Wait for reset to complete (HCRST clears itself)
    var timeout: u32 = 1000;
    while (timeout > 0) : (timeout -= 1) {
        usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
        if (!usbcmd.hcrst) break;
        hal.cpu.stall(10);
    }

    if (timeout == 0) {
        console.err("XHCI: Reset timeout (HCRST stuck)", .{});
        return error.ResetTimeout;
    }

    // Wait for CNR (Controller Not Ready) to clear
    timeout = 1000;
    while (timeout > 0) : (timeout -= 1) {
        const usbsts = op_dev.readTyped(.usbsts, regs.UsbSts);
        if (!usbsts.cnr) break;
        hal.cpu.stall(10);
    }

    if (timeout == 0) {
        console.err("XHCI: Reset timeout (CNR stuck)", .{});
        return error.ResetTimeout;
    }

    console.info("XHCI: Controller reset complete", .{});
}

/// Start the controller
pub fn start(ctrl: *Controller) !void {
    console.info("XHCI: Starting controller...", .{});

    const op_dev = MmioDevice(regs.OpReg).init(ctrl.op_base, 0x1000);

    // Enable interrupts
    var usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
    usbcmd.inte = true;
    usbcmd.rs = true;
    op_dev.writeTyped(.usbcmd, usbcmd);

    // Wait for running
    var timeout: u32 = 100;
    while (timeout > 0) : (timeout -= 1) {
        const usbsts = op_dev.readTyped(.usbsts, regs.UsbSts);
        if (!usbsts.hch) break;
        hal.cpu.stall(100);
    }

    if (timeout == 0) {
        console.err("XHCI: Failed to start controller", .{});
        return error.StartFailed;
    }

    ctrl.running = true;
    console.info("XHCI: Controller running", .{});
}

/// Stop the controller
pub fn stop(ctrl: *Controller) void {
    if (!ctrl.running) return;

    const op_dev = MmioDevice(regs.OpReg).init(ctrl.op_base, 0x1000);
    var usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
    usbcmd.rs = false;
    op_dev.writeTyped(.usbcmd, usbcmd);

    ctrl.running = false;
    console.info("XHCI: Controller stopped", .{});
}

/// Send a No-Op command to test the command ring
pub fn sendNoOp(ctrl: *Controller) !void {
    console.info("XHCI: Sending No-Op command...", .{});

    const noop = trb.NoOpCmdTrb.init(ctrl.command_ring.getCycleState());
    _ = ctrl.command_ring.enqueue(noop.toTrb()) orelse {
        console.err("XHCI: Command ring full", .{});
        return error.RingFull;
    };

    ctrl.ringDoorbell(0, 0);

    const result = ctrl.waitForCommandCompletion(10000) catch |err| {
        console.err("XHCI: No-Op command timeout", .{});
        return err;
    };

    if (result.code == .Success) {
        console.info("XHCI: No-Op command completed successfully", .{});
    } else {
        console.err("XHCI: No-Op command failed with code {}", .{@intFromEnum(result.code)});
        return error.CommandFailed;
    }
}
