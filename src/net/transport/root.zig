// Transport Layer Module
//
// Re-exports ICMP, UDP, TCP, and Socket types and functions.

pub const icmp = @import("icmp.zig");
pub const udp = @import("udp.zig");
pub const tcp = @import("tcp.zig");
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

// Re-export TCP items
pub const TcpHeader = tcp.TcpHeader;
pub const TcpState = tcp.TcpState;
pub const Tcb = tcp.Tcb;
pub const TcpError = tcp.TcpError;
pub const tcpChecksum = tcp.tcpChecksum;
pub const initTcp = tcp.init;
pub const tcpProcessTimers = tcp.processTimers;

// Re-export Socket items
pub const Socket = socket.Socket;
pub const SockAddrIn = socket.SockAddrIn;
pub const SockAddr = socket.SockAddr;
pub const SocketError = socket.SocketError;
pub const TimeVal = socket.TimeVal;
pub const AF_INET = socket.AF_INET;
pub const SOCK_DGRAM = socket.SOCK_DGRAM;
pub const SOCK_STREAM = socket.SOCK_STREAM;
pub const initSockets = socket.init;
pub const deliverUdpPacket = socket.deliverUdpPacket;

// Socket option constants
pub const SOL_SOCKET = socket.SOL_SOCKET;
pub const IPPROTO_IP = socket.IPPROTO_IP;
pub const IPPROTO_TCP = socket.IPPROTO_TCP;
pub const SO_RCVTIMEO = socket.SO_RCVTIMEO;
pub const SO_SNDTIMEO = socket.SO_SNDTIMEO;
pub const SO_BROADCAST = socket.SO_BROADCAST;
pub const SO_REUSEADDR = socket.SO_REUSEADDR;
pub const IP_TOS = socket.IP_TOS;
pub const IP_TTL = socket.IP_TTL;

// Socket option functions
pub const setsockopt = socket.setsockopt;
pub const getsockopt = socket.getsockopt;
pub const getRecvTimeout = socket.getRecvTimeout;
pub const getSendTimeout = socket.getSendTimeout;

// TCP socket operations
pub const socketListen = socket.listen;
pub const socketAccept = socket.accept;
pub const socketConnect = socket.connect;
pub const tcpSend = socket.tcpSend;
pub const tcpRecv = socket.tcpRecv;
pub const queueAcceptConnection = socket.queueAcceptConnection;
