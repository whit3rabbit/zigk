//! Network Configuration Daemon (netcfgd)
//!
//! Provides automatic network address configuration:
//! - DHCPv4 (RFC 2131): Dynamic IPv4 address configuration
//! - SLAAC (RFC 4862): IPv6 Stateless Address Autoconfiguration
//! - DHCPv6 (RFC 8415): Stateful IPv6 address configuration
//!
//! Uses:
//! - UDP sockets for DHCP protocol messages
//! - SYS_NETIF_CONFIG syscall for interface configuration
//! - CAP_NET_CONFIG capability for privilege control

const std = @import("std");
const builtin = @import("builtin");
const syscall = @import("syscall");
const net = syscall.net;

const dhcpv4 = @import("dhcpv4.zig");
const dhcpv6 = @import("dhcpv6.zig");
const slaac = @import("slaac.zig");

// Service state
var running: bool = true;

// Interface index we're configuring (0 = first interface)
const IFACE_IDX: u32 = 0;

// Poll intervals (milliseconds)
const LINK_POLL_INTERVAL_MS: u64 = 1000;
const SLAAC_POLL_INTERVAL_MS: u64 = 5000;

pub fn main() void {
    syscall.print("netcfgd: Network Configuration Daemon starting...\n");

    // Register as service
    syscall.register_service("netcfgd") catch |err| {
        printError("Failed to register netcfgd service", err);
        return;
    };
    syscall.print("netcfgd: Registered as service\n");

    // Get initial interface info
    const iface_info = net.getInterfaceInfo(IFACE_IDX) catch |err| {
        printError("Failed to get interface info", err);
        return;
    };

    printMacAddress(&iface_info.mac_addr);

    // Check link state
    if (!iface_info.link_up) {
        syscall.print("netcfgd: Link down, waiting for link...\n");
        waitForLink();
    }

    syscall.print("netcfgd: Link up, starting configuration\n");

    // Initialize DHCP client
    var dhcp_state = dhcpv4.DhcpClient.init(iface_info.mac_addr);

    // Initialize SLAAC state
    var slaac_state = slaac.SlaacState.init(iface_info.mac_addr);

    // Initialize DHCPv6 client (for stateful IPv6 when M-flag is set)
    var dhcpv6_state = dhcpv6.Dhcpv6Client.init(iface_info.mac_addr, IFACE_IDX);

    // Main service loop
    var last_dhcp_tick: u64 = 0;
    var last_slaac_tick: u64 = 0;
    var last_dhcpv6_tick: u64 = 0;

    while (running) {
        const current_tick = syscall.getTickMs();

        // Process DHCPv4
        if (current_tick -% last_dhcp_tick >= dhcp_state.getNextTimeout()) {
            dhcp_state.process(IFACE_IDX);
            last_dhcp_tick = current_tick;
        }

        // Process SLAAC (check for Router Advertisements)
        if (current_tick -% last_slaac_tick >= SLAAC_POLL_INTERVAL_MS) {
            slaac_state.process(IFACE_IDX);
            last_slaac_tick = current_tick;
        }

        // Process DHCPv6 (triggered by M-flag in Router Advertisement)
        // The DHCPv6 client monitors the M-flag via getRaInfo() internally
        if (current_tick -% last_dhcpv6_tick >= dhcpv6_state.getNextTimeout()) {
            dhcpv6_state.process(current_tick);
            last_dhcpv6_tick = current_tick;
        }

        // Sleep for a bit to avoid busy-waiting
        syscall.sleep_ms(100) catch {};
    }

    // RFC 2131: Release DHCP lease on shutdown
    dhcp_state.release();

    // Close DHCPv6 socket
    dhcpv6_state.closeSocket();

    syscall.print("netcfgd: Shutting down\n");
}

fn waitForLink() void {
    while (running) {
        const info = net.getInterfaceInfo(IFACE_IDX) catch {
            syscall.sleep_ms(LINK_POLL_INTERVAL_MS) catch {};
            continue;
        };

        if (info.link_up) {
            return;
        }

        syscall.sleep_ms(LINK_POLL_INTERVAL_MS) catch {};
    }
}

fn printMacAddress(mac: *const [6]u8) void {
    syscall.print("netcfgd: MAC address: ");
    for (mac, 0..) |byte, i| {
        printHexByte(byte);
        if (i < 5) syscall.print(":");
    }
    syscall.print("\n");
}

fn printHexByte(byte: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[byte >> 4];
    buf[1] = hex[byte & 0xF];
    syscall.print(&buf);
}

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print("netcfgd: ");
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

// Entry point
export fn _start() noreturn {
    main();
    syscall.exit(0);
}
