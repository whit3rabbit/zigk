// XHCI Driver Root (Facade)
//
// Re-exports submodules and provides driver entry point (probe).

const std = @import("std");
const console = @import("console");
const pci = @import("pci");

// Submodules
pub const types = @import("types.zig");
pub const controller = @import("controller.zig");
pub const memory = @import("memory.zig");
pub const interrupts = @import("interrupts.zig");
pub const ports = @import("ports.zig");
pub const device_manager = @import("device_manager.zig");
pub const transfer = @import("transfer/control.zig"); // Export control transfer as main transfer interface?
// Old code exported `Transfer`.
// We can create a namespace struct for Transfer if needed.
// But mostly `usb/root.zig` re-exports `Transfer` from `transfer.zig`.
// `transfer.zig` (old) had `controlTransfer` etc.
// My `transfer/control.zig` has `controlTransfer`.
// So `pub const Transfer = @import("transfer/control.zig");` works for control transfers.
// But what about `bulk` and `interrupt`?
// I can aggregate them?
// Or just export `control` as `Transfer` since that's what generic USB stack uses most?
// Userspace drivers use `mmio` or specific interfaces.
// Let's create an aggregate struct.

pub const Transfer = struct {
    pub const controlTransfer = @import("transfer/control.zig").controlTransfer;
    pub const queueBulkTransfer = @import("transfer/bulk.zig").queueBulkTransfer;
    pub const queueInterruptTransfer = @import("transfer/interrupt.zig").queueInterruptTransfer;
    pub const TransferError = @import("transfer/common.zig").TransferError;
    pub const CONTROL_TIMEOUT_MS = @import("transfer/control.zig").CONTROL_TIMEOUT_MS;
};

// Re-export types
pub const Controller = types.Controller;
pub const Regs = @import("regs.zig");
pub const Trb = @import("trb.zig");
pub const Ring = @import("ring.zig");
pub const Context = @import("context.zig");
pub const Device = @import("device.zig");

// Global controller instance
var g_controller: ?*Controller = null;

/// Probe for XHCI controllers in the PCI device list
pub fn probe(devices: *const pci.DeviceList, pci_access: pci.PciAccess) void {
    console.info("XHCI: Probing for controllers (count={})...", .{devices.count});

    if (g_controller != null) {
        console.warn("XHCI: Controller already initialized", .{});
        return;
    }

    // Debug: List first 5 devices to see what we have
    const max_debug = @min(devices.count, 5);
    for (devices.devices[0..max_debug], 0..) |*dev, i| {
        console.info("XHCI: Dev[{}]: {x}:{x}.{d} class={x:0>2}/{x:0>2}/{x:0>2}", .{
            i, dev.bus, dev.device, dev.func, dev.class_code, dev.subclass, dev.prog_if,
        });
    }

    // Iterate through devices
    for (devices.devices[0..devices.count]) |*dev| {
        // Debug: Log all USB controllers (class 0x0C, subclass 0x03)
        if (dev.class_code == 0x0C and dev.subclass == 0x03) {
            console.debug("XHCI: USB controller at {x:0>2}:{x:0>2}.{d} prog_if=0x{x:0>2}", .{
                dev.bus, dev.device, dev.func, dev.prog_if,
            });
        }

        // Class 0x0C (Serial Bus), Subclass 0x03 (USB), ProgIF 0x30 (XHCI)
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x30) {
            console.info("XHCI: Found controller at {x:0>2}:{x:0>2}.{d}", .{
                dev.bus, dev.device, dev.func,
            });

            // Initialize controller
            g_controller = controller.init(dev, pci_access) catch |err| {
                console.err("XHCI: Failed to initialize controller: {}", .{err});
                return;
            };

            // Set global controller helper for interrupts
            // (Note: controller.init calls interrupts.setupInterrupts which sets interrupts.g_controller.
            //  We maintain root g_controller for getController access).

            // Only initialize the first one for now
            return;
        }
    }

    console.warn("XHCI: No XHCI controller found", .{});
}

/// Get the initialized controller instance
pub fn getController() ?*Controller {
    return g_controller;
}

/// Poll for events manually (wraps interrupts.poll_events)
pub fn pollEvents() usize {
    return interrupts.poll_events();
}
