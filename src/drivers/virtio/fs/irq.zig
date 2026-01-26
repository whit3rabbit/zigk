// VirtIO-FS Interrupt Handling
//
// MSI-X setup and interrupt handler for VirtIO-FS device.
// VirtIO-FS uses two queue types:
//   - Queue 0 (hiprio): FORGET/INTERRUPT messages
//   - Queue 1+ (request): Normal FUSE operations
//
// Reference: VirtIO Specification 1.2+ Section 4.1.4 (PCI MSI-X)

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");

const root = @import("root.zig");
const config = @import("config.zig");

// ============================================================================
// MSI-X Setup
// ============================================================================

/// Configure MSI-X interrupts for the device
pub fn setupMsix(device: *root.VirtioFsDevice, pci_access: pci.PciAccess) !void {
    const ecam = switch (pci_access) {
        .ecam => |e| e,
        .legacy => {
            console.warn("VirtIO-FS: MSI-X not available with legacy PCI access", .{});
            return;
        },
    };

    // Find MSI-X capability
    const msix_cap = pci.capabilities.findMsix(&ecam, device.pci_dev) orelse {
        console.warn("VirtIO-FS: MSI-X capability not found, using polling", .{});
        return;
    };

    // Enable MSI-X
    const msix_alloc = pci.msi.enableMsix(&ecam, device.pci_dev, &msix_cap, 0) orelse {
        console.warn("VirtIO-FS: Failed to enable MSI-X", .{});
        return;
    };

    console.info("VirtIO-FS: MSI-X enabled with {} vectors", .{msix_alloc.vector_count});

    if (msix_alloc.vector_count == 0) {
        console.warn("VirtIO-FS: No MSI-X vectors available", .{});
        return;
    }

    // Allocate vectors for hiprio and request queues
    // We need at least 2 vectors for proper operation, but can work with 1

    // Vector for request queue (priority)
    const req_vector = hal.interrupts.allocateMsixVector() orelse {
        console.warn("VirtIO-FS: No MSI-X vectors available in kernel pool", .{});
        return;
    };

    // Configure MSI-X table entry for request queue
    const req_configured = pci.msi.configureMsixEntry(
        msix_alloc.table_base,
        msix_alloc.vector_count,
        0, // Entry 0 for request queue
        req_vector,
        0, // Target APIC ID 0 (BSP)
    );

    if (!req_configured) {
        _ = hal.interrupts.freeMsixVector(req_vector);
        console.warn("VirtIO-FS: Failed to configure MSI-X entry for request queue", .{});
        return;
    }

    // Register handler for request queue
    if (!hal.interrupts.registerMsixHandler(req_vector, fsRequestIrqHandler)) {
        _ = hal.interrupts.freeMsixVector(req_vector);
        console.warn("VirtIO-FS: Failed to register request queue IRQ handler", .{});
        return;
    }

    device.msix_request_vector = req_vector;

    // Configure request queue to use MSI-X vector 0
    device.common_cfg.queue_select = config.QueueIndex.REQUEST;
    hal.mmio.memoryBarrier();
    device.common_cfg.queue_msix_vector = 0;
    hal.mmio.memoryBarrier();

    if (device.queues) |*queues| {
        queues.request.msix_vector = 0;
    }

    console.info("VirtIO-FS: Request queue -> MSI-X vector {}", .{req_vector});

    // If we have enough vectors, allocate one for hiprio queue too
    if (msix_alloc.vector_count >= 2) {
        if (hal.interrupts.allocateMsixVector()) |hiprio_vector| {
            const hiprio_configured = pci.msi.configureMsixEntry(
                msix_alloc.table_base,
                msix_alloc.vector_count,
                1, // Entry 1 for hiprio queue
                hiprio_vector,
                0,
            );

            if (hiprio_configured) {
                if (hal.interrupts.registerMsixHandler(hiprio_vector, fsHiprioIrqHandler)) {
                    device.msix_hiprio_vector = hiprio_vector;

                    // Configure hiprio queue to use MSI-X vector 1
                    device.common_cfg.queue_select = config.QueueIndex.HIPRIO;
                    hal.mmio.memoryBarrier();
                    device.common_cfg.queue_msix_vector = 1;
                    hal.mmio.memoryBarrier();

                    console.info("VirtIO-FS: Hiprio queue -> MSI-X vector {}", .{hiprio_vector});
                } else {
                    _ = hal.interrupts.freeMsixVector(hiprio_vector);
                }
            } else {
                _ = hal.interrupts.freeMsixVector(hiprio_vector);
            }
        } else {
            // Not critical - hiprio rarely needs interrupts (FORGET is fire-and-forget)
            console.info("VirtIO-FS: No vector for hiprio queue, using polling", .{});
        }
    }

    // Enable all configured vectors
    pci.msi.enableMsixVectors(&ecam, device.pci_dev, &msix_cap);

    // Disable legacy INTx
    pci.msi.disableIntx(&ecam, device.pci_dev);
}

