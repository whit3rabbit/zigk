const constants = @import("../../constants.zig");

/// IP protocol numbers
pub const PROTO_ICMP: u8 = constants.PROTO_ICMP;
pub const PROTO_TCP: u8 = constants.PROTO_TCP;
pub const PROTO_UDP: u8 = constants.PROTO_UDP;

/// Minimum transport header sizes for validation
pub const ICMP_HEADER_MIN: usize = constants.ICMP_HEADER_MIN;
pub const UDP_HEADER_MIN: usize = constants.UDP_HEADER_MIN;
pub const TCP_HEADER_MIN: usize = constants.TCP_HEADER_MIN;

/// Default TTL for outgoing packets
pub const DEFAULT_TTL: u8 = constants.DEFAULT_TTL;

/// Minimum IP header size (without options)
pub const IP_HEADER_MIN: usize = constants.IP_HEADER_MIN;
/// Maximum IP header size (with 40 bytes of options)
pub const IP_HEADER_MAX: usize = constants.IP_HEADER_MAX;

/// IP option types
pub const IPOPT_EOL: u8 = constants.IPOPT_EOL;
pub const IPOPT_NOP: u8 = constants.IPOPT_NOP;
pub const IPOPT_SEC: u8 = constants.IPOPT_SEC;
pub const IPOPT_RR: u8 = constants.IPOPT_RR;
pub const IPOPT_TS: u8 = constants.IPOPT_TS;
pub const IPOPT_LSRR: u8 = constants.IPOPT_LSRR;
pub const IPOPT_SSRR: u8 = constants.IPOPT_SSRR;
