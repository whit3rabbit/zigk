const builtin = @import("builtin");

pub const interface = @import("interface.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const console = @import("console.zig");
pub const font = @import("font.zig");
pub const virtio_gpu = @import("virtio_gpu.zig");
pub const boot_logo = @import("boot_logo.zig");
pub const logo_font = @import("logo_font.zig");

// SVGA driver supports both architectures:
// - x86_64: Uses I/O port space (traditional VMware)
// - aarch64: Uses MMIO (VMware Fusion on Apple Silicon)
pub const svga = if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) struct {
    pub const driver = @import("svga/driver.zig");
    pub const hardware = @import("svga/hardware.zig");
    pub const caps = @import("svga/caps.zig");
    pub const fifo = @import("svga/fifo.zig");
    pub const cursor = @import("svga/cursor.zig");
    pub const regs = @import("svga/regs.zig");
    pub const svga3d = @import("svga/svga3d.zig");
    pub const svga3d_types = @import("svga/svga3d_types.zig");

    pub const SvgaDriver = driver.SvgaDriver;
    pub const HardwareCursor = cursor.HardwareCursor;
    pub const Capabilities = caps.Capabilities;
    pub const Svga3D = svga3d.Svga3D;
} else struct {
    pub const SvgaDriver = void;
    pub const HardwareCursor = void;
    pub const Capabilities = void;
    pub const Svga3D = void;
};

// BGA driver supports both architectures:
// - x86_64: Uses I/O port space or MMIO
// - aarch64: Uses MMIO only (if BGA is available)
pub const bga = struct {
    pub const driver = @import("bga/driver.zig");
    pub const hardware = @import("bga/hardware.zig");
    pub const regs = @import("bga/regs.zig");

    pub const BgaDriver = driver.BgaDriver;
};

// Convenience type aliases
pub const BufferedFramebufferDriver = framebuffer.BufferedFramebufferDriver;
pub const DirectFramebufferDriver = framebuffer.DirectFramebufferDriver;
pub const VirtioGpuDriver = virtio_gpu.VirtioGpuDriver;
pub const SvgaDriver = if (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64) svga.SvgaDriver else void;
pub const BgaDriver = bga.BgaDriver;
