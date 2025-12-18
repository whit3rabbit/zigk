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
const MmioDevice = hal.mmio_device.MmioDevice;

const regs = @import("regs.zig");
const trb = @import("trb.zig");
const ring = @import("ring.zig");
const context = @import("context.zig");
const device = @import("device.zig");
const descriptor = @import("descriptor.zig");
const transfer = @import("transfer.zig");
const hid = @import("../class/hid.zig");
const msc = @import("../class/msc.zig");
const hub = @import("../class/hub.zig");

// Re-export submodules
pub const Regs = regs;
pub const Trb = trb;
pub const Ring = ring;
pub const Context = context;
pub const Device = device;
pub const Transfer = transfer;

// =============================================================================
// Controller State
// =============================================================================

/// XHCI Controller instance
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

    /// Controller state
    running: bool,

    const Self = @This();

    /// Initialize the XHCI controller
    pub fn init(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !*Self {
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
        // Use explicit mapping for high addresses (above RAM) like PCI MMIO regions
        const bar0_virt = vmm.mapMmioExplicit(bar0.base, bar0.size) catch |err| {
            console.err("XHCI: Failed to map BAR0 MMIO: {}", .{err});
            return error.MmioMapFailed;
        };

        // Read capability registers
        const cap_dev = MmioDevice(regs.CapReg).init(bar0_virt, 0x1000); // Size approximate for now
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

        // Calculate register base addresses
        // Security: Validate hardware-provided offsets against BAR0 size
        // to prevent malicious controllers from causing out-of-bounds MMIO access
        if (caplength >= bar0.size) {
            console.err("XHCI: Invalid CAPLENGTH {} exceeds BAR0 size {}", .{ caplength, bar0.size });
            return error.InvalidHardwareConfig;
        }
        if (rtsoff >= bar0.size or rtsoff + 0x20 > bar0.size) {
            console.err("XHCI: Invalid RTSOFF {x} exceeds BAR0 size {x}", .{ rtsoff, bar0.size });
            return error.InvalidHardwareConfig;
        }
        if (dboff >= bar0.size) {
            console.err("XHCI: Invalid DBOFF {x} exceeds BAR0 size {x}", .{ dboff, bar0.size });
            return error.InvalidHardwareConfig;
        }

        const op_base = bar0_virt + caplength;
        const runtime_base = bar0_virt + rtsoff;
        const doorbell_base = bar0_virt + dboff;

        // Allocate controller structure
        const ctrl_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
        const ctrl_virt = @intFromPtr(hal.paging.physToVirt(ctrl_phys));
        const ctrl: *Self = @ptrFromInt(ctrl_virt);

        ctrl.* = Self{
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
        
        const op_dev = MmioDevice(regs.OpReg).init(self.op_base, 0x1000);

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
            hal.cpu.pause();
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
        const op_dev = MmioDevice(regs.OpReg).init(self.op_base, 0x1000);

        // Set MaxSlotsEnabled
        var config = op_dev.readTyped(.config, regs.Config);
        config.max_slots_en = self.max_slots;
        op_dev.writeTyped(.config, config);

        // Allocate DCBAA
        self.dcbaa = try context.Dcbaa.alloc(self.max_slots);
        op_dev.write64(.dcbaap, self.dcbaa.getPhysicalAddress());
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
        op_dev.write64(.crcr, @bitCast(crcr));
        console.info("XHCI: Command Ring at physical {x:0>16}", .{self.command_ring.getPhysicalAddress()});

        // Allocate Event Ring
        self.event_ring = try ring.ConsumerRing.init();

        // Configure Interrupter 0
        const intr0_base = self.runtime_base + regs.intrSetOffset(0);
        const intr_dev = MmioDevice(regs.IntrReg).init(intr0_base, 0x20);

        // Set ERSTSZ (Event Ring Segment Table Size)
        intr_dev.write32(.erstsz, self.event_ring.getErstSize());

        // Set ERDP (Event Ring Dequeue Pointer)
        const erdp = regs.Erdp.init(self.event_ring.getDequeuePointer(), 0);
        intr_dev.writeTyped64(.erdp, erdp);

        // Set ERSTBA (Event Ring Segment Table Base Address)
        intr_dev.write64(.erstba, self.event_ring.getErstBase());

        console.info("XHCI: Event Ring at physical {x:0>16}", .{self.event_ring.phys_base});
    }

    /// Maximum scratchpad buffers that fit in one page (4096 bytes / 8 bytes per entry)
    const MAX_SCRATCHPAD_ENTRIES: u16 = 512;

    /// Allocate scratchpad buffers
    /// Security: Validates scratchpad count to prevent heap overflow
    fn allocScratchpads(self: *Self) !void {
        console.info("XHCI: Allocating {} scratchpad buffers", .{self.scratchpad_count});

        // Security: Validate scratchpad count against array capacity
        // A malicious controller could report an excessive count
        if (self.scratchpad_count > MAX_SCRATCHPAD_ENTRIES) {
            console.err("XHCI: Scratchpad count {} exceeds max {} (single page limit)", .{
                self.scratchpad_count,
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
        while (i < self.scratchpad_count) : (i += 1) {
            const buf_phys = pmm.allocZeroedPages(1) orelse return error.OutOfMemory;
            array[i] = buf_phys;
        }

        // Set DCBAA[0] to scratchpad array
        self.dcbaa.setScratchpadArray(array_phys);
    }

    /// Set up interrupt handling
    fn setupInterrupts(self: *Self) !void {
        // MSI-X requires ECAM access
        const ecam_ptr: ?*const pci.Ecam = switch (self.pci_access) {
            .ecam => |*e| e,
            .legacy => null,
        };

        // Try to enable MSI-X (only with ECAM)
        if (ecam_ptr) |ecam| {
            if (pci.findMsix(ecam, self.pci_dev)) |msix_cap| {
                console.info("XHCI: Found MSI-X capability, attempting to enable...", .{});

                // Allocate 1 vector
                if (interrupts.allocateMsixVector()) |vector| {
                    // Register handler
                    if (interrupts.registerMsixHandler(vector, handleInterrupt)) {
                        // Enable MSI-X
                        // Note: We pass 0 for bar_virt to let enableMsix map it
                        if (pci.enableMsix(ecam, self.pci_dev, &msix_cap, 0)) |msix_alloc| {
                            // Configure vector 0 to point to our allocated vector and BSP
                            // Use current CPU ID or 0 (BSP)
                            const dest_id: u8 = @truncate(hal.apic.lapic.getId());
                            _ = pci.configureMsixEntry(msix_alloc.table_base, msix_alloc.vector_count, 0, vector, dest_id);

                            // Unmask vectors
                            pci.enableMsixVectors(ecam, self.pci_dev, &msix_cap);

                            // Disable legacy INTx
                            pci.msi.disableIntx(ecam, self.pci_dev);

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
        } else {
            console.info("XHCI: Legacy PCI mode, MSI-X not available", .{});
        }

        if (self.msix_vectors == null) {
            console.info("XHCI: Using polling mode for events", .{});
        }

        // Enable interrupter
        const intr0_base = self.runtime_base + regs.intrSetOffset(0);
        const intr_dev = MmioDevice(regs.IntrReg).init(intr0_base, 0x20);
        var iman = intr_dev.readTyped(.iman, regs.Iman);
        iman.ie = true;
        intr_dev.writeTyped(.iman, iman);
    }

    /// Start the controller
    fn start(self: *Self) !void {
        console.info("XHCI: Starting controller...", .{});

        const op_dev = MmioDevice(regs.OpReg).init(self.op_base, 0x1000);

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
        const mmio = hal.mmio;
        mmio.write32(self.doorbell_base + offset, @bitCast(db));
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

    /// Reset a port to enable it and bring the device to the Default state
    fn resetPort(self: *Self, port: u8) !void {
        const port_base = self.op_base + regs.portBaseOffset(port);
        const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);

        // Read current state
        const portsc = port_dev.readTyped(.portsc, regs.PortSc);

        // If not connected, nothing to do
        if (!portsc.ccs) return;

        // Reset sequence: Write 1 to PR (Port Reset)
        // We must preserve R/W bits and write 1 to Clear R/WC bits (status changes)
        // to avoid clearing them accidentally.
        
        var new_cntl = portsc;
        new_cntl.pr = true;      // Assert Reset
        new_cntl.csc = true;     // Clear Connect Status Change
        new_cntl.pec = true;     // Clear Port Enable/Disable Change
        new_cntl.wrc = true;     // Clear Warm Port Reset Change
        new_cntl.occ = true;     // Clear Over-Current Change
        new_cntl.prc = true;     // Clear Port Reset Change
        new_cntl.plc = true;     // Clear Port Link State Change

        port_dev.writeTyped(.portsc, new_cntl);

        // Wait for reset to complete
        // The controller clears PR bit when reset is done
        var timeout: u32 = 500; // 500ms timeout
        while (timeout > 0) : (timeout -= 1) {
            const current = port_dev.readTyped(.portsc, regs.PortSc);
            
            // Check if Reset is done (PR == 0) and Port Enabled (PED == 1)
            if (!current.pr and current.ped) {
                 console.info("XHCI: Port {d} reset successful (Speed: {d})", .{ port, current.speed });
                 return;
            }
            
            // Wait approx 1ms
            var delay: u32 = 10000;
            while (delay > 0) : (delay -= 1) {
                hal.cpu.pause();
            }
        }

        console.warn("XHCI: Port {d} reset timed out or failed to enable", .{port});
        return error.ResetFailed;
    }

    /// Scan ports for connected devices and attempt enumeration
    pub fn scanPorts(self: *Self) void {
        console.info("XHCI: Scanning {d} ports...", .{self.max_ports});

        var port: u8 = 1;
        while (port <= self.max_ports) : (port += 1) {
            const port_base = self.op_base + regs.portBaseOffset(port);
            const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);
            const portsc = port_dev.readTyped(.portsc, regs.PortSc);

            if (portsc.ccs) {
                const speed_name = switch (portsc.speed) {
                    1 => "Full Speed",
                    2 => "Low Speed",
                    3 => "High Speed",
                    4 => "Super Speed",
                    5 => "Super Speed+",
                    else => "Unknown",
                };
                console.info("XHCI: Port {d} connected, speed={s}, enabled={}", .{
                    port,
                    speed_name,
                    portsc.ped,
                });

                // Reset port if not enabled
                if (!portsc.ped) {
                    self.resetPort(port) catch |err| {
                        console.err("XHCI: Failed to reset port {d}: {}", .{ port, err });
                        continue;
                    };
                }

                // Enumerate the device
                const maybe_dev = self.enumerateDevice(port) catch |err| {
                    console.err("XHCI: Failed to enumerate device on port {d}: {}", .{ port, err });
                    continue;
                };

                // If it's a HID device, start interrupt polling
                if (maybe_dev) |dev| {
                    if (dev.hid_driver.is_keyboard or dev.hid_driver.is_mouse) {
                        self.startInterruptPolling(dev) catch |err| {
                            console.err("XHCI: Failed to start HID polling: {}", .{err});
                        };
                    }
                }
            }
        }
    }

    /// Stop the controller
    pub fn stop(self: *Self) void {
        if (!self.running) return;

        const op_dev = MmioDevice(regs.OpReg).init(self.op_base, 0x1000);
        var usbcmd = op_dev.readTyped(.usbcmd, regs.UsbCmd);
        usbcmd.rs = false;
        op_dev.writeTyped(.usbcmd, usbcmd);

        self.running = false;
        console.info("XHCI: Controller stopped", .{});
    }

    // =========================================================================
    // USB Device Enumeration Commands
    // =========================================================================

    /// Send Enable Slot command and return allocated slot ID
    pub fn enableSlot(self: *Self) !u8 {
        console.info("XHCI: Sending Enable Slot command...", .{});

        var enable_cmd = trb.EnableSlotCmdTrb.init(self.command_ring.getCycleState());
        _ = self.command_ring.enqueue(enable_cmd.asTrb().*) orelse {
            return error.RingFull;
        };

        self.ringDoorbell(0, 0);

        // Wait for completion
        var timeout: u32 = 50000;
        while (timeout > 0) : (timeout -= 1) {
            if (self.event_ring.hasPending()) {
                const event = self.event_ring.dequeue() orelse continue;
                const event_type = ring.getTrbType(event);

                if (event_type == .CommandCompletionEvent) {
                    const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                    self.updateErdp();

                    if (completion.status.completion_code == .Success) {
                        const slot_id = completion.getSlotId();
                        console.info("XHCI: Enable Slot succeeded, slot_id={}", .{slot_id});
                        return slot_id;
                    } else {
                        console.err("XHCI: Enable Slot failed: {}", .{@intFromEnum(completion.status.completion_code)});
                        return error.CommandFailed;
                    }
                }
            }
            hal.cpu.pause();
        }

        return error.Timeout;
    }

    /// Send Address Device command
    pub fn addressDevice(self: *Self, dev: *device.UsbDevice, bsr: bool) !void {
        console.info("XHCI: Sending Address Device command (slot={}, BSR={})...", .{ dev.slot_id, bsr });

        // Build Address Device command TRB
        var addr_cmd = trb.AddressDeviceCmdTrb.init(
            dev.input_context_phys,
            dev.slot_id,
            bsr,
            self.command_ring.getCycleState(),
        );

        _ = self.command_ring.enqueue(addr_cmd.asTrb().*) orelse {
            return error.RingFull;
        };

        // Register device context in DCBAA
        self.dcbaa.setSlot(dev.slot_id, dev.device_context_phys);

        self.ringDoorbell(0, 0);

        // Wait for completion
        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            if (self.event_ring.hasPending()) {
                const event = self.event_ring.dequeue() orelse continue;
                const event_type = ring.getTrbType(event);

                if (event_type == .CommandCompletionEvent) {
                    const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                    self.updateErdp();

                    if (completion.status.completion_code == .Success) {
                        console.info("XHCI: Address Device succeeded", .{});
                        return;
                    } else {
                        console.err("XHCI: Address Device failed: {}", .{@intFromEnum(completion.status.completion_code)});
                        return error.CommandFailed;
                    }
                }
            }
            hal.cpu.pause();
        }

        return error.Timeout;
    }

    /// Send Configure Endpoint command
    pub fn configureEndpoint(self: *Self, dev: *device.UsbDevice) !void {
        console.info("XHCI: Sending Configure Endpoint command (slot={})...", .{dev.slot_id});

        var config_cmd = trb.ConfigureEndpointCmdTrb.init(
            dev.input_context_phys,
            dev.slot_id,
            false, // Not deconfiguring
            self.command_ring.getCycleState(),
        );

        _ = self.command_ring.enqueue(config_cmd.asTrb().*) orelse {
            return error.RingFull;
        };

        self.ringDoorbell(0, 0);

        // Wait for completion
        var timeout: u32 = 100000;
        while (timeout > 0) : (timeout -= 1) {
            if (self.event_ring.hasPending()) {
                const event = self.event_ring.dequeue() orelse continue;
                const event_type = ring.getTrbType(event);

                if (event_type == .CommandCompletionEvent) {
                    const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                    self.updateErdp();

                    if (completion.status.completion_code == .Success) {
                        console.info("XHCI: Configure Endpoint succeeded", .{});
                        return;
                    } else {
                        console.err("XHCI: Configure Endpoint failed: {}", .{@intFromEnum(completion.status.completion_code)});
                        return error.CommandFailed;
                    }
                }
            }
            hal.cpu.pause();
        }

        return error.Timeout;
    }

    /// Send Evaluate Context command (for updating EP0 max packet size)
    pub fn evaluateContext(self: *Self, dev: *device.UsbDevice) !void {
        console.info("XHCI: Sending Evaluate Context command (slot={})...", .{dev.slot_id});

        var eval_cmd = trb.EvaluateContextCmdTrb.init(
            dev.input_context_phys,
            dev.slot_id,
            self.command_ring.getCycleState(),
        );

        _ = self.command_ring.enqueue(eval_cmd.asTrb().*) orelse {
            return error.RingFull;
        };

        self.ringDoorbell(0, 0);

        // Wait for completion
        var timeout: u32 = 50000;
        while (timeout > 0) : (timeout -= 1) {
            if (self.event_ring.hasPending()) {
                const event = self.event_ring.dequeue() orelse continue;
                const event_type = ring.getTrbType(event);

                if (event_type == .CommandCompletionEvent) {
                    const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                    self.updateErdp();

                    if (completion.status.completion_code == .Success) {
                        console.info("XHCI: Evaluate Context succeeded", .{});
                        return;
                    } else {
                        console.err("XHCI: Evaluate Context failed: {}", .{@intFromEnum(completion.status.completion_code)});
                        return error.CommandFailed;
                    }
                }
            }
            hal.cpu.pause();
        }

        return error.Timeout;
    }

    // =========================================================================
    // Device Enumeration State Machine
    // =========================================================================

    /// Enumerate a USB device on a port
    /// Returns configured device if successful, null if not a keyboard
    pub fn enumerateDevice(self: *Self, port: u8) !?*device.UsbDevice {
        // Get port speed
        const port_base = self.op_base + regs.portBaseOffset(port);
        const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);
        const portsc = port_dev.readTyped(.portsc, regs.PortSc);

        if (!portsc.ccs or !portsc.ped) {
            console.warn("XHCI: Port {} not connected or enabled", .{port});
            return null;
        }

        const speed: context.Speed = @enumFromInt(portsc.speed);
        console.info("XHCI: Enumerating device on port {} (speed={})", .{ port, @intFromEnum(speed) });

        // 1. Enable Slot
        const slot_id = try self.enableSlot();

        // 2. Allocate device structure
        var dev = try device.UsbDevice.init(slot_id, port, speed);
        errdefer dev.deinit();

        // 3. Build Input Context for Address Device
        dev.buildAddressDeviceContext();

        // 4. Address Device (BSR=0 sends SET_ADDRESS automatically)
        try self.addressDevice(dev, false);
        dev.state = .addressed;

        // 5. GET_DESCRIPTOR(Device, 8 bytes) - get max packet size
        var desc_buf: [18]u8 = undefined;
        const bytes_read = transfer.getDeviceDescriptor(self, dev, desc_buf[0..8]) catch |err| {
            console.err("XHCI: Failed to get device descriptor (short): {}", .{err});
            return err;
        };

        if (bytes_read < 8) {
            console.err("XHCI: Device descriptor too short: {} bytes", .{bytes_read});
            return error.InvalidDescriptor;
        }

        // Update max packet size from descriptor
        const new_max_packet = desc_buf[7];
        if (new_max_packet != dev.max_packet_size) {
            console.info("XHCI: Updating max packet size from {} to {}", .{ dev.max_packet_size, new_max_packet });
            dev.updateMaxPacketSize(new_max_packet);
            dev.buildEvaluateContext();
            try self.evaluateContext(dev);
        }

        // 6. GET_DESCRIPTOR(Device, full 18 bytes)
        _ = transfer.getDeviceDescriptor(self, dev, &desc_buf) catch |err| {
            console.err("XHCI: Failed to get full device descriptor: {}", .{err});
            return err;
        };

        const vid = @as(u16, desc_buf[8]) | (@as(u16, desc_buf[9]) << 8);
        const pid = @as(u16, desc_buf[10]) | (@as(u16, desc_buf[11]) << 8);
        console.info("XHCI: Device VID={x:0>4} PID={x:0>4}", .{ vid, pid });

        // 7. GET_DESCRIPTOR(Configuration)
        var config_buf: [256]u8 = undefined;
        const config_len = transfer.getConfigDescriptor(self, dev, 0, &config_buf) catch |err| {
            console.err("XHCI: Failed to get config descriptor: {}", .{err});
            return err;
        };

        // 8. Parse configuration for HID interface (keyboard or mouse)
        var interface_num: u8 = 0;
        var endpoint_addr: u8 = 0;
        var max_packet: u16 = 0;
        var interval: u8 = 0;

        if (transfer.findKeyboardInterface(config_buf[0..config_len])) |info| {
            console.info("XHCI: Found HID Keyboard", .{});
            dev.hid_driver.is_keyboard = true;
            interface_num = info.interface_num;
            endpoint_addr = info.endpoint_addr;
            max_packet = info.max_packet;
            interval = info.interval;
        } else if (transfer.findMouseInterface(config_buf[0..config_len])) |info| {
            console.info("XHCI: Found HID Mouse", .{});
            dev.hid_driver.is_mouse = true;
            interface_num = info.interface_num;
            endpoint_addr = info.endpoint_addr;
            max_packet = info.max_packet;
            interval = info.interval;
        } else if (transfer.findMscInterface(config_buf[0..config_len])) |info| {
            console.info("XHCI: Found Mass Storage Device", .{});
            console.info("XHCI: MSC Endpoints in=0x{x} out=0x{x} max={}", .{info.bulk_in_ep, info.bulk_out_ep, info.max_packet});
            
            // 9. SET_CONFIGURATION
            const config_val = config_buf[5]; 
            transfer.setConfiguration(self, dev, config_val) catch |err| {
                console.err("XHCI: Failed to set configuration: {}", .{err});
                return err;
            };

            // Configure Bulk IN
            try dev.initBulkEndpoint(info.bulk_in_ep);
            try dev.buildConfigureEndpointContext(info.bulk_in_ep, .bulk_in, info.max_packet, 0);
            try self.configureEndpoint(dev);

             // Configure Bulk OUT
            try dev.initBulkEndpoint(info.bulk_out_ep);
            try dev.buildConfigureEndpointContext(info.bulk_out_ep, .bulk_out, info.max_packet, 0);
            try self.configureEndpoint(dev);

            dev.state = .configured;

            // Run MSC Verification
            var msc_drv = msc.MscDriver.init(self, dev, info.bulk_in_ep, info.bulk_out_ep);
            msc_drv.inquiry() catch |err| {
                console.warn("MSC: Inquiry failed: {}", .{err});
            };

            // Run Capacity Check
            msc_drv.readCapacity() catch |err| {
                console.warn("MSC: Read Capacity failed: {}", .{err});
            };
            
            // Register device
            device.registerDevice(dev);
            console.info("XHCI: USB MSC device enumerated on slot {}", .{slot_id});
            return dev;

        } else if (transfer.findHubInterface(config_buf[0..config_len])) |interface| {
             console.info("XHCI: Found USB Hub Interface {d}", .{interface.bInterfaceNumber});
             
             // Initialize Hub Driver
             dev.is_hub = true;
             
             // Find Interrupt IN endpoint
             var int_in: u8 = 0;
             var max_packet_size: u16 = 8; // Default max packet size for interrupt endpoint
             
             for (interface.endpoints) |ep_desc| {
                 if (ep_desc.bLength == 0) continue;
                 const is_in = (ep_desc.bEndpointAddress & 0x80) != 0;
                 const ep_type = ep_desc.bmAttributes & 0x03;
                 
                 if (is_in and ep_type == 0x03) { // Interrupt IN
                     int_in = ep_desc.bEndpointAddress;
                     max_packet_size = ep_desc.wMaxPacketSize;
                     break;
                 }
             }
             
             // Send Configuration Command (first time for this device, unless already done once for control)
             // Endpoints must be added to Input Context first.
             // For hub, we need to add the Interrupt IN endpoint.
             
             if (int_in != 0) {
                 // Initialize Endpoint
                 console.debug("XHCI: Hub Int IN Endpoint 0x{x} max={d}", .{int_in, max_packet_size});
                 try dev.initBulkEndpoint(int_in); // Reusing bulk helper, works for allocating ring
                 try dev.buildConfigureEndpointContext(int_in, .interrupt_in, max_packet_size, 12); // Interval 12 (~32ms)
             } else {
                 console.warn("XHCI: Hub has no Interrupt IN endpoint", .{});
             }
             
             // Send Configuration Command
             try self.configureEndpoint(dev); // Use self.configureEndpoint
             
             // Initialize Driver
             dev.hub_driver = hub.HubDriver.init(self, dev, int_in);
             try dev.hub_driver.configure();
             
             console.info("XHCI: USB Hub device enumerated on slot {d}", .{slot_id});
             
             device.registerDevice(dev);
             return dev; // Hub returns dev

        } else {
            console.info("XHCI: Device is not a supported device class", .{});
            dev.deinit();
            return null;
        }

        // 9. SET_CONFIGURATION
        const config_value = config_buf[5]; // bConfigurationValue
        transfer.setConfiguration(self, dev, config_value) catch |err| {
            console.err("XHCI: Failed to set configuration: {}", .{err});
            return err;
        };
        console.info("XHCI: Configuration {} set", .{config_value});

        // 10. Configure interrupt endpoint
        try dev.buildConfigureEndpointContext(
            endpoint_addr,
            .interrupt_in,
            max_packet,
            interval,
        );
        try self.configureEndpoint(dev);
        dev.state = .configured;

        // 11. GET_REPORT_DESCRIPTOR to parse full HID capabilities
        var report_desc_buf: [512]u8 = undefined;
        const report_desc_len: usize = transfer.getReportDescriptor(self, dev, interface_num, &report_desc_buf) catch |err| blk: {
            console.warn("XHCI: Failed to get report descriptor: {} - using boot protocol", .{err});
            break :blk 0;
        };

        // 12. Parse report descriptor if we got one
        if (report_desc_len > 0) {
            dev.hid_driver.parseReportDescriptor(report_desc_buf[0..report_desc_len]) catch |err| {
                console.warn("XHCI: Failed to parse report descriptor: {}", .{err});
            };

            // Check if parser detected tablet (overrides initial detection)
            if (dev.hid_driver.is_tablet) {
                console.info("XHCI: Device identified as tablet with absolute positioning", .{});
            }
        }

        // 13. SET_PROTOCOL - only for boot protocol devices (keyboard/mouse, not tablets)
        if (!dev.hid_driver.is_tablet) {
            transfer.setProtocol(self, dev, interface_num, 0) catch |err| {
                console.warn("XHCI: Failed to set boot protocol (may be OK): {}", .{err});
            };
        }

        // 14. SET_IDLE(0) to get reports only on change
        transfer.setIdle(self, dev, interface_num, 0, 0) catch |err| {
            console.warn("XHCI: Failed to set idle (may be OK): {}", .{err});
        };

        // 15. Register device and start polling
        device.registerDevice(dev);
        const device_type: []const u8 = if (dev.hid_driver.is_keyboard)
            "keyboard"
        else if (dev.hid_driver.is_tablet)
            "tablet"
        else
            "mouse";
        console.info("XHCI: USB {s} enumerated successfully on slot {}", .{ device_type, slot_id });

        return dev;
    }

    /// Start interrupt polling for a HID device (keyboard or mouse)
    pub fn startInterruptPolling(self: *Self, dev: *device.UsbDevice) !void {
        console.info("XHCI: Starting HID polling for slot {}", .{dev.slot_id});
        try transfer.queueInterruptTransfer(self, dev);
        dev.state = .polling;
    }

    /// Make updateErdp public for transfer.zig
    pub fn updateErdp(self: *Self) void {
        const intr0_base = self.runtime_base + regs.intrSetOffset(0);
        const intr_dev = MmioDevice(regs.IntrReg).init(intr0_base, 0x20);

        const erdp = regs.Erdp.init(self.event_ring.getDequeuePointer(), 0);
        intr_dev.write64(.erdp, @bitCast(erdp));
    }
};

// =============================================================================
// Interrupt Handler
// =============================================================================

/// Global controller reference for interrupt handler
/// Security: Use atomic operations for thread-safe access between probe() and interrupt handler
var global_controller: std.atomic.Value(?*Controller) = std.atomic.Value(?*Controller).init(null);

/// MSI-X interrupt handler
fn handleInterrupt(frame: *idt.InterruptFrame) void {
    _ = frame;

    // Security: Atomic load ensures we see a consistent pointer value
    const ctrl = global_controller.load(.acquire) orelse return;

    // Check for pending events
    while (ctrl.event_ring.hasPending()) {
        const event = ctrl.event_ring.dequeue() orelse break;
        processEvent(ctrl, event);
    }

    // Update ERDP and clear interrupt pending
    ctrl.updateErdp();

    const intr0_base = ctrl.runtime_base + regs.intrSetOffset(0);
    const intr_dev = MmioDevice(regs.IntrReg).init(intr0_base, 0x20);

    var iman = intr_dev.readTyped(.iman, regs.Iman);
    iman.ip = true; // Write 1 to clear
    intr_dev.writeTyped(.iman, iman);
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
            const transfer_evt = trb.TransferEventTrb.fromTrb(event);
            const slot_id = transfer_evt.control.slot_id;
            const ep_id = transfer_evt.control.ep_id;
            const code = transfer_evt.status.completion_code;
            const residual = transfer_evt.status.trb_transfer_length;

            // Find the device for this slot
            if (device.findDevice(slot_id)) |dev| {
                // Check if this is an interrupt endpoint for keyboard
                if (ep_id == dev.interrupt_dci and dev.state == .polling) {
                    // HID report received
                    if (code == .Success or code == .ShortPacket) {
                        // Security: Calculate actual bytes received from residual
                        // Boot protocol requests 8 bytes, residual = bytes NOT transferred
                        const requested: usize = 8;
                        const actual_len = if (residual <= requested) requested - residual else 0;

                        // Security: Validate we received enough data for a valid report
                        // Boot protocol keyboard reports require at least 8 bytes
                        // Boot protocol mouse reports require at least 3 bytes
                        const min_report_len: usize = if (dev.hid_driver.is_keyboard) 8 else 3;
                        if (actual_len >= min_report_len) {
                            const report = dev.report_buffer[0..actual_len];
                            dev.hid_driver.handleInputReport(report);
                        } else {
                            console.warn("XHCI: Short HID report ({} bytes), ignoring", .{actual_len});
                        }
                    } else if (code == .StallError) {
                        console.warn("XHCI: HID endpoint stalled", .{});
                    }

                    // Re-queue interrupt transfer for continuous polling
                    transfer.queueInterruptTransfer(ctrl, dev) catch |err| {
                        console.err("XHCI: Failed to re-queue HID transfer: {}", .{err});
                        dev.state = .err;
                    };
                } else {
                    // Other transfer (control) - handled by waitForCompletion
                    console.debug("XHCI: Transfer event, slot={}, ep={}, code={}", .{
                        slot_id,
                        ep_id,
                        @intFromEnum(code),
                    });
                }
            } else {
                console.debug("XHCI: Transfer event for unknown slot {}", .{slot_id});
            }
        },
        else => {
            console.debug("XHCI: Unhandled event type {}", .{@intFromEnum(event_type)});
        },
    }
}

// =============================================================================
// MMIO Helpers
// =============================================================================



// =============================================================================
// Module Initialization
// =============================================================================

/// Probe for XHCI controllers and initialize them
pub fn probe(devices: *const pci.DeviceList, pci_access: pci.PciAccess) void {
    console.info("XHCI: Probing for controllers...", .{});

    if (devices.findXhciController()) |dev| {
        const ctrl = Controller.init(dev, pci_access) catch |err| {
            console.err("XHCI: Failed to initialize controller: {}", .{err});
            return;
        };

        // Security: Atomic store ensures interrupt handler sees consistent pointer
        global_controller.store(ctrl, .release);

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
    return global_controller.load(.acquire);
}

/// Poll for pending XHCI events (software fallback when MSI-X isn't working)
/// This should be called periodically to process USB events
/// Returns number of events processed
pub fn pollEvents() usize {
    const ctrl = global_controller.load(.acquire) orelse return 0;

    var event_count: usize = 0;
    while (ctrl.event_ring.hasPending()) {
        const event = ctrl.event_ring.dequeue() orelse break;
        event_count += 1;
        processEvent(ctrl, event);
    }

    if (event_count > 0) {
        // Update ERDP after processing
        ctrl.updateErdp();
    }

    return event_count;
}
