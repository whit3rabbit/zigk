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
const builtin = @import("builtin");
const uapi = @import("uapi");
const virt_pci_uapi = uapi.virt_pci;
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const process_mod = @import("process");
const sched = @import("sched");
const console = @import("console");
const virt_pci = @import("virt_pci");
const caps = @import("caps");
const hal = @import("hal");

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
    for (proc.capabilities.items) |cap| {
        switch (cap) {
            .VirtualPci => |vpci_cap| return vpci_cap,
            else => {},
        }
    }
    return null;
}

/// Deliver an MSI/MSI-X interrupt by parsing the address/data and sending an IPI.
///
/// x86 MSI Address format (Intel SDM Vol 3, 10.11.1):
///   [31:20] = 0xFEE (fixed, identifies as MSI address)
///   [19:12] = Destination APIC ID (physical mode)
///   [3]     = RH (Redirection Hint)
///   [2]     = DM (Destination Mode: 0=physical, 1=logical)
///
/// x86 MSI Data format (Intel SDM Vol 3, 10.11.2):
///   [7:0]   = Vector
///   [10:8]  = Delivery Mode (000=Fixed, 001=Lowest Priority, etc.)
///   [14]    = Level (assert/deassert)
///   [15]    = Trigger Mode (0=edge, 1=level)
fn deliverMsi(address: u64, data: u32) void {
    // Validate MSI address prefix (must be 0xFEE in bits [31:20])
    if ((address >> 20) & 0xFFF != 0xFEE) {
        console.warn("VirtPCI: Invalid MSI address 0x{x} (bad prefix)", .{address});
        return;
    }

    // Extract destination APIC ID and vector
    const dest_apic_id: u32 = @truncate((address >> 12) & 0xFF);
    const vector: u8 = @truncate(data & 0xFF);
    const delivery_mode_raw: u3 = @truncate((data >> 8) & 0x7);

    // Validate vector (must be >= 32 for non-exception interrupts)
    if (vector < 32) {
        console.warn("VirtPCI: MSI vector {} < 32 (reserved for exceptions)", .{vector});
        return;
    }

    if (comptime builtin.cpu.arch == .x86_64) {
        // SECURITY: Only allow safe delivery modes from virtual device MSI injection.
        // SMI (mode 2), NMI (mode 4), INIT (mode 5), and STARTUP (mode 6) are
        // privileged CPU operations that must never be triggered by virtual devices.
        // Only Fixed (0) and Lowest Priority (1) are safe for interrupt delivery.
        const lapic = hal.apic.lapic;
        const delivery_mode: lapic.DeliveryMode = switch (delivery_mode_raw) {
            0 => .fixed,
            1 => .lowest_priority,
            else => {
                console.warn("VirtPCI: Rejected unsafe MSI delivery mode {} (only fixed/lowest_priority allowed)", .{delivery_mode_raw});
                return;
            },
        };

        lapic.sendIpi(dest_apic_id, vector, delivery_mode, .none);
        console.debug("VirtPCI: MSI delivered vec={} dest={} mode={}", .{ vector, dest_apic_id, delivery_mode_raw });
    } else {
        // AArch64: MSI injection not yet supported
        console.warn("VirtPCI: MSI injection not supported on this architecture", .{});
    }
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

    // Get device (ref-counted to prevent UAF if concurrent destroy occurs)
    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

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

    console.info("VirtPCI: Device {} registered for PID {}", .{ dev.id, proc.pid });

    // Trigger driver probe for this newly registered virtual device
    const pci = @import("pci");
    const slot_idx = virt_pci.getSlotIndex(dev) orelse 0;
    const ecam = pci.getEcam();
    if (ecam) |e| {
        _ = pci.probeVirtualDeviceFromConfig(
            &dev.config_space,
            @as(u16, dev.config_space[0x2C]) | (@as(u16, dev.config_space[0x2D]) << 8),
            @as(u16, dev.config_space[0x2E]) | (@as(u16, dev.config_space[0x2F]) << 8),
            slot_idx,
            pci.PciAccess{ .ecam = e },
        );
    }

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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

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
            deliverMsi(dev.msi_address, dev.msi_data);
            return 0;
        },
        .msix => {
            if (!dev.msix_enabled) return error.EINVAL;
            if (irq_config.vector >= dev.msix_table_size) return error.EINVAL;

            // Read MSI-X table entry from BAR backing memory
            if (dev.msix_table_base == 0) return error.EINVAL;

            const entry_addr = dev.msix_table_base + @as(u64, irq_config.vector) * 16;
            const addr_lo: *volatile u32 = @ptrFromInt(entry_addr);
            const addr_hi: *volatile u32 = @ptrFromInt(entry_addr + 4);
            const data: *volatile u32 = @ptrFromInt(entry_addr + 8);
            const ctrl: *volatile u32 = @ptrFromInt(entry_addr + 12);

            // Check if vector is masked
            if ((ctrl.* & 1) != 0) return error.EINVAL;

            const address = (@as(u64, addr_hi.*) << 32) | addr_lo.*;
            deliverMsi(address, data.*);
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

    // Get device (ref-counted to prevent UAF during DMA copy)
    const dev = virt_pci.getDeviceRef(dma_op.device_id, proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    // Validate length
    if (dma_op.length == 0 or dma_op.length > 1024 * 1024) {
        return error.EINVAL;
    }

    // Validate user buffer access
    const host_addr: usize = @intCast(dma_op.host_buffer);
    const len: usize = @intCast(dma_op.length);
    const access_mode: user_mem.AccessMode = switch (dma_op.direction) {
        .to_device => .Read, // User buffer is read source
        .from_device => .Write, // User buffer is write destination
    };
    if (!user_mem.isValidUserAccess(host_addr, len, access_mode)) {
        return error.EFAULT;
    }

    // Find which BAR the IOVA maps to (no-IOMMU path: IOVA = physical address)
    const bar_ptr = dev.findBarForIova(dma_op.iova, dma_op.length) orelse {
        console.debug("VirtPCI: DMA IOVA 0x{x} not in any BAR", .{dma_op.iova});
        return error.EINVAL;
    };

    const user_ptr = user_mem.UserPtr.from(host_addr);

    switch (dma_op.direction) {
        .to_device => {
            // User -> BAR memory (device receives data)
            _ = user_ptr.copyToKernel(bar_ptr[0..len]) catch return error.EFAULT;
        },
        .from_device => {
            // BAR memory -> User (device sends data)
            _ = user_ptr.copyFromKernel(bar_ptr[0..len]) catch return error.EFAULT;
        },
    }

    return len;
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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

    const bar = &dev.bars[bar_index];
    if (!bar.configured) {
        return error.ENOENT;
    }

    // Build bar info
    // SECURITY: Never expose kernel virtual addresses to userspace.
    // Userspace uses phys_addr for DMA IOVA targeting; virt_addr is kernel-only.
    const info = virt_pci_uapi.VPciBarInfo{
        .phys_addr = bar.backing_phys,
        .virt_addr = 0,
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

    // Verify ownership (ref-counted: freeDevice marks closing, putDeviceRef triggers cleanup)
    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

    // Mark as closing and initiate destruction
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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    if (dev.ring_virt == 0) {
        return error.EINVAL;
    }

    // Get ring header
    const header: *volatile virt_pci_uapi.VPciRingHeader = @ptrFromInt(dev.ring_virt);

    // Fast path: events already available
    const available = header.availableEvents();
    if (available > 0) {
        return available;
    }

    // Slow path: block on the device's event wait queue
    const timeout_ticks: u64 = if (timeout_ns == 0)
        0 // Infinite wait
    else
        @max(1, (timeout_ns + 999_999) / 1_000_000);

    // Acquire event_lock, check again under lock, then sleep
    const lock_held = dev.event_lock.acquire();

    // Re-check under lock to prevent lost wakeup
    const avail_locked = header.availableEvents();
    if (avail_locked > 0) {
        lock_held.release();
        return avail_locked;
    }

    // Block: waitOnWithTimeout releases lock_held atomically with sleep
    sched.waitOnWithTimeout(&dev.event_queue, lock_held, timeout_ticks, null);

    // Woken up - check events
    const final_available = header.availableEvents();
    if (final_available > 0) {
        return final_available;
    }

    // No events after wake - must have been a timeout
    if (timeout_ns != 0) {
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

    const dev = virt_pci.getDeviceRef(@truncate(device_id), proc.pid) orelse {
        return error.ENOENT;
    };
    defer virt_pci.putDeviceRef(dev);

    if (dev.state != .registered and dev.state != .active) {
        return error.EINVAL;
    }

    // Copy response from user
    var response: virt_pci_uapi.VPciResponse = undefined;
    const uptr = user_mem.UserPtr.from(response_ptr);
    _ = uptr.copyToKernel(std.mem.asBytes(&response)) catch {
        return error.EFAULT;
    };

    // Match response to pending MMIO read and wake blocked thread
    if (!dev.submitResponse(response.seq, response.data)) {
        // No pending read with this seq - might be a stale/duplicate response
        console.debug("VirtPCI: No pending read for seq={}", .{response.seq});
    }

    // Decrement pending response count in ring header
    if (dev.ring_virt != 0) {
        const header: *volatile virt_pci_uapi.VPciRingHeader = @ptrFromInt(dev.ring_virt);
        const prev = @atomicLoad(u32, &header.pending_responses, .acquire);
        if (prev > 0) {
            _ = @atomicRmw(u32, &header.pending_responses, .Sub, 1, .release);
        }
    }

    return 0;
}
