// mDNS Protocol Constants (RFC 6762)
// Re-exports from dns.zig plus mDNS-specific values

const dns = @import("../dns/dns.zig");

// Re-export DNS constants used by mDNS
pub const TYPE_A = dns.TYPE_A;
pub const TYPE_AAAA = dns.TYPE_AAAA;
pub const TYPE_PTR = dns.TYPE_PTR;
pub const TYPE_SRV = dns.TYPE_SRV;
pub const TYPE_TXT = dns.TYPE_TXT;
pub const TYPE_ANY = dns.TYPE_ANY;
pub const CLASS_IN = dns.CLASS_IN;

// mDNS-specific constants (from dns.zig)
pub const MDNS_PORT = dns.MDNS_PORT;
pub const MDNS_MULTICAST_IPV4 = dns.MDNS_MULTICAST_IPV4;
pub const MDNS_MULTICAST_IPV6 = dns.MDNS_MULTICAST_IPV6;
pub const MDNS_TTL = dns.MDNS_TTL;
pub const MDNS_CACHE_FLUSH_BIT = dns.MDNS_CACHE_FLUSH_BIT;
pub const MDNS_DEFAULT_TTL = dns.MDNS_DEFAULT_TTL;
pub const MDNS_HOST_TTL = dns.MDNS_HOST_TTL;
pub const MDNS_SERVICE_TTL = dns.MDNS_SERVICE_TTL;
pub const FLAGS_MDNS_RESPONSE = dns.FLAGS_MDNS_RESPONSE;

// mDNS Responder State
pub const ResponderState = enum {
    /// Initial state: sending probe queries
    probing,
    /// After probing: sending announcements
    announcing,
    /// Normal operation: responding to queries
    running,
    /// Conflict detected: need to choose new name
    conflict,
};

// mDNS Timing Constants (RFC 6762)
pub const PROBE_WAIT_MS: u32 = 250; // Time between probe queries
pub const PROBE_COUNT: u8 = 3; // Number of probes before claiming
pub const ANNOUNCE_WAIT_MS: u32 = 1000; // Time between announcements
pub const ANNOUNCE_COUNT: u8 = 2; // Number of announcements after probing

// mDNS Limits
pub const MAX_HOSTNAME_LEN: usize = 64;
pub const MAX_SERVICE_NAME_LEN: usize = 64;
pub const MAX_SERVICE_TYPE_LEN: usize = 32;
pub const MAX_TXT_LEN: usize = 256;
pub const MAX_SERVICES: usize = 16;
pub const MAX_CACHE_ENTRIES: usize = 256;

// Cache hash table size
pub const CACHE_HASH_SIZE: usize = 256;

// Multicast MAC addresses
pub const MDNS_MAC_IPV4: [6]u8 = .{ 0x01, 0x00, 0x5E, 0x00, 0x00, 0xFB };
pub const MDNS_MAC_IPV6: [6]u8 = .{ 0x33, 0x33, 0x00, 0x00, 0x00, 0xFB };

// Rate limiting constants (RFC 6762 Section 6)
// Prevents mDNS from being used in amplification attacks
pub const RATE_LIMIT_TOKENS_MAX: u8 = 10; // Maximum responses per replenish period
pub const RATE_LIMIT_REPLENISH_TICKS: u64 = 100; // Replenish interval (~1 second at 100Hz)
