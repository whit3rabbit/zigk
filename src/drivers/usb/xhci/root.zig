// XHCI (USB 3.x) Host Controller Driver
//
// Implements the Extensible Host Controller Interface for USB 3.x devices.
// This driver handles controller initialization, port detection, device
// enumeration, and transfer management.
//
// Reference: xHCI Specification 1.2

const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pmm = @import("pmm");
const vmm = @import("vmm");
const pci = @import("pci");
const msi = pci.msi;
const interrupts = hal.interrupts;
const idt = hal.idt;

const regs = @import("regs.zig");
const trb = @import("trb.zig");
const ring = @import("ring.zig");
const context = @import("context.zig");

// Re-export submodules
pub const Regs = regs;
pub const Trb = trb;
pub const Ring = ring;
pub const Context = context;

// =============================================================================
// Controller State
// =============================================================================

/// XHCI Controller instance
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

    /// Controller state
    running: bool,

    const Self = @This();

    /// Initialize the XHCI controller
    pub fn init(pci_dev: *const pci.PciDevice, pci_ecam: *const pci.Ecam) !*Self {
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
        pci_ecam.enableBusMaster(pci_dev.bus, pci_dev.device, pci_dev.func);
        pci_ecam.enableMemorySpace(pci_dev.bus, pci_dev.device, pci_dev.func);

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
        // Use explicit mapping for high addresses (above RAM) like PCI MMIO regions
        const bar0_virt = vmm.mapMmioExplicit(bar0.base, bar0.size) catch |err| {
            console.err("XHCI: Failed to map BAR0 MMIO: {}", .{err});
            return error.MmioMapFailed;
        };

        // Read capability registers
        const caplength = readReg8(bar0_virt, regs.Cap.CAPLENGTH);
        const hciversion = readReg16(bar0_virt, regs.Cap.HCIVERSION);
        const hcsparams1: regs.HcsParams1 = @bitCast(readReg32(bar0_virt, regs.Cap.HCSPARAMS1));
        const hcsparams2: regs.HcsParams2 = @bitCast(readReg32(bar0_virt, regs.Cap.HCSPARAMS2));
        const hccparams1: regs.HccParams1 = @bitCast(readReg32(bar0_virt, regs.Cap.HCCPARAMS1));
        const dboff = readReg32(bar0_virt, regs.Cap.DBOFF) & 0xFFFFFFFC;
        const rtsoff = readReg32(bar0_virt, regs.Cap.RTSOFF) & 0xFFFFFFE0;

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

        // Calculate register base addresses
        const op_base = bar0_virt + caplength;
        const runtime_base = bar0_virt + rtsoff;
        const doorbell_base = bar0_virt + dboff;

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
        try ctrl.reset();
        try ctrl.initDataStructures();
        try ctrl.setupInterrupts();
        try ctrl.start();

        console.info("XHCI: Controller initialized successfully", .{});
        return ctrl;
    }

    /// Reset the host controller
    fn reset(self: *Self) !void {
        console.info("XHCI: Resetting controller...", .{});

        // Stop controller if running
        var usbcmd: regs.UsbCmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        if (usbcmd.rs) {
            usbcmd.rs = false;
            writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

            // Wait for HCH (Halted) bit
            var timeout: u32 = 1000;
            while (timeout > 0) : (timeout -= 1) {
                const usbsts: regs.UsbSts = @bitCast(readReg32(self.op_base, regs.Op.USBSTS));
                if (usbsts.hch) break;
                hal.cpu.pause();
            }

            if (timeout == 0) {
                console.warn("XHCI: Timeout waiting for controller to halt", .{});
            }
        }

        // Assert HCRST
        usbcmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        usbcmd.hcrst = true;
        writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

        // Wait for reset to complete (HCRST clears itself)
        var timeout: u32 = 1000;
        while (timeout > 0) : (timeout -= 1) {
            usbcmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
            if (!usbcmd.hcrst) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            console.err("XHCI: Reset timeout (HCRST stuck)", .{});
            return error.ResetTimeout;
        }

        // Wait for CNR (Controller Not Ready) to clear
        timeout = 1000;
        while (timeout > 0) : (timeout -= 1) {
            const usbsts: regs.UsbSts = @bitCast(readReg32(self.op_base, regs.Op.USBSTS));
            if (!usbsts.cnr) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            console.err("XHCI: Reset timeout (CNR stuck)", .{});
            return error.ResetTimeout;
        }

        console.info("XHCI: Controller reset complete", .{});
    }

    /// Initialize controller data structures
    fn initDataStructures(self: *Self) !void {
        // Set MaxSlotsEnabled
        var config: regs.Config = @bitCast(readReg32(self.op_base, regs.Op.CONFIG));
        config.max_slots_en = self.max_slots;
        writeReg32(self.op_base, regs.Op.CONFIG, @bitCast(config));

        // Allocate DCBAA
        self.dcbaa = try context.Dcbaa.alloc(self.max_slots);
        writeReg64(self.op_base, regs.Op.DCBAAP, self.dcbaa.getPhysicalAddress());
        console.info("XHCI: DCBAA at physical {x:0>16}", .{self.dcbaa.getPhysicalAddress()});

        // Allocate scratchpad buffers if needed
        if (self.scratchpad_count > 0) {
            try self.allocScratchpads();
        }

        // Allocate Command Ring
        self.command_ring = try ring.ProducerRing.init();
        const crcr = regs.Crcr.init(
            self.command_ring.getPhysicalAddress(),
            self.command_ring.getCycleState(),
        );
        writeReg64(self.op_base, regs.Op.CRCR, @bitCast(crcr));
        console.info("XHCI: Command Ring at physical {x:0>16}", .{self.command_ring.getPhysicalAddress()});

        // Allocate Event Ring
        self.event_ring = try ring.ConsumerRing.init();

        // Configure Interrupter 0
        const intr0_base = self.runtime_base + regs.Runtime.interrupter(0);

        // Set ERSTSZ (Event Ring Segment Table Size)
        writeReg32(intr0_base, regs.Intr.ERSTSZ, self.event_ring.getErstSize());

        // Set ERDP (Event Ring Dequeue Pointer)
        const erdp = regs.Erdp.init(self.event_ring.getDequeuePointer(), 0);
        writeReg64(intr0_base, regs.Intr.ERDP, @bitCast(erdp));

        // Set ERSTBA (Event Ring Segment Table Base Address)
        writeReg64(intr0_base, regs.Intr.ERSTBA, self.event_ring.getErstBase());

        console.info("XHCI: Event Ring at physical {x:0>16}", .{self.event_ring.phys_base});
    }

    /// Allocate scratchpad buffers
    fn allocScratchpads(self: *Self) !void {
        console.info("XHCI: Allocating {} scratchpad buffers", .{self.scratchpad_count});

        // Allocate scratchpad buffer array
        const array_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const array_virt = @intFromPtr(hal.paging.physToVirt(array_phys));
        const array: [*]u64 = @ptrFromInt(array_virt);

        // Allocate each scratchpad buffer (one page each)
        var i: u16 = 0;
        while (i < self.scratchpad_count) : (i += 1) {
            const buf_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
            array[i] = buf_phys;
        }

        // Set DCBAA[0] to scratchpad array
        self.dcbaa.setScratchpadArray(array_phys);
    }

    /// Set up interrupt handling
    fn setupInterrupts(self: *Self) !void {
        // Try to enable MSI-X
        if (pci.findMsix(self.pci_ecam, self.pci_dev)) |msix_cap| {
            console.info("XHCI: Found MSI-X capability, attempting to enable...", .{});

            // Allocate 1 vector
            if (interrupts.allocateMsixVector()) |vector| {
                // Register handler
                if (interrupts.registerMsixHandler(vector, handleInterrupt)) {
                    // Enable MSI-X
                    // Note: We pass 0 for bar_virt to let enableMsix map it
                    if (pci.enableMsix(self.pci_ecam, self.pci_dev, &msix_cap, 0)) |msix_alloc| {
                        // Configure vector 0 to point to our allocated vector and BSP
                        // Use current CPU ID or 0 (BSP)
                        const dest_id: u8 = @truncate(hal.apic.lapic.getId());
                        pci.configureMsixEntry(msix_alloc.table_base, 0, vector, dest_id);

                        // Unmask vectors
                        pci.enableMsixVectors(self.pci_ecam, self.pci_dev, &msix_cap);

                        // Disable legacy INTx
                        pci.msi.disableIntx(self.pci_ecam, self.pci_dev);

                        self.msix_vectors = interrupts.MsixVectorAllocation{
                            .first_vector = vector,
                            .count = 1,
                        };

                        console.info("XHCI: MSI-X enabled with vector {}", .{vector});
                    } else {
                        console.err("XHCI: Failed to enable MSI-X capability", .{});
                        interrupts.unregisterMsixHandler(vector);
                        interrupts.freeMsixVector(vector);
                    }
                } else {
                    console.err("XHCI: Failed to register MSI-X handler", .{});
                    interrupts.freeMsixVector(vector);
                }
            } else {
                console.warn("XHCI: Failed to allocate MSI-X vector, falling back to polling", .{});
            }
        }

        if (self.msix_vectors == null) {
            console.info("XHCI: Using polling mode for events", .{});
        }

        // Enable interrupter
        const intr0_base = self.runtime_base + regs.Runtime.interrupter(0);
        var iman: regs.Iman = @bitCast(readReg32(intr0_base, regs.Intr.IMAN));
        iman.ie = true;
        writeReg32(intr0_base, regs.Intr.IMAN, @bitCast(iman));
    }

    /// Start the controller
    fn start(self: *Self) !void {
        console.info("XHCI: Starting controller...", .{});

        // Enable interrupts
        var usbcmd: regs.UsbCmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        usbcmd.inte = true;
        usbcmd.rs = true;
        writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

        // Wait for running
        var timeout: u32 = 100;
        while (timeout > 0) : (timeout -= 1) {
            const usbsts: regs.UsbSts = @bitCast(readReg32(self.op_base, regs.Op.USBSTS));
            if (!usbsts.hch) break;
            hal.cpu.pause();
        }

        if (timeout == 0) {
            console.err("XHCI: Failed to start controller", .{});
            return error.StartFailed;
        }

        self.running = true;
        console.info("XHCI: Controller running", .{});
    }

    /// Ring the host controller doorbell (for commands)
    pub fn ringDoorbell(self: *Self, slot_id: u8, target: u8) void {
        const db = regs.Doorbell{
            .db_target = target,
            ._rsvd = 0,
            .db_stream_id = 0,
        };
        const offset = regs.doorbellOffset(slot_id);
        writeReg32(self.doorbell_base, offset, @bitCast(db));
    }

    /// Send a No-Op command to test the command ring
    pub fn sendNoOp(self: *Self) !void {
        console.info("XHCI: Sending No-Op command...", .{});

        const noop = trb.NoOpCmdTrb.init(self.command_ring.getCycleState());
        const phys = self.command_ring.enqueue(noop.toTrb()) orelse {
            console.err("XHCI: Command ring full", .{});
            return error.RingFull;
        };
        _ = phys;

        // Ring doorbell 0 (host controller)
        self.ringDoorbell(0, 0);

        // Wait for completion event
        var timeout: u32 = 10000;
        while (timeout > 0) : (timeout -= 1) {
            if (self.event_ring.hasPending()) {
                const event = self.event_ring.dequeue() orelse break;
                const event_type = ring.getTrbType(event);

                if (event_type == .CommandCompletionEvent) {
                    const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                    const code = completion.status.completion_code;

                    if (code == .Success) {
                        console.info("XHCI: No-Op command completed successfully", .{});
                        self.updateErdp();
                        return;
                    } else {
                        console.err("XHCI: No-Op command failed with code {}", .{@intFromEnum(code)});
                        self.updateErdp();
                        return error.CommandFailed;
                    }
                }
            }
            hal.cpu.pause();
        }

        console.err("XHCI: No-Op command timeout", .{});
        return error.Timeout;
    }

    /// Update Event Ring Dequeue Pointer
    fn updateErdp(self: *Self) void {
        const intr0_base = self.runtime_base + regs.Runtime.interrupter(0);
        const erdp = regs.Erdp.init(self.event_ring.getDequeuePointer(), 0);
        writeReg64(intr0_base, regs.Intr.ERDP, @bitCast(erdp));
    }

    /// Scan ports for connected devices
    pub fn scanPorts(self: *Self) void {
        console.info("XHCI: Scanning {} ports...", .{self.max_ports});

        var port: u8 = 1;
        while (port <= self.max_ports) : (port += 1) {
            const portsc_off = regs.Op.portsc(port);
            const portsc: regs.PortSc = @bitCast(readReg32(self.op_base, portsc_off));

            if (portsc.ccs) {
                const speed_name = switch (portsc.speed) {
                    1 => "Full Speed",
                    2 => "Low Speed",
                    3 => "High Speed",
                    4 => "Super Speed",
                    5 => "Super Speed+",
                    else => "Unknown",
                };
                console.info("XHCI: Port {} connected, speed={s}, enabled={}", .{
                    port,
                    speed_name,
                    portsc.ped,
                });
            }
        }
    }

    /// Stop the controller
    pub fn stop(self: *Self) void {
        if (!self.running) return;

        var usbcmd: regs.UsbCmd = @bitCast(readReg32(self.op_base, regs.Op.USBCMD));
        usbcmd.rs = false;
        writeReg32(self.op_base, regs.Op.USBCMD, @bitCast(usbcmd));

        self.running = false;
        console.info("XHCI: Controller stopped", .{});
    }
};

