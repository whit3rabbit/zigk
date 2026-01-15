const std = @import("std");
const fd = @import("fd");
const ahci = @import("ahci");
const io = @import("io");
const pmm = @import("pmm");
const console = @import("console");
const hal = @import("hal");
const t = @import("types.zig");

/// Check if running on emulator platform (QEMU TCG, unknown hypervisor)
/// On emulators, PCI interrupts may not work correctly, so use sync I/O
fn isEmulatorPlatform() bool {
    const hv = hal.hypervisor.getHypervisor();
    return hv == .qemu_tcg or hv == .unknown;
}

/// Read a single sector - uses sync I/O on emulators (PCI IRQs unreliable),
/// async I/O on real hardware
pub fn readSector(device_fd: *fd.FileDescriptor, lba: u32, buf: *[512]u8) t.SectorError!void {
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

    // On emulators, PCI interrupts may not work - use sync (polling) I/O
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        controller.readSectors(port_num, lba, 1, buf) catch return error.IOError;
        return;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(port_num, lba, 1, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, 512);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            @memset(buf, 0);
            if (bytes < 512) return error.IOError;
            hal.mmio.memoryBarrier();
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector - uses sync I/O on emulators, async on real hardware
pub fn writeSector(device_fd: *fd.FileDescriptor, lba: u32, buf: []const u8) t.SectorError!void {
    if (buf.len < 512) return error.IOError;
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

    // On emulators, PCI interrupts may not work - use sync (polling) I/O
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        // writeSectors expects a mutable slice, but the data won't be modified
        var write_buf: [512]u8 = undefined;
        @memcpy(&write_buf, buf[0..512]);
        controller.writeSectors(port_num, lba, 1, &write_buf) catch return error.IOError;
        return;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = pmm.allocZeroedPages(1) orelse return error.IOError;
    defer pmm.freePages(buf_phys, 1);

    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..512]);
    ahci.adapter.blockWriteAsync(port_num, lba, 1, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Read a single sector (SFS instance method) - uses sync I/O on emulators
pub fn readSectorAsync(self: *t.SFS, lba: u32, buf: []u8) !void {
    // On emulators, use sync I/O
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        controller.readSectors(self.port_num, lba, 1, buf[0..512]) catch return error.IOError;
        return;
    }

    // On real hardware, use async I/O
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, 1, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, 512);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < 512) return error.IOError;
            hal.mmio.memoryBarrier();
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..512]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector (SFS instance method) - uses sync I/O on emulators
pub fn writeSectorAsync(self: *t.SFS, lba: u32, buf: []const u8) !void {
    // On emulators, use sync I/O
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        var write_buf: [512]u8 = undefined;
        @memcpy(&write_buf, buf[0..512]);
        controller.writeSectors(self.port_num, lba, 1, &write_buf) catch return error.IOError;
        return;
    }

    // On real hardware, use async I/O
    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = pmm.allocZeroedPages(1) orelse return error.IOError;
    defer pmm.freePages(buf_phys, 1);

    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..512]);
    ahci.adapter.blockWriteAsync(self.port_num, lba, 1, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Read multiple sectors using async AHCI I/O (batched)
/// On emulators, falls back to sync I/O since PCI interrupts may not work
pub fn readSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    // On emulators, use sync I/O (read sector by sector)
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        var current_lba = lba;
        var offset: usize = 0;
        var remaining = sector_count;
        while (remaining > 0) : ({
            current_lba += 1;
            offset += 512;
            remaining -= 1;
        }) {
            controller.readSectors(self.port_num, current_lba, 1, buf[offset..][0..512]) catch return error.IOError;
        }
        return;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, sector_count, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, total_bytes);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < total_bytes) return error.IOError;
            hal.mmio.memoryBarrier();
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..total_bytes]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write multiple sectors using async AHCI I/O (batched)
/// On emulators, falls back to sync I/O since PCI interrupts may not work
pub fn writeSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []const u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    // On emulators, use sync I/O (write sector by sector)
    if (isEmulatorPlatform()) {
        const controller = ahci.getController() orelse return error.IOError;
        var current_lba = lba;
        var offset: usize = 0;
        var remaining = sector_count;
        var write_buf: [512]u8 = undefined;
        while (remaining > 0) : ({
            current_lba += 1;
            offset += 512;
            remaining -= 1;
        }) {
            @memcpy(&write_buf, buf[offset..][0..512]);
            controller.writeSectors(self.port_num, current_lba, 1, &write_buf) catch return error.IOError;
        }
        return;
    }

    // On real hardware, use async I/O with IRQ completion
    const req = io.allocRequest(.disk_write) orelse return error.IOError;
    defer io.freeRequest(req);

    const pages_needed = (total_bytes + 4095) / 4096;
    const buf_phys = pmm.allocZeroedPages(pages_needed) orelse return error.IOError;
    defer pmm.freePages(buf_phys, pages_needed);

    ahci.adapter.copyToDmaBuffer(buf_phys, buf[0..total_bytes]);
    ahci.adapter.blockWriteAsync(self.port_num, lba, sector_count, buf_phys, req) catch return error.IOError;

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => {},
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

pub fn readDirectoryAsync(self: *t.SFS, buf: []u8) !void {
    const total_bytes = t.ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;
    try readSectorsAsync(self, self.superblock.root_dir_start, t.ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

pub fn writeDirectoryAsync(self: *t.SFS, buf: []const u8) !void {
    const total_bytes = t.ROOT_DIR_BLOCKS * 512;
    if (buf.len < total_bytes) return error.IOError;
    try writeSectorsAsync(self, self.superblock.root_dir_start, t.ROOT_DIR_BLOCKS, buf[0..total_bytes]);
}

pub fn updateSuperblock(self: *t.SFS) !void {
    try writeSector(self.device_fd, 0, std.mem.asBytes(&self.superblock));
}
