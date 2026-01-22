// Virtual PCI Device Emulation Framework
//
// Provides userspace-controlled virtual PCI devices for driver testing.
// Port of the pciem framework from Linux/C to zigk.
//
// Features:
//   - Create virtual PCI devices visible to the PCI subsystem
//   - Define BARs with MMIO interception
//   - PCI capability emulation (MSI, MSI-X, PM)
//   - Interrupt injection
//   - DMA operations
//
// Reference: github.com/cakehonolulu/pciem

const std = @import("std");
const uapi = @import("uapi");
const virt_pci_uapi = uapi.virt_pci;
const sync = @import("sync");
const console = @import("console");

pub const device = @import("device.zig");

// Re-export device types
pub const VirtualPciDevice = device.VirtualPciDevice;
pub const VirtualBar = device.VirtualBar;
pub const CapabilityManager = device.CapabilityManager;
pub const CapabilityEntry = device.CapabilityEntry;

// =============================================================================
// Global Device Table
// =============================================================================

/// Maximum system-wide virtual devices
const MAX_DEVICES = virt_pci_uapi.MAX_DEVICES;

/// Global device table
var devices: [MAX_DEVICES]VirtualPciDevice = undefined;
var device_used: [MAX_DEVICES]bool = [_]bool{false} ** MAX_DEVICES;
var devices_lock: sync.RwLock = .{};
var initialized: bool = false;
var next_device_id: u32 = 1;

/// Initialize the virtual PCI subsystem
pub fn init() void {
    if (initialized) return;

    for (&devices, 0..) |*dev, idx| {
        dev.* = VirtualPciDevice.init(@intCast(idx), 0);
        device_used[idx] = false;
    }

    initialized = true;
    console.info("Virtual PCI subsystem initialized (max {} devices)", .{MAX_DEVICES});
}

/// Ensure initialization
fn ensureInit() void {
    if (!initialized) init();
}

// =============================================================================
// Device Allocation
// =============================================================================

/// Allocate a new virtual device
pub fn allocateDevice(owner_pid: u32) !*VirtualPciDevice {
    ensureInit();

    const held = devices_lock.acquireWrite();
    defer held.release();

    // Find free slot
    for (&devices, 0..) |*dev, idx| {
        if (!device_used[idx]) {
            const device_id = next_device_id;
            next_device_id +%= 1;
            if (next_device_id == 0) next_device_id = 1; // Avoid ID 0

            dev.* = VirtualPciDevice.init(device_id, owner_pid);
            device_used[idx] = true;

            console.debug("VirtPCI: Allocated device {} for PID {}", .{ device_id, owner_pid });
            return dev;
        }
    }

    return error.TooManyDevices;
}

/// Get device by ID
pub fn getDevice(device_id: u32) ?*VirtualPciDevice {
    ensureInit();

    const held = devices_lock.acquireRead();
    defer held.release();

    for (&devices, 0..) |*dev, idx| {
        if (device_used[idx] and dev.id == device_id) {
            return dev;
        }
    }

    return null;
}

/// Get device by ID with ownership check
pub fn getDeviceForPid(device_id: u32, pid: u32) ?*VirtualPciDevice {
    const dev = getDevice(device_id) orelse return null;
    if (dev.owner_pid != pid) return null;
    return dev;
}

/// Free a device
pub fn freeDevice(device_id: u32) void {
    ensureInit();

    const held = devices_lock.acquireWrite();
    defer held.release();

    for (&devices, 0..) |*dev, idx| {
        if (device_used[idx] and dev.id == device_id) {
            dev.destroy();
            device_used[idx] = false;
            console.debug("VirtPCI: Freed device {}", .{device_id});
            return;
        }
    }
}

/// Free all devices owned by a process (on exit)
pub fn cleanupByPid(pid: u32) void {
    ensureInit();

    const held = devices_lock.acquireWrite();
    defer held.release();

    for (&devices, 0..) |*dev, idx| {
        if (device_used[idx] and dev.owner_pid == pid) {
            dev.destroy();
            device_used[idx] = false;
            console.debug("VirtPCI: Cleaned up device {} for PID {}", .{ dev.id, pid });
        }
    }
}

/// Count devices owned by a process
pub fn countDevicesForPid(pid: u32) u8 {
    ensureInit();

    const held = devices_lock.acquireRead();
    defer held.release();

    var count: u8 = 0;
    for (&devices) |*dev| {
        if (dev.owner_pid == pid and dev.state != .closing) {
            count += 1;
        }
    }
    return count;
}

/// Get total BAR size for a process
pub fn totalBarSizeForPid(pid: u32) u64 {
    ensureInit();

    const held = devices_lock.acquireRead();
    defer held.release();

    var total: u64 = 0;
    for (&devices) |*dev| {
        if (dev.owner_pid == pid and dev.state != .closing) {
            total +|= dev.total_bar_size;
        }
    }
    return total;
}

// =============================================================================
// Statistics
// =============================================================================

/// Get virtual PCI statistics
pub fn getStats() struct { total: usize, used: usize, active: usize } {
    ensureInit();

    const held = devices_lock.acquireRead();
    defer held.release();

    var used: usize = 0;
    var active: usize = 0;

    for (&devices, 0..) |*dev, idx| {
        if (device_used[idx]) {
            used += 1;
            if (dev.state == .active or dev.state == .registered) {
                active += 1;
            }
        }
    }

    return .{
        .total = MAX_DEVICES,
        .used = used,
        .active = active,
    };
}

// =============================================================================
// Iterators
// =============================================================================

/// Iterator for registered virtual devices (for PCI enumeration)
pub const RegisteredDeviceIterator = struct {
    index: usize = 0,

    pub fn next(self: *RegisteredDeviceIterator) ?*const VirtualPciDevice {
        while (self.index < MAX_DEVICES) {
            const idx = self.index;
            self.index += 1;

            if (device_used[idx]) {
                const dev = &devices[idx];
                if (dev.state == .registered or dev.state == .active) {
                    return dev;
                }
            }
        }
        return null;
    }
};

/// Get iterator for registered virtual devices
/// Note: Caller must hold devices_lock for thread safety
pub fn registeredDevices() RegisteredDeviceIterator {
    ensureInit();
    return .{};
}

/// Acquire read lock for iteration
pub fn acquireReadLock() sync.RwLock.Held(.shared) {
    ensureInit();
    return devices_lock.acquireRead();
}
