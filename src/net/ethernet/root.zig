// Ethernet Module
//
// Re-exports Ethernet frame processing types and functions.

pub const ethernet = @import("ethernet.zig");

// Re-export commonly used items
pub const processFrame = ethernet.processFrame;
pub const buildFrame = ethernet.buildFrame;
pub const sendFrame = ethernet.sendFrame;
pub const macToString = ethernet.macToString;
pub const macEqual = ethernet.macEqual;
pub const isBroadcast = ethernet.isBroadcast;
pub const isMulticast = ethernet.isMulticast;

pub const ETHERTYPE_IPV4 = ethernet.ETHERTYPE_IPV4;
pub const ETHERTYPE_ARP = ethernet.ETHERTYPE_ARP;
pub const BROADCAST_MAC = ethernet.BROADCAST_MAC;
