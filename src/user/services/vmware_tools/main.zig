//! VMware Tools Service
//!
//! Provides VMware/VirtualBox guest integration features:
//! - Time synchronization with host (every 60s)
//! - Graceful shutdown/reboot handling (OS_Halt, OS_Reset)
//! - Screen resolution hints (logged, requires display driver to apply)
//! - Guest info reporting (OS name, tools version)
//! - Capability registration (softPowerOp, syncTime, resolution_set)
//! - Heartbeat (every 30s to prevent "tools not running" warning)
//! - TCLO command acknowledgment (ping, reset, Capabilities, Set_Option)
//!
//! Uses the VMware hypercall interface via sys_vmware_hypercall syscall.
//! RPCI channel (guest->host) for info/capabilities.
//! TCLO channel (host->guest) for commands.

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");

// VMware hypercall constants
const HYPERCALL_PORT: u16 = 0x5658;
const HYPERCALL_MAGIC: u32 = 0x564D5868;

// VMware hypercall command IDs
const CMD_GET_VERSION: u32 = 10;
const CMD_GET_TIME_FULL: u32 = 46;
const CMD_GET_TIME_DIFF: u32 = 47;
const CMD_MESSAGE_OPEN: u32 = 30;
const CMD_MESSAGE_SEND: u32 = 31;
const CMD_MESSAGE_RECEIVE: u32 = 32;
const CMD_MESSAGE_CLOSE: u32 = 33;

// RPCI message types and protocol constants
const RPCI_PROTOCOL_NUM: u32 = 0x49435052; // "RPCI" in little-endian
const TCLO_PROTOCOL_NUM: u32 = 0x4F4C4354; // "TCLO" in little-endian (for host->guest)

// RPCI message status flags (returned in ECX high bits)
const MESSAGE_STATUS_SUCCESS: u32 = 0x0001_0000;
const MESSAGE_STATUS_DORECV: u32 = 0x0002_0000; // More data to receive
const MESSAGE_STATUS_CLOSED: u32 = 0x0004_0000; // Channel was closed
const MESSAGE_STATUS_UNSENT: u32 = 0x0008_0000; // Message not fully sent
const MESSAGE_STATUS_HB: u32 = 0x0010_0000; // High-bandwidth available

// VMware hypercall register state
const VmwareRegs = extern struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
    esi: u32,
    edi: u32,
};

// Linux ABI timeval struct for settimeofday
const timeval = extern struct {
    tv_sec: i64,
    tv_usec: i64,
};

// Service state
var running: bool = true;
var sync_interval_ms: u64 = 60000; // Default: sync time every 60 seconds
var heartbeat_interval_ms: u64 = 30000; // Heartbeat every 30 seconds

// Guest info keys (for SetGuestInfo RPCI command)
const GUESTINFO_DNS_NAME: u32 = 1;
const GUESTINFO_OS_NAME: u32 = 2;
const GUESTINFO_OS_NAME_FULL: u32 = 3;
const GUESTINFO_TOOLS_VERSION: u32 = 4;

// Tools version (format: major.minor.build)
const TOOLS_VERSION_MAJOR: u32 = 1;
const TOOLS_VERSION_MINOR: u32 = 0;
const TOOLS_VERSION_BUILD: u32 = 0;
const TOOLS_VERSION_STRING = "1.0.0-zk";

pub fn main() void {
    syscall.print("VMware Tools Service Starting...\n");

    // Register as service
    syscall.register_service("vmware_tools") catch |err| {
        printError("Failed to register vmware_tools service", err);
        return;
    };
    syscall.print("Registered 'vmware_tools' service\n");

    // Check hypervisor type
    const hv_type = getHypervisorType();
    if (hv_type != 1 and hv_type != 2) { // 1=vmware, 2=virtualbox
        syscall.print("VMware Tools: Not running under VMware/VirtualBox (type=");
        printDec(hv_type);
        syscall.print("), service disabled\n");
        return;
    }

    syscall.print("VMware Tools: Detected compatible hypervisor\n");

    // Check if hypercall interface is accessible
    if (!detectHypercall()) {
        syscall.print("VMware Tools: Hypercall interface not available\n");
        return;
    }

    syscall.print("VMware Tools: Hypercall interface detected\n");

    // Initialize RPCI channel for guest->host commands
    if (!initRpciChannel()) {
        syscall.print("VMware Tools: Warning - RPCI channel unavailable\n");
    }

    // Initialize TCLO channel for host->guest commands (shutdown, etc.)
    _ = initTcloChannel();

    // Send guest information to host
    sendGuestInfo();

    // Register our capabilities
    registerCapabilities();

    // Initial time sync
    if (syncTime()) {
        syscall.print("VMware Tools: Initial time sync successful\n");
    }

    syscall.print("VMware Tools: Starting service loop\n");

    // Main service loop
    serviceLoop();
}

