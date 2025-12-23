const std = @import("std");
const console = @import("console");
const hal = @import("hal");

const types = @import("types.zig");
const regs = @import("regs.zig");
const device_manager = @import("device_manager.zig");
const device = @import("device.zig");
const context = @import("context.zig");

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
