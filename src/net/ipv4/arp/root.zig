const std = @import("std");
pub const cache = @import("cache.zig");
const packet = @import("packet.zig");
const monitor = @import("monitor.zig");

// Re-export types and constants
pub const ArpState = cache.ArpState;
pub const ArpEntry = cache.ArpEntry;
pub const ArpSecurityEvent = monitor.ArpSecurityEvent;

// Re-export public functions
pub const init = cache.init;
pub const tick = monitor.tick;
pub const ageCache = monitor.ageCache;
pub const clearCache = cache.clearCache;
pub const getCacheCount = cache.getCacheCount;
pub const processPacket = packet.processPacket;
pub const resolve = packet.resolve;
pub const resolveOrRequest = packet.resolveOrRequest;
pub const addStaticEntry = cache.addStaticEntry;
pub const removeStaticEntry = cache.removeStaticEntry;
pub const isStaticEntry = cache.isStaticEntry;
pub const getStaticCount = cache.getStaticCount;

// Support legacy constant names if needed
pub const VERIFY_SYNC_TRANSMIT = monitor.VERIFY_SYNC_TRANSMIT;
