// USB Mass Storage Class (MSC) Driver
//
// Implements Bulk-Only Transport (BOT) for USB storage devices.
// Reference: USB Mass Storage Class - Bulk-Only Transport, Rev 1.0

const std = @import("std");
const console = @import("console");
const usb = @import("../xhci/root.zig"); // Access to generic USB types/transfer
const device = @import("../xhci/device.zig");

// =============================================================================
// Constants and Types
// =============================================================================

pub const CLASS_MSC = 0x08;
pub const SUBCLASS_SCSI = 0x06;
pub const PROTOCOL_BOT = 0x50;

/// Command Block Wrapper (CBW)
/// Sent to Bulk OUT endpoint to initiate a command
pub const CommandBlockWrapper = extern struct {
    signature: u32 = 0x43425355, // "USBC"
    tag: u32,
    transfer_length: u32,
    flags: u8,
    lun: u8,
    cb_length: u8,
    command: [16]u8,

    pub fn init(tag: u32, transfer_len: u32, dir_in: bool, lun: u8, cmd_len: u8, cmd_data: []const u8) CommandBlockWrapper {
        var cbw = CommandBlockWrapper{
            .tag = tag,
            .transfer_length = transfer_len,
            .flags = if (dir_in) 0x80 else 0x00,
            .lun = lun,
            .cb_length = cmd_len,
            .command = [_]u8{0} ** 16,
        };
        @memcpy(cbw.command[0..cmd_len], cmd_data[0..cmd_len]);
        return cbw;
    }
};

/// Command Status Wrapper (CSW)
/// Received from Bulk IN endpoint after data stage
pub const CommandStatusWrapper = extern struct {
    signature: u32, // "USBS" = 0x53425355
    tag: u32,
    data_residue: u32,
    status: u8, // 0=Pass, 1=Fail, 2=Phase Error

    pub const SIGNATURE = 0x53425355;
    
    pub const Status = enum(u8) {
        Passed = 0,
        Failed = 1,
        PhaseError = 2,
    };
};

// =============================================================================
// Driver State
// =============================================================================

