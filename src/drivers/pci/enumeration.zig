// PCI Bus Enumeration
//
// Scans the PCI bus hierarchy to discover all connected devices.
// Handles multi-function devices and populates device structures with
// BAR information for driver use.
//
// Reference: PCI Local Bus Specification 3.0, Section 6.1

const console = @import("console");

const std = @import("std");
const ecam = @import("ecam.zig");
const device = @import("device.zig");
const hal = @import("hal");

const Ecam = ecam.Ecam;
const PciDevice = device.PciDevice;
const DeviceList = device.DeviceList;
const Bar = device.Bar;
const ConfigReg = device.ConfigReg;

/// Enumerate all PCI devices and populate a device list
pub fn enumerate(allocator: std.mem.Allocator, pci: *const Ecam) !*DeviceList {
    const devices = try allocator.create(DeviceList);
    devices.* = DeviceList.init();

    console.info("PCI: Enumerating devices on buses {d}-{d}...", .{
        pci.start_bus,
        pci.end_bus,
    });

    console.info("PCI: Scanning bus {d}-{d}", .{pci.start_bus, pci.end_bus});
    var bus: u16 = pci.start_bus;
    while (bus <= pci.end_bus) : (bus += 1) {
        // console.debug("PCI: Scanning bus {d}", .{bus});
        enumerateBus(pci, @truncate(bus), devices);
    }

    console.info("PCI: Found {d} devices", .{devices.count});
    return devices;
}

/// Enumerate all devices on a single bus
fn enumerateBus(pci: *const Ecam, bus: u8, devices: *DeviceList) void {
    var dev: u8 = 0;
    while (dev < 32) : (dev += 1) {
        enumerateDevice(pci, bus, @truncate(dev), devices);
    }
}

/// Enumerate a device slot (may have multiple functions)
fn enumerateDevice(pci: *const Ecam, bus: u8, dev: u5, devices: *DeviceList) void {
    // Check if device exists at function 0
    if (!pci.deviceExists(bus, dev, 0)) {
        return;
    }
    
    console.debug("PCI: Device found at {d}:{d}", .{bus, dev});

    // Check function 0
    checkFunction(pci, bus, dev, 0, devices);

    // Check if multi-function device
    if ((pci.readHeaderType(bus, dev, 0) & 0x80) != 0) {
        var func: u4 = 1;
        while (func < 8) : (func += 1) {
            if (pci.deviceExists(bus, dev, @truncate(func))) {
                checkFunction(pci, bus, dev, @truncate(func), devices);
            }
        }
    }
}

/// Check a specific function and add to device list if valid
fn checkFunction(pci: *const Ecam, bus: u8, dev: u5, func: u3, devices: *DeviceList) void {
    // Read vendor/device ID
    const vendor_id = pci.read16(bus, dev, func, ConfigReg.VENDOR_ID);
    const device_id = pci.read16(bus, dev, func, ConfigReg.DEVICE_ID);

    // If vendor_id is 0xFFFF, device does not exist
    if (vendor_id == 0xFFFF) {
        return;
    }

    // Read class/subclass
    const class_code = pci.read8(bus, dev, func, ConfigReg.CLASS_CODE);
    const subclass = pci.read8(bus, dev, func, ConfigReg.SUBCLASS);
    const prog_if = pci.read8(bus, dev, func, ConfigReg.PROG_IF);
    const revision = pci.read8(bus, dev, func, ConfigReg.REVISION_ID);

    // Read header type
    const header_type = pci.read8(bus, dev, func, ConfigReg.HEADER_TYPE);

    // Read subsystem info
    const subsystem_vendor = pci.read16(bus, dev, func, ConfigReg.SUBSYSTEM_VENDOR);
    const subsystem_id = pci.read16(bus, dev, func, ConfigReg.SUBSYSTEM_ID);

    // Create device struct
    var pci_dev = PciDevice{
        .bus = bus,
        .device = dev,
        .func = func,
        .vendor_id = vendor_id,
        .device_id = device_id,
        .revision = revision,
        .prog_if = prog_if,
        .subclass = subclass,
        .class_code = class_code,
        .header_type = header_type,
        .bar = [_]Bar{Bar.unused()} ** 6,
        .irq_line = pci.read8(bus, dev, func, ConfigReg.INTERRUPT_LINE),
        .irq_pin = pci.read8(bus, dev, func, ConfigReg.INTERRUPT_PIN),
        .gsi = 0,
        .subsystem_vendor = subsystem_vendor,
        .subsystem_id = subsystem_id,
    };

    // Calculate GSI (Global System Interrupt) using default rotation
    // GSI = IOAPIC_BASE (16) + (Pin (0-3) + DeviceID) % 4
    if (pci_dev.irq_pin >= 1 and pci_dev.irq_pin <= 4) {
        const pin_idx = pci_dev.irq_pin - 1;
        // Simple rotation based on device number
        // This assumes default PCI swizzling for root bus devices
        const gsi = 16 + ((@as(u32, pin_idx) + pci_dev.device) % 4);
        pci_dev.gsi = gsi;

        // Update irq_line if it fits (for legacy driver compatibility)
        if (gsi < 256) {
             pci_dev.irq_line = @truncate(gsi);
             // Optional: Write back to PCI config space for consistency
             // pci.write8(bus, dev, func, ConfigReg.INTERRUPT_LINE, pci_dev.irq_line);
        }
    }

    // Read BARs (only for type 0 headers - standard devices)
    if ((pci_dev.header_type & 0x7F) == 0) { // Mask multi-function bit
        readBars(pci, &pci_dev);
    }

    // Add to list
    if (devices.add(pci_dev)) {
        logDevice(&pci_dev);
    } else {
        console.warn("PCI: Device list full, ignoring device at {d}:{d}.{d}", .{bus, dev, func});
    }
}

