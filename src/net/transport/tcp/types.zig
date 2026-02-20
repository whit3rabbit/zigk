const c = @import("constants.zig");
const sync = @import("sync");
const addr_mod = @import("../../core/addr.zig");
pub const IpAddr = addr_mod.IpAddr;

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

pub const SackBlock = struct {
    start: u32,
    end: u32,
};

pub const OooBlock = struct {
    start: u32,
    len: u16,
    data: [c.MAX_TCP_PAYLOAD]u8,
};

/// TCP Control Block - per-connection state
pub const Tcb = struct {
    // Connection identity (4-tuple) - supports IPv4 and IPv6
    local_addr: IpAddr,
    local_port: u16,
    remote_addr: IpAddr,
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
    
    // Window update tracking (RFC 793)
    snd_wl1: u32, // Sequence number of last window update
    snd_wl2: u32, // Ack number of last window update

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
    sack_blocks: [4]SackBlock,
    sack_block_count: u8,
    rcv_sack_blocks: [4]SackBlock,
    rcv_sack_block_count: u8,
    ooo_blocks: [4]OooBlock,
    ooo_count: u8,

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

    // Half-open list (for O(1) SYN flood eviction)
    // Intrusive doubly-linked list of TCBs in SYN-RECEIVED state
    half_open_next: ?*Tcb,
    half_open_prev: ?*Tcb,

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

    // Fast retransmit/recovery (RFC 6582)
    last_ack: u32,
    dup_ack_count: u8,
    fast_recovery: bool,
    recover: u32,

    // Delayed ACK (RFC 1122)
    ack_pending: bool,
    ack_due: u64,

    // Nagle (RFC 896)
    nodelay: bool,

    // Buffer size caps (SO_RCVBUF / SO_SNDBUF via setsockopt)
    // 0 means use c.BUFFER_SIZE (physical buffer size)
    rcv_buf_size: u32,
    snd_buf_size: u32,

    // TCP_CORK: hold sub-MSS segments until full MSS or cork cleared
    tcp_cork: bool,

    // Persist timer (RFC 1122 S4.2.2.17) -- separate from retransmit timer
    persist_timer: u64,    // Ticks accumulated since persist timer armed (0 = not running)
    persist_backoff: u8,   // Exponential backoff level (0-6, capped so interval <= 60s)

    // Generation counter for UAF protection (checked by connect())
    // Incremented on allocation to distinguish reused TCB memory
    generation: u64,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .local_addr = .none,
            .local_port = 0,
            .remote_addr = .none,
            .remote_port = 0,
            .mutex = .{},
            .state = .Closed,
            .allocated = false,
            .closing = false,
            .snd_una = 0,
            .snd_nxt = 0,
            .snd_wnd = 0,
            .iss = 0,
            .snd_wl1 = 0,
            .snd_wl2 = 0,
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
            .sack_blocks = [_]SackBlock{.{ .start = 0, .end = 0 }} ** 4,
            .sack_block_count = 0,
            .rcv_sack_blocks = [_]SackBlock{.{ .start = 0, .end = 0 }} ** 4,
            .rcv_sack_block_count = 0,
            .ooo_blocks = [_]OooBlock{.{ .start = 0, .len = 0, .data = [_]u8{0} ** c.MAX_TCP_PAYLOAD }} ** 4,
            .ooo_count = 0,
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
            .half_open_next = null,
            .half_open_prev = null,
            .created_at = 0, // Set when allocated
            // Congestion Control: IW10 per RFC 6928
            .cwnd = c.INITIAL_CWND,
            .ssthresh = 65535,
            // RTT defaults
            .srtt = 0,
            .rttvar = 750 << 2, // Initial deviation estimate (3 sec / 4) -> 750ms
            .rtt_seq = 0,
            .rtt_start = 0,
            .last_ack = 0,
            .dup_ack_count = 0,
            .fast_recovery = false,
            .recover = 0,
            .ack_pending = false,
            .ack_due = 0,
            .nodelay = false,
            .rcv_buf_size = 0,
            .snd_buf_size = 0,
            .tcp_cork = false,
            .persist_timer = 0,
            .persist_backoff = 0,
            .generation = 0,
        };
    }

    /// Update RTT estimation (Jacobson/Karels)
    /// rtt_sample: Measured RTT in milliseconds
    pub fn updateRto(self: *Self, rtt_sample: u32) void {
        if (self.srtt == 0) {
            // First measurement
            self.srtt = @as(u32, @truncate(@as(u64, rtt_sample) << 3)); // Shift by 3 (scaled by 8)
            self.rttvar = @as(u32, @truncate(@as(u64, rtt_sample / 2) << 2)); // Shift by 2 (scaled by 4)
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

    /// Get local IPv4 address (returns 0 if not IPv4)
    pub fn getLocalIpV4(self: *const Self) u32 {
        return switch (self.local_addr) {
            .v4 => |ip| ip,
            else => 0,
        };
    }

    /// Get remote IPv4 address (returns 0 if not IPv4)
    pub fn getRemoteIpV4(self: *const Self) u32 {
        return switch (self.remote_addr) {
            .v4 => |ip| ip,
            else => 0,
        };
    }

    /// Check if this is an IPv4 connection
    pub fn isIpv4(self: *const Self) bool {
        return self.local_addr.isV4() and self.remote_addr.isV4();
    }

    /// Check if this is an IPv6 connection
    pub fn isIpv6(self: *const Self) bool {
        return self.local_addr.isV6() and self.remote_addr.isV6();
    }

    /// Effective send buffer limit (capped by snd_buf_size if set via SO_SNDBUF)
    pub fn sendBufferLimit(self: *const Self) usize {
        return if (self.snd_buf_size == 0)
            c.BUFFER_SIZE
        else
            @min(@as(usize, self.snd_buf_size), c.BUFFER_SIZE);
    }

    /// Calculate bytes available in send buffer
    /// Respects snd_buf_size cap from SO_SNDBUF while preserving circular buffer invariant.
    pub fn sendBufferSpace(self: *const Self) usize {
        const limit = self.sendBufferLimit();
        const used = if (self.send_head >= self.send_tail)
            self.send_head - self.send_tail
        else
            c.BUFFER_SIZE - self.send_tail + self.send_head;
        // Preserve sentinel slot (used + 1 >= limit) to prevent head==tail ambiguity
        return if (used + 1 >= limit) 0 else limit - used - 1;
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
        // Effective buffer is capped by rcv_buf_size if set (SO_RCVBUF).
        // CRITICAL: sws_floor must use effective_buf not c.BUFFER_SIZE.
        // If rcv_buf_size is small (e.g., 1024), a floor of BUFFER_SIZE/2
        // would exceed the cap and always produce window=0.
        const effective_buf: usize = if (self.rcv_buf_size == 0)
            c.BUFFER_SIZE
        else
            @min(@as(usize, self.rcv_buf_size), c.BUFFER_SIZE);
        const avail = self.recvBufferAvailable();
        const space = effective_buf - @min(avail, effective_buf);
        // WIN-04: SWS avoidance (RFC 1122 S4.2.3.3)
        // Suppress window advertisement if less than min(rcv_buf/2, MSS) is free.
        // At SYN time the buffer is empty so space == effective_buf which always
        // exceeds the floor -- no risk of advertising 0 in SYN-ACK.
        const sws_floor: usize = @min(effective_buf / 2, @as(usize, self.mss));
        const effective_space: usize = if (space >= sws_floor) space else 0;
        // Apply window scaling (RFC 7323): peer left-shifts by rcv_wscale
        const scaled: usize = if (self.wscale_ok)
            effective_space >> @intCast(self.rcv_wscale)
        else
            effective_space;
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

pub const RxAction = enum {
    Continue,
    FreeTcb,
};