fn serviceLoop() void {
    var last_time_sync: u64 = 0;
    var last_heartbeat: u64 = 0;

    while (running) {
        // Sleep for a bit (1 second)
        syscall.sleep_ms(1000) catch {};

        // Get current time (rough, for interval checking)
        const now = getMonotonicTime();

        // Time synchronization
        if (now - last_time_sync >= sync_interval_ms) {
            if (syncTime()) {
                last_time_sync = now;
            }
        }

        // Heartbeat to keep VMware happy
        if (now - last_heartbeat >= heartbeat_interval_ms) {
            sendHeartbeat();
            last_heartbeat = now;
        }

        // Poll for host commands (shutdown, reset, resolution hints)
        pollHostCommands();
    }
}

fn getHypervisorType() u32 {
    // SYS_GET_HYPERVISOR = 1051
    const result = syscall.syscall0(1051);
    if (@as(isize, @bitCast(result)) < 0) return 0;
    return @truncate(result);
}

fn detectHypercall() bool {
    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = ~HYPERCALL_MAGIC,
        .ecx = CMD_GET_VERSION,
        .edx = HYPERCALL_PORT,
        .esi = 0,
        .edi = 0,
    };

    // SYS_VMWARE_HYPERCALL = 1050
    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return false;
    }

    // Check if magic was returned
    return regs.ebx == HYPERCALL_MAGIC;
}

fn syncTime() bool {
    // Get host time via VMware hypercall
    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = 0,
        .ecx = CMD_GET_TIME_FULL,
        .edx = HYPERCALL_PORT,
        .esi = 0,
        .edi = 0,
    };

    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return false;
    }

    // regs.eax contains lower 32 bits of seconds since epoch
    // regs.ebx contains upper 32 bits of seconds
    // regs.ecx contains microseconds
    const host_secs_lo = regs.eax;
    const host_secs_hi = regs.ebx;
    const host_usecs = regs.ecx;

    const host_secs: u64 = (@as(u64, host_secs_hi) << 32) | host_secs_lo;

    // Validate time values from hypervisor to prevent @intCast panic
    // A malicious hypervisor could return values exceeding i64::MAX
    const max_valid_secs: u64 = @intCast(std.math.maxInt(i64));
    if (host_secs > max_valid_secs) {
        return false; // Invalid timestamp from hypervisor
    }
    // Microseconds must be < 1,000,000 per POSIX timeval semantics
    if (host_usecs >= 1_000_000) {
        return false; // Invalid microseconds value
    }

    // Set system time via settimeofday syscall
    // Safe: we validated host_secs <= i64::MAX and host_usecs < 1M above
    var tv = timeval{
        .tv_sec = @intCast(host_secs),
        .tv_usec = @intCast(host_usecs),
    };

    // SYS_SETTIMEOFDAY = 164
    const set_result = syscall.syscall2(164, @intFromPtr(&tv), 0);
    if (@as(isize, @bitCast(set_result)) < 0) {
        return false;
    }

    return true;
}