/// Read all BARs for a device
fn readBars(pci: *const Ecam, dev: *PciDevice) void {
    const orig_cmd = pci.read16(dev.bus, dev.device, dev.func, ConfigReg.COMMAND);
    const disabled_cmd = orig_cmd & ~(device.Command.MEMORY_SPACE | device.Command.IO_SPACE);
    pci.write16(dev.bus, dev.device, dev.func, ConfigReg.COMMAND, disabled_cmd);

    // Restore original command register after sizing to avoid changing device state.
    defer pci.write16(dev.bus, dev.device, dev.func, ConfigReg.COMMAND, orig_cmd);

    // CRITICAL: Disable interrupts during BAR sizing.
    // Writing 0xFFFFFFFF to the BAR register temporarily unmaps the device or puts it in an invalid state.
    // If an interrupt (e.g. from the same device or another device sharing the bus) fires in between,
    // the ISR might try to access the device and crash or read garbage.
    hal.cpu.disableInterrupts();
    defer hal.cpu.enableInterrupts();

    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        // Calculate BAR offset based on type 0 header
        const bar_offset = ConfigReg.BAR0 + (i * 4);
        const bar_value = pci.read32(dev.bus, dev.device, dev.func, @intCast(bar_offset));

        // Probe BAR by writing all 1s and reading back size mask
        // This works even when bar_value is 0 (firmware didn't assign base)
        pci.write32(dev.bus, dev.device, dev.func, @intCast(bar_offset), 0xFFFFFFFF);
        const size_mask = pci.read32(dev.bus, dev.device, dev.func, @intCast(bar_offset));
        pci.write32(dev.bus, dev.device, dev.func, @intCast(bar_offset), bar_value);

        // Debug: Log BAR probe results for devices with interesting patterns
        if (bar_value == 0 and size_mask != 0 and size_mask != 0xFFFFFFFF) {
            console.debug("PCI: {d}:{d}.{d} BAR{d}: value=0 but size_mask=0x{x} (unassigned BAR)", .{
                dev.bus, dev.device, dev.func, i, size_mask,
            });
        }

        // If size_mask is 0 or all 1s, BAR doesn't exist
        if (size_mask == 0 or size_mask == 0xFFFFFFFF) {
            continue;
        }

        var bar = Bar.unused();

        // Use size_mask to determine BAR type (more reliable than bar_value when base is 0)
        if ((size_mask & 1) == 1) {
            // I/O Space
            bar.bar_type = .io;
            bar.is_mmio = false;
            bar.base = bar_value & 0xFFFFFFFC;

            if ((size_mask & 0xFFFFFFFC) != 0) {
                bar.size = (~(size_mask & 0xFFFFFFFC)) +% 1;
            }
        } else {
            // Memory Space - determine type from size_mask since bar_value might be 0
            const is_64bit = (size_mask & 0x4) != 0;
            const is_prefetch = (size_mask & 0x8) != 0;

            bar.is_mmio = true;
            bar.is_64bit = is_64bit;
            bar.prefetchable = is_prefetch;
            bar.bar_type = if (is_64bit) .mmio_64bit else .mmio_32bit;

            var base: u64 = bar_value & 0xFFFFFFF0;
            var size: u64 = 0;

            if (is_64bit) {
                const bar_upper = pci.read32(dev.bus, dev.device, dev.func, @intCast(bar_offset + 4));
                base |= (@as(u64, bar_upper) << 32);

                // Probe upper BAR for 64-bit size
                pci.write32(dev.bus, dev.device, dev.func, @intCast(bar_offset + 4), 0xFFFFFFFF);
                const size_mask_high = pci.read32(dev.bus, dev.device, dev.func, @intCast(bar_offset + 4));
                pci.write32(dev.bus, dev.device, dev.func, @intCast(bar_offset + 4), bar_upper);

                const mask64 = (@as(u64, size_mask_high) << 32) | (size_mask & 0xFFFFFFF0);
                if (mask64 != 0) {
                    size = (~mask64) +% 1;
                }
            } else {
                const mask32 = size_mask & 0xFFFFFFF0;
                if (mask32 != 0) {
                    size = (~mask32) +% 1;
                }
            }

            bar.base = base;
            bar.size = size;

            // Store BAR first, then skip next register for 64-bit BARs
            dev.bar[i] = bar;
            if (is_64bit) {
                i += 1; // Skip next BAR register (upper 32 bits already consumed)
            }
            continue;
        }

        dev.bar[i] = bar;
    }
}

