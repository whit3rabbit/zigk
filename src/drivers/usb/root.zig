// USB Stack
//
// Multi-layered USB implementation:
//   - Host Controller Drivers (HCD): XHCI, EHCI
//   - USB Core: Enumeration, transfers
//   - Class Drivers: HID, Mass Storage
//
// Reference: USB 2.0/3.x Specifications

const console = @import("console");
const pci = @import("pci");

// Host Controller Drivers
pub const xhci = @import("xhci/root.zig");
pub const ehci = @import("ehci/root.zig");

// Common types
pub const types = @import("types.zig");

// Class Drivers
pub const hid = @import("class/hid.zig");

// Re-export common types
pub const SetupPacket = types.SetupPacket;
pub const RequestType = types.RequestType;
pub const Request = types.Request;
pub const DescriptorType = types.DescriptorType;
pub const DeviceDescriptor = types.DeviceDescriptor;
pub const ConfigurationDescriptor = types.ConfigurationDescriptor;
pub const InterfaceDescriptor = types.InterfaceDescriptor;
pub const EndpointDescriptor = types.EndpointDescriptor;
pub const Speed = types.Speed;

/// Initialize the USB subsystem with PCI devices and ECAM
pub fn initFromPci(devices: *const pci.DeviceList, ecam: *const pci.Ecam) void {
    console.info("USB: Initializing USB subsystem...", .{});

    // Probe for XHCI controllers
    xhci.probe(devices, ecam);

    // Probe for EHCI controllers
    ehci.probe(devices, ecam);

    console.info("USB: Initialization complete", .{});
}

/// Get the XHCI controller (if available)
pub fn getXhciController() ?*xhci.Controller {
    return xhci.getController();
}