fn getMonotonicTime() u64 {
    return syscall.gettime_ms() catch 0;
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

// ============================================================================
// RPCI (Remote Procedure Call Interface) Implementation
// ============================================================================

/// RPCI channel state
const RpciChannel = struct {
    id: u32,
    cookie1: u32,
    cookie2: u32,
    is_open: bool,
};

/// Global TCLO channel for host->guest messages
var tclo_channel: RpciChannel = .{
    .id = 0,
    .cookie1 = 0,
    .cookie2 = 0,
    .is_open = false,
};

/// Global RPCI channel for guest->host messages (guest info, capabilities)
var rpci_channel: RpciChannel = .{
    .id = 0,
    .cookie1 = 0,
    .cookie2 = 0,
    .is_open = false,
};

/// Open an RPCI channel
fn rpciOpen(protocol: u32) ?RpciChannel {
    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = protocol,
        .ecx = CMD_MESSAGE_OPEN,
        .edx = HYPERCALL_PORT,
        .esi = 0,
        .edi = 0,
    };

    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return null;
    }

    // Check success flag in ECX
    if ((regs.ecx & MESSAGE_STATUS_SUCCESS) == 0) {
        return null;
    }

    return RpciChannel{
        .id = regs.edx >> 16, // Channel ID in high bits of EDX
        .cookie1 = regs.esi,
        .cookie2 = regs.edi,
        .is_open = true,
    };
}

/// Close an RPCI channel
fn rpciClose(channel: *RpciChannel) void {
    if (!channel.is_open) return;

    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = 0,
        .ecx = CMD_MESSAGE_CLOSE | (@as(u32, channel.id) << 16),
        .edx = HYPERCALL_PORT,
        .esi = channel.cookie1,
        .edi = channel.cookie2,
    };

    _ = syscall.syscall1(1050, @intFromPtr(&regs));
    channel.is_open = false;
}

/// Receive a message from an RPCI channel
/// Returns message length, or 0 if no message available
fn rpciReceive(channel: *RpciChannel, buf: []u8) usize {
    if (!channel.is_open) return 0;

    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = 0,
        .ecx = CMD_MESSAGE_RECEIVE | (@as(u32, channel.id) << 16),
        .edx = HYPERCALL_PORT,
        .esi = channel.cookie1,
        .edi = channel.cookie2,
    };

    const result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) {
        return 0;
    }

    // Check if message available
    if ((regs.ecx & MESSAGE_STATUS_SUCCESS) == 0) {
        return 0;
    }

    // Message type in ECX high word, length in EBX
    const msg_len = regs.ebx;
    if (msg_len == 0) return 0;

    // For simplicity, receive byte-by-byte (low-bandwidth mode)
    // High-bandwidth mode would use backdoor HB port (0x5659)
    var received: usize = 0;
    while (received < msg_len and received < buf.len) {
        var recv_regs = VmwareRegs{
            .eax = HYPERCALL_MAGIC,
            .ebx = 1, // Receive 1 byte
            .ecx = CMD_MESSAGE_RECEIVE | (@as(u32, channel.id) << 16),
            .edx = HYPERCALL_PORT,
            .esi = channel.cookie1,
            .edi = channel.cookie2,
        };

        const recv_result = syscall.syscall1(1050, @intFromPtr(&recv_regs));
        if (@as(isize, @bitCast(recv_result)) < 0) break;
        if ((recv_regs.ecx & MESSAGE_STATUS_SUCCESS) == 0) break;

        buf[received] = @truncate(recv_regs.ebx);
        received += 1;
    }

    return received;
}

/// Send an RPCI message and get response
fn rpciSend(channel: *RpciChannel, msg: []const u8) bool {
    if (!channel.is_open) return false;

    // Send message length first
    var regs = VmwareRegs{
        .eax = HYPERCALL_MAGIC,
        .ebx = @truncate(msg.len),
        .ecx = CMD_MESSAGE_SEND | (@as(u32, channel.id) << 16),
        .edx = HYPERCALL_PORT,
        .esi = channel.cookie1,
        .edi = channel.cookie2,
    };

    var result = syscall.syscall1(1050, @intFromPtr(&regs));
    if (@as(isize, @bitCast(result)) < 0) return false;
    if ((regs.ecx & MESSAGE_STATUS_SUCCESS) == 0) return false;

    // Send message bytes (low-bandwidth, byte at a time)
    for (msg) |byte| {
        var send_regs = VmwareRegs{
            .eax = HYPERCALL_MAGIC,
            .ebx = byte,
            .ecx = CMD_MESSAGE_SEND | (@as(u32, channel.id) << 16),
            .edx = HYPERCALL_PORT,
            .esi = channel.cookie1,
            .edi = channel.cookie2,
        };

        result = syscall.syscall1(1050, @intFromPtr(&send_regs));
        if (@as(isize, @bitCast(result)) < 0) return false;
        if ((send_regs.ecx & MESSAGE_STATUS_SUCCESS) == 0) return false;
    }

    return true;
}

