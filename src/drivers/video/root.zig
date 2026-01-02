const builtin = @import("builtin");

pub const interface = @import("interface.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const console = @import("console.zig");
pub const font = @import("font.zig");
pub const virtio_gpu = @import("virtio_gpu.zig");
pub const boot_logo = @import("boot_logo.zig");
pub const logo_font = @import("logo_font.zig");

// SVGA driver is VMware-specific and uses x86 port I/O
pub const svga = if (builtin.cpu.arch == .x86_64) @import("svga/driver.zig") else struct {
    pub const SvgDriver = void;
};

// Convenience type aliases
pub const BufferedFramebufferDriver = framebuffer.BufferedFramebufferDriver;
pub const DirectFramebufferDriver = framebuffer.DirectFramebufferDriver;
pub const VirtioGpuDriver = virtio_gpu.VirtioGpuDriver;
pub const SvgaDriver = if (builtin.cpu.arch == .x86_64) svga.SvgDriver else void;
