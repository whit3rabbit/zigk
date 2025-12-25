const std = @import("std");
const fd = @import("fd");
const ahci = @import("ahci");
const io = @import("io");
const pmm = @import("pmm");
const console = @import("console");
const t = @import("types.zig");

/// Read a single sector using async AHCI I/O (sync-over-async pattern)
pub fn readSector(device_fd: *fd.FileDescriptor, lba: u32, buf: *[512]u8) t.SectorError!void {
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

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
            @import("hal").mmio.memoryBarrier(); // 
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector using async AHCI I/O (sync-over-async pattern)
pub fn writeSector(device_fd: *fd.FileDescriptor, lba: u32, buf: []const u8) t.SectorError!void {
    if (buf.len < 512) return error.IOError;
    const port_num: u5 = @intCast(@intFromPtr(device_fd.private_data) & 0x1F);

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

/// Read a single sector using async AHCI I/O (associated with SFS instance)
pub fn readSectorAsync(self: *t.SFS, lba: u32, buf: []u8) !void {
    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, 1, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, 512);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < 512) return error.IOError;
            @import("hal").mmio.memoryBarrier(); // 
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..512]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write a single sector using async AHCI I/O
pub fn writeSectorAsync(self: *t.SFS, lba: u32, buf: []const u8) !void {
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
pub fn readSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

    const req = io.allocRequest(.disk_read) orelse return error.IOError;
    defer io.freeRequest(req);

    const buf_phys = ahci.adapter.blockReadAsync(self.port_num, lba, sector_count, req) catch return error.IOError;
    defer ahci.adapter.freeDmaBuffer(buf_phys, total_bytes);

    var future = io.Future{ .request = req };
    const result = future.wait();

    switch (result) {
        .success => |bytes| {
            if (bytes < total_bytes) return error.IOError;
            @import("hal").mmio.memoryBarrier(); // 
            ahci.adapter.copyFromDmaBuffer(buf_phys, buf[0..total_bytes]);
        },
        .err => return error.IOError,
        .cancelled => return error.IOError,
        .pending => unreachable,
    }
}

/// Write multiple sectors using async AHCI I/O (batched)
pub fn writeSectorsAsync(self: *t.SFS, lba: u32, sector_count: u16, buf: []const u8) !void {
    if (sector_count == 0) return;
    const total_bytes = @as(usize, sector_count) * 512;
    if (buf.len < total_bytes) return error.IOError;

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
