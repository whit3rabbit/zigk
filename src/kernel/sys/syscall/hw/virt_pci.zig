// Virtual PCI Device Syscall Handlers
//
// Implements syscalls for the virtual PCI device emulation framework:
//   - sys_vpci_create (1080): Create virtual device
//   - sys_vpci_add_bar (1081): Add BAR to device
//   - sys_vpci_add_cap (1082): Add capability
//   - sys_vpci_set_config (1083): Set config header
//   - sys_vpci_register (1084): Register with PCI subsystem
//   - sys_vpci_inject_irq (1085): Inject interrupt
//   - sys_vpci_dma (1086): DMA operation
//   - sys_vpci_get_bar_info (1087): Get BAR info
//   - sys_vpci_destroy (1088): Destroy device
//   - sys_vpci_wait_event (1089): Wait for MMIO event
//   - sys_vpci_respond (1090): Respond to MMIO read

const std = @import("std");
const uapi = @import("uapi");
const virt_pci_uapi = uapi.virt_pci;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const process_mod = @import("process");
const sched = @import("sched");
const console = @import("console");
const virt_pci = @import("virt_pci");
const caps = @import("caps");

// =============================================================================
// Helper Functions
// =============================================================================

/// Get current process
fn getCurrentProcess() SyscallError!*process_mod.Process {
    const current = sched.getCurrentThread() orelse return error.ESRCH;
    const proc_opaque = current.process orelse return error.ESRCH;
    return @ptrCast(@alignCast(proc_opaque));
}

/// Check if process has VirtualPciCapability
fn checkVirtualPciCapability(proc: *process_mod.Process) ?caps.VirtualPciCapability {
    for (proc.capabilities[0..proc.cap_count]) |cap| {
        switch (cap) {
            .VirtualPci => |vpci_cap| return vpci_cap,
            else => {},
        }
    }
    return null;
}

// =============================================================================
// sys_vpci_create (1080)
// =============================================================================

/// Create a new virtual PCI device
/// Returns: device_id on success
pub fn sys_vpci_create() SyscallError!usize {
    const proc = try getCurrentProcess();

    // Check capability
    const vpci_cap = checkVirtualPciCapability(proc) orelse {
        console.debug("VirtPCI: PID {} lacks VirtualPciCapability", .{proc.pid});
        return error.EPERM;
    };

    // Check device count limit
    const current_count = virt_pci.countDevicesForPid(proc.pid);
    if (!vpci_cap.canCreateDevice(current_count)) {
        console.debug("VirtPCI: PID {} at device limit ({}/{})", .{ proc.pid, current_count, vpci_cap.max_devices });
        return error.EMFILE;
    }

    // Allocate device
    const dev = virt_pci.allocateDevice(proc.pid) catch |err| {
        return switch (err) {
            error.TooManyDevices => error.EMFILE,
        };
    };

    return dev.id;
}

// =============================================================================
// sys_vpci_add_bar (1081)
// =============================================================================

/// Add a BAR to a virtual device
/// arg1: device_id, arg2: bar_config_ptr
pub fn sys_vpci_add_bar(device_id: usize, bar_config_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    // Validate device_id
    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    // Get device
    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Check capability for BAR size limits
    const vpci_cap = checkVirtualPciCapability(proc) orelse return error.EPERM;

    // Copy config from user
    var config: virt_pci_uapi.VPciBarConfig = undefined;
    const uptr = user_mem.UserPtr.from(bar_config_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&config)) catch {
        return error.EFAULT;
    };

    // Validate BAR index
    if (config.bar_index >= 6) return error.EINVAL;

    // Check BAR size limits
    const current_total_mb = virt_pci.totalBarSizeForPid(proc.pid) / (1024 * 1024);
    const new_bar_mb = config.size / (1024 * 1024);
    if (!vpci_cap.canAddBar(@truncate(current_total_mb), @truncate(new_bar_mb))) {
        console.debug("VirtPCI: PID {} BAR size limit exceeded", .{proc.pid});
        return error.ENOMEM;
    }

    // Add BAR
    dev.addBar(config.bar_index, config.size, config.flags) catch |err| {
        return switch (err) {
            error.InvalidBarIndex => error.EINVAL,
            error.BarTooSmall => error.EINVAL,
            error.BarTooLarge => error.EINVAL,
            error.NotPowerOfTwo => error.EINVAL,
            error.InvalidState => error.EINVAL,
            error.BarAlreadyConfigured => error.EEXIST,
            error.OutOfMemory => error.ENOMEM,
        };
    };

    return 0;
}

// =============================================================================
// sys_vpci_add_cap (1082)
// =============================================================================

