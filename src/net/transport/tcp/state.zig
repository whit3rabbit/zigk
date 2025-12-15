const std = @import("std");
const c = @import("constants.zig");
const types = @import("types.zig");
pub const Interface = @import("../../core/interface.zig").Interface;
const sync = @import("../../sync.zig");
const hal = @import("hal");
const entropy = hal.entropy;

pub const TcpState = types.TcpState;
pub const Tcb = types.Tcb;

/// TCB pool (list of active TCBs)
pub var tcb_pool: std.ArrayListUnmanaged(*Tcb) = .{};
pub var tcp_allocator: std.mem.Allocator = undefined;

/// Connection hash table (for fast lookup)
/// We still use a fixed size hash table for buckets, but chaining is via TCB linked list (hash_next)
pub var tcb_hash: [c.TCB_HASH_SIZE]?*Tcb = [_]?*Tcb{null} ** c.TCB_HASH_SIZE;

/// Listening TCBs
pub var listen_tcbs: std.ArrayListUnmanaged(*Tcb) = .{};

/// Global network interface
pub var global_iface: ?*Interface = null;

/// ISN counter (combined with entropy for unpredictability)
/// ISN counter (combined with entropy for unpredictability) - DEPRECATED for linear use
pub var isn_counter: u32 = 0;

/// Monotonic timestamp counter for connection tracking (milliseconds)
/// Incremented by processTimers() each tick
pub var connection_timestamp: u64 = 0;

/// Tick the TCP clock (called from system timer)
pub fn tick() void {
    connection_timestamp +%= ms_per_tick;
    // We could call processTimers() here, but usually it's called separately or via a scheduler job
    // to avoid doing too much work in interrupt context.
    // For this kernel, let's assume processTimers() is called by the same mechanism driving this tick.
}

/// Global TCP lock
pub var lock: sync.Lock = sync.noop_lock;

/// Secret key for ISN generation (RFC 6528)
var secret_key: u64 = 0;

/// Count of half-open connections (SYN-RECEIVED)
pub var half_open_count: usize = 0;

/// TCP State Machine
//
// Complies with:
// - RFC 793: Transmission Control Protocol (State Diagram)
//
// Manages the state of Transmission Control Blocks (TCBs).
// Handles state transitions (e.g. CLOSED -> LISTEN -> SYN_RCVD).
/// Counter for ISN generations since last re-seed
var isn_generation_count: u32 = 0;

/// Re-seed secret key every N ISN generations for defense-in-depth
/// Prevents long-term key exposure from compromising all future ISNs
const ISN_RESEED_THRESHOLD: u32 = 10000;

/// Timestamp counter for TCP timestamps (RFC 7323)
/// Increments with each call, providing monotonic values
var tcp_timestamp_counter: u32 = 0;

/// Set the lock implementation
pub fn setLock(l: sync.Lock) void {
    lock = l;
}

/// Milliseconds per timer tick (default 1ms for 1000Hz)
pub var ms_per_tick: u32 = 1;

/// Initialize TCP subsystem
pub fn init(iface: *Interface, allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    if (ticks_per_sec > 0) {
        ms_per_tick = 1000 / ticks_per_sec;
        if (ms_per_tick == 0) ms_per_tick = 1;
    }
    lock.acquire();
    defer lock.release();

    global_iface = iface;
    tcp_allocator = allocator;
    tcp_allocator = allocator;
    tcb_pool = .{};
    listen_tcbs = .{};

    // Clear hash table
    for (&tcb_hash) |*entry| {
        entry.* = null;
    }

    // Seed ISN counter with hardware entropy
    isn_counter = @truncate(entropy.getHardwareEntropy());
    // Seed secret key
    secret_key = entropy.getHardwareEntropy();
}

/// Count connections in SYN-RECEIVED state (half-open)
pub fn countHalfOpen() usize {
    return half_open_count;
}

