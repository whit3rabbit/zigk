// USB HID Class Driver Package
//
// Re-exports submodules for the HID driver.

pub const types = @import("types.zig");
pub const descriptor = @import("descriptor.zig");
pub const input = @import("input.zig");
pub const driver = @import("driver.zig");

// Re-export core types for compatibility
pub const HidDescriptor = types.HidDescriptor;
pub const HidDriver = driver.HidDriver;
pub const Request = types.Request;
pub const Protocol = types.Protocol;
