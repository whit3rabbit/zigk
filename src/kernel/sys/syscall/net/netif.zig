// Network Interface Configuration Syscall Handler
//
// SYS_NETIF_CONFIG (1060) - Unified network interface management
//
// Enables userspace daemons (netcfgd) to configure network interfaces:
// - IPv4 address/netmask/gateway configuration
// - IPv6 address management (SLAAC, DHCPv6, static)
// - MTU configuration
// - Link state monitoring
//
// Related RFCs:
// - RFC 2131: DHCP (requires interface configuration after lease)
// - RFC 4861: NDP (Router Advertisements for SLAAC)
// - RFC 4862: IPv6 SLAAC (address autoconfiguration)
//
// Security Model:
// - Requires CAP_NET_CONFIG capability for ALL operations
// - Read operations also require capability to prevent information
//   disclosure about network topology and configuration
// - Capability can be scoped to specific interface indices

const std = @import("std");
const uapi = @import("uapi");
const net = @import("net");
const SyscallError = uapi.errno.SyscallError;
const user_mem = @import("user_mem");
const base = @import("base.zig");
const console = @import("console");
const capabilities = @import("capabilities");

// Import UAPI structures
const zk = uapi.syscalls.zk;
const NetifCmd = zk.NetifCmd;
const Ipv4Config = zk.Ipv4Config;
const Ipv6AddrConfig = zk.Ipv6AddrConfig;
const RaInfo = zk.RaInfo;
const InterfaceInfo = zk.InterfaceInfo;

// Network interface access
const socket_state = net.transport.socket.state;
const Interface = socket_state.Interface;
const Ipv6AddrEntry = net.core.interface.Ipv6AddrEntry;

// =============================================================================
// Syscall Handler
// =============================================================================

/// SYS_NETIF_CONFIG (1060) - Network interface configuration
///
/// Arguments:
///   arg1: interface index (currently only 0 supported)
///   arg2: command (NetifCmd enum value)
///   arg3: data pointer (command-specific)
///   arg4: data length
///
/// Returns: 0 on success, negative errno on error
pub fn sys_netif_config(
    iface_idx: usize,
    cmd: usize,
    data_ptr: usize,
    data_len: usize,
) SyscallError!usize {
    // Validate command
    // Zig 0.16.x: std.meta.intToEnum removed, use std.enums.fromInt
    const command = std.enums.fromInt(NetifCmd, @as(u32, @truncate(cmd))) orelse {
        return error.EINVAL;
    };

    // Get current process and check capability
    const proc = base.getCurrentProcess();
    const net_cap = proc.getNetConfigCapability(iface_idx) orelse {
        console.warn("netif: Process {} lacks CAP_NET_CONFIG for iface {}", .{ proc.pid, iface_idx });
        return error.EPERM;
    };

    // Get the network interface
    const iface = socket_state.getInterface() orelse {
        return error.ENODEV;
    };

    // Currently only support interface index 0
    if (iface_idx != 0) {
        return error.ENODEV;
    }

    // Dispatch based on command
    return switch (command) {
        .GetInfo => handleGetInfo(iface, data_ptr, data_len),
        .SetIpv4 => handleSetIpv4(iface, net_cap, data_ptr, data_len),
        .SetIpv6Addr => handleSetIpv6Addr(iface, net_cap, data_ptr, data_len),
        .SetIpv6Gateway => handleSetIpv6Gateway(iface, net_cap, data_ptr, data_len),
        .GetRaInfo => handleGetRaInfo(iface, data_ptr, data_len),
        .SetMtu => handleSetMtu(iface, net_cap, data_ptr, data_len),
        .GetLinkState => handleGetLinkState(iface, data_ptr, data_len),
    };
}

// =============================================================================
// Command Handlers
// =============================================================================

