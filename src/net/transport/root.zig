// Transport Layer Module
//
// Re-exports ICMP, UDP, and Socket types and functions.

pub const icmp = @import("icmp.zig");
pub const udp = @import("udp.zig");
pub const socket = @import("socket.zig");

// Re-export ICMP items
pub const sendEchoRequest = icmp.sendEchoRequest;
pub const sendDestUnreachable = icmp.sendDestUnreachable;
pub const TYPE_ECHO_REQUEST = icmp.TYPE_ECHO_REQUEST;
pub const TYPE_ECHO_REPLY = icmp.TYPE_ECHO_REPLY;
pub const TYPE_DEST_UNREACHABLE = icmp.TYPE_DEST_UNREACHABLE;
pub const CODE_PORT_UNREACHABLE = icmp.CODE_PORT_UNREACHABLE;

// Re-export UDP items
pub const sendDatagram = udp.sendDatagram;
pub const getPayloadLength = udp.getPayloadLength;
pub const MAX_UDP_PAYLOAD = udp.MAX_UDP_PAYLOAD;

// Re-export Socket items
pub const Socket = socket.Socket;
pub const SockAddrIn = socket.SockAddrIn;
pub const SockAddr = socket.SockAddr;
pub const SocketError = socket.SocketError;
pub const AF_INET = socket.AF_INET;
pub const SOCK_DGRAM = socket.SOCK_DGRAM;
pub const SOCK_STREAM = socket.SOCK_STREAM;
pub const initSockets = socket.init;
pub const deliverUdpPacket = socket.deliverUdpPacket;
