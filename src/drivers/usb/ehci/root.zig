// EHCI (USB 2.0) Host Controller Driver
//
// Implements the Enhanced Host Controller Interface for USB 2.0 devices.
// This driver handles controller initialization, port detection, and
// basic management.
//
// Reference: EHCI Specification 1.0

const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const pci = @import("pci");

const regs = @import("regs.zig");

// =============================================================================
// Controller State
// =============================================================================

/// EHCI Controller instance
pub const Controller = struct {
    /// PCI device
    pci_dev: *const pci.PciDevice,
    /// PCI ECAM (for config space access)
    pci_ecam: *const pci.Ecam,

    /// BAR0 base virtual address
    bar0_virt: u64,
    /// BAR0 size (for unmapping)
    bar0_size: usize,

    /// Register set base addresses
    cap_base: u64, // Capability registers
    op_base: u64, // Operational registers

    /// Controller capabilities
    n_ports: u4,
    has_debug_port: bool,
    is_64_bit: bool,

    /// Controller state
    running: bool,

    const Self = @This();

    /// Initialize the EHCI controller
    pub fn init(pci_dev: *const pci.PciDevice, pci_ecam: *const pci.Ecam) !*Self {
        console.info("EHCI: Initializing controller at PCI {x:0>2}:{x:0>2}.{}", .{
            pci_dev.bus,
            pci_dev.device,
            pci_dev.func,
        });

        // Verify this is an EHCI controller (Class 0C, Subclass 03, ProgIF 20)
        if (pci_dev.class_code != 0x0C or pci_dev.subclass != 0x03 or pci_dev.prog_if != 0x20) {
            console.err("EHCI: Device is not an EHCI controller", .{});
            return error.InvalidDevice;
        }

        // Enable bus mastering and memory space
        pci_ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        pci_ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

        // Get BAR0 (MMIO base)
        const bar0 = pci_dev.bar[0];
        if (bar0.size == 0) {
            console.err("EHCI: BAR0 not present", .{});
            return error.NoBars;
        }

        if (!bar0.is_mmio) {
            console.err("EHCI: BAR0 is I/O space, expected memory", .{});
            return error.InvalidBar;
        }

        console.info("EHCI: BAR0 at physical {x:0>16}, size {x}", .{ bar0.base, bar0.size });

        // Map BAR0 into virtual address space
        const bar0_virt = vmm.mapMmioExplicit(bar0.base, bar0.size) catch |err| {
            console.err("EHCI: Failed to map BAR0 MMIO: {}", .{err});
            return error.MmioMapFailed;
        };

        // Read capability registers
        const caplength = readReg8(bar0_virt, regs.Cap.CAPLENGTH);
        const hciversion = readReg16(bar0_virt, regs.Cap.HCIVERSION);
        const hcsparams: regs.HcsParams = @bitCast(readReg32(bar0_virt, regs.Cap.HCSPARAMS));
        const hccparams: regs.HccParams = @bitCast(readReg32(bar0_virt, regs.Cap.HCCPARAMS));

        console.info("EHCI: Version {x:0>4}, CAPLENGTH={}, Ports={}, 64-bit={}", .{
            hciversion,
            caplength,
            hcsparams.n_ports,
            hccparams.addr_64_bit,
        });

        // Calculate operational register base
        const op_base = bar0_virt + caplength;

        // Allocate controller structure
        const ctrl_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const ctrl_virt = @intFromPtr(hal.paging.physToVirt(ctrl_phys));
        const ctrl: *Self = @ptrFromInt(ctrl_virt);

        ctrl.* = Self{
            .pci_dev = pci_dev,
            .pci_ecam = pci_ecam,
            .bar0_virt = bar0_virt,
            .bar0_size = bar0.size,
            .cap_base = bar0_virt,
            .op_base = op_base,
            .n_ports = hcsparams.n_ports,
            .has_debug_port = (hcsparams.dbg_port_num != 0),
            .is_64_bit = hccparams.addr_64_bit,
            .running = false,
        };

        // Take ownership from BIOS if needed (OS Handoff)
        try ctrl.biosHandoff(hccparams.eecp);

        // Reset the controller
        try ctrl.reset();

        // Start the controller
        try ctrl.start();

        console.info("EHCI: Controller initialized successfully", .{});
        return ctrl;
    }

    /// Perform BIOS Handoff (OS ownership)
    fn biosHandoff(self: *Self, eecp: u8) !void {
        if (eecp == 0) return;

        console.info("EHCI: Checking for BIOS ownership at offset {x}", .{eecp});

        // TODO: Implement full EHCI Extended Capability traversal and handoff
        // For now we assume we can just reset if not claimed or if simple handoff
    }

    /// Reset the host controller
    fn reset(self: *Self) !void {
        console.info("EHCI: Resetting controller...", .{});

        // Stop controller
        var usbcmd: regs.UsbCmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        if (usbcmd.rs) {
            usbcmd.rs = false;
            writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

            // Wait for HCH (Halted) bit
            var timeout: u32 = 1000;
            while (timeout > 0) : (timeout -= 1) {
                const usbsts: regs.UsbSts = @bitCast(readReg32(self.op_base, regs.Op.USBSTS));
                if (usbsts.hchalted) break;
                hal.cpu.pause();
            }
            if (timeout == 0) console.warn("EHCI: Timeout waiting for halt", .{});
        }

        // Assert HCRESET
        usbcmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        usbcmd.hcreset = true;
        writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

        // Wait for reset to complete
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            usbcmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
            if (!usbcmd.hcreset) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            console.err("EHCI: Reset timeout", .{});
            return error.ResetTimeout;
        }

        console.info("EHCI: Reset complete", .{});
    }

    /// Start the controller
    fn start(self: *Self) !void {
        // TODO: Setup Periodic/Async lists before starting

        // Route all ports to this host controller (clear ConfigFlag)
        // If we want to support Companion Controllers (USB 1.1), we need to handle this carefully.
        // For now, setting ConfigFlag=1 routes all ports to EHCI.
        writeReg32(self.op_base, regs.Op.CONFIGFLAG, 1);
        hal.cpu.pause();

        console.info("EHCI: Ports routed to EHCI", .{});

        // Turn on power to all ports if PPC (Port Power Control) is set in HCSPARAMS
        // But for now, we just scan.

        self.running = true;
    }

    /// Scan ports for connected devices
    pub fn scanPorts(self: *Self) void {
        console.info("EHCI: Scanning {} ports...", .{self.n_ports});

        var port: u8 = 1;
        while (port <= self.n_ports) : (port += 1) {
            const portsc_off = regs.Op.portsc(port);
            var portsc: regs.PortSc = @bitCast(readReg32(self.op_base, portsc_off));

            // If port has power control, ensure it's powered
            if (!portsc.pp) {
                portsc.pp = true;
                writeReg32(self.op_base, portsc_off, @bitCast(portsc));
                // Wait for power up
                var t: u32 = 20000; // ~20ms
                while (t > 0) : (t -= 1) hal.cpu.pause();
                portsc = @bitCast(readReg32(self.op_base, portsc_off));
            }

            if (portsc.ccs) {
                console.info("EHCI: Port {} connected, owner={}, line_status={}", .{
                    port,
                    portsc.owner,
                    portsc.line_status,
                });

                // TODO: Reset port to determine speed and enable it
            }
        }
    }
};

// =============================================================================
// MMIO Helpers
// =============================================================================

fn readReg8(base: u64, offset: u64) u8 {
    const ptr: *volatile u8 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn readReg16(base: u64, offset: u64) u16 {
    const ptr: *volatile u16 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn readReg32(base: u64, offset: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn writeReg32(base: u64, offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
}

// =============================================================================
// Module Initialization
// =============================================================================

/// Global controller reference
var global_controller: ?*Controller = null;

/// Probe for EHCI controllers and initialize them
pub fn probe(devices: *const pci.DeviceList, ecam: *const pci.Ecam) void {
    console.info("EHCI: Probing for controllers...", .{});

    // Find EHCI Controller: Class 0x0C (Serial Bus), Subclass 0x03 (USB), ProgIF 0x20 (EHCI)
    if (devices.findEhciController()) |dev| {
        const ctrl = Controller.init(dev, ecam) catch |err| {
            console.err("EHCI: Failed to initialize controller: {}", .{err});
            return;
        };

        global_controller = ctrl;
        ctrl.scanPorts();
    } else {
        console.info("EHCI: No controllers found", .{});
    }
}
