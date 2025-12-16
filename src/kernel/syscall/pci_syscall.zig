// PCI Syscall Handlers
//
// Implements syscalls for userspace PCI device access:
// - sys_pci_enumerate: List discovered PCI devices
// - sys_pci_config_read: Read PCI configuration space
// - sys_pci_config_write: Write PCI configuration space
//
// Config space access requires PciConfig capability for the device.

const std = @import("std");
const base = @import("base.zig");
const uapi = @import("uapi");
const console = @import("console");
const pci = @import("pci");

const SyscallError = base.SyscallError;
const UserPtr = base.UserPtr;
const Process = base.Process;

/// PCI device info structure for userspace
/// Matches the layout expected by userspace drivers
pub const PciDeviceInfo = extern struct {
    /// PCI bus number
    bus: u8,
    /// PCI device number (0-31)
    device: u8,
    /// PCI function number (0-7)
    func: u8,
    /// Reserved for alignment
    _pad0: u8 = 0,

    /// Vendor ID
    vendor_id: u16,
    /// Device ID
    device_id: u16,

    /// Class code
    class_code: u8,
    /// Subclass
    subclass: u8,
    /// Programming interface
    prog_if: u8,
    /// Revision ID
    revision: u8,

    /// BAR information (6 BARs)
    bar: [6]BarInfo,

    /// Interrupt line (IRQ)
    irq_line: u8,
    /// Interrupt pin (1=INTA, 2=INTB, etc.)
    irq_pin: u8,
    /// Reserved
    _pad1: [6]u8 = [_]u8{0} ** 6,
};

/// BAR info structure
pub const BarInfo = extern struct {
    /// Physical base address
    base: u64,
    /// Size in bytes
    size: u64,
    /// 1 if MMIO, 0 if I/O port
    is_mmio: u8,
    /// 1 if 64-bit BAR
    is_64bit: u8,
    /// 1 if prefetchable
    prefetchable: u8,
    /// Reserved
    _pad: u8 = 0,
};

/// Convert kernel PciDevice to userspace PciDeviceInfo
fn deviceToInfo(dev: *const pci.PciDevice) PciDeviceInfo {
    var info = PciDeviceInfo{
        .bus = dev.bus,
        .device = dev.device,
        .func = dev.func,
        .vendor_id = dev.vendor_id,
        .device_id = dev.device_id,
        .class_code = dev.class_code,
        .subclass = dev.subclass,
        .prog_if = dev.prog_if,
        .revision = dev.revision,
        .irq_line = dev.irq_line,
        .irq_pin = dev.irq_pin,
        .bar = undefined,
    };

    // Convert BAR info
    for (&info.bar, 0..) |*bar_info, i| {
        const bar = dev.bar[i];
        bar_info.* = BarInfo{
            .base = bar.base,
            .size = bar.size,
            .is_mmio = if (bar.is_mmio) 1 else 0,
            .is_64bit = if (bar.is_64bit) 1 else 0,
            .prefetchable = if (bar.prefetchable) 1 else 0,
        };
    }

    return info;
}

/// sys_pci_enumerate (1033) - List PCI devices
///
/// Copies information about discovered PCI devices to userspace.
/// No capability required (read-only enumeration).
///
/// Arguments:
///   arg0: Pointer to array of PciDeviceInfo structs
///   arg1: Maximum number of devices to return
///
/// Returns:
///   Number of devices copied on success
///   -ENODEV if PCI not initialized
///   -EFAULT if buffer pointer is invalid
pub fn sys_pci_enumerate(buf_ptr_arg: usize, max_count_arg: usize) SyscallError!usize {
    const buf_ptr: u64 = @intCast(buf_ptr_arg);
    const max_count = max_count_arg;

    // Get PCI device list
    const devices = pci.getDevices() orelse {
        console.warn("sys_pci_enumerate: PCI not initialized", .{});
        return error.ENODEV;
    };

    const count = @min(devices.count, max_count);

    if (count == 0) {
        return 0;
    }

    // Validate user buffer
    const entry_size = @sizeOf(PciDeviceInfo);
    if (!base.isValidUserPtr(@intCast(buf_ptr), count * entry_size)) {
        return error.EFAULT;
    }

    // Copy device info to userspace
    for (0..count) |i| {
        if (devices.get(i)) |dev| {
            const info = deviceToInfo(dev);
            const offset = i * entry_size;
            const dest_ptr = UserPtr.from(buf_ptr + offset);
            _ = dest_ptr.copyFromKernel(std.mem.asBytes(&info)) catch {
                return error.EFAULT;
            };
        }
    }

    console.debug("sys_pci_enumerate: Returned {} devices", .{count});

    return count;
}

