// PCI Bus Enumeration
//
// Scans the PCI bus hierarchy to discover all connected devices.
// Handles multi-function devices and populates device structures with
// BAR information for driver use.
//
// Reference: PCI Local Bus Specification 3.0, Section 6.1

const console = @import("console");

const ecam = @import("ecam.zig");
const device = @import("device.zig");

const Ecam = ecam.Ecam;
const PciDevice = device.PciDevice;
const DeviceList = device.DeviceList;
const Bar = device.Bar;
const ConfigReg = device.ConfigReg;

/// Enumerate all PCI devices and populate a device list
pub fn enumerate(pci: *const Ecam) DeviceList {
    var devices = DeviceList.init();

    console.info("PCI: Enumerating devices on buses {d}-{d}...", .{
        pci.start_bus,
        pci.end_bus,
    });

    var bus: u16 = pci.start_bus;
    while (bus <= pci.end_bus) : (bus += 1) {
        enumerateBus(pci, @truncate(bus), &devices);
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

    // Check function 0
    checkFunction(pci, bus, dev, 0, devices);

    // Check if multi-function device
    const header_type = pci.readHeaderType(bus, dev, 0);
    if ((header_type & 0x80) != 0) {
        // Multi-function device - check functions 1-7
        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            if (pci.deviceExists(bus, dev, @truncate(func))) {
                checkFunction(pci, bus, dev, @truncate(func), devices);
            }
        }
    }
}

/// Check a specific function and add to device list if valid
fn checkFunction(pci: *const Ecam, bus: u8, dev: u5, func: u3, devices: *DeviceList) void {
    const vendor_id = pci.readVendorId(bus, dev, func);
    if (vendor_id == 0xFFFF) {
        return;
    }

    var pci_dev = PciDevice{
        .bus = bus,
        .device = dev,
        .func = func,
        .vendor_id = vendor_id,
        .device_id = pci.readDeviceId(bus, dev, func),
        .revision = pci.read8(bus, dev, func, ConfigReg.REVISION_ID),
        .prog_if = pci.read8(bus, dev, func, ConfigReg.PROG_IF),
        .subclass = pci.readSubclass(bus, dev, func),
        .class_code = pci.readClassCode(bus, dev, func),
        .header_type = pci.readHeaderType(bus, dev, func) & 0x7F, // Mask multi-function bit
        .bar = [_]Bar{Bar.unused()} ** 6,
        .irq_line = pci.readIrqLine(bus, dev, func),
        .irq_pin = pci.readIrqPin(bus, dev, func),
        .subsystem_vendor = pci.read16(bus, dev, func, ConfigReg.SUBSYSTEM_VENDOR),
        .subsystem_id = pci.read16(bus, dev, func, ConfigReg.SUBSYSTEM_ID),
    };

    // Parse BARs (only for type 0 headers - standard devices)
    if (pci_dev.header_type == 0) {
        parseBars(pci, &pci_dev);
    }

    // Log device discovery
    logDevice(&pci_dev);

    // Add to list
    if (!devices.add(pci_dev)) {
        console.warn("PCI: Device list full, cannot add {x:0>4}:{x:0>4}", .{
            vendor_id,
            pci_dev.device_id,
        });
    }
}

/// Parse all BARs for a device
fn parseBars(pci: *const Ecam, dev: *PciDevice) void {
    var bar_idx: u3 = 0;
    while (bar_idx < 6) : (bar_idx += 1) {
        const bar = parseBar(pci, dev.bus, dev.device, dev.func, bar_idx);
        dev.bar[bar_idx] = bar;

        // Skip next BAR if this is a 64-bit BAR
        if (bar.is_64bit and bar_idx < 5) {
            bar_idx += 1;
            dev.bar[bar_idx] = Bar.unused();
        }
    }
}

/// Parse a single BAR
fn parseBar(pci: *const Ecam, bus: u8, dev: u5, func: u3, bar_idx: u3) Bar {
    const bar_value = pci.readBar(bus, dev, func, bar_idx);

    // Check if BAR is unused
    if (bar_value == 0) {
        return Bar.unused();
    }

    // Check BAR type (bit 0)
    const is_io = (bar_value & 1) != 0;

    if (is_io) {
        // I/O space BAR
        return parseIoBar(pci, bus, dev, func, bar_idx, bar_value);
    } else {
        // Memory space BAR
        return parseMmioBar(pci, bus, dev, func, bar_idx, bar_value);
    }
}

