const std = @import("std");
const c = @import("constants.zig");
const types = @import("types.zig");
pub const Interface = @import("../../core/interface.zig").Interface;
const sync = @import("../../sync.zig");
const net_pool = @import("../../core/pool.zig");
// const hal = @import("hal"); // Removed dependency
// const entropy = @import("../entropy.zig"); // Removed incorrect import (using platform.entropy)
const platform = @import("../../platform.zig");

pub const TcpState = types.TcpState;
pub const Tcb = types.Tcb;
pub const IpAddr = types.IpAddr;

/// TCB pool (list of active TCBs)
pub var tcb_pool: std.ArrayListUnmanaged(*Tcb) = .{};
pub var tcp_allocator: std.mem.Allocator = undefined;

/// TX Buffer Pool (64 x 2048 = 128KB)
/// Avoids heap allocation on transmit path
/// Shared by TCP and UDP
pub fn allocTxBuffer() ?[]u8 {
    return net_pool.allocTxBuffer();
}

pub fn freeTxBuffer(buf: []u8) void {
    net_pool.freeTxBuffer(buf);
}

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

/// Global TCP lock - MUST be initialized before use
/// SECURITY: Uses IrqLock to ensure proper interrupt state management
/// LOCK ORDER: Always take state.lock before any per-TCB mutex to avoid AB-BA deadlocks.
pub var lock: sync.IrqLock = .{};

/// Secret key for TCP hash buckets (SipHash-2-4) - stable across connections
var hash_key: [16]u8 = [_]u8{0} ** 16;
/// Secret key for ISN generation (RFC 6528) - can be re-seeded
var isn_key: [16]u8 = [_]u8{0} ** 16;

/// Count of half-open connections (SYN-RECEIVED)
pub var half_open_count: usize = 0;

/// Head of half-open TCB list (oldest first for O(1) eviction)
/// Doubly-linked intrusive list for O(1) insert/remove
var half_open_head: ?*Tcb = null;
var half_open_tail: ?*Tcb = null;

/// Insert TCB into half-open list (at tail - newest)
/// Call this when TCB transitions to SYN-RECEIVED state
pub fn halfOpenListInsert(tcb: *Tcb) void {
    tcb.half_open_next = null;
    tcb.half_open_prev = half_open_tail;

    if (half_open_tail) |tail| {
        tail.half_open_next = tcb;
    } else {
        half_open_head = tcb;
    }
    half_open_tail = tcb;
}

/// Remove TCB from half-open list
/// Call this when TCB transitions out of SYN-RECEIVED state
pub fn halfOpenListRemove(tcb: *Tcb) void {
    // Update prev's next pointer
    if (tcb.half_open_prev) |prev| {
        prev.half_open_next = tcb.half_open_next;
    } else {
        // tcb was head
        half_open_head = tcb.half_open_next;
    }

    // Update next's prev pointer
    if (tcb.half_open_next) |next| {
        next.half_open_prev = tcb.half_open_prev;
    } else {
        // tcb was tail
        half_open_tail = tcb.half_open_prev;
    }

    tcb.half_open_next = null;
    tcb.half_open_prev = null;
}

/// TCP State Machine
//
// Complies with:
// - RFC 793: Transmission Control Protocol (State Diagram)
//
// Manages the state of Transmission Control Blocks (TCBs).
// Handles state transitions (e.g. CLOSED -> LISTEN -> SYN_RCVD).
/// Counter for ISN generations since last re-seed
var isn_generation_count: u32 = 0;

/// Global monotonic generation counter for TCBs
/// Used to detect TCB reuse when waking from block
var tcb_generation_counter: u64 = 0;

/// Re-seed secret key every N ISN generations for defense-in-depth
/// Prevents long-term key exposure from compromising all future ISNs
const ISN_RESEED_THRESHOLD: u32 = 10000;

/// Timestamp counter for TCP timestamps (RFC 7323)
/// Increments with each call, providing monotonic values
var tcp_timestamp_counter: std.atomic.Value(u32) = .{ .raw = 0 };

