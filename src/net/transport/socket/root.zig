// Socket module root - re-exports split submodules to keep public API stable.

const types = @import("types.zig");
const state = @import("state.zig");
const scheduler = @import("scheduler.zig");
const lifecycle = @import("lifecycle.zig");
const udp_api = @import("udp_api.zig");
const tcp_api = @import("tcp_api.zig");
const options = @import("options.zig");
const poll_mod = @import("poll.zig");
const control = @import("control.zig");
const errors = @import("errors.zig");

// Helpers
pub const htons = types.htons;
pub const htonl = types.htonl;

// Constants and types
pub const AF_INET = types.AF_INET;
pub const SOCK_STREAM = types.SOCK_STREAM;
pub const SOCK_DGRAM = types.SOCK_DGRAM;
pub const SOL_SOCKET = types.SOL_SOCKET;
pub const IPPROTO_IP = types.IPPROTO_IP;
pub const IPPROTO_TCP = types.IPPROTO_TCP;
pub const SO_REUSEADDR = types.SO_REUSEADDR;
pub const SO_BROADCAST = types.SO_BROADCAST;
pub const SO_RCVTIMEO = types.SO_RCVTIMEO;
pub const SO_SNDTIMEO = types.SO_SNDTIMEO;
pub const IP_TOS = types.IP_TOS;
pub const IP_TTL = types.IP_TTL;
pub const IP_ADD_MEMBERSHIP = types.IP_ADD_MEMBERSHIP;
pub const IP_DROP_MEMBERSHIP = types.IP_DROP_MEMBERSHIP;
pub const IP_MULTICAST_IF = types.IP_MULTICAST_IF;
pub const IP_MULTICAST_TTL = types.IP_MULTICAST_TTL;
pub const IP_RECVTOS = types.IP_RECVTOS;
pub const SHUT_RD = control.SHUT_RD;
pub const SHUT_WR = control.SHUT_WR;
pub const SHUT_RDWR = control.SHUT_RDWR;
pub const IpMreq = types.IpMreq;
pub const TimeVal = types.TimeVal;
pub const SockAddrIn = types.SockAddrIn;
pub const SockAddr = types.SockAddr;
pub const Socket = types.Socket;

// Scheduler hooks
pub const ThreadPtr = scheduler.ThreadPtr;
pub const WakeFn = scheduler.WakeFn;
pub const BlockFn = scheduler.BlockFn;
pub const GetCurrentThreadFn = scheduler.GetCurrentThreadFn;
pub const setSchedulerFunctions = scheduler.setSchedulerFunctions;
pub const wakeThread = scheduler.wakeThread;

// State management
pub const setLock = state.setLock;
pub const init = state.init;
pub const getSocket = state.getSocket;
pub const findByPort = state.findByPort;
pub const allocateEphemeralPort = state.allocateEphemeralPort;
pub const allocateRandomEphemeralPort = state.allocateRandomEphemeralPort;

// Lifecycle
pub const socket = lifecycle.socket;
pub const bind = lifecycle.bind;
pub const close = lifecycle.close;

// UDP path
pub const sendto = udp_api.sendto;
pub const recvfrom = udp_api.recvfrom;
pub const deliverUdpPacket = udp_api.deliverUdpPacket;

// TCP path
pub const listen = tcp_api.listen;
pub const accept = tcp_api.accept;
pub const connect = tcp_api.connect;
pub const getTcb = tcp_api.getTcb;
pub const checkConnectStatus = tcp_api.checkConnectStatus;
pub const queueAcceptConnection = tcp_api.queueAcceptConnection;
pub const tcpSend = tcp_api.tcpSend;
pub const tcpRecv = tcp_api.tcpRecv;

// Options
pub const setsockopt = options.setsockopt;
pub const getsockopt = options.getsockopt;
pub const getRecvTimeout = options.getRecvTimeout;
pub const getSendTimeout = options.getSendTimeout;

// Polling
pub const checkPollEvents = poll_mod.checkPollEvents;

// Misc control
pub const shutdown = control.shutdown;
pub const getsockname = control.getsockname;
pub const getpeername = control.getpeername;

// Errors
pub const SocketError = errors.SocketError;
pub const errorToErrno = errors.errorToErrno;