/// Add a capability to a virtual device
/// arg1: device_id, arg2: cap_config_ptr
/// Returns: capability offset
pub fn sys_vpci_add_cap(device_id: usize, cap_config_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Copy config from user
    var config: virt_pci_uapi.VPciCapConfig = undefined;
    const uptr = user_mem.UserPtr.from(cap_config_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&config)) catch {
        return error.EFAULT;
    };

    // Add capability
    const offset = dev.addCapability(config.cap_type, &config.config_data) catch |err| {
        return switch (err) {
            error.InvalidState => error.EINVAL,
            error.TooManyCapabilities => error.ENOSPC,
        };
    };

    return offset;
}

// =============================================================================
// sys_vpci_set_config (1083)
// =============================================================================

/// Set PCI configuration header
/// arg1: device_id, arg2: config_header_ptr
pub fn sys_vpci_set_config(device_id: usize, config_header_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Check capability for class restrictions
    const vpci_cap = checkVirtualPciCapability(proc) orelse return error.EPERM;

    // Copy config from user
    var header: virt_pci_uapi.VPciConfigHeader = undefined;
    const uptr = user_mem.UserPtr.from(config_header_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&header)) catch {
        return error.EFAULT;
    };

    // Check if class is allowed
    if (!vpci_cap.allowsClass(header.class_code)) {
        console.debug("VirtPCI: PID {} class code 0x{x} not allowed", .{ proc.pid, header.class_code });
        return error.EPERM;
    }

    // Set config
    dev.setConfigHeader(&header);

    return 0;
}

// =============================================================================
// sys_vpci_register (1084)
// =============================================================================

/// Register device with PCI subsystem and create event ring
/// arg1: device_id
/// Returns: ring_id
pub fn sys_vpci_register(device_id: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Check state
    if (dev.state != .configuring) {
        return error.EINVAL;
    }

    // Allocate event ring
    dev.allocateEventRing(virt_pci_uapi.DEFAULT_RING_ENTRIES) catch |err| {
        return switch (err) {
            error.NotPowerOfTwo => error.EINVAL,
            error.OutOfMemory => error.ENOMEM,
        };
    };

    // Transition to registered state
    const held = dev.lock.acquire();
    dev.state = .registered;
    held.release();

    // TODO: Add to PCI enumeration as virtual device
    // This would make the device visible to pci.getDevices()

    console.info("VirtPCI: Device {} registered for PID {}", .{ dev.id, proc.pid });

    // Return a ring_id (use device_id for now, could be separate)
    return dev.id;
}

// =============================================================================
// sys_vpci_inject_irq (1085)
// =============================================================================

/// Inject MSI/MSI-X interrupt
/// arg1: device_id, arg2: irq_config_ptr
pub fn sys_vpci_inject_irq(device_id: usize, irq_config_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Check capability allows IRQ injection
    const vpci_cap = checkVirtualPciCapability(proc) orelse return error.EPERM;
    if (!vpci_cap.allow_irq_injection) {
        return error.EPERM;
    }

    // Device must be registered
    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    // Copy config from user
    var irq_config: virt_pci_uapi.VPciIrqConfig = undefined;
    const uptr = user_mem.UserPtr.from(irq_config_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&irq_config)) catch {
        return error.EFAULT;
    };

    // Inject interrupt based on type
    switch (irq_config.irq_type) {
        .msi => {
            if (!dev.msi_enabled) return error.EINVAL;
            // TODO: Implement MSI injection
            // This requires writing to the APIC's ICR (Interrupt Command Register)
            // to send an edge-triggered interrupt to the configured address/data
            //
            // For now, log and return success (interrupt won't actually fire)
            console.debug("VirtPCI: MSI inject addr=0x{x} data=0x{x} (not implemented)", .{ dev.msi_address, dev.msi_data });
            return 0;
        },
        .msix => {
            if (!dev.msix_enabled) return error.EINVAL;
            if (irq_config.vector >= dev.msix_table_size) return error.EINVAL;

            // Read MSI-X table entry
            if (dev.msix_table_base == 0) return error.EINVAL;

            const entry_addr = dev.msix_table_base + @as(u64, irq_config.vector) * 16;
            const addr_lo: *volatile u32 = @ptrFromInt(entry_addr);
            const addr_hi: *volatile u32 = @ptrFromInt(entry_addr + 4);
            const data: *volatile u32 = @ptrFromInt(entry_addr + 8);
            const ctrl: *volatile u32 = @ptrFromInt(entry_addr + 12);

            // Check if masked
            if ((ctrl.* & 1) != 0) return error.EINVAL;

            const address = (@as(u64, addr_hi.*) << 32) | addr_lo.*;
            // TODO: Implement MSI-X injection (same as MSI, different address/data source)
            console.debug("VirtPCI: MSI-X inject vec={} addr=0x{x} data=0x{x} (not implemented)", .{ irq_config.vector, address, data.* });
            return 0;
        },
        .intx => {
            // Legacy INTx not supported for virtual devices
            return error.ENOTSUP;
        },
    }

    return 0;
}

// =============================================================================
// sys_vpci_dma (1086)
// =============================================================================

