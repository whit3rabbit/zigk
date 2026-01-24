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

/// Get device by ID with ownership check (no refcount -- use getDeviceRef for syscalls)
pub fn getDeviceForPid(device_id: u32, pid: u32) ?*VirtualPciDevice {
    const dev = getDevice(device_id) orelse return null;
    if (dev.owner_pid != pid) return null;
    return dev;
}

/// Acquire a reference-counted handle to a device.
/// The caller MUST call putDeviceRef() when done to prevent resource leaks.
/// Returns null if the device does not exist, is not owned by `pid`, or is closing.
pub fn getDeviceRef(device_id: u32, pid: u32) ?*VirtualPciDevice {
    ensureInit();

    const held = devices_lock.acquireRead();
    defer held.release();

    for (&devices, 0..) |*dev, idx| {
        if (device_used[idx] and dev.id == device_id) {
            if (dev.owner_pid != pid) return null;
            if (dev.state == .closing) return null;
            // Increment refcount while holding read lock.
            // This prevents racing with freeDevice which requires write lock.
            _ = @atomicRmw(u32, &dev.ref_count, .Add, 1, .acquire);
            return dev;
        }
    }
    return null;
}

/// Release a reference-counted handle to a device.
/// If this was the last reference and the device is closing, frees resources
/// and marks the device slot as reusable.
pub fn putDeviceRef(dev: *VirtualPciDevice) void {
    const prev = @atomicRmw(u32, &dev.ref_count, .Sub, 1, .release);
    // prev is the value BEFORE subtraction. If it was 1, refcount is now 0.
    if (prev == 1 and dev.state == .closing) {
        dev.destroyResources();
        // Mark slot as reusable under write lock.
        const held = devices_lock.acquireWrite();
        defer held.release();
        if (getSlotIndex(dev)) |idx| {
            device_used[idx] = false;
        }
    }
}

/// Free a device. Marks it as closing under write lock.
/// If no active references, frees resources immediately and marks slot unused.
/// If active references exist, resource cleanup is deferred to the last putDeviceRef.
/// Wakes blocked waiters after releasing the write lock (lock ordering requirement).
pub fn freeDevice(device_id: u32) void {
    ensureInit();

    var dev_to_wake: ?*VirtualPciDevice = null;
    {
        const held = devices_lock.acquireWrite();
        defer held.release();

        for (&devices, 0..) |*dev, idx| {
            if (device_used[idx] and dev.id == device_id) {
                const can_free_now = dev.beginDestroy();
                if (can_free_now) {
                    dev.destroyResources();
                    device_used[idx] = false;
                } else {
                    // Slot stays occupied until last ref is released.
                    // getDeviceRef will reject it (state == .closing).
                    dev_to_wake = dev;
                }
                console.debug("VirtPCI: Freed device {} (immediate={})", .{ device_id, can_free_now });
                break;
            }
        }
    }

    // Wake blocked waiters OUTSIDE devices_lock to respect lock ordering:
    // scheduler lock (#4) must be acquired before devices_lock (#8.5).
    if (dev_to_wake) |dev| {
        const event_held = dev.event_lock.acquire();
        _ = dev.event_queue.wakeUp(std.math.maxInt(usize));
        event_held.release();
    }
}

/// Free all devices owned by a process (on exit).
/// Defers resource cleanup if active references exist.
/// Wakes blocked waiters after releasing the write lock.
pub fn cleanupByPid(pid: u32) void {
    ensureInit();

    var deferred_wakes: [MAX_DEVICES]?*VirtualPciDevice = [_]?*VirtualPciDevice{null} ** MAX_DEVICES;
    var wake_count: usize = 0;

    {
        const held = devices_lock.acquireWrite();
        defer held.release();

        for (&devices, 0..) |*dev, idx| {
            if (device_used[idx] and dev.owner_pid == pid) {
                const can_free_now = dev.beginDestroy();
                if (can_free_now) {
                    dev.destroyResources();
                    device_used[idx] = false;
                } else {
                    deferred_wakes[wake_count] = dev;
                    wake_count += 1;
                }
                console.debug("VirtPCI: Cleaned up device {} for PID {} (immediate={})", .{ dev.id, pid, can_free_now });
            }
        }
    }

    // Wake blocked waiters OUTSIDE devices_lock (lock ordering).
    for (deferred_wakes[0..wake_count]) |maybe_dev| {
        if (maybe_dev) |dev| {
            const event_held = dev.event_lock.acquire();
            _ = dev.event_queue.wakeUp(std.math.maxInt(usize));
            event_held.release();
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
pub fn acquireReadLock() sync.RwLock.ReadHeld {
    ensureInit();
    return devices_lock.acquireRead();
}

/// Get the slot index for a device pointer (needed for probe binding).
/// Returns the index into the global device table, or null if the pointer
/// is not within the device array.
pub fn getSlotIndex(dev: *const VirtualPciDevice) ?usize {
    const base = @intFromPtr(&devices[0]);
    const ptr = @intFromPtr(dev);
    if (ptr < base) return null;
    const offset = ptr - base;
    const idx = offset / @sizeOf(VirtualPciDevice);
    if (idx >= MAX_DEVICES) return null;
    return idx;
}
