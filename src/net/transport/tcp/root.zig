
// TCP Protocol Implementation
//
// RFC 793/9293: Transmission Control Protocol
//
// Provides reliable, ordered, connection-oriented byte stream delivery.
// This is a minimal implementation with:
//   - 7-state machine (CLOSED, LISTEN, SYN-SENT, SYN-RECEIVED, ESTABLISHED, CLOSE-WAIT, LAST-ACK)
//   - Fixed 8KB receive window (no auto-tuning)
//   - Timeout-based retransmission (no fast retransmit)
//   - In-order delivery only (out-of-order segments dropped)
//
// Deferred features: congestion control, SACK, window scaling, TIME-WAIT

const constants = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const checksum = @import("checksum.zig");
const rx = @import("rx.zig");
const api = @import("api.zig");
const timers = @import("timers.zig");
const errors = @import("errors.zig");

// Exposed constants and types
pub const MAX_TCP_PAYLOAD = constants.MAX_TCP_PAYLOAD;
pub const BUFFER_SIZE = constants.BUFFER_SIZE;
pub const TcpHeader = types.TcpHeader;
pub const Tcb = types.Tcb;
pub const TcpState = types.TcpState;

// State/initialization
pub const setLock = state.setLock;
pub const init = state.init;

// Checksum
pub const tcpChecksum = checksum.tcpChecksum;

// Packet processing
pub const processPacket = rx.processPacket;

// Socket API surface
pub const listen = api.listen;
pub const connect = api.connect;
pub const close = api.close;
pub const sendFinPacket = api.sendFinPacket;
pub const send = api.send;
pub const recv = api.recv;

// Timer hooks
pub const processTimers = timers.processTimers;
pub const handleIcmpError = timers.handleIcmpError;

// Errors
pub const TcpError = errors.TcpError;
pub const errorToErrno = errors.errorToErrno;