/// Cleanup MSI-X resources
pub fn cleanupMsix(device: *root.VirtioFsDevice) void {
    if (device.msix_request_vector) |vector| {
        hal.interrupts.unregisterMsixHandler(vector);
        _ = hal.interrupts.freeMsixVector(vector);
        device.msix_request_vector = null;
    }

    if (device.msix_hiprio_vector) |vector| {
        hal.interrupts.unregisterMsixHandler(vector);
        _ = hal.interrupts.freeMsixVector(vector);
        device.msix_hiprio_vector = null;
    }
}

// ============================================================================
// Interrupt Handlers
// ============================================================================

/// Handler for request queue interrupts
fn fsRequestIrqHandler(_: *hal.idt.InterruptFrame) void {
    if (root.getDevice()) |device| {
        handleRequestInterrupt(device);
    }
}

/// Handler for hiprio queue interrupts
fn fsHiprioIrqHandler(_: *hal.idt.InterruptFrame) void {
    if (root.getDevice()) |device| {
        handleHiprioInterrupt(device);
    }
}

/// Handle interrupt from request queue
pub fn handleRequestInterrupt(device: *root.VirtioFsDevice) void {
    // Read and clear ISR (if available)
    if (device.isr_addr != 0) {
        const isr_ptr: *volatile u8 = @ptrFromInt(device.isr_addr);
        _ = isr_ptr.*; // Reading clears the ISR
    }

    // Process completed requests
    if (device.queues) |*queues| {
        queues.request.processCompleted();
    }
}

/// Handle interrupt from hiprio queue
pub fn handleHiprioInterrupt(device: *root.VirtioFsDevice) void {
    // Read and clear ISR
    if (device.isr_addr != 0) {
        const isr_ptr: *volatile u8 = @ptrFromInt(device.isr_addr);
        _ = isr_ptr.*;
    }

    // Process completed FORGET messages (clean up descriptors)
    if (device.queues) |*queues| {
        queues.hiprio.processCompleted();
    }
}

// ============================================================================
// Legacy IRQ
// ============================================================================

/// Register legacy IRQ handler (fallback if MSI-X unavailable)
pub fn registerLegacyIrq(device: *root.VirtioFsDevice) void {
    const irq_line = device.pci_dev.irq_line;

    if (irq_line == 0 or irq_line == 255) {
        console.warn("VirtIO-FS: No IRQ line assigned, using polling", .{});
        return;
    }

    const vector = @as(u8, @intCast(irq_line)) + 32; // PIC offset

    hal.interrupts.registerHandler(vector, fsLegacyIrqHandler);
    console.info("VirtIO-FS: Registered legacy IRQ {} (vector {})", .{ irq_line, vector });

    hal.apic.routeIrq(irq_line, vector, 0);
    hal.apic.enableIrq(irq_line);
}

/// Legacy IRQ handler (handles both queues)
fn fsLegacyIrqHandler(frame: *hal.idt.InterruptFrame) void {
    fsRequestIrqHandler(frame);
    fsHiprioIrqHandler(frame);
}

// ============================================================================
// Polling Mode
// ============================================================================

/// Poll for completions (used when interrupts are unavailable or debugging)
pub fn pollCompletions(device: *root.VirtioFsDevice) u32 {
    if (device.queues) |*queues| {
        var processed: u32 = 0;

        // Poll request queue
        while (queues.request.hasPending() and processed < 256) : (processed += 1) {
            queues.request.processCompleted();
        }

        // Poll hiprio queue (less frequently)
        queues.hiprio.processCompleted();

        return processed;
    }
    return 0;
}