/// Allocate a new TCB
pub fn allocateTcb() ?*Tcb {
    // Security: Enforce MAX_TCBS limit to prevent resource exhaustion
    if (tcb_pool.items.len >= c.MAX_TCBS) {
        return null;
    }

    const tcb = tcp_allocator.create(Tcb) catch return null;
    tcb.* = Tcb.init();
    tcb.allocated = true;
    tcb.created_at = connection_timestamp;

    tcb_pool.append(tcp_allocator, tcb) catch {
        tcp_allocator.destroy(tcb);
        return null;
    };

    return tcb;
}

/// Free a TCB
/// Security: Uses two-phase deletion pattern:
/// 1. Mark as closing to prevent new packet processing
/// 2. Remove from hash table to prevent new lookups
/// 3. Reset state and free memory
pub fn freeTcb(tcb: *Tcb) void {
    // Maintain half-open counter
    if (tcb.state == .SynReceived) {
        if (half_open_count > 0) half_open_count -= 1;
    }
    // Phase 1: Mark as closing - any concurrent packet processing
    // that somehow obtained a reference will see this flag and bail out
    tcb.closing = true;

    // Phase 2: Remove from hash table - prevents new lookups
    removeTcbFromHash(tcb);

    // Phase 3: Reset and free
    tcb.reset();

    // Remove from pool
    for (tcb_pool.items, 0..) |item, i| {
        if (item == tcb) {
             _ = tcb_pool.swapRemove(i);
             break;
        }
    }

    tcp_allocator.destroy(tcb);
}

/// Hash function for connection lookup
/// Uses Jenkins one-at-a-time hash for better distribution
pub fn hashConnection(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) usize {
    var h: u32 = 0;

    // Mix local IP
    h +%= local_ip;
    h +%= (h << 10);
    h ^= (h >> 6);

    // Mix remote IP
    h +%= remote_ip;
    h +%= (h << 10);
    h ^= (h >> 6);

    // Mix ports
    h +%= @as(u32, local_port);
    h +%= (h << 10);
    h ^= (h >> 6);

    h +%= @as(u32, remote_port);
    h +%= (h << 10);
    h ^= (h >> 6);

    // Final mixing
    h +%= (h << 3);
    h ^= (h >> 11);
    h +%= (h << 15);

    return @as(usize, h) % c.TCB_HASH_SIZE;
}

/// Insert TCB into hash table
pub fn insertTcbIntoHash(tcb: *Tcb) void {
    const idx = hashConnection(tcb.local_ip, tcb.local_port, tcb.remote_ip, tcb.remote_port);
    tcb.hash_next = tcb_hash[idx];
    tcb_hash[idx] = tcb;
}

/// Remove TCB from hash table
pub fn removeTcbFromHash(tcb: *Tcb) void {
    const idx = hashConnection(tcb.local_ip, tcb.local_port, tcb.remote_ip, tcb.remote_port);

    var prev: ?*Tcb = null;
    var curr = tcb_hash[idx];

    while (curr) |c_tcb| {
        if (c_tcb == tcb) {
            if (prev) |p| {
                p.hash_next = c_tcb.hash_next;
            } else {
                tcb_hash[idx] = c_tcb.hash_next;
            }
            tcb.hash_next = null;
            return;
        }
        prev = c_tcb;
        curr = c_tcb.hash_next;
    }
}

/// Find TCB by connection 4-tuple
pub fn findTcb(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) ?*Tcb {
    const idx = hashConnection(local_ip, local_port, remote_ip, remote_port);
    var curr = tcb_hash[idx];

    while (curr) |tcb| {
        if (tcb.local_ip == local_ip and tcb.local_port == local_port and
            tcb.remote_ip == remote_ip and tcb.remote_port == remote_port)
        {
            return tcb;
        }
        curr = tcb.hash_next;
    }
    return null;
}