pub const MscDriver = struct {
    dev: *device.UsbDevice,
    ctrl: *usb.Controller,
    
    // Bulk Endpoints
    bulk_in_ep: u8,
    bulk_out_ep: u8,
    
    // Command Tag Tracker
    current_tag: u32 = 1,

    // Device Capacity
    sector_count: u32 = 0,
    sector_size: u32 = 0,

    const Self = @This();

    pub fn init(ctrl: *usb.Controller, dev: *device.UsbDevice, ep_in: u8, ep_out: u8) Self {
        return Self{
            .dev = dev,
            .ctrl = ctrl,
            .bulk_in_ep = ep_in,
            .bulk_out_ep = ep_out,
        };
    }

    /// Perform a SCSI Command
    pub fn sendScsiCommand(
        self: *Self,
        lun: u8,
        cmd: []const u8,
        data: ?[]u8,
        dir_in: bool,
    ) !void {
        const tag = self.current_tag;
        self.current_tag +%= 1;

        // Security: Use checked cast instead of truncate to prevent silent overflow
        const data_len: u32 = if (data) |d| std.math.cast(u32, d.len) orelse return error.BufferTooLarge else 0;

        // Security: Validate command length (SCSI commands are max 16 bytes)
        if (cmd.len > 16) return error.InvalidCommand;
        const cmd_len: u8 = @intCast(cmd.len);

        // 1. Send CBW
        var cbw = CommandBlockWrapper.init(
            tag,
            data_len,
            dir_in,
            lun,
            cmd_len,
            cmd,
        );
        
        const cbw_bytes = std.mem.asBytes(&cbw)[0..31];
        // Note: CBW is always 31 bytes
        console.debug("MSC: Sending CBW (tag={})", .{tag});
        _ = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_out_ep, cbw_bytes);
        console.debug("MSC: CBW sent", .{});
        
        // 2. Data Stage
        if (data) |buf| {
            if (buf.len > 0) {
                const ep = if (dir_in) self.bulk_in_ep else self.bulk_out_ep;
                console.debug("MSC: Transferring data len={}", .{buf.len});
                const transferred = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, ep, buf);
                console.debug("MSC: Data transferred={}", .{transferred});

                if (transferred < buf.len) {
                    console.warn("MSC: Short data transfer: {} < {}", .{transferred, buf.len});
                    // Security: Zero remaining buffer on IN transfers to prevent info leak
                    // Device may have written less than expected, leaving stale data
                    if (dir_in) {
                        @memset(buf[transferred..], 0);
                    }
                }
            }
        }

        // 3. Receive CSW
        // Security: Zero-initialize to prevent kernel memory leaks on short transfers
        var csw: CommandStatusWrapper = std.mem.zeroes(CommandStatusWrapper);
        // Explicitly slice to 13 bytes to match wire format (remove padding)
        const csw_bytes = std.mem.asBytes(&csw)[0..13];
        console.debug("MSC: Receiving CSW...", .{});
        const csw_len = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_in_ep, csw_bytes);
        console.debug("MSC: CSW received len={}", .{csw_len});

        if (csw_len != 13) {
            console.err("MSC: Invalid CSW length {}", .{csw_len});
            return error.ProtocolError;
        }

        if (csw.signature != CommandStatusWrapper.SIGNATURE) {
            console.err("MSC: Invalid CSW signature 0x{x}", .{csw.signature});
            return error.ProtocolError;
        }

        if (csw.tag != tag) {
            console.err("MSC: CSW tag mismatch: expected {}, got {}", .{tag, csw.tag});
            return error.ProtocolError;
        }

        if (csw.status != 0) {
             console.err("MSC: Command failed with status {}", .{csw.status});
             return error.CommandFailed;
        }
    }

    /// SCSI Inquiry
    pub fn inquiry(self: *Self) !void {
        console.info("MSC: Sending SCSI Inquiry...", .{});

        // Security: Zero-initialize DMA buffer to prevent kernel memory leaks
        var buffer: [36]u8 = [_]u8{0} ** 36;
        const cmd = [_]u8{
            0x12, // INQUIRY
            0x00, // Flags
            0x00, // Page Code
            0x00, // Reserved
            0x24, // Allocation Length (36)
            0x00, // Control
        };

        try self.sendScsiCommand(0, &cmd, &buffer, true);

        // Parse Respose
        const periph_type = buffer[0] & 0x1F;
        const removable = (buffer[1] & 0x80) != 0;
        const vendor = buffer[8..16];
        const product = buffer[16..32];
        const revision = buffer[32..36];

        console.info("MSC: Inquiry Successful:", .{});
        console.info("  Type: 0x{x}", .{periph_type});
        console.info("  Removable: {}", .{removable});
        console.info("  Vendor: {s}", .{vendor});
        console.info("  Product: {s}", .{product});
        console.info("  Rev: {s}", .{revision});
    }
    
    /// Test Unit Ready
    pub fn testUnitReady(self: *Self) !void {
         const cmd = [_]u8{
            0x00, // TEST UNIT READY
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
        };
        try self.sendScsiCommand(0, &cmd, null, false);
        console.info("MSC: Unit is Ready", .{});
    }

    /// Read Capacity (10)
    /// Updates internal sector_count and sector_size
    pub fn readCapacity(self: *Self) !void {
        console.info("MSC: Reading Capacity...", .{});

        // Security: Zero-initialize DMA buffer to prevent kernel memory leaks
        var buffer: [8]u8 = [_]u8{0} ** 8;
        const cmd = [_]u8{
            0x25, // READ CAPACITY (10)
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
        };

        try self.sendScsiCommand(0, &cmd, &buffer, true);

        // Parse Big Endian response
        // Use double slicing to get *[4]u8 from capture
        self.sector_count = std.mem.readInt(u32, buffer[0..4][0..4], .big) + 1; // Returns highest LBA, so count is +1
        self.sector_size = std.mem.readInt(u32, buffer[4..8][0..4], .big);

        console.info("MSC: Capacity: {} blocks, {} bytes/block", .{ self.sector_count, self.sector_size });
        console.info("MSC: Total Size: {} MB", .{ (self.sector_count / 1024) * self.sector_size / 1024 });
    }

    /// Read (10)
    pub fn read(self: *Self, lba: u32, count: u16, buffer: []u8) !void {
        if (self.sector_size == 0) return error.DeviceNotReady;
        if (buffer.len < count * self.sector_size) return error.BufferTooSmall;

        const cmd = [_]u8{
            0x28, // READ (10)
            0x00, // Flags
            @truncate(lba >> 24),
            @truncate(lba >> 16),
            @truncate(lba >> 8),
            @truncate(lba),
            0x00, // Group Number
            @truncate(count >> 8),
            @truncate(count), // Transfer Length
            0x00, // Control
        };

        try self.sendScsiCommand(0, &cmd, buffer, true);
    }

    /// Write (10)
    pub fn write(self: *Self, lba: u32, count: u16, buffer: []const u8) !void {
        if (self.sector_size == 0) return error.DeviceNotReady;
        if (buffer.len < count * self.sector_size) return error.BufferTooSmall;

        const cmd = [_]u8{
            0x2A, // WRITE (10)
            0x00, // Flags
            @truncate(lba >> 24),
            @truncate(lba >> 16),
            @truncate(lba >> 8),
            @truncate(lba),
            0x00, // Group Number
            @truncate(count >> 8),
            @truncate(count), // Transfer Length
            0x00, // Control
        };

        // Cast const buffer to mutable for sendScsiCommand signature (it won't modify it for OUT transfers)
        // Ideally sendScsiCommand should take const buffer for data
        const mutable_buf = @constCast(buffer);
        try self.sendScsiCommand(0, &cmd, mutable_buf, false);
    }
};
