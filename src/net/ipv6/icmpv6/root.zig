// ICMPv6 Protocol Implementation
//
// Implements RFC 4443 (ICMPv6)
//
// Message types implemented:
// - Echo Request (128) / Echo Reply (129)
// - Destination Unreachable (1)
// - Packet Too Big (2) - for PMTUD
// - Time Exceeded (3)
// - Parameter Problem (4)
//
// NDP messages (133-137) are delegated to the ndp module.

pub const types = @import("types.zig");
pub const process = @import("process.zig");
pub const transmit = @import("transmit.zig");

// Re-export main functions
pub const processPacket = process.processPacket;
pub const sendEchoRequest = transmit.sendEchoRequest;
pub const sendEchoReply = transmit.sendEchoReply;
pub const sendDestUnreachable = transmit.sendDestUnreachable;
pub const sendPacketTooBig = transmit.sendPacketTooBig;
pub const sendTimeExceeded = transmit.sendTimeExceeded;
pub const sendParamProblem = transmit.sendParamProblem;

// Re-export types
pub const Icmpv6Header = types.Icmpv6Header;
pub const Icmpv6EchoHeader = types.Icmpv6EchoHeader;
pub const ICMPV6_HEADER_SIZE = types.ICMPV6_HEADER_SIZE;

// Re-export message type constants
pub const TYPE_DEST_UNREACHABLE = types.TYPE_DEST_UNREACHABLE;
pub const TYPE_PACKET_TOO_BIG = types.TYPE_PACKET_TOO_BIG;
pub const TYPE_TIME_EXCEEDED = types.TYPE_TIME_EXCEEDED;
pub const TYPE_PARAM_PROBLEM = types.TYPE_PARAM_PROBLEM;
pub const TYPE_ECHO_REQUEST = types.TYPE_ECHO_REQUEST;
pub const TYPE_ECHO_REPLY = types.TYPE_ECHO_REPLY;

// NDP message types (handled by ndp module)
pub const TYPE_ROUTER_SOLICITATION = types.TYPE_ROUTER_SOLICITATION;
pub const TYPE_ROUTER_ADVERTISEMENT = types.TYPE_ROUTER_ADVERTISEMENT;
pub const TYPE_NEIGHBOR_SOLICITATION = types.TYPE_NEIGHBOR_SOLICITATION;
pub const TYPE_NEIGHBOR_ADVERTISEMENT = types.TYPE_NEIGHBOR_ADVERTISEMENT;
pub const TYPE_REDIRECT = types.TYPE_REDIRECT;

// Destination Unreachable codes
pub const CODE_NO_ROUTE = types.CODE_NO_ROUTE;
pub const CODE_ADMIN_PROHIBITED = types.CODE_ADMIN_PROHIBITED;
pub const CODE_BEYOND_SCOPE = types.CODE_BEYOND_SCOPE;
pub const CODE_ADDR_UNREACHABLE = types.CODE_ADDR_UNREACHABLE;
pub const CODE_PORT_UNREACHABLE = types.CODE_PORT_UNREACHABLE;
