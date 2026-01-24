// PCI Driver Registration and Probing Framework
//
// Linux-style PCI driver registration mechanism. Drivers register with
// a PciDriver struct containing an id_table (array of PciDeviceId) and
// a probe function. On device discovery, the framework matches devices
// against registered drivers and calls probe on the first match.
//
// Reference: Linux kernel pci_driver / pci_device_id / pci_match_one_device

const std = @import("std");
const sync = @import("sync");
const console = @import("console");
const pci_mod = @import("root.zig");
const PciDevice = pci_mod.PciDevice;
const DeviceList = pci_mod.DeviceList;
const PciAccess = pci_mod.PciAccess;

// =============================================================================
// Device ID Matching (Linux: struct pci_device_id)
// =============================================================================

/// Wildcard value: matches any vendor/device/subsystem ID
pub const PCI_ANY_ID: u16 = 0xFFFF;

/// PCI device ID entry for driver matching.
/// Mirrors Linux's struct pci_device_id.
pub const PciDeviceId = struct {
    /// Vendor ID to match (PCI_ANY_ID = any)
    vendor: u16 = 0,
    /// Device ID to match (PCI_ANY_ID = any)
    device: u16 = 0,
    /// Subsystem vendor ID to match (PCI_ANY_ID = any)
    subvendor: u16 = PCI_ANY_ID,
    /// Subsystem device ID to match (PCI_ANY_ID = any)
    subdevice: u16 = PCI_ANY_ID,
    /// 24-bit class: (class_code << 16) | (subclass << 8) | prog_if
    class: u32 = 0,
    /// Mask for class comparison (0 = don't check class)
    class_mask: u32 = 0,
    /// Opaque driver-specific data passed to probe
    driver_data: usize = 0,

    /// Check if this entry is the sentinel (all-zero terminator)
    pub fn isSentinel(self: *const PciDeviceId) bool {
        return self.vendor == 0 and self.device == 0 and self.class_mask == 0;
    }
};

// =============================================================================
// Driver Structure (Linux: struct pci_driver)
// =============================================================================

/// Probe function signature.
/// Called when a device matches the driver's id_table.
/// Returns opaque driver_data pointer on success, null on failure.
pub const ProbeFn = *const fn (
    dev: *const PciDevice,
    pci_access: PciAccess,
    id: *const PciDeviceId,
) ?*anyopaque;

/// Remove function signature.
/// Called when a device is being unbound from a driver.
pub const RemoveFn = *const fn (
    dev: *const PciDevice,
    driver_data: *anyopaque,
) void;

/// PCI driver descriptor. Drivers populate this and register it.
pub const PciDriver = struct {
    /// Human-readable driver name (for logging)
    name: []const u8,
    /// Table of device IDs this driver handles (sentinel-terminated)
    id_table: []const PciDeviceId,
    /// Probe function called on match
    probe: ProbeFn,
    /// Optional remove function for unbinding
    remove: ?RemoveFn = null,
};

// =============================================================================
// Per-device Binding State
// =============================================================================

/// Tracks which driver (if any) is bound to a device.
pub const PciBinding = struct {
    /// Index into driver_table of the bound driver
    driver_index: u8 = 0,
    /// Opaque data returned by the driver's probe function
    driver_data: ?*anyopaque = null,
    /// Whether this device has a driver bound
    bound: bool = false,
};

// =============================================================================
// Driver Registry (static, max 32 drivers)
// =============================================================================

const MAX_DRIVERS = 32;

/// Registered drivers (static array, no heap allocation)
var driver_table: [MAX_DRIVERS]?*const PciDriver = [_]?*const PciDriver{null} ** MAX_DRIVERS;
/// Number of registered drivers
var driver_count: u8 = 0;
/// RwLock protecting driver_table, driver_count, and device_bindings
var driver_registry_lock: sync.RwLock = .{};

/// Per-device binding state (indexed by position in DeviceList)
var device_bindings: [DeviceList.MAX_DEVICES]PciBinding = [_]PciBinding{.{}} ** DeviceList.MAX_DEVICES;

/// Register a PCI driver. Returns error if registry is full.
pub fn pciRegisterDriver(driver: *const PciDriver) error{TooManyDrivers}!void {
    const held = driver_registry_lock.acquireWrite();
    defer held.release();

    if (driver_count >= MAX_DRIVERS) {
        console.err("PCI: Driver registry full, cannot register '{s}'", .{driver.name});
        return error.TooManyDrivers;
    }

    driver_table[driver_count] = driver;
    driver_count += 1;

    console.info("PCI: Registered driver '{s}' (id_table: {d} entries)", .{
        driver.name,
        driver.id_table.len,
    });
}