/// sys_pci_config_read (1034) - Read PCI config register
///
/// Reads a 32-bit value from PCI configuration space.
/// Requires PciConfig capability for the device.
///
/// Arguments:
///   arg0: Bus number
///   arg1: Device number (0-31)
///   arg2: Function number (0-7)
///   arg3: Register offset (must be 4-byte aligned)
///
/// Returns:
///   32-bit register value on success
///   -EPERM if process lacks PciConfig capability
///   -EINVAL if offset not aligned or device/func out of range
///   -ENODEV if PCI not initialized
pub fn sys_pci_config_read(
    bus_arg: usize,
    device_arg: usize,
    func_arg: usize,
    offset_arg: usize,
) SyscallError!usize {
    const bus: u8 = @intCast(bus_arg & 0xFF);
    const device: u5 = @intCast(device_arg & 0x1F);
    const func: u3 = @intCast(func_arg & 0x7);
    const offset: u12 = @intCast(offset_arg & 0xFFF);

    // Validate alignment (config reads must be 4-byte aligned for 32-bit)
    if (offset & 0x3 != 0) {
        return error.EINVAL;
    }

    // Get current process
    const proc = base.getCurrentProcess();

    // Check PciConfig capability
    if (!proc.hasPciConfigCapability(bus, device, func)) {
        console.warn("sys_pci_config_read: Process {} lacks PciConfig capability for {}:{}.{}", .{
            proc.pid,
            bus,
            device,
            func,
        });
        return error.EPERM;
    }

    // Get PCI ECAM accessor
    const ecam = pci.getEcam() orelse {
        console.warn("sys_pci_config_read: PCI ECAM not available", .{});
        return error.ENODEV;
    };

    // Read config register
    const value = ecam.read32(bus, device, func, offset);

    return @intCast(value);
}

/// sys_pci_config_write (1035) - Write PCI config register
///
/// Writes a 32-bit value to PCI configuration space.
/// Requires PciConfig capability for the device.
///
/// Arguments:
///   arg0: Bus number
///   arg1: Device number (0-31)
///   arg2: Function number (0-7)
///   arg3: Register offset (must be 4-byte aligned)
///   arg4: Value to write
///
/// Returns:
///   0 on success
///   -EPERM if process lacks PciConfig capability
///   -EINVAL if offset not aligned
///   -ENODEV if PCI not initialized
pub fn sys_pci_config_write(
    bus_arg: usize,
    device_arg: usize,
    func_arg: usize,
    offset_arg: usize,
    value_arg: usize,
) SyscallError!usize {
    const bus: u8 = @intCast(bus_arg & 0xFF);
    const device: u5 = @intCast(device_arg & 0x1F);
    const func: u3 = @intCast(func_arg & 0x7);
    const offset: u12 = @intCast(offset_arg & 0xFFF);
    const value: u32 = @intCast(value_arg & 0xFFFFFFFF);

    // Validate alignment
    if (offset & 0x3 != 0) {
        return error.EINVAL;
    }

    // Get current process
    const proc = base.getCurrentProcess();

    // Check PciConfig capability
    if (!proc.hasPciConfigCapability(bus, device, func)) {
        console.warn("sys_pci_config_write: Process {} lacks PciConfig capability for {}:{}.{}", .{
            proc.pid,
            bus,
            device,
            func,
        });
        return error.EPERM;
    }

    // Get PCI ECAM accessor
    var ecam = pci.getEcam() orelse {
        console.warn("sys_pci_config_write: PCI ECAM not available", .{});
        return error.ENODEV;
    };

    // Write config register
    ecam.write32(bus, device, func, offset, value);

    console.debug("sys_pci_config_write: {}:{}.{} offset={x} value={x}", .{
        bus,
        device,
        func,
        offset,
        value,
    });

    return 0;
}
