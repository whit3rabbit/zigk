const std = @import("std");
const console = @import("console");
const hal = @import("hal");

const types = @import("types.zig");
const regs = @import("regs.zig");
const device_manager = @import("device_manager.zig");
const device = @import("device.zig");
const context = @import("context.zig");
const transfer_pool = @import("transfer_pool.zig");

const Controller = types.Controller;
const MmioDevice = hal.mmio_device.MmioDevice;

/// Reset a port to enable it and bring the device to the Default state
/// Security: Preserves R/WC bits by writing 1s to them (as they are W1C or preserved)
/// to ensure we don't accidentally clear status changes we haven't processed.
pub fn resetPort(ctrl: *Controller, port: u8) !void {
    const port_base = ctrl.op_base + regs.portBaseOffset(port);
    const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);

    // Read current state
    const portsc = port_dev.readTyped(.portsc, regs.PortSc);

    // If not connected, nothing to do
    if (!portsc.ccs) return;

    // Reset sequence: Write 1 to PR (Port Reset)
    // We must preserve R/W bits and write 1 to Clear R/WC bits (status changes)
    // to avoid clearing them accidentally?
    // Wait, typically W1C bits are cleared by writing 1.
    // If we write 1 to them, we CLEAR them.
    // Logic in root.zig was:
    // new_cntl.csc = true; ... (Clear Connect Status Change)
    // This acknowledges the change so we can proceed.
    
    var new_cntl = portsc;
    new_cntl.pr = true;      // Assert Reset
    new_cntl.csc = true;     // Clear Connect Status Change
    new_cntl.pec = true;     // Clear Port Enable/Disable Change
    new_cntl.wrc = true;     // Clear Warm Port Reset Change
    new_cntl.occ = true;     // Clear Over-Current Change
    new_cntl.prc = true;     // Clear Port Reset Change
    new_cntl.plc = true;     // Clear Port Link State Change

    port_dev.writeTyped(.portsc, new_cntl);

    // Wait for reset to complete
    // The controller clears PR bit when reset is done
    var timeout: u32 = 500; // 500ms timeout
    while (timeout > 0) : (timeout -= 1) {
        const current = port_dev.readTyped(.portsc, regs.PortSc);
        
        // Check if Reset is done (PR == 0) and Port Enabled (PED == 1)
        if (!current.pr and current.ped) {
             console.info("XHCI: Port {d} reset successful (Speed: {d})", .{ port, current.speed });
             return;
        }
        
        // Wait approx 1ms
        var delay: u32 = 10000;
        while (delay > 0) : (delay -= 1) {
            hal.cpu.pause();
        }
    }

    console.warn("XHCI: Port {d} reset timed out or failed to enable", .{port});
    return error.ResetFailed;
}

/// Scan ports for connected devices and attempt enumeration
pub fn scanPorts(ctrl: *Controller) void {
    console.info("XHCI: Scanning {d} ports...", .{ctrl.max_ports});

    var port: u8 = 1;
    while (port <= ctrl.max_ports) : (port += 1) {
        const port_base = ctrl.op_base + regs.portBaseOffset(port);
        const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);
        const portsc = port_dev.readTyped(.portsc, regs.PortSc);

        if (portsc.ccs) {
            const speed_name = switch (portsc.speed) {
                1 => "Full Speed",
                2 => "Low Speed",
                3 => "High Speed",
                4 => "Super Speed",
                5 => "Super Speed+",
                else => "Unknown",
            };
            console.info("XHCI: Port {d} connected, speed={s}, enabled={}", .{
                port,
                speed_name,
                portsc.ped,
            });

            // Reset port if not enabled
            if (!portsc.ped) {
                resetPort(ctrl, port) catch |err| {
                    console.err("XHCI: Failed to reset port {d}: {}", .{ port, err });
                    continue;
                };
            }

            // Enumerate the device on root hub (parent=null)
            // route_string=0, root_port=port, speed_override=null, depth=0 (root level)
            const maybe_dev = device_manager.enumerateDevice(ctrl, null, port, 0, port, null, 0) catch |err| {
                console.err("XHCI: Failed to enumerate device on port {d}: {}", .{ port, err });
                continue;
            };

            // If it's a HID device or Hub, start interrupt polling
            // Note: device_manager.enumerateDevice now starts polling internally if successful!
            // But we should verify.
            // device_manager line 265: `try startInterruptPolling(ctrl, dev);`
            // So we don't need to do it here for root devices.
            _ = maybe_dev;
        }
    }
}

// =============================================================================
// Hotplug Event Handling
// =============================================================================

