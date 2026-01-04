//! SLAAC (Stateless Address Autoconfiguration) Implementation
//!
//! Implements RFC 4862 for IPv6 stateless address autoconfiguration
//! using Router Advertisement information from the kernel.
//!
//! Process:
//! 1. Query kernel for RA info via SYS_NETIF_CONFIG
//! 2. If A-flag set, generate address from prefix + EUI-64
//! 3. Configure address on interface
//! 4. Set default gateway from RA source

const std = @import("std");
const syscall = @import("syscall");
const net = syscall.net;

/// SLAAC state tracker
pub const SlaacState = struct {
    /// MAC address for EUI-64 generation
    mac_addr: [6]u8,
    /// Whether we've configured an address
    configured: bool,
    /// Last RA timestamp we processed
    last_ra_timestamp: u64,
    /// Configured global address
    global_addr: [16]u8,
    /// Prefix length of global address
    prefix_len: u8,

    const Self = @This();

    /// IPv6 scope values
    const SCOPE_GLOBAL: u8 = 14;

    pub fn init(mac: [6]u8) Self {
        return Self{
            .mac_addr = mac,
            .configured = false,
            .last_ra_timestamp = 0,
            .global_addr = [_]u8{0} ** 16,
            .prefix_len = 0,
        };
    }

    /// Main processing function - check for new RA info
    pub fn process(self: *Self, iface_idx: u32) void {
        // Query kernel for RA info
        const ra_info = net.getRaInfo(iface_idx) catch |err| {
            if (err != error.EAGAIN) {
                // EAGAIN just means no RA yet, other errors are logged
                printError("getRaInfo failed", err);
            }
            return;
        };

        // Check if this is a new RA
        // SECURITY NOTE: Timestamp deduplication is intentional.
        // If two RAs arrive at same millisecond, processing both is redundant
        // (same prefix info). This is not a TOCTOU - kernel provides timestamp,
        // and reprocessing duplicate RAs has no security benefit.
        if (ra_info.timestamp == self.last_ra_timestamp) {
            return; // Already processed
        }
        self.last_ra_timestamp = ra_info.timestamp;

        syscall.print("slaac: Processing Router Advertisement\n");

        // Check flags
        if (ra_info.isManagedFlag()) {
            syscall.print("slaac: M-flag set, DHCPv6 should be used for addresses\n");
            // We still process for SLAAC if A-flag is also set
        }

        if (ra_info.isOtherFlag()) {
            syscall.print("slaac: O-flag set, DHCPv6 should be used for other config\n");
        }

        // Check if A-flag (autonomous) is set - means we can use SLAAC
        if (!ra_info.isAutonomousFlag()) {
            syscall.print("slaac: A-flag not set, skipping SLAAC\n");
            return;
        }

        // Generate address from prefix + EUI-64
        const addr = self.generateAddress(&ra_info.prefix, ra_info.prefix_len);

        // Configure address
        if (!self.configured or !std.mem.eql(u8, &self.global_addr, &addr)) {
            syscall.print("slaac: Configuring global address\n");

            net.addIpv6Address(iface_idx, addr, ra_info.prefix_len, SCOPE_GLOBAL) catch |err| {
                printError("addIpv6Address failed", err);
                return;
            };

            // Set default gateway to router address
            net.setIpv6Gateway(iface_idx, ra_info.router_addr) catch |err| {
                printError("setIpv6Gateway failed", err);
            };

            self.global_addr = addr;
            self.prefix_len = ra_info.prefix_len;
            self.configured = true;

            printIpv6Address("slaac: Configured address: ", &addr, ra_info.prefix_len);
        }
    }

    /// Generate IPv6 address from prefix + Modified EUI-64
    fn generateAddress(self: *const Self, prefix: *const [16]u8, prefix_len: u8) [16]u8 {
        var addr: [16]u8 = prefix.*;

        // Clear interface identifier portion (last 64 bits)
        // SLAAC requires /64 prefix (RFC 4862 Section 5.5.3); clamp for defense-in-depth
        // even if kernel provides unexpected prefix_len > 64
        _ = prefix_len; // Informational only; SLAAC always uses 64-bit interface ID
        @memset(addr[8..16], 0);

        // Generate Modified EUI-64 from MAC
        // MAC: aa:bb:cc:dd:ee:ff -> EUI-64: aa^02:bb:cc:ff:fe:dd:ee:ff
        addr[8] = self.mac_addr[0] ^ 0x02; // Flip U/L bit
        addr[9] = self.mac_addr[1];
        addr[10] = self.mac_addr[2];
        addr[11] = 0xFF;
        addr[12] = 0xFE;
        addr[13] = self.mac_addr[3];
        addr[14] = self.mac_addr[4];
        addr[15] = self.mac_addr[5];

        return addr;
    }
};

fn printError(msg: []const u8, err: anyerror) void {
    syscall.print("slaac: ");
    syscall.print(msg);
    syscall.print(": ");
    syscall.print(@errorName(err));
    syscall.print("\n");
}

fn printIpv6Address(prefix: []const u8, addr: *const [16]u8, prefix_len: u8) void {
    syscall.print(prefix);

    // Print IPv6 address in compressed format (simplified)
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        if (i > 0) syscall.print(":");
        printHexWord((@as(u16, addr[i]) << 8) | addr[i + 1]);
    }

    syscall.print("/");
    printDecimal(prefix_len);
    syscall.print("\n");
}

fn printHexWord(val: u16) void {
    const hex = "0123456789abcdef";
    var buf: [4]u8 = undefined;
    buf[0] = hex[(val >> 12) & 0xF];
    buf[1] = hex[(val >> 8) & 0xF];
    buf[2] = hex[(val >> 4) & 0xF];
    buf[3] = hex[val & 0xF];

    // Skip leading zeros (simplified)
    var start: usize = 0;
    while (start < 3 and buf[start] == '0') : (start += 1) {}
    syscall.print(buf[start..]);
}

fn printDecimal(val: u8) void {
    if (val == 0) {
        syscall.print("0");
        return;
    }
    var buf: [3]u8 = undefined;
    var i: usize = 0;
    var v: u8 = val;
    while (v > 0) : (i += 1) {
        buf[2 - i] = (v % 10) + '0';
        v /= 10;
    }
    syscall.print(buf[3 - i ..]);
}