/// GET_INFO: Return interface information
fn handleGetInfo(iface: *Interface, data_ptr: usize, data_len: usize) SyscallError!usize {
    if (data_len < @sizeOf(InterfaceInfo)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(InterfaceInfo), .Write)) {
        return error.EFAULT;
    }

    // Build info structure
    var info: InterfaceInfo = std.mem.zeroes(InterfaceInfo);

    // Copy name
    @memcpy(&info.name, &iface.name);

    // Copy MAC
    @memcpy(&info.mac_addr, &iface.mac_addr);

    // Interface state
    info.is_up = iface.is_up;
    info.link_up = iface.link_up;
    info.mtu = iface.mtu;

    // IPv4 configuration (convert from host to network byte order)
    info.ipv4_addr = @byteSwap(iface.ip_addr);
    info.ipv4_netmask = @byteSwap(iface.netmask);
    info.ipv4_gateway = @byteSwap(iface.gateway);

    // IPv6 gateway
    info.has_ipv6_gateway = iface.has_ipv6_gateway;
    if (iface.has_ipv6_gateway) {
        @memcpy(&info.ipv6_gateway, &iface.ipv6_gateway);
    }

    // IPv6 address count
    info.ipv6_addr_count = @intCast(iface.ipv6_addr_count);

    // Copy to userspace
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyFromKernel(std.mem.asBytes(&info)) catch {
        return error.EFAULT;
    };

    return 0;
}

/// SET_IPV4: Configure IPv4 address, netmask, gateway
fn handleSetIpv4(
    iface: *Interface,
    cap: capabilities.NetConfigCapability,
    data_ptr: usize,
    data_len: usize,
) SyscallError!usize {
    // Check capability allows IPv4 configuration
    if (!cap.allow_ipv4) {
        return error.EPERM;
    }

    if (data_len < @sizeOf(Ipv4Config)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(Ipv4Config), .Read)) {
        return error.EFAULT;
    }

    // Read configuration from userspace
    var config: Ipv4Config = undefined;
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyToKernel(std.mem.asBytes(&config)) catch {
        return error.EFAULT;
    };

    // Convert from network to host byte order and apply
    iface.ip_addr = @byteSwap(config.ip_addr);
    iface.netmask = @byteSwap(config.netmask);
    iface.gateway = @byteSwap(config.gateway);

    console.info("netif: IPv4 configured: {}.{}.{}.{}/{}", .{
        (iface.ip_addr >> 24) & 0xFF,
        (iface.ip_addr >> 16) & 0xFF,
        (iface.ip_addr >> 8) & 0xFF,
        iface.ip_addr & 0xFF,
        @popCount(iface.netmask),
    });

    return 0;
}

/// SET_IPV6_ADDR: Add or remove IPv6 address
fn handleSetIpv6Addr(
    iface: *Interface,
    cap: capabilities.NetConfigCapability,
    data_ptr: usize,
    data_len: usize,
) SyscallError!usize {
    // Check capability allows IPv6 configuration
    if (!cap.allow_ipv6) {
        return error.EPERM;
    }

    if (data_len < @sizeOf(Ipv6AddrConfig)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(Ipv6AddrConfig), .Read)) {
        return error.EFAULT;
    }

    // Read configuration from userspace
    var config: Ipv6AddrConfig = undefined;
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyToKernel(std.mem.asBytes(&config)) catch {
        return error.EFAULT;
    };

    // Convert scope to internal enum
    const scope: Ipv6AddrEntry.Ipv6Scope = switch (config.scope) {
        2 => .LinkLocal,
        5 => .SiteLocal,
        14 => .Global,
        else => .Global, // Default to global for unknown scopes
    };

    // Perform add or remove
    if (config.action == Ipv6AddrConfig.ACTION_ADD) {
        if (!iface.addIpv6Address(config.addr, config.prefix_len, scope)) {
            return error.ENOSPC; // No space for more addresses
        }
        console.info("netif: IPv6 address added (prefix_len={})", .{config.prefix_len});
    } else if (config.action == Ipv6AddrConfig.ACTION_REMOVE) {
        if (!iface.removeIpv6Address(config.addr)) {
            return error.ENOENT; // Address not found
        }
        console.info("netif: IPv6 address removed", .{});
    } else {
        return error.EINVAL;
    }

    return 0;
}

