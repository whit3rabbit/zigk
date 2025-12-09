// TCP protocol constants and defaults.
// Maintains documentation from the monolithic tcp.zig for easier navigation.

/// TCP header size (20 bytes without options)
pub const TCP_HEADER_SIZE: usize = 20;

/// Maximum TCP payload (MTU - IP header - TCP header)
pub const MAX_TCP_PAYLOAD: usize = 1500 - @import("../../core/packet.zig").IP_HEADER_SIZE - TCP_HEADER_SIZE;

/// Default MSS (Maximum Segment Size) for Ethernet
pub const DEFAULT_MSS: u16 = 1460;

/// Minimum MSS per RFC 793 (must accept 536-byte segments)
pub const MIN_MSS: u16 = 536;

/// TCP option kinds
pub const TCPOPT_EOL: u8 = 0; // End of option list
pub const TCPOPT_NOP: u8 = 1; // No-operation (padding)
pub const TCPOPT_MSS: u8 = 2; // Maximum segment size
pub const TCPOPT_WINDOW: u8 = 3; // Window scale (RFC 7323)
pub const TCPOPT_SACK_PERM: u8 = 4; // SACK permitted (RFC 2018)
pub const TCPOPT_SACK: u8 = 5; // SACK block (RFC 2018)
pub const TCPOPT_TIMESTAMP: u8 = 8; // Timestamp (RFC 7323)

/// TCP option lengths
pub const TCPOLEN_MSS: u8 = 4;
pub const TCPOLEN_WINDOW: u8 = 3;
pub const TCPOLEN_SACK_PERM: u8 = 2;
pub const TCPOLEN_TIMESTAMP: u8 = 10;

/// Maximum window scale (RFC 7323: shift count 0-14)
pub const TCP_MAX_WSCALE: u8 = 14;

/// Maximum TCP options size (TCP header is 20-60 bytes, 40 bytes for options)
pub const TCP_MAX_OPTIONS_SIZE: usize = 40;

/// Fixed receive window size (8KB for MVP)
pub const RECV_WINDOW_SIZE: u16 = 8192;

/// Send/receive buffer sizes
pub const BUFFER_SIZE: usize = 8192;

/// Initial RTO (Retransmission Timeout) in milliseconds
pub const INITIAL_RTO_MS: u32 = 1000;

/// Maximum RTO after backoff (64 seconds)
pub const MAX_RTO_MS: u32 = 64000;

/// Maximum retransmission attempts before connection reset
pub const MAX_RETRIES: u8 = 8;

/// Connection hash table size (must be power of 2)
pub const TCB_HASH_SIZE: usize = 64;

/// Maximum number of TCBs (connections)
pub const MAX_TCBS: usize = 256;

/// Maximum half-open connections (SYN-RECEIVED state) to prevent SYN flood
pub const MAX_HALF_OPEN: usize = 128;

/// State timeout values in milliseconds (connections exceeding these are GC'd)
pub const STATE_TIMEOUT_MS = struct {
    syn_sent: u64 = 75_000, // 75 seconds (15s * 5 retries)
    syn_recv: u64 = 75_000, // 75 seconds
    established: u64 = 7_200_000, // 2 hours (TCP keepalive interval)
    close_wait: u64 = 60_000, // 60 seconds (app should close promptly)
    last_ack: u64 = 60_000, // 60 seconds
    listen: u64 = 0, // No timeout for listening sockets
    closed: u64 = 0, // Already closed
};
