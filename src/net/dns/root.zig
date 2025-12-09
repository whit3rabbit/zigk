
pub const protocol = @import("dns.zig");
pub const client = @import("client.zig");

// Convenience exports
pub const resolve = client.resolve;
pub const DnsError = client.DnsError;
pub const Header = protocol.Header;
pub const FLAGS_RD = protocol.FLAGS_RD;
