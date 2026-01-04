// ICMPv6 Types and Constants
//
// Implements RFC 4443 (ICMPv6) message types and structures.
// Also includes NDP (RFC 4861) constants.
//
// References:
// - RFC 4443: Internet Control Message Protocol (ICMPv6) for the IPv6 Specification
// - RFC 4861: Neighbor Discovery for IP version 6 (IPv6)

const std = @import("std");

/// ICMPv6 Header (4 bytes base, variable data follows)
pub const Icmpv6Header = extern struct {
    msg_type: u8,
    code: u8,
    checksum: u16,

    pub fn getChecksum(self: *const Icmpv6Header) u16 {
        return @byteSwap(self.checksum);
    }

    pub fn setChecksum(self: *Icmpv6Header, val: u16) void {
        self.checksum = @byteSwap(val);
    }
};

pub const ICMPV6_HEADER_SIZE: usize = 4;

/// ICMPv6 Echo Header (extends base header with identifier and sequence)
/// RFC 4443 Section 4.1, 4.2
pub const Icmpv6EchoHeader = extern struct {
    msg_type: u8,
    code: u8,
    checksum: u16,
    identifier: u16,
    sequence: u16,

    pub fn getIdentifier(self: *const Icmpv6EchoHeader) u16 {
        return @byteSwap(self.identifier);
    }

    pub fn getSequence(self: *const Icmpv6EchoHeader) u16 {
        return @byteSwap(self.sequence);
    }

    pub fn setIdentifier(self: *Icmpv6EchoHeader, val: u16) void {
        self.identifier = @byteSwap(val);
    }

    pub fn setSequence(self: *Icmpv6EchoHeader, val: u16) void {
        self.sequence = @byteSwap(val);
    }
};

pub const ICMPV6_ECHO_HEADER_SIZE: usize = 8;

/// ICMPv6 Packet Too Big message (RFC 4443 Section 3.2)
pub const Icmpv6PacketTooBig = extern struct {
    msg_type: u8, // TYPE_PACKET_TOO_BIG (2)
    code: u8, // 0
    checksum: u16,
    mtu: u32, // Maximum Transmission Unit

    pub fn getMtu(self: *const Icmpv6PacketTooBig) u32 {
        return @byteSwap(self.mtu);
    }

    pub fn setMtu(self: *Icmpv6PacketTooBig, val: u32) void {
        self.mtu = @byteSwap(val);
    }
};

/// ICMPv6 Parameter Problem (RFC 4443 Section 3.4)
pub const Icmpv6ParamProblem = extern struct {
    msg_type: u8, // TYPE_PARAM_PROBLEM (4)
    code: u8,
    checksum: u16,
    pointer: u32, // Offset to the erroneous field

    pub fn getPointer(self: *const Icmpv6ParamProblem) u32 {
        return @byteSwap(self.pointer);
    }

    pub fn setPointer(self: *Icmpv6ParamProblem, val: u32) void {
        self.pointer = @byteSwap(val);
    }
};

// =============================================================================
// ICMPv6 Error Message Types (0-127)
// =============================================================================

/// Destination Unreachable (RFC 4443 Section 3.1)
pub const TYPE_DEST_UNREACHABLE: u8 = 1;
/// Packet Too Big (RFC 4443 Section 3.2) - Used for PMTUD (RFC 8201)
pub const TYPE_PACKET_TOO_BIG: u8 = 2;
/// Time Exceeded (RFC 4443 Section 3.3)
pub const TYPE_TIME_EXCEEDED: u8 = 3;
/// Parameter Problem (RFC 4443 Section 3.4)
pub const TYPE_PARAM_PROBLEM: u8 = 4;

// =============================================================================
// ICMPv6 Informational Message Types (128-255)
// =============================================================================

/// Echo Request (RFC 4443 Section 4.1)
pub const TYPE_ECHO_REQUEST: u8 = 128;
/// Echo Reply (RFC 4443 Section 4.2)
pub const TYPE_ECHO_REPLY: u8 = 129;

// NDP Message Types (RFC 4861) - Handled by NDP module
/// Router Solicitation (RFC 4861 Section 4.1)
pub const TYPE_ROUTER_SOLICITATION: u8 = 133;
/// Router Advertisement (RFC 4861 Section 4.2)
pub const TYPE_ROUTER_ADVERTISEMENT: u8 = 134;
/// Neighbor Solicitation (RFC 4861 Section 4.3)
pub const TYPE_NEIGHBOR_SOLICITATION: u8 = 135;
/// Neighbor Advertisement (RFC 4861 Section 4.4)
pub const TYPE_NEIGHBOR_ADVERTISEMENT: u8 = 136;
/// Redirect (RFC 4861 Section 4.5)
pub const TYPE_REDIRECT: u8 = 137;

// =============================================================================
// Destination Unreachable Codes
// =============================================================================

/// No route to destination
pub const CODE_NO_ROUTE: u8 = 0;
/// Communication with destination administratively prohibited
pub const CODE_ADMIN_PROHIBITED: u8 = 1;
/// Beyond scope of source address
pub const CODE_BEYOND_SCOPE: u8 = 2;
/// Address unreachable
pub const CODE_ADDR_UNREACHABLE: u8 = 3;
/// Port unreachable
pub const CODE_PORT_UNREACHABLE: u8 = 4;
/// Source address failed ingress/egress policy
pub const CODE_POLICY_FAIL: u8 = 5;
/// Reject route to destination
pub const CODE_REJECT_ROUTE: u8 = 6;

// =============================================================================
// Time Exceeded Codes
// =============================================================================

/// Hop limit exceeded in transit
pub const CODE_HOP_LIMIT_EXCEEDED: u8 = 0;
/// Fragment reassembly time exceeded
pub const CODE_REASSEMBLY_EXCEEDED: u8 = 1;

// =============================================================================
// Parameter Problem Codes
// =============================================================================

/// Erroneous header field encountered
pub const CODE_HEADER_FIELD: u8 = 0;
/// Unrecognized Next Header type encountered
pub const CODE_UNKNOWN_NEXT_HEADER: u8 = 1;
/// Unrecognized IPv6 option encountered
pub const CODE_UNKNOWN_OPTION: u8 = 2;

// =============================================================================
// Security Constants
// =============================================================================

/// Minimum ICMPv6 packet size (header only)
pub const MIN_ICMPV6_SIZE: usize = 4;

/// Maximum Echo data length (limit DoS via large ping)
pub const MAX_ECHO_DATA_SIZE: usize = 1280 - 40 - 8; // IPv6 min MTU - IPv6 header - ICMPv6 echo header

/// Rate limit: max ICMPv6 error messages per second per destination
pub const ICMPV6_ERROR_RATE_LIMIT: u32 = 10;

// =============================================================================
// Helper Functions
// =============================================================================

/// Check if message type is an error message (0-127)
pub fn isErrorMessage(msg_type: u8) bool {
    return msg_type < 128;
}

/// Check if message type is an informational message (128-255)
pub fn isInformationalMessage(msg_type: u8) bool {
    return msg_type >= 128;
}

/// Check if message type is an NDP message
pub fn isNdpMessage(msg_type: u8) bool {
    return msg_type >= TYPE_ROUTER_SOLICITATION and msg_type <= TYPE_REDIRECT;
}