/// SECURITY: Re-seed timestamp counter every N calls to reduce predictability.
/// Unlike ISNs, timestamps just need monotonicity (RFC 7323), so we add a
/// random forward jump rather than resetting. This prevents cross-connection
/// correlation and activity pattern leakage while maintaining correctness.
const TIMESTAMP_RESEED_THRESHOLD: u32 = 1000;
var timestamp_reseed_counter: std.atomic.Value(u32) = .{ .raw = 0 };

/// Milliseconds per timer tick (default 1ms for 1000Hz)
pub var ms_per_tick: u32 = 1;

/// Initialize TCP subsystem
/// SECURITY: This MUST be called before any TCP operations.
/// Initializes the global lock and seeds cryptographic state.
pub fn init(iface: *Interface, allocator: std.mem.Allocator, ticks_per_sec: u32) void {
    if (ticks_per_sec > 0) {
        ms_per_tick = 1000 / ticks_per_sec;
        if (ms_per_tick == 0) ms_per_tick = 1;
    }

    // SECURITY: Initialize lock before first use - prevents silent failures
    lock.init();

    const held = lock.acquire();
    defer held.release();

    global_iface = iface;
    tcp_allocator = allocator;
    tcb_pool = .{};
    listen_tcbs = .{};

    // Clear hash table
    for (&tcb_hash) |*entry| {
        entry.* = null;
    }

    // Seed ISN counter with hardware entropy
    isn_counter = @truncate(platform.entropy.getHardwareEntropy());
    // Seed hash key (128-bit) - must remain stable for hash table lookups
    const k1 = platform.entropy.getHardwareEntropy();
    const k2 = platform.entropy.getHardwareEntropy();
    @memcpy(hash_key[0..8], std.mem.asBytes(&k1));
    @memcpy(hash_key[8..16], std.mem.asBytes(&k2));
    // Seed ISN key (128-bit) - can be re-seeded without rehashing tables
    const k3 = platform.entropy.getHardwareEntropy();
    const k4 = platform.entropy.getHardwareEntropy();
    @memcpy(isn_key[0..8], std.mem.asBytes(&k3));
    @memcpy(isn_key[8..16], std.mem.asBytes(&k4));
}

/// Initialize TCP state lock for syscall-only mode (no network stack).
/// SECURITY: Must be called before any TCP socket operations.
pub fn initSyscallOnly() void {
    lock.init();
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
    
    // Assign generation
    tcb_generation_counter +%= 1;
    tcb.generation = tcb_generation_counter;

    tcb_pool.append(tcp_allocator, tcb) catch {
        tcp_allocator.destroy(tcb);
        return null;
    };

    return tcb;
}

/// Check if a TCB pointer is still valid (exists in the pool)
pub fn isTcbValid(tcb: *Tcb) bool {
    for (tcb_pool.items) |item| {
        if (item == tcb) return true;
    }
    return false;
}

