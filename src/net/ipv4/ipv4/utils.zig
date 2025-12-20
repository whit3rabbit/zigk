const std = @import("std");

/// Validate that a netmask has contiguous 1s followed by 0s
pub fn isValidNetmask(mask: u32) bool {
    if (mask == 0) return false;
    const inverted = ~mask;
    return (inverted & (inverted +% 1)) == 0;
}

/// Check if IP is broadcast (all 1s or directed broadcast)
pub fn isBroadcast(ip: u32, netmask: u32) bool {
    if (ip == 0xFFFFFFFF) return true;
    const host_mask = ~netmask;
    return (ip & host_mask) == host_mask;
}

/// Check if IP is multicast (224.0.0.0 - 239.255.255.255)
pub fn isMulticast(ip: u32) bool {
    return (ip >> 24) >= 224 and (ip >> 24) <= 239;
}

/// Check if IP is loopback (127.x.x.x)
pub fn isLoopback(ip: u32) bool {
    return (ip >> 24) == 127;
}
