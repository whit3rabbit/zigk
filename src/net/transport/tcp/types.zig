const c = @import("constants.zig");
const sync = @import("sync");

// TCP header (20 bytes minimum, options may follow). All multi-byte fields are
// in network byte order. Kept here to preserve the original documentation
// around flag helpers.
pub const TcpHeader = extern struct {
    src_port: u16 align(1),
    dst_port: u16 align(1),
    seq_num: u32 align(1),
    ack_num: u32 align(1),
    data_offset_flags: u16 align(1),
    window: u16 align(1),
    checksum: u16 align(1),
    urgent_ptr: u16 align(1),

    const Self = @This();

    // TCP flag positions (in low byte of data_offset_flags after byteswap)
    pub const FLAG_FIN: u16 = 0x0001;
    pub const FLAG_SYN: u16 = 0x0002;
    pub const FLAG_RST: u16 = 0x0004;
    pub const FLAG_PSH: u16 = 0x0008;
    pub const FLAG_ACK: u16 = 0x0010;
    pub const FLAG_URG: u16 = 0x0020;

    pub fn getSrcPort(self: *align(1) const Self) u16 {
        return @byteSwap(self.src_port);
    }
    pub fn getDstPort(self: *align(1) const Self) u16 {
        return @byteSwap(self.dst_port);
    }
    pub fn getSeqNum(self: *align(1) const Self) u32 {
        return @byteSwap(self.seq_num);
    }
    pub fn getAckNum(self: *align(1) const Self) u32 {
        return @byteSwap(self.ack_num);
    }
    pub fn getWindow(self: *align(1) const Self) u16 {
        return @byteSwap(self.window);
    }

    /// Get data offset in bytes (header length including options)
    pub fn getDataOffset(self: *align(1) const Self) usize {
        const dof = @byteSwap(self.data_offset_flags);
        return @as(usize, (dof >> 12) & 0xF) * 4;
    }

    /// Get TCP flags
    pub fn getFlags(self: *align(1) const Self) u16 {
        return @byteSwap(self.data_offset_flags) & 0x3F;
    }

    pub fn hasFlag(self: *align(1) const Self, flag: u16) bool {
        return (self.getFlags() & flag) != 0;
    }

    pub fn setSrcPort(self: *align(1) Self, port: u16) void {
        self.src_port = @byteSwap(port);
    }
    pub fn setDstPort(self: *align(1) Self, port: u16) void {
        self.dst_port = @byteSwap(port);
    }
    pub fn setSeqNum(self: *align(1) Self, seq: u32) void {
        self.seq_num = @byteSwap(seq);
    }
    pub fn setAckNum(self: *align(1) Self, ack: u32) void {
        self.ack_num = @byteSwap(ack);
    }
    pub fn setWindow(self: *align(1) Self, win: u16) void {
        self.window = @byteSwap(win);
    }

    /// Set data offset (header length / 4) and flags
    pub fn setDataOffsetFlags(self: *align(1) Self, header_words: u4, flags: u16) void {
        const dof = (@as(u16, header_words) << 12) | (flags & 0x3F);
        self.data_offset_flags = @byteSwap(dof);
    }

    comptime {
        if (@sizeOf(TcpHeader) != 20) @compileError("TcpHeader must be 20 bytes");
    }
};

/// TCP connection states (RFC 793 section 3.2)
/// Full state machine for proper connection teardown
pub const TcpState = enum(u8) {
    /// No connection
    Closed = 0,
    /// Waiting for connection request (passive open)
    Listen = 1,
    /// SYN sent, waiting for SYN-ACK (active open)
    SynSent = 2,
    /// SYN received, SYN-ACK sent, waiting for ACK
    SynReceived = 3,
    /// Connection open, data transfer
    Established = 4,
    /// FIN sent, waiting for ACK of FIN (active close initiated)
    FinWait1 = 5,
    /// FIN-ACK received, waiting for peer's FIN
    FinWait2 = 6,
    /// Received FIN, waiting for application to close (passive close)
    CloseWait = 7,
    /// Both sides sent FIN simultaneously, waiting for ACKs
    Closing = 8,
    /// FIN sent after CloseWait, waiting for ACK
    LastAck = 9,
    /// Both FINs exchanged, waiting 2*MSL before releasing resources
    TimeWait = 10,
};

