// Neighbor Discovery Protocol Implementation
//
// Implements RFC 4861 (Neighbor Discovery for IPv6)
//
// Message types:
// - Router Solicitation (133)
// - Router Advertisement (134)
// - Neighbor Solicitation (135)
// - Neighbor Advertisement (136)
// - Redirect (137)
//
// Functions:
// - Neighbor cache management
// - Address resolution (like ARP for IPv4)
// - Duplicate Address Detection (DAD)
// - Router discovery

pub const types = @import("types.zig");
pub const cache = @import("cache.zig");
pub const process = @import("process.zig");
pub const transmit = @import("transmit.zig");

// Re-export types
pub const NeighborState = types.NeighborState;
pub const NeighborEntry = types.NeighborEntry;
pub const NeighborSolicitationHeader = types.NeighborSolicitationHeader;
pub const NeighborAdvertisementHeader = types.NeighborAdvertisementHeader;
pub const RouterSolicitationHeader = types.RouterSolicitationHeader;
pub const RouterAdvertisementHeader = types.RouterAdvertisementHeader;
pub const LinkLayerAddressOption = types.LinkLayerAddressOption;
pub const PrefixInfoOption = types.PrefixInfoOption;

// Re-export message type constants
pub const TYPE_ROUTER_SOLICITATION = types.TYPE_ROUTER_SOLICITATION;
pub const TYPE_ROUTER_ADVERTISEMENT = types.TYPE_ROUTER_ADVERTISEMENT;
pub const TYPE_NEIGHBOR_SOLICITATION = types.TYPE_NEIGHBOR_SOLICITATION;
pub const TYPE_NEIGHBOR_ADVERTISEMENT = types.TYPE_NEIGHBOR_ADVERTISEMENT;
pub const TYPE_REDIRECT = types.TYPE_REDIRECT;

// Re-export option type constants
pub const OPT_SOURCE_LINK_ADDR = types.OPT_SOURCE_LINK_ADDR;
pub const OPT_TARGET_LINK_ADDR = types.OPT_TARGET_LINK_ADDR;
pub const OPT_PREFIX_INFO = types.OPT_PREFIX_INFO;
pub const OPT_REDIRECTED_HEADER = types.OPT_REDIRECTED_HEADER;
pub const OPT_MTU = types.OPT_MTU;

// Re-export cache constants
pub const MAX_NEIGHBOR_ENTRIES = cache.MAX_NEIGHBOR_ENTRIES;

// Re-export main functions
pub const processPacket = process.processPacket;
pub const resolveOrRequest = transmit.resolveOrRequest;
pub const sendNeighborSolicitation = transmit.sendNeighborSolicitation;
pub const sendNeighborAdvertisement = transmit.sendNeighborAdvertisement;
pub const sendRouterSolicitation = transmit.sendRouterSolicitation;
pub const performDad = transmit.performDad;

// Re-export cache functions
pub const lookup = cache.lookup;
pub const addStaticEntry = cache.addStaticEntry;
pub const removeStaticEntry = cache.removeStaticEntry;
pub const clearCache = cache.clearCache;
pub const getCacheCount = cache.getCacheCount;
pub const init = cache.init;
pub const tick = cache.tick;

// Re-export helper functions
pub const computeSolicitedNodeMulticast = types.computeSolicitedNodeMulticast;
pub const isSolicitedNodeMulticast = types.isSolicitedNodeMulticast;
pub const requiresHopLimit255 = types.requiresHopLimit255;
