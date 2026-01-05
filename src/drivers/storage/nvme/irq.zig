// NVMe Interrupt Handling
//
// MSI-X setup and interrupt handler for NVMe controller.
// Supports per-queue interrupt vectors for optimal performance.
//
// Reference: NVM Express Base Specification 2.0, Section 7.7

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const pci = @import("pci");

const root = @import("root.zig");

// ============================================================================
// MSI-X Setup
// ============================================================================

/// Configure MSI-X interrupts for the controller
pub fn setupMsix(controller: *root.NvmeController, pci_access: pci.PciAccess) !void {
    const ecam = switch (pci_access) {
        .ecam => |e| e,
        .legacy => {
            console.warn("NVMe: MSI-X not available with legacy PCI access", .{});
            return;
        },
    };

    // Find MSI-X capability
    const msix_cap = pci.capabilities.findMsix(&ecam, controller.pci_dev) orelse {
        console.warn("NVMe: MSI-X capability not found, using polling", .{});
        return;
    };

    // Enable MSI-X
    const msix_alloc = pci.msi.enableMsix(&ecam, controller.pci_dev, &msix_cap, 0) orelse {
        console.warn("NVMe: Failed to enable MSI-X", .{});
        return;
    };

    console.info("NVMe: MSI-X enabled with {} vectors", .{msix_alloc.vector_count});

    // Allocate vectors for each queue (admin + I/O)
    const queues_to_configure = @min(
        @as(usize, controller.io_queue_count) + 1,
        @as(usize, msix_alloc.vector_count),
    );

    for (0..queues_to_configure) |i| {
        // Allocate vector from kernel pool
        const vector = hal.interrupts.allocateMsixVector() orelse {
            console.warn("NVMe: No more MSI-X vectors available", .{});
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
            hal.interrupts.freeMsixVector(vector);
            console.warn("NVMe: Failed to configure MSI-X entry {}", .{i});
            continue;
        }

        // Register handler
        if (!hal.interrupts.registerMsixHandler(vector, nvmeIrqHandler, @ptrCast(controller))) {
            hal.interrupts.freeMsixVector(vector);
            console.warn("NVMe: Failed to register handler for vector {}", .{vector});
            continue;
        }

        controller.msix_vectors[i] = vector;
        console.info("NVMe: Queue {} -> MSI-X vector {}", .{ i, vector });
    }

    // Enable all configured vectors
    pci.msi.enableMsixVectors(&ecam, controller.pci_dev, &msix_cap);
}

/// Cleanup MSI-X resources
pub fn cleanupMsix(controller: *root.NvmeController) void {
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

/// NVMe interrupt handler
/// Called by the interrupt dispatcher when an NVMe MSI-X vector fires
pub fn nvmeIrqHandler(ctx: ?*anyopaque) void {
    if (ctx) |ptr| {
        const controller: *root.NvmeController = @ptrCast(@alignCast(ptr));
        controller.handleInterrupt();
    } else if (root.getController()) |controller| {
        controller.handleInterrupt();
    }
}

/// Register legacy IRQ handler (fallback if MSI-X unavailable)
pub fn registerLegacyIrq(controller: *root.NvmeController) void {
    const irq = controller.pci_dev.irq_line;

    if (irq == 0 or irq == 255) {
        console.warn("NVMe: No IRQ line assigned, using polling", .{});
        return;
    }

    const vector = @as(u8, @intCast(irq)) + 32; // PIC offset

    if (hal.interrupts.registerHandler(vector, nvmeIrqHandler, @ptrCast(controller))) {
        console.info("NVMe: Registered legacy IRQ {} (vector {})", .{ irq, vector });

        // Unmask the interrupt
        hal.apic.enableIrq(irq);
    } else {
        console.warn("NVMe: Failed to register legacy IRQ handler", .{});
    }
}

// ============================================================================
// Polling Mode
// ============================================================================

/// Poll for completions (used when interrupts are unavailable)
/// Returns number of completions processed
pub fn pollCompletions(controller: *root.NvmeController) u32 {
    var total: u32 = 0;

    // Poll admin queue
    total += pollQueue(controller, 0);

    // Poll I/O queues
    for (0..controller.io_queue_count) |i| {
        total += pollQueue(controller, @intCast(i + 1));
    }

    return total;
}

fn pollQueue(controller: *root.NvmeController, qid: u16) u32 {
    var processed: u32 = 0;

    const qp = if (qid == 0)
        &controller.admin_queue
    else if (qid <= controller.io_queue_count)
        &(controller.io_queues[qid - 1] orelse return 0)
    else
        return 0;

    while (qp.hasCompletion()) {
        controller.handleQueueInterrupt(qid);
        processed += 1;

        // Limit iterations to prevent infinite loop
        if (processed >= qp.size) break;
    }

    return processed;
}