/// Perform DMA read/write operation
/// arg1: dma_op_ptr
pub fn sys_vpci_dma(dma_op_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    // Check capability allows DMA
    const vpci_cap = checkVirtualPciCapability(proc) orelse return error.EPERM;
    if (!vpci_cap.allow_dma) {
        return error.EPERM;
    }

    // Copy DMA op from user
    var dma_op: virt_pci_uapi.VPciDmaOp = undefined;
    const uptr = user_mem.UserPtr.from(dma_op_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&dma_op)) catch {
        return error.EFAULT;
    };

    // Get device
    const dev = virt_pci.getDeviceForPid(dma_op.device_id, proc.pid) orelse {
        return error.ENOENT;
    };

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    // Validate length
    if (dma_op.length == 0 or dma_op.length > 1024 * 1024) {
        return error.EINVAL;
    }

    // TODO: Implement IOVA translation and actual DMA
    // For now, we would need to:
    // 1. Translate IOVA to physical address (if IOMMU domain exists)
    // 2. Map physical pages
    // 3. Copy data between userspace buffer and physical memory

    // Placeholder - actual implementation requires IOMMU integration
    console.debug("VirtPCI: DMA op dev={} dir={} iova=0x{x} len={}", .{ dma_op.device_id, @intFromEnum(dma_op.direction), dma_op.iova, dma_op.length });

    return error.ENOTSUP;
}

// =============================================================================
// sys_vpci_get_bar_info (1087)
// =============================================================================

/// Get BAR information after registration
/// arg1: device_id, arg2: bar_index, arg3: bar_info_ptr
pub fn sys_vpci_get_bar_info(device_id: usize, bar_index: usize, bar_info_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;
    if (bar_index >= 6) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    const bar = &dev.bars[bar_index];
    if (!bar.configured) {
        return error.ENOENT;
    }

    // Build bar info
    const info = virt_pci_uapi.VPciBarInfo{
        .phys_addr = bar.backing_phys,
        .virt_addr = bar.backing_virt,
        .size = bar.size,
        .flags = bar.flags,
    };

    // Copy to user
    const uptr = user_mem.UserPtr.from(bar_info_ptr);
    _ = uptr.copyFromKernel(std.mem.asBytes(&info)) catch {
        return error.EFAULT;
    };

    return 0;
}

// =============================================================================
// sys_vpci_destroy (1088)
// =============================================================================

/// Unregister and destroy a virtual device
/// arg1: device_id
pub fn sys_vpci_destroy(device_id: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    // Verify ownership
    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    // Mark as closing and free
    _ = dev; // Used for ownership check
    virt_pci.freeDevice(@truncate(device_id));

    return 0;
}

// =============================================================================
// sys_vpci_wait_event (1089)
// =============================================================================

/// Wait for MMIO event (blocking)
/// arg1: device_id, arg2: timeout_ns (0 = infinite)
/// Returns: number of pending events
pub fn sys_vpci_wait_event(device_id: usize, timeout_ns: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    if (dev.ring_virt == 0) {
        return error.EINVAL;
    }

    // Get ring header
    const header: *volatile virt_pci_uapi.VPciRingHeader = @ptrFromInt(dev.ring_virt);

    // Check if events available
    var available = header.availableEvents();
    if (available > 0) {
        return available;
    }

    // Block waiting for events
    // TODO: Implement proper futex-based waiting
    const timeout: ?u64 = if (timeout_ns == 0) null else @intCast(timeout_ns);

    if (timeout) |ns| {
        const timeout_ticks = (ns + 999_999) / 1_000_000;
        if (timeout_ticks > 0) {
            sched.sleepForTicks(timeout_ticks);
        }
    } else {
        sched.yield();
    }

    // Re-check
    available = header.availableEvents();
    if (available > 0) {
        return available;
    }

    if (timeout != null) {
        return error.ETIMEDOUT;
    }

    return error.EAGAIN;
}

// =============================================================================
// sys_vpci_respond (1090)
// =============================================================================

/// Submit response to an MMIO read event
/// arg1: device_id, arg2: response_ptr
pub fn sys_vpci_respond(device_id: usize, response_ptr: usize) SyscallError!usize {
    const proc = try getCurrentProcess();

    if (device_id > std.math.maxInt(u32)) return error.EINVAL;

    const dev = virt_pci.getDeviceForPid(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    // Copy response from user
    var response: virt_pci_uapi.VPciResponse = undefined;
    const uptr = user_mem.UserPtr.from(response_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&response)) catch {
        return error.EFAULT;
    };

    // TODO: Match response.seq to pending request and complete it
    // This requires tracking pending MMIO reads and waking blocked threads

    console.debug("VirtPCI: Response seq={} data=0x{x}", .{ response.seq, response.data });

    // Decrement pending response count
    if (dev.ring_virt != 0) {
        const header: *volatile virt_pci_uapi.VPciRingHeader = @ptrFromInt(dev.ring_virt);
        _ = @atomicRmw(u32, &header.pending_responses, .Sub, 1, .release);
    }

    return 0;
}
