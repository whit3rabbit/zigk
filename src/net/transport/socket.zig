// Socket module entrypoint
//
// This file delegates to the refactored submodule structure in transport/socket/
// to maintain API compatibility while using the new split architecture.
//
// Note: zig 0.15+ deprecated `pub usingnamespace`, so we explicitly re-export.

const root = @import("socket/root.zig");

// Sub-modules for syscall handlers that need deeper access
pub const state = @import("socket/state.zig");

// Helpers
pub const htons = root.htons;
pub const htonl = root.htonl;

// Constants and types
pub const AF_INET = root.AF_INET;
pub const AF_INET6 = root.AF_INET6;
pub const SOCK_STREAM = root.SOCK_STREAM;
pub const SOCK_DGRAM = root.SOCK_DGRAM;
pub const SOL_SOCKET = root.SOL_SOCKET;
pub const IPPROTO_IP = root.IPPROTO_IP;
pub const IPPROTO_TCP = root.IPPROTO_TCP;
pub const IPPROTO_IPV6 = root.IPPROTO_IPV6;
pub const SO_REUSEADDR = root.SO_REUSEADDR;
pub const SO_BROADCAST = root.SO_BROADCAST;
pub const SO_RCVTIMEO = root.SO_RCVTIMEO;
pub const SO_SNDTIMEO = root.SO_SNDTIMEO;
pub const IP_TOS = root.IP_TOS;
pub const IP_TTL = root.IP_TTL;
pub const IP_ADD_MEMBERSHIP = root.IP_ADD_MEMBERSHIP;
pub const IP_DROP_MEMBERSHIP = root.IP_DROP_MEMBERSHIP;
pub const IP_MULTICAST_IF = root.IP_MULTICAST_IF;
pub const IP_MULTICAST_TTL = root.IP_MULTICAST_TTL;
pub const IP_RECVTOS = root.IP_RECVTOS;
pub const IPV6_JOIN_GROUP = root.IPV6_JOIN_GROUP;
pub const IPV6_LEAVE_GROUP = root.IPV6_LEAVE_GROUP;
pub const IPV6_MULTICAST_HOPS = root.IPV6_MULTICAST_HOPS;
pub const SHUT_RD = root.SHUT_RD;
pub const SHUT_WR = root.SHUT_WR;
pub const SHUT_RDWR = root.SHUT_RDWR;

pub const IpMreq = root.IpMreq;
pub const Ipv6Mreq = root.Ipv6Mreq;
pub const TimeVal = root.TimeVal;
pub const SockAddrIn = root.SockAddrIn;
pub const SockAddrIn6 = root.SockAddrIn6;
pub const SockAddr = root.SockAddr;
pub const Socket = root.Socket;
pub const IpAddr = root.IpAddr;

// Scheduler hooks
pub const ThreadPtr = root.ThreadPtr;
pub const WakeFn = root.WakeFn;
pub const BlockFn = root.BlockFn;
pub const GetCurrentThreadFn = root.GetCurrentThreadFn;
pub const setSchedulerFunctions = root.setSchedulerFunctions;
pub const wakeThread = root.wakeThread;

// State management
pub const setLock = root.setLock;
pub const init = root.init;
pub const getSocket = root.getSocket;
pub const acquireSocket = root.acquireSocket;
pub const releaseSocket = root.releaseSocket;
pub const findByPort = root.findByPort;

// Lifecycle
pub const socket = root.socket;
pub const bind = root.bind;
pub const bind6 = root.bind6;
pub const close = root.close;

// UDP path
pub const sendto = root.sendto;
pub const sendto6 = root.sendto6;
pub const recvfrom = root.recvfrom;
pub const recvfromIp = root.recvfromIp;
pub const deliverUdpPacket = root.deliverUdpPacket;
pub const deliverUdpPacket6 = root.deliverUdpPacket6;

// TCP path
pub const listen = root.listen;
pub const accept = root.accept;
pub const connect = root.connect;
pub const getTcb = root.getTcb;
pub const checkConnectStatus = root.checkConnectStatus;
pub const queueAcceptConnection = root.queueAcceptConnection;
pub const tcpSend = root.tcpSend;
pub const tcpRecv = root.tcpRecv;

// TCP async path (Phase 2)
pub const acceptAsync = root.acceptAsync;
pub const recvAsync = root.recvAsync;
pub const sendAsync = root.sendAsync;
pub const connectAsync = root.connectAsync;
pub const completePendingAccept = root.completePendingAccept;
pub const completePendingRecv = root.completePendingRecv;
pub const completePendingConnect = root.completePendingConnect;
pub const completePendingSend = root.completePendingSend;

// Options
pub const setsockopt = root.setsockopt;
pub const getsockopt = root.getsockopt;
pub const getRecvTimeout = root.getRecvTimeout;
pub const getSendTimeout = root.getSendTimeout;

// Polling
pub const checkPollEvents = root.checkPollEvents;

// Misc control
pub const shutdown = root.shutdown;
pub const getsockname = root.getsockname;
pub const getpeername = root.getpeername;

// Errors
pub const SocketError = root.SocketError;
pub const errorToErrno = root.errorToErrno;
