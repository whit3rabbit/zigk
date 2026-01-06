// VirtIO-Input Interrupt Handling
//
// MSI-X setup and interrupt handler for VirtIO-Input devices.
// Input devices need fast interrupt response for low-latency input.
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

/// Configure MSI-X interrupt for the driver
pub fn setupMsix(driver: *root.VirtioInputDriver, pci_access: pci.PciAccess) !void {
    const ecam = switch (pci_access) {
        .ecam => |e| e,
        .legacy => {
            console.warn("VirtIO-Input: MSI-X not available with legacy PCI access", .{});
            return;
        },
    };

    // Find MSI-X capability
    const msix_cap = pci.capabilities.findMsix(&ecam, driver.pci_dev) orelse {
        console.info("VirtIO-Input: MSI-X not available, using polling", .{});
        return;
    };

    // Enable MSI-X
    const msix_alloc = pci.msi.enableMsix(&ecam, driver.pci_dev, &msix_cap, 0) orelse {
        console.warn("VirtIO-Input: Failed to enable MSI-X", .{});
        return;
    };

    if (msix_alloc.vector_count == 0) {
        console.warn("VirtIO-Input: No MSI-X vectors available", .{});
        return;
    }

    // Allocate a single vector for the event queue
    const vector = hal.interrupts.allocateMsixVector() orelse {
        console.warn("VirtIO-Input: No MSI-X vectors available in kernel pool", .{});
        return;
    };

    // Configure MSI-X table entry 0
    const configured = pci.msi.configureMsixEntry(
        msix_alloc.table_base,
        msix_alloc.vector_count,
        0, // Entry 0
        vector,
        0, // Target APIC ID 0 (BSP)
    );

    if (!configured) {
        _ = hal.interrupts.freeMsixVector(vector);
        console.warn("VirtIO-Input: Failed to configure MSI-X entry", .{});
        return;
    }

    // Register interrupt handler
    if (!hal.interrupts.registerMsixHandler(vector, inputIrqHandler)) {
        _ = hal.interrupts.freeMsixVector(vector);
        console.warn("VirtIO-Input: Failed to register interrupt handler", .{});
        return;
    }

    driver.msix_vector = vector;

    // Configure event queue to use this MSI-X vector
    driver.common_cfg.queue_select = config.QueueIndex.EVENTS;
    hal.mmio.memoryBarrier();
    driver.common_cfg.queue_msix_vector = 0;
    hal.mmio.memoryBarrier();

    // Enable all vectors
    pci.msi.enableMsixVectors(&ecam, driver.pci_dev, &msix_cap);

    // Disable legacy INTx
    pci.msi.disableIntx(&ecam, driver.pci_dev);

    console.info("VirtIO-Input: MSI-X enabled on vector {}", .{vector});
}

/// Cleanup MSI-X resources
pub fn cleanupMsix(driver: *root.VirtioInputDriver) void {
    if (driver.msix_vector) |vector| {
        hal.interrupts.unregisterMsixHandler(vector);
        _ = hal.interrupts.freeMsixVector(vector);
        driver.msix_vector = null;
    }
}

// ============================================================================
// Interrupt Handler
// ============================================================================

/// MSI-X interrupt handler for VirtIO-Input
/// Called when the device has completed writing events to the event queue
fn inputIrqHandler(_: *hal.idt.InterruptFrame) void {
    // Process events from all VirtIO-Input drivers
    // In practice, the vector could be per-device, but for simplicity
    // we process all devices since input events are lightweight
    const driver_count = root.getDriverCount();
    for (0..driver_count) |i| {
        if (root.getDriverByIndex(@intCast(i))) |driver| {
            driver.processEvents();
        }
    }
}

// ============================================================================
// Polling Mode
// ============================================================================

/// Poll for events (used when MSI-X unavailable or for debugging)
/// This should be called periodically (e.g., from scheduler tick or timer)
pub fn pollEvents() void {
    root.pollAll();
}

/// Check if any driver needs polling (no MSI-X configured)
pub fn needsPolling() bool {
    const driver_count = root.getDriverCount();
    for (0..driver_count) |i| {
        if (root.getDriverByIndex(@intCast(i))) |driver| {
            if (driver.msix_vector == null and driver.initialized) {
                return true;
            }
        }
    }
    return false;
}