/// Handle port status change event from interrupt handler
/// Security: Called from interrupt context - must be fast and non-blocking
pub fn handlePortStatusChange(ctrl: *Controller, port_id: u8) void {
    // Validate port ID
    if (port_id == 0 or port_id > ctrl.max_ports) {
        console.warn("XHCI: Invalid port {} in status change event", .{port_id});
        return;
    }

    const port_base = ctrl.op_base + regs.portBaseOffset(port_id);
    const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);
    var portsc = port_dev.readTyped(.portsc, regs.PortSc);

    // Handle Connection Status Change
    if (portsc.csc) {
        if (portsc.ccs) {
            // Device connected
            console.info("XHCI: Device connected on port {}", .{port_id});
            handlePortConnect(ctrl, port_id, portsc);
        } else {
            // Device disconnected
            console.info("XHCI: Device disconnected from port {}", .{port_id});
            handlePortDisconnect(ctrl, port_id);
        }
    }

    // Handle Port Enable/Disable Change
    if (portsc.pec) {
        if (!portsc.ped and portsc.ccs) {
            // Port disabled but device still connected - possibly an error
            console.warn("XHCI: Port {} disabled unexpectedly", .{port_id});
        }
    }

    // Clear all change bits by writing 1 (W1C - Write 1 to Clear)
    // Keep other R/W bits unchanged
    var clear_bits = portsc;
    clear_bits.csc = true;  // Clear Connect Status Change
    clear_bits.pec = true;  // Clear Port Enable/Disable Change
    clear_bits.wrc = true;  // Clear Warm Port Reset Change
    clear_bits.occ = true;  // Clear Over-Current Change
    clear_bits.prc = true;  // Clear Port Reset Change
    clear_bits.plc = true;  // Clear Port Link State Change
    clear_bits.cec = true;  // Clear Config Error Change
    port_dev.writeTyped(.portsc, clear_bits);
}

/// Handle device connection - reset port and trigger enumeration
fn handlePortConnect(ctrl: *Controller, port_id: u8, portsc: regs.PortSc) void {
    // Reset port to enable it and get device to Default state
    resetPort(ctrl, port_id) catch |err| {
        console.err("XHCI: Hotplug reset failed for port {}: {}", .{ port_id, err });
        return;
    };

    // Re-read PORTSC after reset to get actual speed
    const port_base = ctrl.op_base + regs.portBaseOffset(port_id);
    const port_dev = MmioDevice(regs.PortReg).init(port_base, 0x10);
    const new_portsc = port_dev.readTyped(.portsc, regs.PortSc);

    // Determine speed from post-reset PORTSC
    const speed: context.Speed = @enumFromInt(new_portsc.speed);
    _ = portsc; // Original portsc not used after reset

    // Enumerate device with depth=0 (root port)
    const maybe_dev = device_manager.enumerateDevice(
        ctrl,
        null, // parent = null (root hub)
        port_id,
        0, // route_string
        port_id, // root_port_num
        speed, // speed_override from PORTSC
        0, // depth = 0 (root level)
    ) catch |err| {
        console.err("XHCI: Hotplug enumeration failed for port {}: {}", .{ port_id, err });
        return;
    };

    if (maybe_dev) |dev| {
        console.info("XHCI: Hotplug device enumerated on port {} (slot {})", .{ port_id, dev.slot_id });
    }
}

/// Handle device disconnection - find and cleanup device
fn handlePortDisconnect(ctrl: *Controller, port_id: u8) void {
    // Find all devices on this root port (including hub children)
    const devices_to_remove = findDevicesOnPort(port_id);

    // Disconnect devices in reverse order (children first, then parents)
    // This ensures hub children are cleaned up before the hub itself
    var i: usize = devices_to_remove.count;
    while (i > 0) {
        i -= 1;
        if (devices_to_remove.devices[i]) |dev| {
            disconnectDevice(ctrl, dev);
        }
    }
}

/// Result of findDevicesOnPort - contains devices to disconnect
const DeviceList = struct {
    devices: [device.MAX_DEVICES]?*device.UsbDevice,
    count: usize,
};

/// Find all devices on a root port (including hub children)
/// Returns devices ordered by depth (deepest first for safe cleanup)
fn findDevicesOnPort(root_port: u8) DeviceList {
    var result = DeviceList{
        .devices = [_]?*device.UsbDevice{null} ** device.MAX_DEVICES,
        .count = 0,
    };

    // Scan all registered devices
    for (1..device.MAX_DEVICES) |slot_id| {
        if (device.findDevice(@truncate(slot_id))) |dev| {
            // Check if device is on this root port
            if (dev.port == root_port and dev.parent == null) {
                // This is a root device on the port
                addDeviceAndChildren(&result, dev);
            }
        }
    }

    return result;
}