/// Parse an I/O space BAR
fn parseIoBar(pci: *const Ecam, bus: u8, dev: u5, func: u3, bar_idx: u3, bar_value: u32) Bar {
    // I/O BARs use bits [31:2] for base address
    const base: u64 = bar_value & 0xFFFFFFFC;

    // Determine size by writing all 1s and reading back
    pci.writeBar(bus, dev, func, bar_idx, 0xFFFFFFFF);
    const size_mask = pci.readBar(bus, dev, func, bar_idx);
    pci.writeBar(bus, dev, func, bar_idx, bar_value); // Restore

    // Size is determined by finding lowest set bit in inverted mask
    const size = calculateBarSize(size_mask & 0xFFFFFFFC);

    return Bar{
        .base = base,
        .size = size,
        .is_mmio = false,
        .is_64bit = false,
        .prefetchable = false,
        .bar_type = .io,
    };
}

/// Parse an MMIO BAR
fn parseMmioBar(pci: *const Ecam, bus: u8, dev: u5, func: u3, bar_idx: u3, bar_value: u32) Bar {
    // Check BAR type (bits [2:1])
    const bar_type = (bar_value >> 1) & 0x3;
    const is_64bit = (bar_type == 2);
    const prefetchable = (bar_value & 0x8) != 0;

    var base: u64 = bar_value & 0xFFFFFFF0;
    var size_mask: u64 = 0;

    if (is_64bit and bar_idx < 5) {
        // 64-bit BAR - combine with next BAR
        const bar_high = pci.readBar(bus, dev, func, bar_idx + 1);
        base |= @as(u64, bar_high) << 32;

        // Determine size
        pci.writeBar(bus, dev, func, bar_idx, 0xFFFFFFFF);
        pci.writeBar(bus, dev, func, bar_idx + 1, 0xFFFFFFFF);
        const low_mask = pci.readBar(bus, dev, func, bar_idx);
        const high_mask = pci.readBar(bus, dev, func, bar_idx + 1);
        pci.writeBar(bus, dev, func, bar_idx, bar_value);
        pci.writeBar(bus, dev, func, bar_idx + 1, bar_high);

        size_mask = (@as(u64, high_mask) << 32) | (low_mask & 0xFFFFFFF0);
    } else {
        // 32-bit BAR
        pci.writeBar(bus, dev, func, bar_idx, 0xFFFFFFFF);
        size_mask = pci.readBar(bus, dev, func, bar_idx) & 0xFFFFFFF0;
        pci.writeBar(bus, dev, func, bar_idx, bar_value);
    }

    const size = calculateBarSize(size_mask);

    return Bar{
        .base = base,
        .size = size,
        .is_mmio = true,
        .is_64bit = is_64bit,
        .prefetchable = prefetchable,
        .bar_type = if (is_64bit) .mmio_64bit else .mmio_32bit,
    };
}

/// Calculate BAR size from size mask (result of writing all 1s)
fn calculateBarSize(size_mask: u64) u64 {
    if (size_mask == 0) return 0;

    // Invert and add 1 to get size
    // Size mask has lowest bits clear up to size alignment
    const inverted = ~size_mask;
    return (inverted + 1) & size_mask;
}

/// Log device information
fn logDevice(dev: *const PciDevice) void {
    // Get class name for common classes
    const class_name = switch (dev.class_code) {
        0x01 => "Storage",
        0x02 => "Network",
        0x03 => "Display",
        0x04 => "Multimedia",
        0x06 => "Bridge",
        0x0C => "Serial Bus",
        else => "Other",
    };

    console.info("PCI: {d:0>2}:{d:0>2}.{d} {x:0>4}:{x:0>4} [{s}] IRQ={d}", .{
        dev.bus,
        dev.device,
        dev.func,
        dev.vendor_id,
        dev.device_id,
        class_name,
        dev.irq_line,
    });

    // Log BARs if present
    for (dev.bar, 0..) |bar, i| {
        if (bar.isValid()) {
            if (bar.is_mmio) {
                console.info("  BAR{d}: MMIO 0x{x:0>16} size={d}KB {s}{s}", .{
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
pub fn initFromAcpi(rsdp_ptr: anytype) !struct { ecam: Ecam, devices: DeviceList } {
    const acpi = @import("acpi");

    // Find ECAM base from MCFG table
    const ecam_info = acpi.mcfg.findEcamBase(rsdp_ptr) orelse {
        console.err("PCI: MCFG table not found, cannot initialize ECAM", .{});
        return error.NoMcfg;
    };

    console.info("PCI: ECAM base=0x{x:0>16}, buses {d}-{d}", .{
        ecam_info.base_address,
        ecam_info.start_bus,
        ecam_info.end_bus,
    });

    // Initialize ECAM accessor
    const pci = try Ecam.init(ecam_info.base_address, ecam_info.start_bus, ecam_info.end_bus);

    // Enumerate devices
    const devices = enumerate(&pci);

    return .{ .ecam = pci, .devices = devices };
}