/// Unregister a PCI driver by name.
/// Unbinds from any devices currently using this driver.
pub fn pciUnregisterDriver(name: []const u8) void {
    const held = driver_registry_lock.acquireWrite();
    defer held.release();

    var found_idx: ?u8 = null;
    for (driver_table[0..driver_count], 0..) |entry, i| {
        if (entry) |drv| {
            if (std.mem.eql(u8, drv.name, name)) {
                found_idx = @intCast(i);
                break;
            }
        }
    }

    const idx = found_idx orelse return;

    // Unbind any devices bound to this driver
    for (&device_bindings) |*binding| {
        if (binding.bound and binding.driver_index == idx) {
            binding.bound = false;
            binding.driver_data = null;
        }
    }

    // Compact the array (shift entries down)
    if (idx < driver_count - 1) {
        var i: u8 = idx;
        while (i < driver_count - 1) : (i += 1) {
            driver_table[i] = driver_table[i + 1];
        }
        // Update binding indices for shifted drivers
        for (&device_bindings) |*binding| {
            if (binding.bound and binding.driver_index > idx) {
                binding.driver_index -= 1;
            }
        }
    }
    driver_table[driver_count - 1] = null;
    driver_count -= 1;

    console.info("PCI: Unregistered driver '{s}'", .{name});
}

// =============================================================================
// Device Matching (port of pci_match_one_device)
// =============================================================================

/// Match a single PciDeviceId entry against a PCI device.
/// Returns true if the device matches all non-wildcard fields in the id.
pub fn pciMatchOneDevice(id: *const PciDeviceId, dev: *const PciDevice) bool {
    if (id.isSentinel()) return false;

    if (id.vendor != PCI_ANY_ID and id.vendor != dev.vendor_id) return false;
    if (id.device != PCI_ANY_ID and id.device != dev.device_id) return false;
    if (id.subvendor != PCI_ANY_ID and id.subvendor != dev.subsystem_vendor) return false;
    if (id.subdevice != PCI_ANY_ID and id.subdevice != dev.subsystem_id) return false;

    if (id.class_mask != 0) {
        const dev_class: u32 = (@as(u32, dev.class_code) << 16) |
            (@as(u32, dev.subclass) << 8) |
            @as(u32, dev.prog_if);
        if (((id.class ^ dev_class) & id.class_mask) != 0) return false;
    }

    return true;
}

/// Find the first matching PciDeviceId in a driver's id_table for a device.
/// Returns the matching entry or null if none match.
pub fn pciMatchDevice(driver: *const PciDriver, dev: *const PciDevice) ?*const PciDeviceId {
    for (driver.id_table) |*id| {
        if (id.isSentinel()) break;
        if (pciMatchOneDevice(id, dev)) return id;
    }
    return null;
}

// =============================================================================
// Probe Dispatch
// =============================================================================

/// Match result: driver index and matched id, copied locally so the lock can be released.
const MatchResult = struct {
    driver_idx: u8,
    driver: *const PciDriver,
    matched_id: PciDeviceId, // Copied by value
};

/// Find the first matching driver for a device, starting from `start_idx`.
/// Must be called with driver_registry_lock held (read or write).
fn findMatch(dev: *const PciDevice, start_idx: u8) ?MatchResult {
    var i: u8 = start_idx;
    while (i < driver_count) : (i += 1) {
        const driver = driver_table[i] orelse continue;
        if (pciMatchDevice(driver, dev)) |matched_id| {
            return .{
                .driver_idx = i,
                .driver = driver,
                .matched_id = matched_id.*,
            };
        }
    }
    return null;
}

/// Probe one device against all registered drivers.
/// First successful match wins (driver's probe returns non-null).
pub fn probeDevice(dev: *const PciDevice, dev_index: usize, pci_access: PciAccess) bool {
    if (dev_index >= DeviceList.MAX_DEVICES) return false;

    // Check if already bound (read lock)
    {
        const held = driver_registry_lock.acquireRead();
        defer held.release();
        if (device_bindings[dev_index].bound) return true;
    }

    var start_idx: u8 = 0;
    while (true) {
        // Find next matching driver under read lock
        const match = blk: {
            const held = driver_registry_lock.acquireRead();
            defer held.release();
            break :blk findMatch(dev, start_idx) orelse return false;
        };

        // Call probe without holding any lock (probe may allocate/sleep)
        const matched_id_copy = match.matched_id;
        const result = match.driver.probe(dev, pci_access, &matched_id_copy);

        if (result) |driver_data| {
            // Success: acquire write lock and set binding
            const write_held = driver_registry_lock.acquireWrite();
            device_bindings[dev_index] = .{
                .driver_index = match.driver_idx,
                .driver_data = driver_data,
                .bound = true,
            };
            write_held.release();

            console.info("PCI: Bound '{s}' to {x:0>4}:{x:0>4} at {x:0>2}:{x:0>2}.{d}", .{
                match.driver.name,
                dev.vendor_id,
                dev.device_id,
                dev.bus,
                dev.device,
                dev.func,
            });
            return true;
        }

        // Probe failed, try next driver
        start_idx = match.driver_idx + 1;
    }
}

