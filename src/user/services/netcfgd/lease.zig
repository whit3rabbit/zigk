//! DHCP Lease Management
//!
//! Tracks lease state including T1/T2 timers for renewal and rebinding.
//! Implements RFC 2131 lease lifecycle.

const syscall = @import("syscall");

/// Lease information and timers
pub const LeaseInfo = struct {
    /// Assigned IP address (host byte order)
    ip_addr: u32,
    /// Subnet mask (host byte order)
    netmask: u32,
    /// Gateway (host byte order)
    gateway: u32,
    /// Lease duration in seconds
    lease_time: u32,
    /// T1 renewal time in seconds
    t1_time: u32,
    /// T2 rebinding time in seconds
    t2_time: u32,
    /// Tick when lease was acquired
    lease_start_tick: u64,
    /// Whether lease is valid
    valid: bool,

    const Self = @This();

    /// Milliseconds per second
    const MS_PER_SEC: u64 = 1000;

    pub fn init() Self {
        return Self{
            .ip_addr = 0,
            .netmask = 0,
            .gateway = 0,
            .lease_time = 0,
            .t1_time = 0,
            .t2_time = 0,
            .lease_start_tick = 0,
            .valid = false,
        };
    }

    /// Set lease from DHCPACK
    pub fn setLease(self: *Self, ip: u32, mask: u32, gw: u32, lease_secs: u32) void {
        self.ip_addr = ip;
        self.netmask = mask;
        self.gateway = gw;
        self.lease_time = lease_secs;
        // Default T1 = 0.5 * lease, T2 = 0.875 * lease (RFC 2131)
        self.t1_time = lease_secs / 2;
        self.t2_time = (lease_secs * 7) / 8;
        self.lease_start_tick = syscall.getTickMs();
        self.valid = true;
    }

    /// Renew lease (reset timers)
    pub fn renewLease(self: *Self, new_lease_secs: u32) void {
        self.lease_time = new_lease_secs;
        self.t1_time = new_lease_secs / 2;
        self.t2_time = (new_lease_secs * 7) / 8;
        self.lease_start_tick = syscall.getTickMs();
    }

    /// Get seconds elapsed since lease start
    fn getElapsedSecs(self: *const Self) u64 {
        const now = syscall.getTickMs();
        const elapsed_ms = now -% self.lease_start_tick;
        return elapsed_ms / MS_PER_SEC;
    }

    /// Check if T1 (renewal) time has passed
    pub fn isT1Expired(self: *const Self) bool {
        if (!self.valid) return false;
        return self.getElapsedSecs() >= self.t1_time;
    }

    /// Check if T2 (rebinding) time has passed
    pub fn isT2Expired(self: *const Self) bool {
        if (!self.valid) return false;
        return self.getElapsedSecs() >= self.t2_time;
    }

    /// Check if lease has expired
    pub fn isExpired(self: *const Self) bool {
        if (!self.valid) return true;
        return self.getElapsedSecs() >= self.lease_time;
    }

    /// Get milliseconds until T1
    pub fn getTimeToT1(self: *const Self) u64 {
        if (!self.valid) return 0;
        const elapsed = self.getElapsedSecs();
        if (elapsed >= self.t1_time) return 0;
        return (self.t1_time - elapsed) * MS_PER_SEC;
    }

    /// Get milliseconds until T2
    pub fn getTimeToT2(self: *const Self) u64 {
        if (!self.valid) return 0;
        const elapsed = self.getElapsedSecs();
        if (elapsed >= self.t2_time) return 0;
        return (self.t2_time - elapsed) * MS_PER_SEC;
    }

    /// Get milliseconds until expiry
    pub fn getTimeToExpiry(self: *const Self) u64 {
        if (!self.valid) return 0;
        const elapsed = self.getElapsedSecs();
        if (elapsed >= self.lease_time) return 0;
        return (self.lease_time - elapsed) * MS_PER_SEC;
    }

    /// Invalidate the lease
    pub fn invalidate(self: *Self) void {
        self.valid = false;
        self.ip_addr = 0;
    }
};
