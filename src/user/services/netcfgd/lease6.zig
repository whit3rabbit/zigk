//! DHCPv6 Lease Timer Tracking (RFC 8415)
//!
//! Tracks IPv6 address lease state, T1/T2 renewal timers, and lifetimes.
//! Uses monotonic tick counts for timer comparisons.

const std = @import("std");

/// Maximum length of server DUID we store
pub const MAX_SERVER_DUID_LEN: usize = 128;

/// Lease state
pub const LeaseState = enum {
    /// No lease acquired
    None,
    /// Lease is valid and active
    Bound,
    /// T1 expired, attempting RENEW
    Renewing,
    /// T2 expired, attempting REBIND
    Rebinding,
    /// Lease expired, need new SOLICIT
    Expired,
};

/// IPv6 lease information
pub const Lease6Info = struct {
    /// Assigned IPv6 address
    addr: [16]u8,

    /// Prefix length (typically 128 for single address, 64 for prefix delegation)
    prefix_len: u8,

    /// Server DUID (for RENEW unicast)
    server_duid: [MAX_SERVER_DUID_LEN]u8,
    server_duid_len: usize,

    /// Server IPv6 address (for RENEW unicast)
    server_addr: [16]u8,

    /// Identity Association ID
    iaid: u32,

    /// T1: Time to start RENEW (seconds from grant)
    t1: u32,

    /// T2: Time to start REBIND (seconds from grant)
    t2: u32,

    /// Valid lifetime (seconds from grant)
    valid_lifetime: u32,

    /// Preferred lifetime (seconds from grant)
    preferred_lifetime: u32,

    /// Tick count when lease was granted (for timer calculations)
    grant_tick: u64,

    /// Current lease state
    state: LeaseState,

    const Self = @This();

    /// Initialize empty lease
    pub fn init() Self {
        return .{
            .addr = [_]u8{0} ** 16,
            .prefix_len = 128,
            .server_duid = [_]u8{0} ** MAX_SERVER_DUID_LEN,
            .server_duid_len = 0,
            .server_addr = [_]u8{0} ** 16,
            .iaid = 0,
            .t1 = 0,
            .t2 = 0,
            .valid_lifetime = 0,
            .preferred_lifetime = 0,
            .grant_tick = 0,
            .state = .None,
        };
    }

    /// Store server DUID from ADVERTISE/REPLY
    pub fn setServerDuid(self: *Self, duid: []const u8) void {
        const copy_len = @min(duid.len, MAX_SERVER_DUID_LEN);
        @memcpy(self.server_duid[0..copy_len], duid[0..copy_len]);
        self.server_duid_len = copy_len;
    }

    /// Get stored server DUID slice
    pub fn getServerDuid(self: *const Self) []const u8 {
        return self.server_duid[0..self.server_duid_len];
    }

    /// Calculate elapsed seconds since lease grant
    /// tick_rate_hz: ticks per second (e.g., 1000 for millisecond ticks)
    pub fn elapsedSeconds(self: *const Self, current_tick: u64, tick_rate_hz: u64) u64 {
        if (current_tick < self.grant_tick) return 0;
        return (current_tick - self.grant_tick) / tick_rate_hz;
    }

    /// Check if T1 timer has expired (time to RENEW)
    pub fn isT1Expired(self: *const Self, current_tick: u64, tick_rate_hz: u64) bool {
        if (self.t1 == 0) return false; // T1 = 0 means no renewal
        return self.elapsedSeconds(current_tick, tick_rate_hz) >= self.t1;
    }

    /// Check if T2 timer has expired (time to REBIND)
    pub fn isT2Expired(self: *const Self, current_tick: u64, tick_rate_hz: u64) bool {
        if (self.t2 == 0) return false; // T2 = 0 means no rebind
        return self.elapsedSeconds(current_tick, tick_rate_hz) >= self.t2;
    }

    /// Check if lease has completely expired
    pub fn isExpired(self: *const Self, current_tick: u64, tick_rate_hz: u64) bool {
        if (self.valid_lifetime == 0) return true; // No valid lease
        return self.elapsedSeconds(current_tick, tick_rate_hz) >= self.valid_lifetime;
    }

    /// Check if preferred lifetime has expired (address becomes deprecated)
    pub fn isDeprecated(self: *const Self, current_tick: u64, tick_rate_hz: u64) bool {
        if (self.preferred_lifetime == 0) return true;
        return self.elapsedSeconds(current_tick, tick_rate_hz) >= self.preferred_lifetime;
    }

    /// Get remaining valid lifetime in seconds
    pub fn remainingValid(self: *const Self, current_tick: u64, tick_rate_hz: u64) u64 {
        const elapsed = self.elapsedSeconds(current_tick, tick_rate_hz);
        if (elapsed >= self.valid_lifetime) return 0;
        return self.valid_lifetime - elapsed;
    }

    /// Get remaining time until T1 in seconds
    pub fn remainingT1(self: *const Self, current_tick: u64, tick_rate_hz: u64) u64 {
        if (self.t1 == 0) return 0xFFFFFFFF; // Infinite
        const elapsed = self.elapsedSeconds(current_tick, tick_rate_hz);
        if (elapsed >= self.t1) return 0;
        return self.t1 - elapsed;
    }

    /// Get remaining time until T2 in seconds
    pub fn remainingT2(self: *const Self, current_tick: u64, tick_rate_hz: u64) u64 {
        if (self.t2 == 0) return 0xFFFFFFFF; // Infinite
        const elapsed = self.elapsedSeconds(current_tick, tick_rate_hz);
        if (elapsed >= self.t2) return 0;
        return self.t2 - elapsed;
    }

    /// Update lease state based on current time
    pub fn updateState(self: *Self, current_tick: u64, tick_rate_hz: u64) void {
        if (self.state == .None) return;

        if (self.isExpired(current_tick, tick_rate_hz)) {
            self.state = .Expired;
        } else if (self.isT2Expired(current_tick, tick_rate_hz)) {
            if (self.state == .Bound or self.state == .Renewing) {
                self.state = .Rebinding;
            }
        } else if (self.isT1Expired(current_tick, tick_rate_hz)) {
            if (self.state == .Bound) {
                self.state = .Renewing;
            }
        }
    }

    /// Record successful lease acquisition
    pub fn recordLease(
        self: *Self,
        addr: [16]u8,
        iaid: u32,
        t1: u32,
        t2: u32,
        preferred: u32,
        valid: u32,
        current_tick: u64,
    ) void {
        self.addr = addr;
        self.iaid = iaid;
        self.t1 = t1;
        self.t2 = t2;
        self.preferred_lifetime = preferred;
        self.valid_lifetime = valid;
        self.grant_tick = current_tick;
        self.state = .Bound;
    }

    /// Record successful renewal (updates lifetimes, resets timers)
    pub fn recordRenewal(
        self: *Self,
        t1: u32,
        t2: u32,
        preferred: u32,
        valid: u32,
        current_tick: u64,
    ) void {
        self.t1 = t1;
        self.t2 = t2;
        self.preferred_lifetime = preferred;
        self.valid_lifetime = valid;
        self.grant_tick = current_tick;
        self.state = .Bound;
    }

    /// Clear lease (after RELEASE or expiry)
    pub fn clear(self: *Self) void {
        self.* = Self.init();
    }

    /// Check if we have a valid address
    pub fn hasAddress(self: *const Self) bool {
        const zeros = [_]u8{0} ** 16;
        return !std.mem.eql(u8, &self.addr, &zeros);
    }
};

/// Calculate default T1/T2 if server sends 0 (RFC 8415)
/// T1 = 0.5 * preferred_lifetime
/// T2 = 0.8 * preferred_lifetime
pub fn calculateDefaultTimers(preferred: u32) struct { t1: u32, t2: u32 } {
    return .{
        .t1 = preferred / 2,
        .t2 = (preferred * 4) / 5,
    };
}
