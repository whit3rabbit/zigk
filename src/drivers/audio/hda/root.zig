// Intel HDA Root Module

pub const init_mod = @import("init.zig");
pub const types = @import("types.zig");
pub const regs = @import("regs.zig");

pub const init = init_mod.init;
pub const Hda = types.Hda;