/// Log device information
fn logDevice(dev: *const PciDevice) void {
    // Get class name for common classes
    _ = switch (dev.class_code) {
        0x01 => "Storage",
        0x02 => "Network",
        0x03 => "Display",
        0x04 => "Multimedia",
        0x06 => "Bridge",
        0x0C => "Serial Bus",
        else => "Other",
    };

    console.info("PCI: {x:0>4}:{x:0>4} Class {x:0>2}/{x:0>2} (Bus {d}, Dev {d}, Func {d})", .{
        dev.vendor_id,
        dev.device_id,
        dev.class_code,
        dev.subclass,
        dev.bus,
        dev.device,
        dev.func,
    });

    // Log BARs if present
    for (dev.bar, 0..) |bar, i| {
        if (bar.isValid()) {
            if (bar.is_mmio) {
                console.info("  BAR{d}: MMIO 0x{x} size={d}KB {s}{s}", .{
                    i,
                    bar.base,
                    bar.size / 1024,
                    if (bar.is_64bit) "64-bit " else "",
                    if (bar.prefetchable) "prefetch" else "",
                });
            } else {
                console.info("  BAR{d}: I/O  0x{x:0>4} size={d}", .{
                    i,
                    bar.base,
                    bar.size,
                });
            }
        }
    }
}

/// Initialize PCI subsystem with ECAM from ACPI
pub fn initFromAcpi(allocator: std.mem.Allocator, rsdp_address: u64) !struct { ecam: Ecam, devices: *DeviceList } {
    const acpi = @import("acpi");

    // Cast address to RSDP pointer
    const rsdp_ptr = @as(*align(1) const acpi.rsdp.Rsdp, @ptrFromInt(rsdp_address));
    console.info("Debug: rsdp_ptr created, calling findEcamBase", .{});

    // Find ECAM base from MCFG table
    const ecam_info = acpi.mcfg.findEcamBase(rsdp_ptr) orelse {
        console.err("PCI: MCFG table not found, cannot initialize ECAM", .{});
        return error.NoMcfg;
    };

    console.info("PCI: ECAM base=0x{x}, buses {d}-{d}", .{
        ecam_info.base_address,
        ecam_info.start_bus,
        ecam_info.end_bus,
    });

    // Initialize ECAM accessor
    const pci = try Ecam.init(ecam_info.base_address, ecam_info.start_bus, ecam_info.end_bus);

    // Enumerate devices
    const devices = try enumerate(allocator, &pci);

    return .{ .ecam = pci, .devices = devices };
}
