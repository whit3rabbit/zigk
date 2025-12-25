// AArch64 I/O Port Stubs
//
// AArch64 does not have a separate I/O port address space like x86.
// Devices use MMIO. These stubs are provided for compatibility with
// drivers that expect x86-style port I/O.

pub fn outb(_: u16, _: u8) void {}
pub fn inb(_: u16) u8 { return 0; }
pub fn outw(_: u16, _: u16) void {}
pub fn inw(_: u16) u16 { return 0; }
pub fn outl(_: u16, _: u32) void {}
pub fn inl(_: u16) u32 { return 0; }
