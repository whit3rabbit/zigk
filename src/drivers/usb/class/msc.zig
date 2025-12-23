// USB Mass Storage Class (MSC) Driver
//
// Implements Bulk-Only Transport (BOT) for USB storage devices.
// Reference: USB Mass Storage Class - Bulk-Only Transport, Rev 1.0

const std = @import("std");
const console = @import("console");
const io = @import("io");
const pmm = @import("pmm");
const hal = @import("hal");

const usb = @import("../xhci/root.zig"); // Access to generic USB types/transfer
const device = @import("../xhci/device.zig");
const bulk = @import("../xhci/transfer/bulk.zig");

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

    // =========================================================================
    // Async I/O Operations
    // =========================================================================

    /// Async Read (10) with IoRequest
    ///
    /// Performs a SCSI READ(10) command asynchronously. The data stage uses
    /// async bulk transfer while CBW/CSW stages are synchronous (small/fast).
    ///
    /// Caller responsibilities:
    ///   1. Allocate IoRequest from kernel pool
    ///   2. Allocate DMA buffer via pmm.allocZeroedPages()
    ///   3. Call readAsync() to queue the transfer
    ///   4. Wait on IoRequest.wait() or use io_uring
    ///   5. Copy data from DMA buffer after completion
    ///   6. Free DMA buffer and IoRequest
    ///
    /// Returns: Physical address of DMA buffer containing read data
    pub fn readAsync(
        self: *Self,
        lba: u32,
        count: u16,
        io_request: *io.IoRequest,
    ) !u64 {
        if (self.sector_size == 0) return error.DeviceNotReady;

        const data_len = @as(usize, count) * self.sector_size;
        const page_count = (data_len + 4095) / 4096;

        // Allocate DMA buffer for data stage
        const buf_phys = pmm.allocZeroedPages(page_count) orelse return error.OutOfMemory;
        errdefer pmm.freePages(buf_phys, page_count);

        const tag = self.current_tag;
        self.current_tag +%= 1;

        // 1. Send CBW (synchronous - only 31 bytes)
        var cbw = CommandBlockWrapper.init(
            tag,
            @intCast(data_len),
            true, // IN direction
            0, // LUN
            10, // CDB length
            &[_]u8{
                0x28, // READ (10)
                0x00,
                @truncate(lba >> 24),
                @truncate(lba >> 16),
                @truncate(lba >> 8),
                @truncate(lba),
                0x00,
                @truncate(count >> 8),
                @truncate(count),
                0x00,
            },
        );

        const cbw_bytes = std.mem.asBytes(&cbw)[0..31];
        _ = usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_out_ep, cbw_bytes) catch |err| {
            pmm.freePages(buf_phys, page_count);
            return err;
        };

        // 2. Data Stage (async - uses IoRequest)
        bulk.queueBulkTransferAsync(
            self.ctrl,
            self.dev,
            self.bulk_in_ep,
            buf_phys,
            data_len,
            io_request,
        ) catch |err| {
            pmm.freePages(buf_phys, page_count);
            return err;
        };

        // Set IoRequest metadata
        io_request.op_data = .{
            .usb = .{
                .slot_id = self.dev.slot_id,
                .dci = 0, // Will be set by queueBulkTransferAsync
                .request_len = @truncate(data_len),
                .buf_phys = buf_phys,
            },
        };

        // Return physical address - caller must:
        // 1. Wait on io_request
        // 2. Receive CSW (via receiveCSW())
        // 3. Free DMA buffer
        return buf_phys;
    }

    /// Receive CSW after async data transfer completes
    /// Must be called after io_request completes for readAsync/writeAsync
    pub fn receiveCSW(self: *Self, expected_tag: u32) !void {
        var csw: CommandStatusWrapper = std.mem.zeroes(CommandStatusWrapper);
        const csw_bytes = std.mem.asBytes(&csw)[0..13];
        const csw_len = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_in_ep, csw_bytes);

        if (csw_len != 13) return error.ProtocolError;
        if (csw.signature != CommandStatusWrapper.SIGNATURE) return error.ProtocolError;
        if (csw.tag != expected_tag) return error.ProtocolError;
        if (csw.status != 0) return error.CommandFailed;
    }

    /// Async Write (10) with IoRequest
    ///
    /// Performs a SCSI WRITE(10) command asynchronously.
    ///
    /// Caller responsibilities:
    ///   1. Allocate IoRequest from kernel pool
    ///   2. Allocate DMA buffer via pmm.allocZeroedPages()
    ///   3. Copy data to DMA buffer
    ///   4. Call writeAsync() to queue the transfer
    ///   5. Wait on IoRequest.wait() or use io_uring
    ///   6. Receive CSW via receiveCSW()
    ///   7. Free DMA buffer and IoRequest
    pub fn writeAsync(
        self: *Self,
        lba: u32,
        count: u16,
        buf_phys: u64,
        buf_len: usize,
        io_request: *io.IoRequest,
    ) !u32 {
        if (self.sector_size == 0) return error.DeviceNotReady;

        const data_len = @as(usize, count) * self.sector_size;
        if (buf_len < data_len) return error.BufferTooSmall;

        const tag = self.current_tag;
        self.current_tag +%= 1;

        // 1. Send CBW (synchronous - only 31 bytes)
        var cbw = CommandBlockWrapper.init(
            tag,
            @intCast(data_len),
            false, // OUT direction
            0, // LUN
            10, // CDB length
            &[_]u8{
                0x2A, // WRITE (10)
                0x00,
                @truncate(lba >> 24),
                @truncate(lba >> 16),
                @truncate(lba >> 8),
                @truncate(lba),
                0x00,
                @truncate(count >> 8),
                @truncate(count),
                0x00,
            },
        );

        const cbw_bytes = std.mem.asBytes(&cbw)[0..31];
        _ = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_out_ep, cbw_bytes);

        // 2. Data Stage (async - uses IoRequest)
        try bulk.queueBulkTransferAsync(
            self.ctrl,
            self.dev,
            self.bulk_out_ep,
            buf_phys,
            data_len,
            io_request,
        );

        // Set IoRequest metadata
        io_request.op_data = .{
            .usb = .{
                .slot_id = self.dev.slot_id,
                .dci = 0,
                .request_len = @truncate(data_len),
                .buf_phys = buf_phys,
            },
        };

        // Return tag for CSW verification
        return tag;
    }

    /// Get current command tag (for async operations)
    pub fn getCurrentTag(self: *const Self) u32 {
        return self.current_tag;
    }

    /// Calculate page count needed for sector count
    pub fn pagesForSectors(self: *const Self, sector_count: u16) usize {
        const data_len = @as(usize, sector_count) * self.sector_size;
        return (data_len + 4095) / 4096;
    }
};