/// Initialize TCLO channel for host->guest commands
fn initTcloChannel() bool {
    if (rpciOpen(TCLO_PROTOCOL_NUM)) |ch| {
        tclo_channel = ch;
        syscall.print("VMware Tools: TCLO channel opened\n");
        return true;
    }
    syscall.print("VMware Tools: Failed to open TCLO channel\n");
    return false;
}

/// Initialize RPCI channel for guest->host commands
fn initRpciChannel() bool {
    if (rpciOpen(RPCI_PROTOCOL_NUM)) |ch| {
        rpci_channel = ch;
        syscall.print("VMware Tools: RPCI channel opened\n");
        return true;
    }
    syscall.print("VMware Tools: Failed to open RPCI channel\n");
    return false;
}

/// Send a GuestRPC command and optionally get response
fn guestRpc(cmd: []const u8, response_buf: ?[]u8) ?usize {
    if (!rpci_channel.is_open) {
        if (!initRpciChannel()) return null;
    }

    if (!rpciSend(&rpci_channel, cmd)) {
        return null;
    }

    // If response buffer provided, read response
    if (response_buf) |buf| {
        return rpciReceive(&rpci_channel, buf);
    }

    return 0;
}

/// Send guest information to VMware host
fn sendGuestInfo() void {
    // Report OS name
    _ = guestRpc("SetGuestInfo  2 zk", null);

    // Report full OS name
    _ = guestRpc("SetGuestInfo  3 ZK Microkernel 1.0", null);

    // Report tools version (uses info-set for newer protocol)
    _ = guestRpc("info-set guestinfo.vmtools.versionString " ++ TOOLS_VERSION_STRING, null);
    _ = guestRpc("info-set guestinfo.vmtools.versionNumber 1000", null);

    // Report tools description
    _ = guestRpc("info-set guestinfo.vmtools.description ZK VMware Tools", null);

    syscall.print("VMware Tools: Sent guest info to host\n");
}

/// Register capabilities with VMware host
fn registerCapabilities() void {
    // Tell VMware we support various features
    // Format: "tools.capability.<cap> <value>"

    // We support soft power operations (shutdown/reboot)
    _ = guestRpc("tools.capability.softPowerOp_state 1", null);

    // We support time sync
    _ = guestRpc("tools.capability.syncTime 1", null);

    // We do NOT support clipboard (security)
    _ = guestRpc("tools.capability.unity 0", null);
    _ = guestRpc("tools.capability.dnd 0", null);
    _ = guestRpc("tools.capability.copy_paste 0", null);

    // We support resolution hints (even if we can't apply them yet)
    _ = guestRpc("tools.capability.resolution_set 1", null);

    // Report tools state as running
    _ = guestRpc("tools.set.version " ++ TOOLS_VERSION_STRING, null);

    syscall.print("VMware Tools: Registered capabilities\n");
}

/// Send heartbeat to VMware to indicate tools are running
fn sendHeartbeat() void {
    // The heartbeat tells VMware the tools are alive
    // This prevents "VMware Tools not running" warnings
    _ = guestRpc("tools.capability.hgfs_server toolbox 1", null);
}

/// Send reply to TCLO command
fn sendTcloReply(reply: []const u8) void {
    if (!tclo_channel.is_open) return;

    // TCLO replies go back on the same channel
    _ = rpciSend(&tclo_channel, reply);
}