/// Free a TCB
/// Security: Uses two-phase deletion pattern:
/// 1. Mark as closing to prevent new packet processing
/// 2. Remove from hash table to prevent new lookups
/// 3. Reset state and free memory
pub fn freeTcb(tcb: *Tcb) void {
    // Maintain half-open counter and remove from half-open list
    if (tcb.state == .SynReceived) {
        halfOpenListRemove(tcb);
        if (half_open_count > 0) half_open_count -= 1;
    }
    // Phase 1: Mark as closing - any concurrent packet processing
    // that somehow obtained a reference will see this flag and bail out
    tcb.closing = true;

    // Phase 2: Remove from hash table - prevents new lookups
    removeTcbFromHash(tcb);

    // Safety: Also remove from listen table if present, to prevent dangling pointers
    removeFromListenTable(tcb);

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

/// Hash function for connection lookup - polymorphic version supporting IPv4/IPv6
/// Uses SipHash-2-4 for protection against hash flooding DoS
pub fn hashConnectionIp(local_addr: IpAddr, local_port: u16, remote_addr: IpAddr, remote_port: u16) usize {
    var hasher = std.crypto.auth.siphash.SipHash64(2, 4).init(&hash_key);

    // Hash local address based on family
    switch (local_addr) {
        .none => hasher.update(&[_]u8{0} ** 4),
        .v4 => |ip| hasher.update(std.mem.asBytes(&ip)),
        .v6 => |ip| hasher.update(&ip),
    }
    hasher.update(std.mem.asBytes(&local_port));

    // Hash remote address based on family
    switch (remote_addr) {
        .none => hasher.update(&[_]u8{0} ** 4),
        .v4 => |ip| hasher.update(std.mem.asBytes(&ip)),
        .v6 => |ip| hasher.update(&ip),
    }
    hasher.update(std.mem.asBytes(&remote_port));

    return @as(usize, @truncate(hasher.finalInt())) % c.TCB_HASH_SIZE;
}

/// Hash function for connection lookup (IPv4 wrapper for backward compatibility)
/// Uses SipHash-2-4 for protection against hash flooding DoS
pub fn hashConnection(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) usize {
    return hashConnectionIp(.{ .v4 = local_ip }, local_port, .{ .v4 = remote_ip }, remote_port);
}

/// Insert TCB into hash table (works for both IPv4 and IPv6)
pub fn insertTcbIntoHash(tcb: *Tcb) void {
    const idx = hashConnectionIp(tcb.local_addr, tcb.local_port, tcb.remote_addr, tcb.remote_port);
    tcb.hash_next = tcb_hash[idx];
    tcb_hash[idx] = tcb;
}

/// Remove TCB from hash table (works for both IPv4 and IPv6)
pub fn removeTcbFromHash(tcb: *Tcb) void {
    const idx = hashConnectionIp(tcb.local_addr, tcb.local_port, tcb.remote_addr, tcb.remote_port);

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

/// Find TCB by connection 4-tuple - polymorphic version supporting IPv4/IPv6
pub fn findTcbIp(local_addr: IpAddr, local_port: u16, remote_addr: IpAddr, remote_port: u16) ?*Tcb {
    // Caller must hold state.lock for the duration of any lookup-then-modify sequence.
    const idx = hashConnectionIp(local_addr, local_port, remote_addr, remote_port);
    var curr = tcb_hash[idx];

    while (curr) |tcb| {
        if (tcb.local_addr.eql(local_addr) and tcb.local_port == local_port and
            tcb.remote_addr.eql(remote_addr) and tcb.remote_port == remote_port)
        {
            return tcb;
        }
        curr = tcb.hash_next;
    }
    return null;
}

/// Find TCB by connection 4-tuple (IPv4 wrapper for backward compatibility)
pub fn findTcb(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16) ?*Tcb {
    return findTcbIp(.{ .v4 = local_ip }, local_port, .{ .v4 = remote_ip }, remote_port);
}

/// Find listening TCB by local port and address - polymorphic version
/// Returns a listener bound to exact address, or to unspecified address (wildcard)
/// Prefers exact IP match over wildcard.
/// For wildcard listeners, also checks address family compatibility.
///
/// SO_REUSEPORT FIFO dispatch: when multiple listeners share a port, the one
/// with the lowest listen_accept_count is selected (least-loaded approximation).
/// listen_accept_count is incremented in handleSynReceivedEstablished() when a
/// connection is queued into the listener's accept queue. No lock is needed
/// since listen_accept_count is only a load-balancing heuristic -- slight staleness
/// is acceptable.
pub fn findListeningTcbIp(local_port: u16, local_addr: IpAddr) ?*Tcb {
    var exact_match: ?*Tcb = null;
    var exact_accept: usize = std.math.maxInt(usize);
    var any_match: ?*Tcb = null;
    var any_accept: usize = std.math.maxInt(usize);

    for (listen_tcbs.items) |tcb| {
        if (tcb.local_port == local_port and tcb.state == .Listen) {
            const ac = tcb.listen_accept_count;

            // Check for exact address match -- prefer lowest accept_count
            if (tcb.local_addr.eql(local_addr)) {
                if (ac < exact_accept) {
                    exact_match = tcb;
                    exact_accept = ac;
                }
            // Check for wildcard match with address family compatibility
            } else if (tcb.local_addr.isUnspecified()) {
                // .none accepts any family
                // .v4 with 0.0.0.0 accepts IPv4 only
                // .v6 with :: accepts IPv6 only (unless IPV6_V6ONLY is false)
                const family_match = switch (tcb.local_addr) {
                    .none => true,
                    .v4 => local_addr.isV4(),
                    .v6 => local_addr.isV6(),
                };
                if (family_match and ac < any_accept) {
                    any_match = tcb;
                    any_accept = ac;
                }
            }
        }
    }
    return exact_match orelse any_match;
}

/// Find listening TCB by local port and local IP (IPv4 wrapper for backward compatibility)
/// local_ip: The destination IP of the incoming packet
/// Returns a listener bound to local_ip, or to 0.0.0.0 (INADDR_ANY)
/// Prefers exact IP match over wildcard.
pub fn findListeningTcb(local_port: u16, local_ip: u32) ?*Tcb {
    return findListeningTcbIp(local_port, .{ .v4 = local_ip });
}

/// Validate that a connection exists for the given 4-tuple.
/// Used by ICMP handler to validate PMTU updates (RFC 5927).
/// Returns true if an active TCP connection matches the 4-tuple.
/// Optionally validates if the sequence number from the ICMP payload is valid (in flight).
pub fn validateConnectionExists(local_ip: u32, local_port: u16, remote_ip: u32, remote_port: u16, seq_num: ?u32) bool {
    const held = lock.acquire();
    defer held.release();

    const tcb = findTcb(local_ip, local_port, remote_ip, remote_port) orelse return false;

    // Check sequence number if provided
    // RFC 5927: SEQ must be within range [SND.UNA, SND.NXT]
    if (seq_num) |seq| {
        // Simple check: SND.UNA <= SEQ <= SND.NXT
        const dist = seq -% tcb.snd_una;
        const window = tcb.snd_nxt -% tcb.snd_una;
        if (dist > window) {
             return false; // Sequence number not in flight
        }
    }

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

/// Generate Initial Sequence Number (RFC 6528) - polymorphic version supporting IPv4/IPv6
/// Uses hardware entropy + counter for unpredictability
/// ISN = M + F(localip, localport, remoteip, remoteport, secret_key)
/// Secret key is periodically re-seeded for defense-in-depth
pub fn generateIsnIp(local_addr: IpAddr, l_port: u16, remote_addr: IpAddr, r_port: u16) u32 {
    // M = Timer. RFC 6528 suggests a 4us timer.
    // We use our millisecond connection_timestamp scaled to approximate higher resolution
    // and prevent easy guessing, combined with the global entropy counter.
    // 250 increments per ms = 4us resolution approx
    const time_component = @as(u32, @truncate(connection_timestamp)) *% 250;

    // Use the time component as the linear baseline 'M'
    const M = time_component;

    isn_generation_count +%= 1;

    // Periodically re-seed secret key with fresh entropy
    // XOR mixing preserves existing entropy while adding new randomness
    if (isn_generation_count >= ISN_RESEED_THRESHOLD) {
        const k1 = platform.entropy.getHardwareEntropy();
        const k2 = platform.entropy.getHardwareEntropy();
        const sk_u64: *[2]u64 = @ptrCast(@alignCast(&isn_key));
        sk_u64[0] ^= k1;
        sk_u64[1] ^= k2;
        isn_generation_count = 0;
    }

    // F = SipHash-2-4(key, 4-tuple)
    // Security: Mix in fresh hardware entropy for every connection to prevent
    // attack against the linear counter component.
    const fresh_entropy = platform.entropy.getHardwareEntropy();

    var hasher = std.crypto.auth.siphash.SipHash64(2, 4).init(&isn_key);

    // Hash local address based on family
    switch (local_addr) {
        .none => hasher.update(&[_]u8{0} ** 4),
        .v4 => |ip| hasher.update(std.mem.asBytes(&ip)),
        .v6 => |ip| hasher.update(&ip),
    }
    hasher.update(std.mem.asBytes(&l_port));

    // Hash remote address based on family
    switch (remote_addr) {
        .none => hasher.update(&[_]u8{0} ** 4),
        .v4 => |ip| hasher.update(std.mem.asBytes(&ip)),
        .v6 => |ip| hasher.update(&ip),
    }
    hasher.update(std.mem.asBytes(&r_port));
    hasher.update(std.mem.asBytes(&fresh_entropy));

    // ISN = M + F.
    // SipHash64 returns u64, we take lower 32 bits
    const k: u32 = @truncate(hasher.finalInt());

    return M +% k;
}

/// Generate Initial Sequence Number (RFC 6528) - IPv4 wrapper for backward compatibility
pub fn generateIsn(l_ip: u32, l_port: u16, r_ip: u32, r_port: u16) u32 {
    return generateIsnIp(.{ .v4 = l_ip }, l_port, .{ .v4 = r_ip }, r_port);
}

/// Get current timestamp for TCP Timestamps option (RFC 7323)
/// Returns a monotonically increasing 32-bit value
/// Uses entropy-seeded counter since we don't have a dedicated timer
///
/// SECURITY: Periodically mixes in fresh entropy to prevent:
/// - Cross-connection timestamp correlation
/// - Activity pattern inference from linear increments
/// RFC 7323 only requires monotonicity, not contiguity.
pub fn nextTimestamp() u32 {
    // Seed with entropy on first call for unpredictability
    if (tcp_timestamp_counter.load(.acquire) == 0) {
        const seed: u32 = @truncate(platform.entropy.getHardwareEntropy());
        _ = tcp_timestamp_counter.cmpxchgStrong(0, seed, .acq_rel, .acquire);
    }

    // SECURITY: Periodically add random forward jump to break predictability.
    // We add 1-256 extra ticks randomly every TIMESTAMP_RESEED_THRESHOLD calls.
    // This maintains monotonicity while preventing correlation attacks.
    const reseed_count = timestamp_reseed_counter.fetchAdd(1, .acq_rel);
    var increment: u32 = 1;
    if (reseed_count % TIMESTAMP_RESEED_THRESHOLD == 0) {
        // Add random forward jump (1-256 extra ticks)
        const entropy: u32 = @truncate(platform.entropy.getHardwareEntropy());
        increment +%= (entropy & 0xFF) +| 1; // 1-256 range, saturating add
    }

    const prev = tcp_timestamp_counter.fetchAdd(increment, .acq_rel);
    return prev +% increment;
}

/// Evict oldest half-open TCB to make space for valid connections (DoS mitigation)
/// Returns true if an entry was evicted
/// Uses O(1) intrusive list - oldest is always at head
pub fn evictOldestHalfOpenTcb() bool {
    const held = lock.acquire();
    defer held.release();
    return evictOldestHalfOpenTcbUnlocked();
}

/// Unlocked version of evictOldestHalfOpenTcb - caller MUST hold state.lock
/// SECURITY: Used by processListenPacket to atomically check limit and evict
pub fn evictOldestHalfOpenTcbUnlocked() bool {
    // O(1) - oldest is at head of list
    const oldest_tcb = half_open_head orelse return false;

    // Verify it's actually in SYN-RECEIVED state (sanity check)
    if (oldest_tcb.state != .SynReceived) {
        // Inconsistent state - remove from list but don't free
        halfOpenListRemove(oldest_tcb);
        return false;
    }

    // SAFETY: No IRQ race window exists here because:
    // 1. Caller holds state.lock (IrqLock) which disables interrupts on this CPU
    // 2. The per-TCB mutex protects TCB fields from concurrent CPU access
    // 3. Setting closing=true before mutex release ensures any thread that somehow
    //    obtained a reference will see the flag and bail out
    // 4. freeTcb removes TCB from hash table, preventing new lookups
    // The mutex release before freeTcb is safe because IRQs are disabled by state.lock.
    if (oldest_tcb.mutex.tryAcquire()) |tcb_held| {
        // Mark as closing before releasing mutex to prevent concurrent access
        oldest_tcb.closing = true;
        tcb_held.release();
        freeTcb(oldest_tcb); // freeTcb handles halfOpenListRemove
        return true;
    }

    return false;
}
