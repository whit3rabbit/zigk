// TCP Reno Congestion Control (RFC 5681, RFC 6582, RFC 6928)
//
// Entry points:
//   onAck       -- Called on each valid ACK (slow-start + congestion avoidance + fast recovery)
//   onTimeout   -- Called on RTO expiry (RFC 5681 S3.5 + RFC 6298)
//   onDupAck    -- Called on duplicate ACK (fast retransmit/recovery, RFC 5681 S3.2)
//
// Callers MUST hold tcb.mutex before calling any function here.
// No heap allocation. All operations mutate *Tcb in-place.

const std = @import("std");
const types = @import("../types.zig");
const c = @import("../constants.zig");
const Tcb = types.Tcb;
const seqGte = types.seqGte;

/// Called on each valid cumulative ACK.
/// Handles fast recovery (full and partial) and normal path (slow-start +
/// congestion avoidance).
///
/// Callers are responsible for retransmitting the lost segment BEFORE calling
/// onAck when a partial ACK occurs during fast recovery (RFC 6582 S3.2).
pub fn onAck(tcb: *Tcb, acked_bytes: u32) void {
    const mss = @as(u32, tcb.mss);

    if (tcb.fast_recovery) {
        if (seqGte(tcb.snd_una, tcb.recover)) {
            // Full ACK: exit fast recovery, deflate cwnd to ssthresh
            tcb.fast_recovery = false;
            tcb.cwnd = tcb.ssthresh;
        } else {
            // Partial ACK during fast recovery: set cwnd = ssthresh + MSS
            // (caller handles retransmit of the next unacknowledged segment)
            tcb.cwnd = tcb.ssthresh + mss;
        }
        tcb.cwnd = capCwnd(tcb);
        return;
    }

    // Normal path
    if (tcb.cwnd < tcb.ssthresh) {
        // Slow-start: increase by min(acked_bytes, MSS) per ACK
        const inc = @min(acked_bytes, mss);
        tcb.cwnd = std.math.add(u32, tcb.cwnd, inc) catch std.math.maxInt(u32);
    } else {
        // Congestion avoidance: AIMD -- increase by MSS^2/cwnd (at most 1 MSS per RTT)
        // Compute in u64 to avoid intermediate overflow, then truncate to u32.
        const mss64 = @as(u64, mss);
        const cwnd64 = @as(u64, tcb.cwnd);
        const inc64 = @max(1, (mss64 * mss64) / cwnd64);
        const inc = @as(u32, @intCast(@min(inc64, std.math.maxInt(u32))));
        tcb.cwnd = std.math.add(u32, tcb.cwnd, inc) catch std.math.maxInt(u32);
    }

    tcb.cwnd = capCwnd(tcb);
}

/// Called on RTO expiry.
/// Implements RFC 5681 S3.5: halve ssthresh, reset cwnd to 1*SMSS.
/// Also applies Karn's Algorithm (CC-03): clears rtt_seq so the
/// retransmitted segment is not used for RTT estimation.
pub fn onTimeout(tcb: *Tcb) void {
    const mss = @as(u32, tcb.mss);

    // flight_size = bytes in flight (wrapping subtraction is correct for seq arithmetic)
    const flight_size = tcb.snd_nxt -% tcb.snd_una;

    // ssthresh = max(FlightSize / 2, 2*SMSS) -- RFC 5681 S3.5 eq 4
    tcb.ssthresh = @max(flight_size / 2, 2 * mss);

    // cwnd = 1*SMSS (NOT IW10, conservative restart per RFC 5681 S3.5)
    tcb.cwnd = mss;

    // Exit fast recovery if active
    tcb.fast_recovery = false;

    // Karn's Algorithm (CC-03): do not use retransmitted segment for RTT
    tcb.rtt_seq = 0;
}

/// Called on each duplicate ACK.
/// Implements RFC 5681 S3.2 fast retransmit/fast recovery:
/// - On the 3rd dup ACK (not already in recovery): enter fast recovery
/// - While in fast recovery: inflate cwnd by MSS per additional dup ACK
pub fn onDupAck(tcb: *Tcb, dup_count: u8) void {
    const mss = @as(u32, tcb.mss);

    if (dup_count == 3 and !tcb.fast_recovery) {
        // Enter fast recovery (RFC 5681 S3.2 step 1)
        const flight_size = tcb.snd_nxt -% tcb.snd_una;
        tcb.ssthresh = @max(flight_size / 2, 2 * mss);
        tcb.cwnd = tcb.ssthresh + 3 * mss;
        tcb.fast_recovery = true;
        tcb.recover = tcb.snd_nxt;
        tcb.cwnd = capCwnd(tcb);
    } else if (tcb.fast_recovery) {
        // Inflate cwnd during fast recovery (RFC 5681 S3.2 step 3)
        tcb.cwnd = std.math.add(u32, tcb.cwnd, mss) catch std.math.maxInt(u32);
        tcb.cwnd = capCwnd(tcb);
    }
    // dup_count < 3 and not in recovery: no action
}

/// Cap cwnd at MAX_CWND (CC-05).
/// Called after every cwnd increase to prevent unbounded growth on idle connections.
inline fn capCwnd(tcb: *const Tcb) u32 {
    return @min(tcb.cwnd, c.MAX_CWND);
}
