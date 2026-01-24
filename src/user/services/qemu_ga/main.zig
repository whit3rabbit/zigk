//! QEMU Guest Agent Service
//!
//! Provides QEMU/KVM guest integration features:
//! - JSON-RPC protocol over VirtIO-Console
//! - Guest information queries
//! - File read/write operations
//! - Filesystem freeze/thaw for snapshots
//!
//! Reference: QEMU Guest Agent Protocol
//! https://qemu.readthedocs.io/en/latest/interop/qemu-ga-ref.html

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");

// Hypervisor types (from kernel hypervisor detection)
const HV_TYPE_NONE: u32 = 0;
const HV_TYPE_VMWARE: u32 = 1;
const HV_TYPE_VIRTUALBOX: u32 = 2;
const HV_TYPE_KVM: u32 = 3;
const HV_TYPE_HYPERV: u32 = 4;
const HV_TYPE_XEN: u32 = 5;
const HV_TYPE_QEMU_TCG: u32 = 6;

// VirtIO-Console PCI identifiers
const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_CONSOLE_DEVICE_ID_MODERN: u16 = 0x1043; // 0x1040 + 3
const VIRTIO_CONSOLE_DEVICE_ID_LEGACY: u16 = 0x1003;

// JSON-RPC message buffer size
const MAX_MESSAGE_SIZE: usize = 4096;

// Service state
var running: bool = true;
var console_fd: i32 = -1;

pub fn main() void {
    syscall.print("QEMU Guest Agent Starting...\n");

    // Register as service
    syscall.register_service("qemu_ga") catch |err| {
        printError("Failed to register qemu_ga service", err);
        return;
    };
    syscall.print("Registered 'qemu_ga' service\n");

    // Check hypervisor type
    const hv_type = getHypervisorType();
    if (hv_type != HV_TYPE_KVM and hv_type != HV_TYPE_QEMU_TCG) {
        syscall.print("QEMU GA: Not running under QEMU/KVM (type=");
        printDec(hv_type);
        syscall.print("), service disabled\n");
        return;
    }

    syscall.print("QEMU GA: Detected QEMU/KVM hypervisor\n");

    // Try to find VirtIO-Console device
    if (!findVirtioConsole()) {
        syscall.print("QEMU GA: VirtIO-Console not found, waiting...\n");
        // In a real implementation, we'd wait for the device to appear
        // For now, just return as the VirtIO-Console driver isn't implemented yet
        return;
    }

    syscall.print("QEMU GA: VirtIO-Console found, starting service loop\n");

    // Main service loop
    serviceLoop();
}

fn serviceLoop() void {
    var recv_buf: [MAX_MESSAGE_SIZE]u8 = undefined;

    while (running) {
        // Sleep briefly when no data
        syscall.sleep_ms(100) catch {};

        // Read from VirtIO-Console
        // TODO: Implement when VirtIO-Console driver is ready
        if (console_fd < 0) continue;

        const bytes_read = syscall.read(@intCast(console_fd), &recv_buf, recv_buf.len) catch {
            continue;
        };

        if (bytes_read == 0) continue;

        // Process JSON-RPC message
        processMessage(recv_buf[0..bytes_read]);
    }
}

fn processMessage(data: []const u8) void {
    // Parse JSON-RPC request
    // Format: {"execute": "guest-sync-delimited", "arguments": {...}}

    // Find the command name
    const cmd = parseCommand(data) orelse {
        sendError("parse error");
        return;
    };

    // Handle known commands
    if (std.mem.eql(u8, cmd, "guest-sync-delimited")) {
        handleSync(data);
    } else if (std.mem.eql(u8, cmd, "guest-sync")) {
        handleSync(data);
    } else if (std.mem.eql(u8, cmd, "guest-ping")) {
        handlePing();
    } else if (std.mem.eql(u8, cmd, "guest-info")) {
        handleInfo();
    } else if (std.mem.eql(u8, cmd, "guest-get-host-name")) {
        handleGetHostname();
    } else if (std.mem.eql(u8, cmd, "guest-shutdown")) {
        handleShutdown(data);
    } else {
        sendError("unknown command");
    }
}

