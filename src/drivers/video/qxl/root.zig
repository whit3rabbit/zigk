//! QXL Driver Module
//!
//! Exports for the QXL paravirtualized graphics driver.
//! Used in QEMU/KVM with "-vga qxl" option.

pub const driver = @import("driver.zig");
pub const hardware = @import("hardware.zig");
pub const rom = @import("rom.zig");
pub const regs = @import("regs.zig");

pub const QxlDriver = driver.QxlDriver;
pub const RomParser = rom.RomParser;
pub const ModeInfo = rom.ModeInfo;
pub const IoAccess = regs.IoAccess;
