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

        const data_len: u32 = if (data) |d| @truncate(d.len) else 0;

        // 1. Send CBW
        var cbw = CommandBlockWrapper.init(
            tag,
            data_len,
            dir_in,
            lun,
            @truncate(cmd.len),
            cmd,
        );
        
        const cbw_bytes = std.mem.asBytes(&cbw);
        // Note: CBW is always 31 bytes
        _ = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_out_ep, cbw_bytes);
        
        // 2. Data Stage
        if (data) |buf| {
            if (buf.len > 0) {
                const ep = if (dir_in) self.bulk_in_ep else self.bulk_out_ep;
                const transferred = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, ep, buf);
                
                if (transferred < buf.len) {
                    console.warn("MSC: Short data transfer: {} < {}", .{transferred, buf.len});
                }
            }
        }

        // 3. Receive CSW
        var csw: CommandStatusWrapper = undefined;
        const csw_bytes = std.mem.asBytes(&csw);
        const csw_len = try usb.Transfer.queueBulkTransfer(self.ctrl, self.dev, self.bulk_in_ep, csw_bytes);

        if (csw_len != @sizeOf(CommandStatusWrapper)) {
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

        var buffer: [36]u8 = undefined; // Standard Inquiry data length
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
};
