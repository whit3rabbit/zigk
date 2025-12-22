// XHCI Driver Root (Facade)
//
// Re-exports submodules and provides driver entry point (probe).

const std = @import("std");
const console = @import("console");
const pci = @import("pci");
const hal = @import("hal");

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
    if (g_controller != null) {
        console.warn("XHCI: Controller already initialized", .{});
        return;
    }

    // First pass: Check device list for XHCI (class 0x0C/0x03/0x30)
    for (devices.devices[0..devices.count]) |*dev| {
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x30) {
            if (initController(dev, pci_access)) return;
        }
    }

    // QEMU/TCG workaround: ECAM MMIO has timing issues on macOS/Apple Silicon.
    // Use Legacy PCI I/O ports (0xCF8/0xCFC) for reliable device detection.
    const legacy = pci.Legacy.init();

    // Scan bus 0 for USB controllers (class 0x0C subclass 0x03)
    var found_xhci = false;
    var dev_num: u5 = 0;
    while (dev_num < 32) : (dev_num += 1) {
        const vendor_id = legacy.read16(0, dev_num, 0, 0x00);
        if (vendor_id == 0xFFFF) continue; // No device

        const class_dword = legacy.read32(0, dev_num, 0, 0x08);
        const class_code: u8 = @truncate(class_dword >> 24);
        const subclass: u8 = @truncate(class_dword >> 16);
        const prog_if: u8 = @truncate(class_dword >> 8);
        const device_id = legacy.read16(0, dev_num, 0, 0x02);

        console.debug("XHCI: Legacy probe 00:{x:0>2}.0: vid={x:0>4} did={x:0>4} class={x:0>2}/{x:0>2}/{x:0>2}", .{
            dev_num, vendor_id, device_id, class_code, subclass, prog_if,
        });

        // XHCI: Class 0x0C (Serial Bus), Subclass 0x03 (USB), ProgIF 0x30 (XHCI)
        if (class_code == 0x0C and subclass == 0x03 and prog_if == 0x30) {
            // Read BAR0/BAR1 via legacy (since ECAM values are corrupted)
            const bar0_raw = legacy.read32(0, dev_num, 0, 0x10);
            const bar1_raw = legacy.read32(0, dev_num, 0, 0x14);

            // Decode BAR0: bits 2:1 indicate type (00=32bit, 10=64bit)
            const is_64bit = ((bar0_raw >> 1) & 0x3) == 2;
            const bar_base = if (is_64bit)
                (@as(u64, bar1_raw) << 32) | (@as(u64, bar0_raw) & 0xFFFFFFF0)
            else
                @as(u64, bar0_raw & 0xFFFFFFF0);

            console.info("XHCI: Found via legacy probe at 00:{x:0>2}.0 (vid={x:0>4} did={x:0>4}) BAR={x:0>16}", .{
                dev_num, vendor_id, device_id, bar_base,
            });

            // Build a corrected PciDevice struct using legacy reads
            var fixed_dev = pci.PciDevice{
                .bus = 0,
                .device = dev_num,
                .func = 0,
                .vendor_id = vendor_id,
                .device_id = device_id,
                .revision = @truncate(class_dword),
                .prog_if = prog_if,
                .subclass = subclass,
                .class_code = class_code,
                .header_type = 0,
                .bar = undefined,
                .irq_line = legacy.read8(0, dev_num, 0, 0x3C),
                .irq_pin = legacy.read8(0, dev_num, 0, 0x3D),
                .gsi = 0,
                .subsystem_vendor = legacy.read16(0, dev_num, 0, 0x2C),
                .subsystem_id = legacy.read16(0, dev_num, 0, 0x2E),
            };

            // Initialize BAR array
            for (&fixed_dev.bar) |*bar| {
                bar.* = pci.Bar{
                    .base = 0,
                    .size = 0,
                    .is_mmio = false,
                    .is_64bit = false,
                    .prefetchable = false,
                    .bar_type = .unused,
                };
            }

            // Set BAR0 with correct values from legacy read
            // Note: We don't know exact size, but XHCI typically needs 64KB
            // The controller init will read capability regs to verify
            fixed_dev.bar[0] = pci.Bar{
                .base = bar_base,
                .size = 0x10000, // 64KB minimum for XHCI operational regs
                .is_mmio = true,
                .is_64bit = is_64bit,
                .prefetchable = (bar0_raw & 0x8) != 0,
                .bar_type = if (is_64bit) .mmio_64bit else .mmio_32bit,
            };

            if (initController(&fixed_dev, pci_access)) {
                found_xhci = true;
            }

            if (found_xhci) break;
        }
    }

    if (!found_xhci) {
        console.warn("XHCI: No XHCI controller found on bus 0", .{});
    }
}

/// Initialize XHCI controller from PCI device
fn initController(dev: *const pci.PciDevice, pci_access: pci.PciAccess) bool {
    console.info("XHCI: Found controller at {x:0>2}:{x:0>2}.{d}", .{
        dev.bus, dev.device, dev.func,
    });

    g_controller = controller.init(dev, pci_access) catch |err| {
        console.err("XHCI: Failed to initialize controller: {}", .{err});
        return false;
    };

    return true;
}

/// Get the initialized controller instance
pub fn getController() ?*Controller {
    return g_controller;
}

/// Poll for events manually (wraps interrupts.poll_events)
pub fn pollEvents() usize {
    return interrupts.poll_events();
}
