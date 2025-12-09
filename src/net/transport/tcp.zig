
// TCP module entrypoint
const root = @import("tcp/root.zig");

// Constants and Types
pub const MAX_TCP_PAYLOAD = root.MAX_TCP_PAYLOAD;
pub const TcpHeader = root.TcpHeader;
pub const Tcb = root.Tcb;
pub const TcpState = root.TcpState;

// Functions
pub const setLock = root.setLock;
pub const init = root.init;
pub const tcpChecksum = root.tcpChecksum;
pub const processPacket = root.processPacket;
pub const listen = root.listen;
pub const connect = root.connect;
pub const close = root.close;
pub const sendFinPacket = root.sendFinPacket;
pub const send = root.send;
pub const recv = root.recv;
pub const processTimers = root.processTimers;
pub const handleIcmpError = root.handleIcmpError;
pub const TcpError = root.TcpError;
pub const errorToErrno = root.errorToErrno;

// Re-export BUFFER_SIZE just in case
pub const BUFFER_SIZE = root.BUFFER_SIZE;