/// Parse and handle resolution set command
/// Format: "Resolution_Set <width> <height>"
fn handleResolutionSet(cmd: []const u8) void {
    // Skip "Resolution_Set " prefix (15 chars)
    if (cmd.len < 16) return;

    var width: u32 = 0;
    var height: u32 = 0;
    var i: usize = 15;
    var parsing_height = false;

    // Parse width and height with overflow protection
    // A malicious hypervisor could send crafted values to trigger overflow
    while (i < cmd.len) : (i += 1) {
        const c = cmd[i];
        if (c == ' ') {
            parsing_height = true;
            continue;
        }
        if (c >= '0' and c <= '9') {
            const digit: u32 = c - '0';
            if (parsing_height) {
                height = std.math.mul(u32, height, 10) catch {
                    sendTcloReply("ERROR overflow");
                    return;
                };
                height = std.math.add(u32, height, digit) catch {
                    sendTcloReply("ERROR overflow");
                    return;
                };
            } else {
                width = std.math.mul(u32, width, 10) catch {
                    sendTcloReply("ERROR overflow");
                    return;
                };
                width = std.math.add(u32, width, digit) catch {
                    sendTcloReply("ERROR overflow");
                    return;
                };
            }
        }
    }

    if (width > 0 and height > 0) {
        syscall.print("VMware Tools: Resolution hint ");
        printDec(width);
        syscall.print("x");
        printDec(height);
        syscall.print(" (not applied - no display driver)\n");

        // TODO: When display driver exists, call ioctl to set resolution
        // For now, just acknowledge the command
    }

    // Reply OK to the host
    sendTcloReply("OK ");
}

/// Poll for host commands (shutdown, reset, etc.)
///
/// SECURITY NOTE: The hypervisor is in a higher trust domain than the guest.
/// We do not sanitize ANSI escape sequences in logged commands because:
/// 1. The hypervisor can already shutdown/reboot the guest via TCLO
/// 2. Log tampering is not an escalation vs. the power the hypervisor already has
/// 3. The kernel requires CAP_HYPERVISOR to issue hypercalls, preventing
///    unprivileged guest processes from injecting malicious TCLO responses
fn pollHostCommands() void {
    if (!tclo_channel.is_open) return;

    var buf: [256]u8 = [_]u8{0} ** 256;
    const len = rpciReceive(&tclo_channel, &buf);

    if (len > 0) {
        syscall.print("VMware Tools: Received host command: ");
        syscall.print(buf[0..len]);
        syscall.print("\n");

        // Handle known commands
        if (len >= 7 and startsWith(buf[0..len], "OS_Halt")) {
            sendTcloReply("OK ");
            syscall.print("VMware Tools: Host requested shutdown\n");
            // SYS_REBOOT = 169 with LINUX_REBOOT_CMD_POWER_OFF = 0x4321FEDC
            _ = syscall.syscall4(169, 0xfee1dead, 672274793, 0x4321FEDC, 0);
        } else if (len >= 8 and startsWith(buf[0..len], "OS_Reset")) {
            sendTcloReply("OK ");
            syscall.print("VMware Tools: Host requested reboot\n");
            // SYS_REBOOT = 169 with LINUX_REBOOT_CMD_RESTART = 0x01234567
            _ = syscall.syscall4(169, 0xfee1dead, 672274793, 0x01234567, 0);
        } else if (len >= 14 and startsWith(buf[0..len], "Resolution_Set")) {
            handleResolutionSet(buf[0..len]);
        } else if (len >= 4 and startsWith(buf[0..len], "ping")) {
            // Respond to ping with pong
            sendTcloReply("OK ");
        } else if (len >= 5 and startsWith(buf[0..len], "reset")) {
            // Tools reset request - re-register capabilities
            sendTcloReply("OK ");
            registerCapabilities();
        } else if (len >= 11 and startsWith(buf[0..len], "Capabilities")) {
            // Host asking for capabilities
            sendTcloReply("OK ");
        } else if (len >= 8 and startsWith(buf[0..len], "Set_Option")) {
            // Host setting an option - acknowledge
            sendTcloReply("OK ");
        } else {
            // Unknown command - still acknowledge to avoid host timeout
            sendTcloReply("OK ");
        }
    }
}

/// Compare two slices for equality
fn eqlSlice(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Check if slice starts with prefix
fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eqlSlice(haystack[0..prefix.len], prefix);
}

export fn _start() noreturn {
    main();
    syscall.exit(0);
}
