const std = @import("std");
const hal = @import("hal");
const pci = @import("pci");
const fd = @import("fd");
const console = @import("console");
const kernel_io = @import("io");
const devfs = @import("devfs");
const types = @import("types.zig");
const init_mod = @import("init.zig");
const ops = @import("ops.zig");
const mixer = @import("mixer.zig");
const regs = @import("regs.zig");

// Export types and constants
pub const Ac97 = types.Ac97;
pub const BDL_ENTRY_COUNT = types.BDL_ENTRY_COUNT;
pub const BUFFER_SIZE = types.BUFFER_SIZE;
pub const Regs = regs;

// Global Instance
var ac97_driver: ?*Ac97 = null;

const idt = hal.idt;

/// IRQ Handler for AC97 buffer completion interrupts.
fn ac97IrqHandler(frame: *const idt.InterruptFrame) void {
    _ = frame;
    if (ac97_driver) |driver| {
        ops.handleInterrupt(driver);
    }
}

// File Ops
fn dspWrite(fd_ctx: *fd.FileDescriptor, buf: []const u8) isize {
    _ = fd_ctx;
    if (ac97_driver) |drv| {
        return ops.write(drv, buf);
    }
    return -1;
}

fn dspIoctl(fd_ctx: *fd.FileDescriptor, cmd: u64, arg: u64) isize {
    _ = fd_ctx;
    if (ac97_driver) |drv| {
        return mixer.ioctl(drv, @truncate(cmd), arg);
    }
    return -1;
}

pub const dsp_ops = fd.FileOps{
    .read = null, // Playback only for now
    .write = dspWrite,
    .close = null,
    .seek = null,
    .stat = null,
    .ioctl = dspIoctl,
    .mmap = null,
    .poll = null,
    .truncate = null,
};

pub fn initFromPci(pci_dev: *const pci.PciDevice, pci_access: pci.PciAccess) !void {
    ac97_driver = try init_mod.init(pci_dev, pci_access);
    if (ac97_driver) |drv| {
        enableAsyncMode(drv);

        // Register /dev/dsp with devfs
        devfs.registerDevice("dsp", &dsp_ops, null) catch |err| {
            console.warn("AC97: Failed to register /dev/dsp: {}", .{err});
        };
    }
}

/// Enable interrupt-driven async mode.
pub fn enableAsyncMode(self: *Ac97) void {
    if (self.irq_enabled) return;

    hal.interrupts.registerHandler(
        @as(u8, self.irq_line) + 32,
        ac97IrqHandler,
    );

    const cr = hal.io.inb(self.nabm_base + regs.NABM_PO_CR);
    hal.io.outb(self.nabm_base + regs.NABM_PO_CR, cr | regs.CR_IOCE);

    self.irq_enabled = true;
    console.info("AC97: Async mode enabled (IRQ {})", .{self.irq_line});
}

/// Get the global AC97 driver instance.
pub fn getDriver() ?*Ac97 {
    return ac97_driver;
}

/// Submit an async audio write via io_uring.
pub fn submitAsyncWrite(request: *kernel_io.IoRequest) bool {
    const driver = ac97_driver orelse return false;
    ops.writeAsync(driver, request);
    return true;
}