/// TCP Control Block - per-connection state
pub const Tcb = struct {
    // Connection identity (4-tuple)
    local_ip: u32,
    local_port: u16,
    remote_ip: u32,
    remote_port: u16,
    
    // Lock protecting this TCB
    mutex: sync.Spinlock,

    // Connection state
    state: TcpState,
    allocated: bool,
    /// Security: Two-phase deletion flag. When true, TCB is being torn down
    /// and should not be used for new packet processing. Prevents use-after-free
    /// in edge cases where lock ordering might be violated.
    closing: bool,

    // Send sequence variables (RFC 793 section 3.2)
    snd_una: u32, // Oldest unacknowledged sequence number
    snd_nxt: u32, // Next sequence number to send
    snd_wnd: u32, // Peer's advertised receive window (scaled)
    iss: u32, // Initial send sequence number

    // Receive sequence variables
    rcv_nxt: u32, // Next expected sequence number
    rcv_wnd: u16, // Our advertised receive window
    irs: u32, // Initial receive sequence number

    // Retransmission state
    rto_ms: u32, // Current retransmission timeout
    retrans_count: u8, // Number of retransmissions
    retrans_timer: u64, // Timer start tick (0 = not running)

    // MSS negotiation
    mss: u16, // Maximum segment size to send

    // QoS/ToS value for outgoing packets
    tos: u8,

    // Window scaling (RFC 7323)
    snd_wscale: u8, // Shift count for peer's window (applied to received SEG.WND)
    rcv_wscale: u8, // Shift count we advertise (applied to our window before sending)
    wscale_ok: bool, // True if both sides negotiated window scaling

    // SACK support (RFC 2018)
    sack_ok: bool, // True if both sides negotiated SACK

    // Timestamps (RFC 7323)
    ts_ok: bool, // True if both sides negotiated timestamps
    ts_recent: u32, // Most recent timestamp received from peer
    ts_val: u32, // Our last sent timestamp value

    // Send buffer (circular)
    send_buf: [c.BUFFER_SIZE]u8,
    send_head: usize, // Write position (next byte to buffer)
    send_tail: usize, // Read position (next byte to send/retransmit)
    send_acked: usize, // Position of oldest unacked byte

    // Receive buffer (circular)
    recv_buf: [c.BUFFER_SIZE]u8,
    recv_head: usize, // Write position
    recv_tail: usize, // Read position (application consumption)

    // Parent socket index (for accept queue linkage)
    parent_socket: ?usize,

    // Thread blocked on this connection (for connect blocking)
    // Set by syscall layer, woken when state changes to Established or Closed
    blocked_thread: ?*anyopaque,

    // Hash chain (for TCB lookup)
    hash_next: ?*Tcb,

    // Connection tracking - timestamp when TCB was created (for state timeouts)
    created_at: u64,

    // Congestion Control (RFC 5681)
    cwnd: u32,       // Congestion Window (bytes)
    ssthresh: u32,   // Slow Start Threshold (bytes)

    // RTT Estimation (Jacobson/Karels)
    srtt: u32,       // Smoothed RTT (scaled by 8)
    rttvar: u32,     // RTT Variation (scaled by 4)
    rtt_seq: u32,    // Sequence number being timed (0 means not timing)
    rtt_start: u64,  // Timestamp when rtt_seq was sent (ticks)

    const Self = @This();

    pub fn init() Self {
        return Self{
            .local_ip = 0,
            .local_port = 0,
            .remote_ip = 0,
            .remote_port = 0,
            .mutex = .{},
            .state = .Closed,
            .allocated = false,
            .closing = false,
            .snd_una = 0,
            .snd_nxt = 0,
            .snd_wnd = 0,
            .iss = 0,
            .rcv_nxt = 0,
            .rcv_wnd = c.RECV_WINDOW_SIZE,
            .irs = 0,
            .rto_ms = c.INITIAL_RTO_MS,
            .retrans_count = 0,
            .retrans_timer = 0,
            .mss = c.DEFAULT_MSS,
            .tos = 0,
            // Window scaling - default to no scaling
            .snd_wscale = 0,
            .rcv_wscale = 0,
            .wscale_ok = false,
            // SACK
            .sack_ok = false,
            // Timestamps
            .ts_ok = false,
            .ts_recent = 0,
            .ts_val = 0,
            .send_buf = [_]u8{0} ** c.BUFFER_SIZE,
            .send_head = 0,
            .send_tail = 0,
            .send_acked = 0,
            .recv_buf = [_]u8{0} ** c.BUFFER_SIZE,
            .recv_head = 0,
            .recv_tail = 0,
            .parent_socket = null,
            .blocked_thread = null,
            .hash_next = null,
            .created_at = 0, // Set when allocated
            // Congestion Control default: 2 MSS (conservative start)
            .cwnd = c.DEFAULT_MSS * 2,
            .ssthresh = 65535,
            // RTT defaults
            .srtt = 0,
            .rttvar = 750 << 2, // Initial deviation estimate (3 sec / 4) -> 750ms
            .rtt_seq = 0,
            .rtt_start = 0,
        };
    }

    /// Update RTT estimation (Jacobson/Karels)
    /// rtt_sample: Measured RTT in milliseconds
    pub fn updateRto(self: *Self, rtt_sample: u32) void {
        if (self.srtt == 0) {
            // First measurement
            self.srtt = rtt_sample << 3; // Shift by 3 (scaled by 8)
            self.rttvar = (rtt_sample / 2) << 2; // Shift by 2 (scaled by 4)
        } else {
            // Update RTTVAR
            // RTTVAR = (1 - beta) * RTTVAR + beta * |SRTT - R'|
            // beta = 1/4
            const srtt_val = self.srtt >> 3;
            const diff = if (rtt_sample > srtt_val)
                rtt_sample - srtt_val
            else
                srtt_val - rtt_sample;

            self.rttvar = extractRttVar(self.rttvar, diff);

            // Update SRTT
            // SRTT = (1 - alpha) * SRTT + alpha * R'
            // alpha = 1/8
            self.srtt = extractSrtt(self.srtt, rtt_sample);
        }

        // RTO = SRTT + 4 * RTTVAR
        const rto = (self.srtt >> 3) + (self.rttvar); // rttvar is already 4*var

        // Clamp RTO
        self.rto_ms = @max(1000, @min(rto, c.MAX_RTO_MS));
    }

    fn extractRttVar(old_var: u32, diff: u32) u32 {
        // (3 * old_var + diff) / 4 -> handled by scaled math
        // OldVar is scaled by 4
        // We want: var_new = (3/4)*var_old + (1/4)*diff
        // var_new_scaled = 4 * ((3/4)*(var_old_scaled/4) + (1/4)*diff)
        // This math is messy in comments, simplified:
        // NewVar = OldVar - (OldVar >> 2) + diff
        return old_var - (old_var >> 2) + diff;
    }

    fn extractSrtt(old_srtt: u32, sample: u32) u32 {
        // (7 * old_srtt + sample) / 8
        // OldSrtt is scaled by 8
        // NewSrtt = OldSrtt - (OldSrtt >> 3) + sample
        return old_srtt - (old_srtt >> 3) + sample;
    }

    /// Reset TCB to initial state
    pub fn reset(self: *Self) void {
        self.* = Self.init();
    }

    /// Calculate bytes available in send buffer
    pub fn sendBufferSpace(self: *const Self) usize {
        if (self.send_head >= self.send_tail) {
            return c.BUFFER_SIZE - (self.send_head - self.send_tail) - 1;
        } else {
            return self.send_tail - self.send_head - 1;
        }
    }

    /// Calculate bytes available to read from receive buffer
    pub fn recvBufferAvailable(self: *const Self) usize {
        if (self.recv_head >= self.recv_tail) {
            return self.recv_head - self.recv_tail;
        } else {
            return c.BUFFER_SIZE - self.recv_tail + self.recv_head;
        }
    }

    /// Check if there is data in the receive buffer available to be read
    pub fn hasRecvData(self: *const Self) bool {
        return self.recvBufferAvailable() > 0;
    }

    /// Check if there is space in the send buffer
    pub fn hasSendBufferSpace(self: *const Self) bool {
        return self.sendBufferSpace() > 0;
    }

    /// Calculate current receive window (space in recv buffer)
    /// When window scaling is negotiated (RFC 7323), the advertised window
    /// must be right-shifted by our scale factor before sending in TCP header.
    pub fn currentRecvWindow(self: *const Self) u16 {
        const space = c.BUFFER_SIZE - self.recvBufferAvailable();
        // Apply window scaling - peer will left-shift by rcv_wscale
        const scaled = if (self.wscale_ok)
            space >> @intCast(self.rcv_wscale)
        else
            space;
        return @intCast(@min(scaled, 65535));
    }
};

// Sequence number arithmetic (RFC 793 section 3.3)

/// Sequence number less than (handles 32-bit wraparound)
pub fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// Sequence number less than or equal
pub fn seqLte(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) <= 0;
}

/// Sequence number greater than
pub fn seqGt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

/// Sequence number greater than or equal
pub fn seqGte(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

/// Check if seq is in range [low, high)
pub fn seqBetween(seq: u32, low: u32, high: u32) bool {
    return seqGte(seq, low) and seqLt(seq, high);
}
