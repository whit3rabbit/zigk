// VirtIO-SCSI LUN State Tracking
//
// Tracks discovered SCSI Logical Unit Numbers (LUNs) and their properties.
// Each LUN represents a logical storage device that can be accessed independently.

const std = @import("std");
const command = @import("command.zig");
const config = @import("config.zig");

// ============================================================================
// LUN State
// ============================================================================

/// Discovered SCSI LUN information
pub const ScsiLun = struct {
    /// Target ID (0-255 typically)
    target: u16,

    /// LUN number (0-16383 per SAM-5)
    lun: u32,

    /// Whether this LUN is active and usable
    active: bool,

    /// Block size in bytes (typically 512 or 4096)
    block_size: u32,

    /// Total number of blocks
    total_blocks: u64,

    /// Total capacity in bytes
    capacity_bytes: u64,

    /// SCSI device type from INQUIRY
    device_type: command.DeviceType,

    /// Whether media is removable
    removable: bool,

    /// Vendor identification (8 bytes, space-padded ASCII)
    vendor: [8]u8,

    /// Product identification (16 bytes, space-padded ASCII)
    product: [16]u8,

    /// Product revision level (4 bytes, space-padded ASCII)
    revision: [4]u8,

    /// Index in the controller's LUN array
    index: u8,

    /// Initialize an empty/inactive LUN
    pub fn initInactive(index: u8) ScsiLun {
        return ScsiLun{
            .target = 0,
            .lun = 0,
            .active = false,
            .block_size = 0,
            .total_blocks = 0,
            .capacity_bytes = 0,
            .device_type = .NOT_PRESENT,
            .removable = false,
            .vendor = [_]u8{' '} ** 8,
            .product = [_]u8{' '} ** 16,
            .revision = [_]u8{' '} ** 4,
            .index = index,
        };
    }

    /// Initialize from INQUIRY data
    pub fn initFromInquiry(
        index: u8,
        target: u16,
        lun_num: u32,
        inquiry: *const command.InquiryData,
    ) ScsiLun {
        return ScsiLun{
            .target = target,
            .lun = lun_num,
            .active = inquiry.isPresent(),
            .block_size = 0, // Filled in by READ CAPACITY
            .total_blocks = 0,
            .capacity_bytes = 0,
            .device_type = inquiry.deviceType(),
            .removable = inquiry.isRemovable(),
            .vendor = inquiry.vendor,
            .product = inquiry.product,
            .revision = inquiry.revision,
            .index = index,
        };
    }

    /// Update capacity from READ CAPACITY (10) response
    pub fn updateCapacity10(self: *ScsiLun, cap: *const command.ReadCapacity10Data) void {
        self.block_size = cap.blockSize();
        const last_lba = cap.lastLba();

        // Handle 2TB+ devices that return 0xFFFFFFFF
        if (last_lba == 0xFFFFFFFF) {
            // Need READ CAPACITY (16) for actual size
            self.total_blocks = 0xFFFFFFFF;
            self.capacity_bytes = 0;
        } else {
            // total_blocks = last_lba + 1 (with overflow check)
            self.total_blocks = @as(u64, last_lba) + 1;
            self.capacity_bytes = std.math.mul(u64, self.total_blocks, self.block_size) catch 0;
        }
    }

    /// Update capacity from READ CAPACITY (16) response
    pub fn updateCapacity16(self: *ScsiLun, cap: *const command.ReadCapacity16Data) void {
        self.block_size = cap.blockSize();
        const last_lba = cap.lastLba();

        // total_blocks = last_lba + 1 (with overflow check)
        self.total_blocks = std.math.add(u64, last_lba, 1) catch last_lba;
        self.capacity_bytes = std.math.mul(u64, self.total_blocks, self.block_size) catch 0;
    }

    /// Check if this is a block device (disk)
    pub fn isBlockDevice(self: *const ScsiLun) bool {
        return self.device_type == .DISK or
            self.device_type == .RBC or
            self.device_type == .RAID;
    }

    /// Check if device needs READ CAPACITY (16)
    pub fn needsCapacity16(self: *const ScsiLun) bool {
        return self.total_blocks == 0xFFFFFFFF;
    }

    /// Get capacity in MB
    pub fn capacityMB(self: *const ScsiLun) u64 {
        return self.capacity_bytes / (1024 * 1024);
    }

    /// Get capacity in GB
    pub fn capacityGB(self: *const ScsiLun) u64 {
        return self.capacity_bytes / (1024 * 1024 * 1024);
    }

    /// Get vendor string (trimmed)
    pub fn vendorStr(self: *const ScsiLun) []const u8 {
        return trimAscii(&self.vendor);
    }

    /// Get product string (trimmed)
    pub fn productStr(self: *const ScsiLun) []const u8 {
        return trimAscii(&self.product);
    }

    /// Get revision string (trimmed)
    pub fn revisionStr(self: *const ScsiLun) []const u8 {
        return trimAscii(&self.revision);
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Trim trailing spaces from ASCII string
fn trimAscii(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') {
        end -= 1;
    }
    return s[0..end];
}

/// Format LUN identifier string (e.g., "0:0" for target 0, LUN 0)
pub fn formatLunId(buf: []u8, target: u16, lun: u32) []u8 {
    return std.fmt.bufPrint(buf, "{d}:{d}", .{ target, lun }) catch buf[0..0];
}

/// Generate device name (e.g., "vda", "vdb", ...)
pub fn generateDeviceName(buf: []u8, index: u8) []u8 {
    if (index < 26) {
        // vda through vdz
        return std.fmt.bufPrint(buf, "vd{c}", .{@as(u8, 'a') + index}) catch buf[0..0];
    } else {
        // vdaa, vdab, etc. for index >= 26
        const first = (index / 26) - 1;
        const second = index % 26;
        return std.fmt.bufPrint(buf, "vd{c}{c}", .{
            @as(u8, 'a') + first,
            @as(u8, 'a') + second,
        }) catch buf[0..0];
    }
}