/// SET_IPV6_GATEWAY: Set IPv6 default gateway
fn handleSetIpv6Gateway(
    iface: *Interface,
    cap: capabilities.NetConfigCapability,
    data_ptr: usize,
    data_len: usize,
) SyscallError!usize {
    // Check capability allows IPv6 configuration
    if (!cap.allow_ipv6) {
        return error.EPERM;
    }

    if (data_len < 16) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, 16, .Read)) {
        return error.EFAULT;
    }

    // Read gateway address from userspace
    var gateway: [16]u8 = undefined;
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyToKernel(&gateway) catch {
        return error.EFAULT;
    };

    iface.setIpv6Gateway(gateway);
    console.info("netif: IPv6 gateway set", .{});

    return 0;
}

/// GET_RA_INFO: Get last Router Advertisement info for SLAAC
fn handleGetRaInfo(iface: *Interface, data_ptr: usize, data_len: usize) SyscallError!usize {
    if (data_len < @sizeOf(RaInfo)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(RaInfo), .Write)) {
        return error.EFAULT;
    }

    // Check if we have RA info
    const kernel_ra = iface.getRaInfo() orelse {
        return error.EAGAIN; // No RA received yet, try again later
    };

    // Convert kernel RaInfo to UAPI RaInfo format
    var uapi_ra: RaInfo = std.mem.zeroes(RaInfo);
    @memcpy(&uapi_ra.router_addr, &kernel_ra.router_addr);
    @memcpy(&uapi_ra.prefix, &kernel_ra.prefix);
    uapi_ra.prefix_len = kernel_ra.prefix_len;
    // Combine RA flags and prefix A-flag for userspace
    uapi_ra.flags = kernel_ra.ra_flags;
    if (kernel_ra.isAutonomousFlag()) {
        uapi_ra.flags |= 0x20; // Set A-flag bit
    }
    if (kernel_ra.isOnLinkFlag()) {
        uapi_ra.flags |= 0x10; // Set L-flag bit
    }
    uapi_ra.valid_lifetime = kernel_ra.valid_lifetime;
    uapi_ra.preferred_lifetime = kernel_ra.preferred_lifetime;
    uapi_ra.mtu = kernel_ra.mtu;
    uapi_ra.timestamp = kernel_ra.timestamp;

    // Copy to userspace
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyFromKernel(std.mem.asBytes(&uapi_ra)) catch {
        return error.EFAULT;
    };

    return 0;
}

/// SET_MTU: Set interface MTU
fn handleSetMtu(
    iface: *Interface,
    cap: capabilities.NetConfigCapability,
    data_ptr: usize,
    data_len: usize,
) SyscallError!usize {
    // Check capability allows MTU configuration
    if (!cap.allow_mtu) {
        return error.EPERM;
    }

    if (data_len < @sizeOf(u16)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(u16), .Read)) {
        return error.EFAULT;
    }

    // Read MTU from userspace
    var mtu: u16 = undefined;
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyToKernel(std.mem.asBytes(&mtu)) catch {
        return error.EFAULT;
    };

    // Validate MTU range (minimum 1280 for IPv6, maximum 9000 for jumbo frames)
    if (mtu < 1280 or mtu > 9000) {
        return error.EINVAL;
    }

    iface.mtu = mtu;
    console.info("netif: MTU set to {}", .{mtu});

    return 0;
}

/// GET_LINK_STATE: Return link up/down state
fn handleGetLinkState(iface: *Interface, data_ptr: usize, data_len: usize) SyscallError!usize {
    if (data_len < @sizeOf(bool)) {
        return error.EINVAL;
    }

    if (!user_mem.isValidUserAccess(data_ptr, @sizeOf(bool), .Write)) {
        return error.EFAULT;
    }

    const link_up: bool = iface.link_up;

    // Copy to userspace
    const user_ptr = user_mem.UserPtr.from(data_ptr);
    _ = user_ptr.copyFromKernel(std.mem.asBytes(&link_up)) catch {
        return error.EFAULT;
    };

    return 0;
}