// =============================================================================
// Interrupt Handler
// =============================================================================

/// Global controller reference for interrupt handler
var global_controller: ?*Controller = null;

/// MSI-X interrupt handler
fn handleInterrupt(frame: *idt.InterruptFrame) void {
    _ = frame;

    const ctrl = global_controller orelse return;

    // Check for pending events
    while (ctrl.event_ring.hasPending()) {
        const event = ctrl.event_ring.dequeue() orelse break;
        processEvent(ctrl, event);
    }

    // Update ERDP and clear interrupt pending
    ctrl.updateErdp();

    const intr0_base = ctrl.runtime_base + regs.Runtime.interrupter(0);
    var iman: regs.Iman = @bitCast(readReg32(intr0_base, regs.Intr.IMAN));
    iman.ip = true; // Write 1 to clear
    writeReg32(intr0_base, regs.Intr.IMAN, @bitCast(iman));
}

/// Process a single event TRB
fn processEvent(ctrl: *Controller, event: *const trb.Trb) void {
    // Validate event pointer is within Event Ring bounds
    const event_addr = @intFromPtr(event);
    const ring_base = @intFromPtr(ctrl.event_ring.trbs);
    const ring_end = ring_base + ctrl.event_ring.size * @sizeOf(trb.Trb);

    if (event_addr < ring_base or event_addr >= ring_end) {
        console.err("XHCI: Invalid event pointer {x}", .{event_addr});
        return;
    }

    const event_type = ring.getTrbType(event);

    switch (event_type) {
        .CommandCompletionEvent => {
            const completion = trb.CommandCompletionEventTrb.fromTrb(event);

            // Validate command pointer alignment
            if (completion.command_trb_pointer != 0 and completion.command_trb_pointer % 16 != 0) {
                 console.warn("XHCI: Invalid command TRB pointer alignment {x}", .{completion.command_trb_pointer});
            }
            
            console.debug("XHCI: Command completion, code={}", .{@intFromEnum(completion.status.completion_code)});
        },
        .PortStatusChangeEvent => {
            const psc = trb.PortStatusChangeEventTrb.fromTrb(event);
            const port_id = psc.getPortId();
            console.info("XHCI: Port {} status changed", .{port_id});
        },
        .TransferEvent => {
            const transfer = trb.TransferEventTrb.fromTrb(event);
            console.debug("XHCI: Transfer event, slot={}, ep={}, code={}", .{
                transfer.control.slot_id,
                transfer.control.ep_id,
                @intFromEnum(transfer.status.completion_code),
            });
        },
        else => {
            console.debug("XHCI: Unhandled event type {}", .{@intFromEnum(event_type)});
        },
    }
}

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

fn readReg64(base: u64, offset: u64) u64 {
    const ptr: *volatile u64 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn writeReg32(base: u64, offset: u64, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
}

fn writeReg64(base: u64, offset: u64, value: u64) void {
    const ptr: *volatile u64 = @ptrFromInt(base + offset);
    ptr.* = value;
}

// =============================================================================
// Module Initialization
// =============================================================================

/// Probe for XHCI controllers and initialize them
pub fn probe(devices: *const pci.DeviceList, ecam: *const pci.Ecam) void {
    console.info("XHCI: Probing for controllers...", .{});

    if (devices.findXhciController()) |dev| {
        const ctrl = Controller.init(dev, ecam) catch |err| {
            console.err("XHCI: Failed to initialize controller: {}", .{err});
            return;
        };

        global_controller = ctrl;

        // Test with No-Op command
        ctrl.sendNoOp() catch |err| {
            console.err("XHCI: No-Op test failed: {}", .{err});
        };

        // Scan for connected devices
        ctrl.scanPorts();
    } else {
        console.info("XHCI: No controllers found", .{});
    }
}

/// Get the global controller (if initialized)
pub fn getController() ?*Controller {
    return global_controller;
}
