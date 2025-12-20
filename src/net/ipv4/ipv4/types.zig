const std = @import("std");

/// IP protocol numbers
pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

/// Minimum transport header sizes for validation
pub const ICMP_HEADER_MIN: usize = 8;
pub const UDP_HEADER_MIN: usize = 8;
pub const TCP_HEADER_MIN: usize = 20;

/// Default TTL for outgoing packets
pub const DEFAULT_TTL: u8 = 64;

/// Minimum IP header size (without options)
pub const IP_HEADER_MIN: usize = 20;
/// Maximum IP header size (with 40 bytes of options)
pub const IP_HEADER_MAX: usize = 60;

/// IP option types
pub const IPOPT_EOL: u8 = 0;
pub const IPOPT_NOP: u8 = 1;
pub const IPOPT_SEC: u8 = 130;
pub const IPOPT_RR: u8 = 7;
pub const IPOPT_TS: u8 = 68;
pub const IPOPT_LSRR: u8 = 131;
pub const IPOPT_SSRR: u8 = 137;