/// Find listening TCB by local port
pub fn findListeningTcb(local_port: u16) ?*Tcb {
    for (listen_tcbs.items) |tcb| {
         if (tcb.local_port == local_port and tcb.state == .Listen) {
             return tcb;
         }
    }
    return null;
}

/// Validate that a connection exists for the given 4-tuple.
/// Used by ICMP handler to validate PMTU updates (RFC 5927).
/// Returns true if an active TCP connection matches the 4-tuple.
pub fn validateConnectionExists(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) bool {
    lock.acquire();
    defer lock.release();

    const tcb = findTcb(local_ip, local_port, remote_ip, remote_port) orelse return false;

    // Only accept PMTU updates for established or nearly-established connections
    // Reject for closed/listen states which wouldn't be sending data
    return switch (tcb.state) {
        .Established, .SynSent, .SynReceived, .FinWait1, .FinWait2, .CloseWait, .Closing, .LastAck => true,
        .Closed, .Listen, .TimeWait => false,
    };
}

/// Add TCB to listen table
pub fn addToListenTable(tcb: *Tcb) bool {
    listen_tcbs.append(tcp_allocator, tcb) catch return false;
    return true;
}

/// Remove TCB from listen table
pub fn removeFromListenTable(tcb: *Tcb) void {
    for (listen_tcbs.items, 0..) |item, i| {
        if (item == tcb) {
            _ = listen_tcbs.swapRemove(i);
            return;
        }
    }
}

/// Generate Initial Sequence Number (RFC 6528)
/// Uses hardware entropy + counter for unpredictability
/// ISN = M + F(localip, localport, remoteip, remoteport, secret_key)
/// Secret key is periodically re-seeded for defense-in-depth
pub fn generateIsn(l_ip: u32, l_port: u16, r_ip: u32, r_port: u16) u32 {
    // M = Timer. RFC 6528 suggests a 4us timer.
    // We use our millisecond connection_timestamp scaled to approximate higher resolution
    // and prevent easy guessing, combined with the global entropy counter.
    // 250 increments per ms = 4us resolution approx
    const time_component = @as(u32, @truncate(connection_timestamp)) *% 250;
    
    // We still mix in isn_counter (which is random seeded) but we don't
    // strictly rely on its linear increment leaking volume.
    // Actually, to fully prevent leak we should not assume a global linear counter that
    // increments per connection.
    
    // Use the time component as the linear basline 'M'
    const M = time_component;
    
    isn_generation_count +%= 1;

    // Periodically re-seed secret key with fresh entropy
    // XOR mixing preserves existing entropy while adding new randomness
    if (isn_generation_count >= ISN_RESEED_THRESHOLD) {
        secret_key ^= entropy.getHardwareEntropy();
        isn_generation_count = 0;
    }

    // F = Simple hash of 4-tuple + secret
    var k = secret_key;
    k +%= l_ip;
    k *%= 0x9e3779b97f4a7c15;
    k +%= r_ip;
    k *%= 0x9e3779b97f4a7c15;
    k +%= l_port;
    k *%= 0x9e3779b97f4a7c15;
    k +%= r_port;
    k *%= 0x9e3779b97f4a7c15;
    k ^= (k >> 30);
    k *%= 0xbf58476d1ce4e5b9;
    k ^= (k >> 27);
    k *%= 0x94d049bb133111eb;
    k ^= (k >> 31);

    return M +% @as(u32, @truncate(k));
}

/// Get current timestamp for TCP Timestamps option (RFC 7323)
/// Returns a monotonically increasing 32-bit value
/// Uses entropy-seeded counter since we don't have a dedicated timer
pub fn nextTimestamp() u32 {
    // Increment counter each call - provides monotonicity required by RFC 7323
    // Seed with entropy on first call for unpredictability
    if (tcp_timestamp_counter == 0) {
        tcp_timestamp_counter = @truncate(entropy.getHardwareEntropy());
    }
    tcp_timestamp_counter +%= 1;
    return tcp_timestamp_counter;
}
