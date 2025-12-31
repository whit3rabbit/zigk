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
/// No capability required for basic enumeration (vendor/device IDs, class codes).
///
/// SECURITY: Physical BAR addresses are ONLY exposed to processes with
/// appropriate capabilities (PciConfig or Mmio). Unprivileged callers
/// receive zeroed BAR base addresses to prevent ASLR/KASLR bypass attacks.
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

    // SECURITY NOTE: count is bounded by devices.count which is <= MAX_DEVICES (64).
    // Even though max_count is user-controlled, @min ensures count <= 64.
    // Therefore, count * entry_size cannot overflow (64 * ~140 bytes = ~9KB).
    const count = @min(devices.count, max_count);

    if (count == 0) {
        return 0;
    }

    // Validate user buffer
    const entry_size = @sizeOf(PciDeviceInfo);
    if (!base.isValidUserAccess(@intCast(buf_ptr), count * entry_size, base.AccessMode.Write)) {
        return error.EFAULT;
    }

    // Get current process for capability checking
    const proc = base.getCurrentProcess();

    // Copy device info to userspace
    for (0..count) |i| {
        if (devices.get(i)) |dev| {
            var info = deviceToInfo(dev);

            // SECURITY: Redact physical BAR addresses unless the process has
            // capability to access this device's config space or MMIO.
            // This prevents unprivileged processes from learning physical
            // memory layout (defeats ASLR/KASLR bypass attacks).
            const has_pci_cap = proc.hasPciConfigCapability(dev.bus, dev.device, dev.func);

            if (!has_pci_cap) {
                // Check if process has MMIO capability for any of the BARs
                var has_any_mmio_cap = false;
                for (&info.bar) |*bar_info| {
                    if (bar_info.base != 0 and bar_info.size != 0) {
                        if (proc.hasMmioCapability(bar_info.base, bar_info.size)) {
                            has_any_mmio_cap = true;
                            break;
                        }
                    }
                }

                // No capability - redact all physical addresses
                if (!has_any_mmio_cap) {
                    for (&info.bar) |*bar_info| {
                        bar_info.base = 0; // Redact physical address
                        // Keep size/type info - these are useful and not sensitive
                    }
                }
            }

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
/// SECURITY: By default, writes to security-sensitive registers are blocked:
/// - Command register (0x04): Controls bus mastering, memory/IO enable
/// - BAR registers (0x10-0x24): Control device memory mappings
/// - Expansion ROM (0x30): Could load malicious firmware
///
/// To write these registers, the capability must have allow_unsafe=true.
/// This prevents userspace drivers from:
/// 1. Re-enabling bus mastering on a device the kernel disabled
/// 2. Remapping device memory to overlap kernel regions
/// 3. Redirecting MSI interrupts to hijack kernel control flow
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
///   -EPERM if process lacks PciConfig capability or writing restricted register
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

    // Get PciConfig capability (need full capability to check allow_unsafe)
    const pci_cap = proc.getPciConfigCapability(bus, device, func) orelse {
        console.warn("sys_pci_config_write: Process {} lacks PciConfig capability for {}:{}.{}", .{
            proc.pid,
            bus,
            device,
            func,
        });
        return error.EPERM;
    };

    // SECURITY: Check if writing to this register is allowed
    // Restricted registers (Command, BARs, ROM) require allow_unsafe=true
    if (!pci_cap.allowsWrite(offset)) {
        console.warn("sys_pci_config_write: Process {} denied write to restricted register 0x{x} on {}:{}.{}", .{
            proc.pid,
            offset,
            bus,
            device,
            func,
        });
        console.warn("  Hint: Set allow_unsafe=true in PciConfigCapability for kernel drivers", .{});
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
