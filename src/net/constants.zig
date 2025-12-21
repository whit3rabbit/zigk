// Network protocol constants shared across the stack.
// Consolidates header sizes, protocol numbers, ethertypes, and TCP defaults.

/// Maximum packet size (MTU + headers)
pub const MAX_PACKET_SIZE: usize = 2048;

/// Ethernet header size
pub const ETH_HEADER_SIZE: usize = 14;
/// IPv4 header size (minimum, without options)
pub const IP_HEADER_SIZE: usize = 20;
/// TCP header size (minimum, without options)
pub const TCP_HEADER_SIZE: usize = 20;
/// UDP header size
pub const UDP_HEADER_SIZE: usize = 8;
/// ICMP header size
pub const ICMP_HEADER_SIZE: usize = 8;

/// IP protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// Default TTL for outgoing packets
pub const DEFAULT_TTL: u8 = 64;

/// Minimum transport header sizes for validation
pub const ICMP_HEADER_MIN: usize = 8;
pub const UDP_HEADER_MIN: usize = 8;
pub const TCP_HEADER_MIN: usize = 20;

/// Minimum/maximum IP header size (with options)
pub const IP_HEADER_MIN: usize = 20;
pub const IP_HEADER_MAX: usize = 60;

/// IP option types
pub const IPOPT_EOL: u8 = 0;
pub const IPOPT_NOP: u8 = 1;
pub const IPOPT_SEC: u8 = 130;
pub const IPOPT_RR: u8 = 7;
pub const IPOPT_TS: u8 = 68;
pub const IPOPT_LSRR: u8 = 131;
pub const IPOPT_SSRR: u8 = 137;

/// Ethertype values in host byte order
pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const ETHERTYPE_IPV6: u16 = 0x86DD;

/// TCP protocol constants and defaults
/// Maximum TCP payload (MTU - IP header - TCP header)
pub const MAX_TCP_PAYLOAD: usize = 1500 - IP_HEADER_SIZE - TCP_HEADER_SIZE;

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

/// Delayed ACK timeout (RFC 1122 recommends <= 200ms)
pub const TCP_DELAYED_ACK_MS: u32 = 200;

/// Connection hash table size (must be power of 2)
/// Increased to 1024 to mitigate hash flooding and improve lookup performance
pub const TCB_HASH_SIZE: usize = 1024;

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
