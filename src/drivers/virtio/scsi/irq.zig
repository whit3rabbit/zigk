// VirtIO-SCSI Interrupt Handling
//
// MSI-X setup and interrupt handler for VirtIO-SCSI controller.
// Supports per-queue interrupt vectors for optimal performance.
//
// Reference: VirtIO Specification 1.1, Section 4.1.4 (PCI MSI-X)

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");

const root = @import("root.zig");
const config = @import("config.zig");

// ============================================================================
// MSI-X Setup
// ============================================================================

/// Configure MSI-X interrupts for the controller
pub fn setupMsix(controller: *root.VirtioScsiController, pci_access: pci.PciAccess) !void {
    const ecam = switch (pci_access) {
        .ecam => |e| e,
        .legacy => {
            console.warn("VirtIO-SCSI: MSI-X not available with legacy PCI access", .{});
            return;
        },
    };

    // Find MSI-X capability
    const msix_cap = pci.capabilities.findMsix(&ecam, controller.pci_dev) orelse {
        console.warn("VirtIO-SCSI: MSI-X capability not found, using polling", .{});
        return;
    };

    // Enable MSI-X
    const msix_alloc = pci.msi.enableMsix(&ecam, controller.pci_dev, &msix_cap, 0) orelse {
        console.warn("VirtIO-SCSI: Failed to enable MSI-X", .{});
        return;
    };

    console.info("VirtIO-SCSI: MSI-X enabled with {} vectors", .{msix_alloc.vector_count});

    // Calculate vectors needed:
    // - 1 for configuration changes (optional)
    // - 1 per request queue
    const vectors_needed = controller.queues.request_queue_count + 1;
    const vectors_to_configure = @min(
        @as(usize, vectors_needed),
        @as(usize, msix_alloc.vector_count),
    );

    // Configure vectors for request queues
    for (0..vectors_to_configure) |i| {
        // Allocate vector from kernel pool
        const vector = hal.interrupts.allocateMsixVector() orelse {
            console.warn("VirtIO-SCSI: No more MSI-X vectors available", .{});
            break;
        };

        // Configure MSI-X table entry
        const configured = pci.msi.configureMsixEntry(
            msix_alloc.table_base,
            msix_alloc.vector_count,
            @intCast(i),
            vector,
            0, // Target APIC ID 0 (BSP)
        );

        if (!configured) {
            _ = hal.interrupts.freeMsixVector(vector);
            console.warn("VirtIO-SCSI: Failed to configure MSI-X entry {}", .{i});
            continue;
        }

        // Register handler
        if (!hal.interrupts.registerMsixHandler(vector, scsiIrqHandlerWrapper)) {
            _ = hal.interrupts.freeMsixVector(vector);
            console.warn("VirtIO-SCSI: Failed to register handler for vector {}", .{vector});
            continue;
        }

        controller.msix_vectors[i] = vector;

        // Configure queue to use this MSI-X vector
        if (i < controller.queues.request_queue_count) {
            if (controller.queues.request_queues[i]) |*q| {
                q.msix_vector = @intCast(i);

                // Tell the device which vector to use for this queue
                const queue_idx = config.QueueIndex.REQUEST_BASE + @as(u16, @intCast(i));
                controller.common_cfg.queue_select = queue_idx;
                controller.common_cfg.queue_msix_vector = @intCast(i);
            }
        }

        console.info("VirtIO-SCSI: Queue {} -> MSI-X vector {}", .{ i, vector });
    }

    // Enable all configured vectors
    pci.msi.enableMsixVectors(&ecam, controller.pci_dev, &msix_cap);

    // Disable legacy INTx
    pci.msi.disableIntx(&ecam, controller.pci_dev);
}

/// Cleanup MSI-X resources
pub fn cleanupMsix(controller: *root.VirtioScsiController) void {
    for (&controller.msix_vectors) |*vec_opt| {
        if (vec_opt.*) |vector| {
            hal.interrupts.unregisterMsixHandler(vector);
            hal.interrupts.freeMsixVector(vector);
            vec_opt.* = null;
        }
    }
}

// ============================================================================
// Interrupt Handler
// ============================================================================

/// Wrapper for MSI-X handler that matches HAL signature
fn scsiIrqHandlerWrapper(_: *hal.idt.InterruptFrame) void {
    if (root.getController()) |controller| {
        controller.handleInterrupt();
    }
}

/// Register legacy IRQ handler (fallback if MSI-X unavailable)
pub fn registerLegacyIrq(controller: *root.VirtioScsiController) void {
    const irq = controller.pci_dev.irq_line;

    if (irq == 0 or irq == 255) {
        console.warn("VirtIO-SCSI: No IRQ line assigned, using polling", .{});
        return;
    }

    const vector = @as(u8, @intCast(irq)) + 32; // PIC offset

    // Register with interrupt system (uses global controller via scsiIrqHandlerWrapper)
    hal.interrupts.registerHandler(vector, scsiIrqHandlerWrapper);
    console.info("VirtIO-SCSI: Registered legacy IRQ {} (vector {})", .{ irq, vector });

    // Route the IRQ and unmask it
    hal.apic.routeIrq(irq, vector, 0);
    hal.apic.enableIrq(irq);
}

// ============================================================================
// Polling Mode
// ============================================================================

/// Poll for completions (used when interrupts are unavailable or for debugging)
/// Returns number of completions processed
pub fn pollCompletions(controller: *root.VirtioScsiController) u32 {
    var total: u32 = 0;

    // Poll all request queues
    for (0..controller.queues.request_queue_count) |i| {
        if (controller.queues.request_queues[i]) |*q| {
            var processed: u32 = 0;
            while (q.hasPending() and processed < 256) : (processed += 1) {
                controller.processQueueCompletion(q);
            }
            total += processed;
        }
    }

    return total;
}

/// Poll a single queue for completions
pub fn pollQueue(controller: *root.VirtioScsiController, queue_idx: u8) u32 {
    if (queue_idx >= controller.queues.request_queue_count) return 0;

    const q = controller.queues.getRequestQueue(queue_idx) orelse return 0;

    var processed: u32 = 0;
    while (q.hasPending() and processed < 256) : (processed += 1) {
        controller.processQueueCompletion(q);
    }

    return processed;
}
