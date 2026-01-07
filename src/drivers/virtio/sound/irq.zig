// VirtIO-Sound Interrupt Handler
//
// Handles MSI-X interrupt setup and interrupt processing.
// Falls back to polling if MSI-X is not available.

const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const console = @import("console");
const root = @import("root.zig");
const config = @import("config.zig");

// =============================================================================
// MSI-X Setup
// =============================================================================

/// Setup MSI-X interrupts for the driver
pub fn setupMsix(driver: *root.VirtioSoundDriver, pci_access: pci.PciAccess) !void {
    const ecam = switch (pci_access) {
        .ecam => |e| e,
        .legacy => {
            console.warn("VirtIO-Sound: MSI-X not available with legacy PCI access", .{});
            return error.NotSupported;
        },
    };

    const pci_dev = driver.pci_dev;

    // Find MSI-X capability
    const msix_cap = pci.capabilities.findMsix(&ecam, pci_dev) orelse {
        console.info("VirtIO-Sound: MSI-X not available, using polling", .{});
        return error.NotSupported;
    };

    // Enable MSI-X
    const msix_alloc = pci.msi.enableMsix(&ecam, pci_dev, &msix_cap, 0) orelse {
        console.warn("VirtIO-Sound: Failed to enable MSI-X", .{});
        return error.NotSupported;
    };

    if (msix_alloc.vector_count == 0) {
        console.warn("VirtIO-Sound: No MSI-X vectors available", .{});
        return error.NoResources;
    }

    // Allocate vector for TX queue
    const vector = hal.interrupts.allocateMsixVector() orelse {
        console.warn("VirtIO-Sound: No MSI-X vectors available in kernel pool", .{});
        return error.NoResources;
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
        console.warn("VirtIO-Sound: Failed to configure MSI-X entry", .{});
        return error.ConfigurationFailed;
    }

    // Register interrupt handler
    if (!hal.interrupts.registerMsixHandler(vector, soundIrqHandler)) {
        _ = hal.interrupts.freeMsixVector(vector);
        console.warn("VirtIO-Sound: Failed to register interrupt handler", .{});
        return error.RegistrationFailed;
    }

    // Store vector
    driver.msix_vectors[0] = vector;

    // Configure queue to use this vector
    driver.common_cfg.queue_select = config.QueueIndex.TX_BASE;
    hal.mmio.memoryBarrier();
    driver.common_cfg.queue_msix_vector = 0; // MSI-X table entry 0
    hal.mmio.memoryBarrier();

    // Enable all vectors
    pci.msi.enableMsixVectors(&ecam, pci_dev, &msix_cap);

    // Disable legacy INTx
    pci.msi.disableIntx(&ecam, pci_dev);

    console.info("VirtIO-Sound: MSI-X enabled, vector {}", .{vector});
}

// =============================================================================
// Interrupt Handler
// =============================================================================

/// MSI-X interrupt handler
fn soundIrqHandler(frame: *const hal.idt.InterruptFrame) void {
    _ = frame;

    const driver = root.getDriver() orelse return;
    driver.handleInterrupt();

    // Send EOI
    hal.apic.sendEoi();
}

// =============================================================================
// Polling Fallback
// =============================================================================

/// Poll for completed transfers (fallback when no MSI-X)
pub fn pollCompletions(driver: *root.VirtioSoundDriver) void {
    if (!driver.initialized) return;

    // Check ISR status
    const isr_ptr: *volatile u8 = @ptrFromInt(driver.isr_addr);
    const isr = isr_ptr.*;

    if ((isr & 1) != 0) {
        // Queue interrupt pending
        driver.handleInterrupt();
    }
}