/// Probe all unbound devices against registered drivers.
/// Called during boot after driver registration is complete.
pub fn probeAllDevices(devices: *const DeviceList, pci_access: PciAccess) void {
    if (driver_count == 0) {
        console.info("PCI: No drivers registered, skipping probe", .{});
        return;
    }

    console.info("PCI: Probing {d} devices against {d} registered drivers...", .{
        devices.count,
        driver_count,
    });

    var bound_count: u32 = 0;
    for (devices.devices[0..devices.count], 0..) |*dev, idx| {
        if (probeDevice(dev, idx, pci_access)) {
            bound_count += 1;
        }
    }

    console.info("PCI: Probe complete, {d} device(s) bound", .{bound_count});
}

// =============================================================================
// Virtual Device Probe
// =============================================================================

/// Probe a virtual device by its raw config space bytes.
/// Called from sys_vpci_register after the device transitions to .registered state.
/// Accepts raw config bytes to avoid a circular dependency on the virt_pci module.
pub fn probeVirtualDeviceFromConfig(
    config_space: *const [256]u8,
    subsys_vendor: u16,
    subsys_id: u16,
    virt_slot: usize,
    pci_access: PciAccess,
) bool {
    // Build a temporary PciDevice from the config space for matching
    const vendor_id = @as(u16, config_space[0]) | (@as(u16, config_space[1]) << 8);
    const device_id_val = @as(u16, config_space[2]) | (@as(u16, config_space[3]) << 8);
    const class_code = config_space[0x0B];
    const subclass = config_space[0x0A];
    const prog_if = config_space[0x09];
    const revision = config_space[0x08];

    var temp_dev = PciDevice{
        .bus = 0xFF, // Virtual bus
        .device = @truncate(virt_slot & 0x1F),
        .func = 0,
        .vendor_id = vendor_id,
        .device_id = device_id_val,
        .revision = revision,
        .prog_if = prog_if,
        .subclass = subclass,
        .class_code = class_code,
        .header_type = 0,
        .bar = undefined,
        .irq_line = 0,
        .irq_pin = 0,
        .gsi = 0,
        .subsystem_vendor = subsys_vendor,
        .subsystem_id = subsys_id,
    };

    // Initialize BAR array to unused
    for (&temp_dev.bar) |*bar| {
        bar.* = pci_mod.Bar.unused();
    }

    console.debug("PCI: Probing virtual device {x:0>4}:{x:0>4} class={x:0>2}:{x:0>2}", .{
        vendor_id,
        device_id_val,
        class_code,
        subclass,
    });

    // Use a device_bindings slot offset for virtual devices
    // Virtual devices use slots starting at MAX_DEVICES/2 to avoid collision
    // with physical device indices
    const binding_idx = DeviceList.MAX_DEVICES / 2 + (virt_slot % (DeviceList.MAX_DEVICES / 2));

    return probeDevice(&temp_dev, binding_idx, pci_access);
}

// =============================================================================
// Helper Constructors (like Linux PCI_DEVICE / PCI_DEVICE_CLASS macros)
// =============================================================================

/// Create a PciDeviceId matching a specific vendor:device pair.
/// Equivalent to Linux PCI_DEVICE(vendor, device) macro.
pub fn deviceId(vendor: u16, dev_id: u16) PciDeviceId {
    return .{
        .vendor = vendor,
        .device = dev_id,
        .subvendor = PCI_ANY_ID,
        .subdevice = PCI_ANY_ID,
        .class = 0,
        .class_mask = 0,
    };
}

/// Create a PciDeviceId matching by class code.
/// Equivalent to Linux PCI_DEVICE_CLASS(class, mask) macro.
/// class_code and subclass are combined into the 24-bit class field.
pub fn classId(class_code: u8, subclass: u8, mask: u32) PciDeviceId {
    return .{
        .vendor = PCI_ANY_ID,
        .device = PCI_ANY_ID,
        .subvendor = PCI_ANY_ID,
        .subdevice = PCI_ANY_ID,
        .class = (@as(u32, class_code) << 16) | (@as(u32, subclass) << 8),
        .class_mask = mask,
    };
}

/// Get the binding for a device at a given index.
/// Returns null if the device is not bound.
pub fn getBinding(dev_index: usize) ?*const PciBinding {
    if (dev_index >= DeviceList.MAX_DEVICES) return null;
    const binding = &device_bindings[dev_index];
    if (!binding.bound) return null;
    return binding;
}

/// Check if a device at a given index is bound to any driver.
pub fn isDeviceBound(dev_index: usize) bool {
    if (dev_index >= DeviceList.MAX_DEVICES) return false;
    return device_bindings[dev_index].bound;
}
