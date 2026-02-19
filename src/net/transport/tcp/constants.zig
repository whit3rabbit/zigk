// TCP protocol constants and defaults.
// Re-exported from the shared net/constants.zig to keep protocol constants centralized.

const constants = @import("../../constants.zig");

pub const TCP_HEADER_SIZE: usize = constants.TCP_HEADER_SIZE;
pub const MAX_TCP_PAYLOAD: usize = constants.MAX_TCP_PAYLOAD;
pub const DEFAULT_MSS: u16 = constants.DEFAULT_MSS;
pub const MIN_MSS: u16 = constants.MIN_MSS;

pub const TCPOPT_EOL: u8 = constants.TCPOPT_EOL;
pub const TCPOPT_NOP: u8 = constants.TCPOPT_NOP;
pub const TCPOPT_MSS: u8 = constants.TCPOPT_MSS;
pub const TCPOPT_WINDOW: u8 = constants.TCPOPT_WINDOW;
pub const TCPOPT_SACK_PERM: u8 = constants.TCPOPT_SACK_PERM;
pub const TCPOPT_SACK: u8 = constants.TCPOPT_SACK;
pub const TCPOPT_TIMESTAMP: u8 = constants.TCPOPT_TIMESTAMP;

pub const TCPOLEN_MSS: u8 = constants.TCPOLEN_MSS;
pub const TCPOLEN_WINDOW: u8 = constants.TCPOLEN_WINDOW;
pub const TCPOLEN_SACK_PERM: u8 = constants.TCPOLEN_SACK_PERM;
pub const TCPOLEN_TIMESTAMP: u8 = constants.TCPOLEN_TIMESTAMP;

pub const TCP_MAX_WSCALE: u8 = constants.TCP_MAX_WSCALE;
pub const TCP_MAX_OPTIONS_SIZE: usize = constants.TCP_MAX_OPTIONS_SIZE;
pub const RECV_WINDOW_SIZE: u16 = constants.RECV_WINDOW_SIZE;
pub const BUFFER_SIZE: usize = constants.BUFFER_SIZE;
pub const INITIAL_CWND: u32 = constants.INITIAL_CWND;
pub const MAX_CWND: u32 = constants.MAX_CWND;
pub const INITIAL_RTO_MS: u32 = constants.INITIAL_RTO_MS;
pub const MAX_RTO_MS: u32 = constants.MAX_RTO_MS;
pub const MAX_RETRIES: u8 = constants.MAX_RETRIES;
pub const TCP_DELAYED_ACK_MS: u32 = constants.TCP_DELAYED_ACK_MS;
pub const TCB_HASH_SIZE: usize = constants.TCB_HASH_SIZE;
pub const MAX_TCBS: usize = constants.MAX_TCBS;
pub const MAX_HALF_OPEN: usize = constants.MAX_HALF_OPEN;
pub const STATE_TIMEOUT_MS = constants.STATE_TIMEOUT_MS;
