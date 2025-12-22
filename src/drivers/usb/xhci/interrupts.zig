const std = @import("std");
const console = @import("console");
const hal = @import("hal");
const pci = @import("pci");

const types = @import("types.zig");
const regs = @import("regs.zig");
const trb = @import("trb.zig");
const ring = @import("ring.zig");
const device = @import("device.zig");
const device_manager = @import("device_manager.zig");

const interrupts = hal.interrupts;
const Controller = types.Controller;

pub const MsixVectorAllocation = interrupts.MsixVectorAllocation;

/// Global pointer to controller for interrupt handler
var g_controller: ?*Controller = null;

/// MSI-X Interrupt Handler
pub fn handleInterrupt(frame: *hal.interrupts.InterruptFrame) void {
    const vector: u8 = @truncate(frame.vector);
    _ = vector;
    // Identify which interrupter this is
    // For now we assume 1:1 mapping or primary interrupter
    // const interrupter_idx: u8 = 0; // TODO: Map vector to interrupter index
    
    if (g_controller) |ctrl| {
        _ = processEvents(ctrl);
    }
}

/// Poll events manually (for non-MSI mode or testing)
/// Returns number of events processed
pub fn poll_events() usize {
    if (g_controller) |ctrl| {
        return processEvents(ctrl);
    }
    return 0;
}

/// Helper for binding poll function
fn poll_events_wrapper() usize {
    return poll_events();
}

/// Process all pending events in the Event Ring
pub fn processEvents(ctrl: *Controller) usize {
    var count: usize = 0;

    while (ctrl.event_ring.hasPending()) {
        const event = ctrl.event_ring.dequeue() orelse break;
        count += 1;

        const event_type = ring.getTrbType(event);
        
        // Update ERDP for every event (or batch it? Specs say update ERDP to clear EHB)
        // We update at end or per event. Per event is safer for now.
        // Actually, updating ERDP clears the specific event segment?
        // No, ERDP points to current dequeue ptr.
        // Updating it tells HW we processed up to here.
        ctrl.updateErdp();

        switch (event_type) {
            .TransferEvent => {
                const evt = trb.TransferEventTrb.fromTrb(event);
                const slot_id = evt.control.slot_id;
                const ep_dci = evt.control.ep_id;
                const code = evt.status.completion_code;
                const len = evt.status.trb_transfer_length;

                // 1. Check if it matches a synchronous PendingTransfer
                if (device.matchesPendingTransfer(slot_id, ep_dci)) {
                    device.completePendingTransfer(code, @truncate(len));
                }
                
                // 2. Check if it's an asynchronous Interrupt endpoint (HID/Hub)
                if (device.findDevice(slot_id)) |dev| {
                    if (dev.state == .polling and ep_dci == dev.interrupt_dci) {
                        // Handle interrupt data
                        if (code == .Success or code == .ShortPacket) {
                            // Data is in dev.report_buffer
                            // IMPORTANT: trb_transfer_length is RESIDUAL (bytes NOT transferred)
                            // Actual transferred = request_length - residual
                            // Interrupt transfers request 8 bytes (see transfer/interrupt.zig)
                            const request_len: u32 = 8;
                            const actual_transferred = if (len <= request_len) request_len - len else 0;
                            // Security: Ensure actual_transferred doesn't exceed buffer
                            const data_len = @min(actual_transferred, @as(u32, @intCast(dev.report_buffer.len)));
                            device_manager.handleInterrupt(ctrl, dev, dev.report_buffer[0..data_len]);
                        } else {
                            console.warn("XHCI: Interrupt transfer failed: {}", .{@intFromEnum(code)});
                            // Retry?
                            // device_manager.handleInterrupt handles retry logic or error state
                        }
                    }
                }
            },
            .CommandCompletionEvent => {
                // Signal command completion to waiters via atomic flag
                // This avoids the race condition where waiters poll the event ring
                // but the interrupt handler has already consumed the event.
                const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                ctrl.pending_cmd_slot_id = completion.getSlotId();
                ctrl.pending_cmd_code = completion.status.completion_code;
                // Store with release semantics so waiters see updated slot_id and code
                ctrl.pending_cmd_valid.store(true, .release);
            },
            .PortStatusChangeEvent => {
                console.info("XHCI: Port Status Change Event", .{});
                // TODO: Handle hotplug
                // ports.handlePortStatusChange(ctrl, ...);
            },
            else => {
                // console.debug("XHCI: Ignored event type {}", .{event_type});
            },
        }
    }
    
    return count;
}

/// Set up interrupt handling
pub fn setupInterrupts(ctrl: *Controller) !void {
    // Set global controller reference
    g_controller = ctrl;
    
    // Set polling function pointer
    ctrl.poll_events_fn = poll_events_wrapper;

    // MSI-X requires ECAM access
    const ecam_ptr: ?*const pci.Ecam = switch (ctrl.pci_access) {
        .ecam => |*e| e,
        .legacy => null,
    };

    // Try to enable MSI-X (only with ECAM)
    if (ecam_ptr) |ecam| {
        if (pci.findMsix(ecam, ctrl.pci_dev)) |msix_cap| {
            console.info("XHCI: Found MSI-X capability, attempting to enable...", .{});

            // Allocate 1 vector
            if (interrupts.allocateMsixVector()) |vector| {
                // Register handler
                if (interrupts.registerMsixHandler(vector, handleInterrupt)) {
                    // Enable MSI-X
                    if (pci.enableMsix(ecam, ctrl.pci_dev, &msix_cap, 0)) |msix_alloc| {
                        // Configure vector 0 to point to our allocated vector and BSP
                        const dest_id: u8 = @truncate(hal.apic.lapic.getId());
                        _ = pci.configureMsixEntry(msix_alloc.table_base, msix_alloc.vector_count, 0, vector, dest_id);

                        // Unmask vectors
                        pci.enableMsixVectors(ecam, ctrl.pci_dev, &msix_cap);

                        // Disable legacy INTx
                        pci.msi.disableIntx(ecam, ctrl.pci_dev);

                        ctrl.msix_vectors = interrupts.MsixVectorAllocation{
                            .first_vector = vector,
                            .count = 1,
                        };

                        console.info("XHCI: MSI-X enabled with vector {}", .{vector});
                    } else {
                        console.err("XHCI: Failed to enable MSI-X capability", .{});
                        interrupts.unregisterMsixHandler(vector);
                        _ = interrupts.freeMsixVector(vector);
                    }
                } else {
                    console.err("XHCI: Failed to register MSI-X handler", .{});
                    _ = interrupts.freeMsixVector(vector);
                }
            } else {
                console.warn("XHCI: Failed to allocate MSI-X vector, falling back to polling", .{});
            }
        }
    } else {
        console.info("XHCI: Legacy PCI mode, MSI-X not available", .{});
    }

    if (ctrl.msix_vectors == null) {
        console.info("XHCI: Using polling mode for events", .{});
    }

    // Enable interrupter
    const intr0_base = ctrl.runtime_base + regs.intrSetOffset(0);
    const intr_dev = hal.mmio_device.MmioDevice(regs.IntrReg).init(intr0_base, 0x20);
    var iman = intr_dev.readTyped(.iman, regs.Iman);
    iman.ie = true;
    intr_dev.writeTyped(.iman, iman);
}
