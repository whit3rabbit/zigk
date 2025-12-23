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
const interrupt_transfer = @import("transfer/interrupt.zig");
const transfer_pool = @import("transfer_pool.zig");
const ports = @import("ports.zig");

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

/// Maximum events to process per interrupt to prevent DoS from malicious hardware
/// Security: Limits CPU time spent in interrupt handler
const MAX_EVENTS_PER_INTERRUPT: usize = 256;

/// Process all pending events in the Event Ring
/// Security: Limits events processed per call to prevent DoS attacks
pub fn processEvents(ctrl: *Controller) usize {
    var count: usize = 0;

    // Security: Cap iterations to prevent a malicious device from monopolizing CPU
    while (count < MAX_EVENTS_PER_INTERRUPT and ctrl.event_ring.hasPending()) {
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

                // Security: Validate slot_id from hardware before any lookup
                // slot_id 0 is reserved for host controller, 1-255 are valid device slots
                if (slot_id == 0 or slot_id > ctrl.max_slots) {
                    console.warn("XHCI: Invalid slot_id {} in TransferEvent, ignoring", .{slot_id});
                    continue;
                }

                // 0. Check for async TransferRequest (new IoRequest-based path)
                // Pattern: Grab under lock, complete outside lock (AHCI style)
                // Security: Must acquire reference to device to prevent UAF if device
                // disconnects on another CPU while we're processing the completion.
                if (device.findDeviceWithRef(slot_id)) |dev| {
                    defer _ = dev.releaseRef(); // Security: Always release reference

                    var transfer_req: ?*device.UsbDevice.TransferRequest = null;

                    // Grab pending transfer under device lock
                    {
                        const held = dev.device_lock.acquire();
                        defer held.release();
                        transfer_req = dev.takePendingTransfer(@truncate(ep_dci));
                    }

                    // Complete OUTSIDE lock to avoid holding lock during IoRequest completion
                    if (transfer_req) |req| {
                        // complete() handles: state transition, IoRequest completion, sched.unblock
                        if (req.complete(code, @truncate(len))) {
                            // Execute callback if present (for HID re-queue in IoRequest mode)
                            // Security: Callbacks must NOT retain references to dev or report_buffer
                            // past their return - we release the reference after this block.
                            switch (req.callback) {
                                .interrupt => |cb| cb(dev, dev.report_buffer),
                                .control => |cb| cb(dev, code, @truncate(len)),
                                .none => {},
                            }
                        }
                        // Return request to pool
                        transfer_pool.freeRequest(req);
                        continue; // Skip legacy paths
                    }
                }

                // 1. Check if it matches a synchronous PendingTransfer (legacy path)
                if (device.matchesPendingTransfer(slot_id, ep_dci)) {
                    device.completePendingTransfer(code, @truncate(len));
                }

                // 2. Check if it's an asynchronous Interrupt endpoint (HID/Hub)
                // Security: Use getInterruptEventData to safely access device state
                // under the lock, preventing TOCTOU race with device disconnect.
                // The returned data holds a reference that we MUST release.
                if (device.getInterruptEventData(slot_id, ep_dci)) |evt_data| {
                    defer evt_data.release(); // Security: Always release reference

                    // Handle interrupt data
                    if (code == .Success or code == .ShortPacket) {
                        // IMPORTANT: trb_transfer_length is RESIDUAL (bytes NOT transferred)
                        // Actual transferred = request_length - residual
                        // Security: Use the stored request length from when transfer was queued,
                        // not a hardcoded constant that could diverge from actual queued length.
                        const request_len: u24 = evt_data.last_request_len;

                        // Security: Validate residual doesn't exceed request length
                        // A malicious device could return invalid residual values
                        const actual_transferred: u24 = if (len <= request_len) request_len - len else 0;

                        // Security: Double-validate against the pre-validated buffer length
                        // evt_data.report_buffer_len was captured under lock
                        const data_len: usize = @min(
                            @as(usize, actual_transferred),
                            evt_data.report_buffer_len,
                        );

                        // Security: Validate data_len is reasonable (non-zero for success)
                        // and doesn't exceed our buffer. The report_buffer was zeroed before
                        // transfer was queued (see interrupt_transfer.queueInterruptTransfer),
                        // so even if hardware lies about residual, we only see zeros.
                        if (data_len <= evt_data.report_buffer_len) {
                            device_manager.handleInterrupt(ctrl, evt_data.dev, evt_data.report_buffer[0..data_len]);
                        }
                    } else {
                        console.warn("XHCI: Interrupt transfer failed: {}", .{@intFromEnum(code)});
                    }
                }
            },
            .CommandCompletionEvent => {
                // Signal command completion to waiters via atomic packed struct
                // Security: Atomic store of entire struct prevents TOCTOU race
                // where waiters could read stale slot_id/code with new valid flag.
                const completion = trb.CommandCompletionEventTrb.fromTrb(event);
                ctrl.pending_cmd_result.store(
                    types.PendingCmdResult.fromCompletion(
                        completion.getSlotId(),
                        completion.status.completion_code,
                    ),
                    .release,
                );
            },
            .PortStatusChangeEvent => {
                const psc_evt = trb.PortStatusChangeEventTrb.fromTrb(event);
                const port_id = psc_evt.getPortId();
                ports.handlePortStatusChange(ctrl, port_id);
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