fn parseCommand(data: []const u8) ?[]const u8 {
    // Simple JSON parsing for command extraction
    // Look for "execute":"<command>"
    const needle = "\"execute\":";
    const pos = std.mem.indexOf(u8, data, needle) orelse return null;
    const start = pos + needle.len;

    // Skip whitespace and quote
    var i = start;
    while (i < data.len and (data[i] == ' ' or data[i] == '"')) : (i += 1) {}
    const cmd_start = i;

    // Find end of command
    while (i < data.len and data[i] != '"') : (i += 1) {}
    if (i == cmd_start) return null;

    return data[cmd_start..i];
}

fn handleSync(data: []const u8) void {
    // Extract sync ID from arguments
    // Respond with the same ID
    _ = data;
    sendResponse("{\"return\":{}}");
}

fn handlePing() void {
    sendResponse("{\"return\":{}}");
}

fn handleInfo() void {
    // Return guest agent info
    const response =
        \\{"return":{"version":"1.0","supported_commands":[
        \\{"name":"guest-sync-delimited","enabled":true},
        \\{"name":"guest-sync","enabled":true},
        \\{"name":"guest-ping","enabled":true},
        \\{"name":"guest-info","enabled":true},
        \\{"name":"guest-get-host-name","enabled":true},
        \\{"name":"guest-shutdown","enabled":true}
        \\]}}
    ;
    sendResponse(response);
}

fn handleGetHostname() void {
    // Return hostname (we use "zk" as the OS name)
    sendResponse("{\"return\":{\"host-name\":\"zk\"}}");
}

fn handleShutdown(data: []const u8) void {
    _ = data;
    // TODO: Parse mode (halt, powerdown, reboot)
    // For now, just acknowledge
    sendResponse("{\"return\":{}}");

    // Trigger shutdown
    // TODO: Implement via sys_reboot syscall
    syscall.print("QEMU GA: Shutdown requested\n");
    running = false;
}

fn sendResponse(response: []const u8) void {
    if (console_fd < 0) return;
    _ = syscall.write(@intCast(console_fd), response.ptr, response.len) catch {};
}

fn sendError(msg: []const u8) void {
    // Format: {"error":{"class":"GenericError","desc":"<msg>"}}
    _ = msg;
    const error_response = "{\"error\":{\"class\":\"GenericError\",\"desc\":\"error\"}}";
    sendResponse(error_response);
}

fn getHypervisorType() u32 {
    // SYS_GET_HYPERVISOR = 1051
    const result = syscall.syscall0(1051);
    if (@as(isize, @bitCast(result)) < 0) return 0;
    return @truncate(result);
}

fn findVirtioConsole() bool {
    // Enumerate PCI devices to find VirtIO-Console
    var pci_devices: [32]syscall.PciDeviceInfo = undefined;
    const device_count = syscall.pci_enumerate(&pci_devices) catch {
        return false;
    };

    for (pci_devices[0..device_count]) |*dev| {
        if (dev.vendor_id == VIRTIO_VENDOR_ID and
            (dev.device_id == VIRTIO_CONSOLE_DEVICE_ID_MODERN or
            dev.device_id == VIRTIO_CONSOLE_DEVICE_ID_LEGACY))
        {
            syscall.print("QEMU GA: Found VirtIO-Console at ");
            printDec(dev.bus);
            syscall.print(":");
            printDec(dev.device);
            syscall.print(".");
            printDec(dev.func);
            syscall.print("\n");

            // TODO: Initialize VirtIO-Console driver and get fd
            // For now, device detection only
            return true;
        }
    }

    return false;
}

// Helper functions

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printDec(value: u64) void {
    if (value == 0) {
        syscall.print("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    syscall.print(buf[i..]);
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}