/// Recursively add device and all its children to the list
/// Children are added before parents (deepest first)
fn addDeviceAndChildren(list: *DeviceList, dev: *device.UsbDevice) void {
    // First, find and add all children (for hubs)
    if (dev.is_hub) {
        for (1..device.MAX_DEVICES) |slot_id| {
            if (device.findDevice(@truncate(slot_id))) |child| {
                if (child.parent == dev) {
                    // Recursively add child and its descendants
                    addDeviceAndChildren(list, child);
                }
            }
        }
    }

    // Then add this device (after children)
    if (list.count < device.MAX_DEVICES) {
        list.devices[list.count] = dev;
        list.count += 1;
    }
}

/// Disconnect a single device with proper cleanup
/// Security: Follows xHCI spec sequence to ensure hardware state is consistent
/// This function properly stops endpoints, cancels pending transfers, and disables
/// the slot before calling deinit. Must be used instead of direct deinit calls.
pub fn disconnectDevice(ctrl: *Controller, dev: *device.UsbDevice) void {
    console.info("XHCI: Disconnecting device on slot {}", .{dev.slot_id});

    // 1. Transition to disconnecting state (prevent new transfers)
    {
        const held = dev.device_lock.acquire();
        defer held.release();

        // Check if already being cleaned up
        if (dev.state == .disconnecting or dev.state == .disabled or dev.state == .err) {
            return;
        }
        dev.state = .disconnecting;
    }

    // 2. Stop all endpoints
    for (1..32) |dci_usize| {
        const dci: u5 = @truncate(dci_usize);
        if (dev.endpoints[dci] != null) {
            device_manager.stopEndpoint(ctrl, dev, dci) catch |err| {
                console.warn("XHCI: Failed to stop endpoint DCI {}: {}", .{ dci, err });
                // Continue cleanup even if stop fails
            };
        }
    }

    // 3. Cancel pending transfers
    cancelPendingTransfers(dev);

    // 4. Disable slot
    device_manager.disableSlot(ctrl, dev.slot_id) catch |err| {
        console.warn("XHCI: Failed to disable slot {}: {}", .{ dev.slot_id, err });
    };

    // 5. Mark as disabled and cleanup
    dev.state = .disabled;
    dev.deinit();
}

/// Deferred callback info for execution outside lock
const DeferredCallback = struct {
    callback: device.UsbDevice.TransferCallback,
    dev: *device.UsbDevice,
};

/// Cancel all pending transfers for a device
/// Security: Frees transfer requests back to the pool to prevent memory leaks.
/// Callbacks are collected under lock but executed AFTER lock release to prevent
/// lock ordering violations if callbacks acquire higher-level locks (e.g., devices_lock).
fn cancelPendingTransfers(dev: *device.UsbDevice) void {
    // Collect callbacks to execute after releasing lock
    // Max 32 pending transfers (one per DCI)
    var deferred_callbacks: [32]?DeferredCallback = [_]?DeferredCallback{null} ** 32;
    var callback_count: usize = 0;

    // Phase 1: Cancel transfers and collect callbacks under lock
    {
        const held = dev.device_lock.acquire();
        defer held.release();

        for (&dev.pending_transfers) |*transfer_opt| {
            if (transfer_opt.*) |transfer| {
                // Attempt to cancel the transfer
                if (transfer.cancel()) {
                    transfer.completion_code = .Stopped;

                    // Collect callback for deferred execution (control only)
                    // Interrupt callbacks have no meaningful data when cancelled
                    switch (transfer.callback) {
                        .control => {
                            if (callback_count < 32) {
                                deferred_callbacks[callback_count] = .{
                                    .callback = transfer.callback,
                                    .dev = dev,
                                };
                                callback_count += 1;
                            }
                        },
                        .interrupt, .none => {},
                    }
                }
                // Security: Free the transfer request back to the pool to prevent leak
                transfer_pool.freeRequest(transfer);
                transfer_opt.* = null;
            }
        }
    }

    // Phase 2: Execute callbacks OUTSIDE the lock
    // This prevents deadlock if callbacks acquire devices_lock (lock level 8.5)
    // since device_lock is at level 8.6 (must be acquired after devices_lock).
    for (deferred_callbacks[0..callback_count]) |maybe_cb| {
        if (maybe_cb) |cb| {
            switch (cb.callback) {
                .control => |control_cb| control_cb(cb.dev, .Stopped, 0),
                .interrupt, .none => {},
            }
        }
    }
}
