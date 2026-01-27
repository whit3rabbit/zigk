//! QXL Driver Module
//!
//! Exports for the QXL paravirtualized graphics driver.
//! Used in QEMU/KVM with "-vga qxl" option.
//!
//! Supports both framebuffer-only mode and 2D acceleration via command rings.

pub const driver = @import("driver.zig");
pub const hardware = @import("hardware.zig");
pub const rom = @import("rom.zig");
pub const regs = @import("regs.zig");
pub const ram = @import("ram.zig");
pub const drawable = @import("drawable.zig");
pub const commands = @import("commands.zig");

pub const QxlDriver = driver.QxlDriver;
pub const RomParser = rom.RomParser;
pub const ModeInfo = rom.ModeInfo;
pub const IoAccess = regs.IoAccess;
pub const RamManager = ram.RamManager;
pub const DrawablePool = drawable.DrawablePool;
pub const QxlDrawable = drawable.QxlDrawable;
