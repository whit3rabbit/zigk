// TCP Protocol Implementation
//
// Complies with:
// - RFC 793: Transmission Control Protocol
// - RFC 1122: Requirements for Internet Hosts -- Communication Layers
// - RFC 7323: TCP Extensions for High Performance (Window Scaling, Timestamps)
//
// Provides reliable, connection-oriented packet stream delivery.
//
// Architecture:
// - root.zig: Entry point and packet dispatch
// - state.zig: State Machine (RFC 793 event processing)
// - rx.zig: Input processing (Segment arrival)
// - tx.zig: Output processing (Segment transmission)
// - timers.zig: Retransmission and timeouts
// - options.zig: TCP Options parsing/building
//
// Current implementation:
//   - 7-state machine (CLOSED, LISTEN, SYN-SENT, SYN-RECEIVED, ESTABLISHED, CLOSE-WAIT, LAST-ACK)
//   - RFC 7323 window scaling (dynamic receive window)
//   - RFC 6582 fast retransmit/recovery (dup ACK detection)
//   - In-order delivery only (out-of-order segments dropped)

const constants = @import("constants.zig");
const types = @import("types.zig");
const state = @import("state.zig");
const checksum = @import("../../core/checksum.zig");
const rx = @import("rx/root.zig");
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
pub const validateConnectionExists = state.validateConnectionExists;
pub const tick = state.tick;

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
