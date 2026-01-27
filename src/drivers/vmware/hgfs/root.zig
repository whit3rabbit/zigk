//! VMware HGFS (Host-Guest File System) Driver
//!
//! Provides access to VMware shared folders via the HGFS protocol over RPCI.
//! Enables file sharing between host and guest when running under VMware
//! Workstation, Fusion, or ESXi.
//!
//! Architecture:
//!   Guest Kernel <-> RPCI Channel <-> VMware Host <-> Host Filesystem
//!
//! Usage:
//!   const hgfs = @import("hgfs");
//!   var driver = hgfs.HgfsDriver.init() catch return null;
//!   try driver.createSession();
//!   const handle = try driver.open("/path/to/file", .Read);
//!   const bytes = try driver.read(handle, buffer);
//!   try driver.close(handle);
//!
//! Reference: open-vm-tools/modules/linux/vmhgfs/

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const heap = @import("heap");
const sync = @import("sync");

pub const protocol = @import("protocol.zig");

// Re-export protocol types
pub const HgfsStatus = protocol.HgfsStatus;
pub const HgfsOp = protocol.HgfsOp;
pub const HgfsAttr = protocol.HgfsAttr;
pub const HgfsFileType = protocol.HgfsFileType;

// =============================================================================
// Error Types
// =============================================================================

pub const HgfsError = error{
    NotDetected,
    RpciOpenFailed,
    SessionCreateFailed,
    SessionDestroyed,
    ProtocolError,
    InvalidResponse,
    InvalidHandle,
    NotFound,
    PermissionDenied,
    IoError,
    NameTooLong,
    NotEmpty,
    NotSupported,
    Timeout,
    BufferTooSmall,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
};

// =============================================================================
// HGFS Driver
// =============================================================================

/// HGFS Driver instance
pub const HgfsDriver = struct {
    /// RPCI channel for HGFS communication
    channel: hal.vmware.RpciChannel,

    /// Session ID (from CreateSession)
    session_id: u64,

    /// Request ID counter
    next_request_id: u32,

    /// Lock for synchronous operations
    lock: sync.Spinlock,

    /// Request/response buffers
    request_buf: [protocol.MAX_IO_SIZE + 512]u8,
    response_buf: [protocol.MAX_IO_SIZE + 512]u8,

    /// Whether session is active
    session_active: bool,

    const Self = @This();

    /// Initialize HGFS driver
    /// Checks for VMware hypervisor and opens RPCI channel
    pub fn init() HgfsError!*Self {
        // Check if running under VMware
        if (!hal.vmware.detect()) {
            return error.NotDetected;
        }

        // Allocate driver instance
        const driver = heap.allocator().create(Self) catch {
            return error.ProtocolError;
        };
        errdefer heap.allocator().destroy(driver);

        // Open RPCI channel
        driver.channel = hal.vmware.RpciChannel.open(hal.vmware.RpciProtocol.RPCI) catch {
            return error.RpciOpenFailed;
        };

        driver.session_id = 0;
        driver.next_request_id = 1;
        driver.lock = .{};
        driver.session_active = false;

        // Zero-initialize buffers (security: DMA hygiene)
        @memset(&driver.request_buf, 0);
        @memset(&driver.response_buf, 0);

        return driver;
    }

    /// Deinitialize driver
    pub fn deinit(self: *Self) void {
        if (self.session_active) {
            self.destroySession() catch {};
        }
        self.channel.close();
        heap.allocator().destroy(self);
    }

    /// Create HGFS session
    pub fn createSession(self: *Self) HgfsError!void {
        const held = self.lock.acquire();
        defer held.release();

        // Build CreateSession request
        var req_pos: usize = 0;

        // Request header
        var header = protocol.HgfsRequestHeader.init(
            .CreateSessionV4,
            self.allocRequestId(),
            0, // No session yet
        );

        // Will update packet_size after adding payload
        const payload_size: u32 = @intCast(protocol.HgfsCreateSessionRequest.SIZE);
        header.packet_size = @intCast(protocol.HgfsRequestHeader.SIZE);
        header.packet_size += payload_size;

        // Write header
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        // Write payload
        const session_req = protocol.HgfsCreateSessionRequest{};
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsCreateSessionRequest.SIZE], std.mem.asBytes(&session_req));
        req_pos += protocol.HgfsCreateSessionRequest.SIZE;

        // Send via RPCI with "f " prefix (HGFS marker)
        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        // Parse response
        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsCreateSessionReply.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));

        if (!reply_hdr.getStatus().isSuccess()) {
            return error.SessionCreateFailed;
        }

        const session_reply: *const protocol.HgfsCreateSessionReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        self.session_id = session_reply.session_id;
        self.session_active = true;

        console.info("HGFS: Session created (id=0x{x}, shares={d})", .{
            self.session_id,
            session_reply.num_shares,
        });
    }

    /// Destroy HGFS session
    pub fn destroySession(self: *Self) HgfsError!void {
        const held = self.lock.acquire();
        defer held.release();

        if (!self.session_active) return;

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .DestroySessionV4,
            self.allocRequestId(),
            self.session_id,
        );
        // packet_size already set to header size in init()

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        _ = self.sendHgfsRequest(self.request_buf[0..req_pos]) catch {};
        self.session_active = false;
    }

    /// Compute packet size as u32 for header field
    fn packetSize(sizes: []const usize) u32 {
        var total: usize = 0;
        for (sizes) |s| {
            total += s;
        }
        return @intCast(total);
    }

    /// Open a file
    pub fn open(self: *Self, path: []const u8, mode: OpenMode) HgfsError!u32 {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var req_pos: usize = 0;

        // Encode path
        var path_buf: [protocol.MAX_PATH_LEN]u8 = undefined;
        const path_len = protocol.encodePath(path, &path_buf) catch return error.NameTooLong;

        var header = protocol.HgfsRequestHeader.init(
            .OpenV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsOpenRequest.SIZE, path_len });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        // Open request
        var open_req = protocol.HgfsOpenRequest{
            .mode = @intFromEnum(mode.toHgfsMode()),
            .flags = mode.toHgfsFlags(),
            .special_flags = 0,
            .permissions = 0o644,
            .desired_access = mode.toDesiredAccess(),
            .share_access = 0x07, // Read | Write | Delete
            .desired_lock = 0,
            .file_name_length = @truncate(path_len),
        };

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsOpenRequest.SIZE], std.mem.asBytes(&open_req));
        req_pos += protocol.HgfsOpenRequest.SIZE;

        // Append path
        @memcpy(self.request_buf[req_pos..][0..path_len], path_buf[0..path_len]);
        req_pos += path_len;

        // Send request
        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));

        try self.checkStatus(reply_hdr.getStatus());

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsOpenReply.SIZE) {
            return error.InvalidResponse;
        }

        const open_reply: *const protocol.HgfsOpenReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        return open_reply.handle;
    }

    /// Close a file handle
    pub fn close(self: *Self, handle: u32) HgfsError!void {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .Close,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsCloseRequest.SIZE });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        const close_req = protocol.HgfsCloseRequest{ .handle = handle };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsCloseRequest.SIZE], std.mem.asBytes(&close_req));
        req_pos += protocol.HgfsCloseRequest.SIZE;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());
    }

    /// Read from a file
    pub fn read(self: *Self, handle: u32, offset: u64, buf: []u8) HgfsError!usize {
        if (!self.session_active) return error.SessionDestroyed;
        if (buf.len == 0) return 0;

        const held = self.lock.acquire();
        defer held.release();

        const read_size: u32 = @intCast(@min(buf.len, protocol.MAX_IO_SIZE));
        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .ReadV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsReadRequest.SIZE });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        const read_req = protocol.HgfsReadRequest{
            .handle = handle,
            .offset = offset,
            .size = read_size,
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsReadRequest.SIZE], std.mem.asBytes(&read_req));
        req_pos += protocol.HgfsReadRequest.SIZE;

        // Zero destination buffer (security)
        @memset(buf, 0);

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsReadReply.SIZE) {
            return error.InvalidResponse;
        }

        const read_reply: *const protocol.HgfsReadReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));
        const actual_size = read_reply.actual_size;

        if (actual_size == 0) return 0;

        // Validate response size
        const data_offset = protocol.HgfsReplyHeader.SIZE + protocol.HgfsReadReply.SIZE;
        if (resp_len < data_offset + actual_size) {
            return error.InvalidResponse;
        }

        const copy_size = @min(actual_size, @as(u32, @truncate(buf.len)));
        @memcpy(buf[0..copy_size], self.response_buf[data_offset..][0..copy_size]);

        return copy_size;
    }

    /// Write to a file
    pub fn write(self: *Self, handle: u32, offset: u64, data: []const u8) HgfsError!usize {
        if (!self.session_active) return error.SessionDestroyed;
        if (data.len == 0) return 0;

        const held = self.lock.acquire();
        defer held.release();

        const write_size: u32 = @intCast(@min(data.len, protocol.MAX_IO_SIZE));
        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .WriteV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsWriteRequest.SIZE }) + write_size;

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        const write_req = protocol.HgfsWriteRequest{
            .handle = handle,
            .flags = 0,
            .offset = offset,
            .size = write_size,
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsWriteRequest.SIZE], std.mem.asBytes(&write_req));
        req_pos += protocol.HgfsWriteRequest.SIZE;

        // Append data
        @memcpy(self.request_buf[req_pos..][0..write_size], data[0..write_size]);
        req_pos += write_size;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsWriteReply.SIZE) {
            return error.InvalidResponse;
        }

        const write_reply: *const protocol.HgfsWriteReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        return write_reply.actual_size;
    }

    /// Get file attributes
    pub fn getAttr(self: *Self, path: []const u8) HgfsError!protocol.HgfsAttr {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        // Encode path
        var path_buf: [protocol.MAX_PATH_LEN]u8 = undefined;
        const path_len = protocol.encodePath(path, &path_buf) catch return error.NameTooLong;

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .GetAttrV2,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsGetAttrRequest.SIZE, path_len });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        var getattr_req = protocol.HgfsGetAttrRequest{
            .file_name_length = @truncate(path_len),
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsGetAttrRequest.SIZE], std.mem.asBytes(&getattr_req));
        req_pos += protocol.HgfsGetAttrRequest.SIZE;

        @memcpy(self.request_buf[req_pos..][0..path_len], path_buf[0..path_len]);
        req_pos += path_len;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsGetAttrReply.SIZE) {
            return error.InvalidResponse;
        }

        const getattr_reply: *const protocol.HgfsGetAttrReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        return getattr_reply.attr;
    }

    /// Open directory for enumeration
    pub fn searchOpen(self: *Self, path: []const u8) HgfsError!u32 {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var path_buf: [protocol.MAX_PATH_LEN]u8 = undefined;
        const path_len = protocol.encodePath(path, &path_buf) catch return error.NameTooLong;

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .SearchOpenV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsSearchOpenRequest.SIZE, path_len });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        var search_req = protocol.HgfsSearchOpenRequest{
            .dir_name_length = @truncate(path_len),
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsSearchOpenRequest.SIZE], std.mem.asBytes(&search_req));
        req_pos += protocol.HgfsSearchOpenRequest.SIZE;

        @memcpy(self.request_buf[req_pos..][0..path_len], path_buf[0..path_len]);
        req_pos += path_len;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsSearchOpenReply.SIZE) {
            return error.InvalidResponse;
        }

        const search_reply: *const protocol.HgfsSearchOpenReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        return search_reply.handle;
    }

    /// Read directory entry
    /// Returns null when no more entries
    pub fn searchRead(self: *Self, handle: u32, index: u32, name_buf: []u8) HgfsError!?DirEntry {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .SearchReadV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsSearchReadRequest.SIZE });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        const search_req = protocol.HgfsSearchReadRequest{
            .handle = handle,
            .offset = index,
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsSearchReadRequest.SIZE], std.mem.asBytes(&search_req));
        req_pos += protocol.HgfsSearchReadRequest.SIZE;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));

        // End of directory returns specific status
        const status = reply_hdr.getStatus();
        if (status == .NoSuchFile) {
            return null; // End of directory
        }
        try self.checkStatus(status);

        if (resp_len < protocol.HgfsReplyHeader.SIZE + protocol.HgfsSearchReadReply.SIZE) {
            return error.InvalidResponse;
        }

        const search_reply: *const protocol.HgfsSearchReadReply = @ptrCast(@alignCast(self.response_buf[protocol.HgfsReplyHeader.SIZE..].ptr));

        if (search_reply.count == 0) {
            return null;
        }

        // Parse first directory entry
        const entry_offset = protocol.HgfsReplyHeader.SIZE + protocol.HgfsSearchReadReply.SIZE;
        if (resp_len < entry_offset + protocol.HgfsDirEntry.HEADER_SIZE) {
            return error.InvalidResponse;
        }

        const dir_entry: *const protocol.HgfsDirEntry = @ptrCast(@alignCast(self.response_buf[entry_offset..].ptr));

        // Copy filename
        const name_len = @min(dir_entry.file_name_length, @as(u32, @truncate(name_buf.len)));
        const name_start = entry_offset + protocol.HgfsDirEntry.HEADER_SIZE;
        if (resp_len < name_start + name_len) {
            return error.InvalidResponse;
        }

        @memcpy(name_buf[0..name_len], self.response_buf[name_start..][0..name_len]);

        return DirEntry{
            .name_len = name_len,
            .attr = dir_entry.attr,
        };
    }

    /// Close search handle
    pub fn searchClose(self: *Self, handle: u32) HgfsError!void {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .SearchClose,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsSearchCloseRequest.SIZE });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        const close_req = protocol.HgfsSearchCloseRequest{ .handle = handle };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsSearchCloseRequest.SIZE], std.mem.asBytes(&close_req));
        req_pos += protocol.HgfsSearchCloseRequest.SIZE;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());
    }

    /// Create a directory
    pub fn mkdir(self: *Self, path: []const u8) HgfsError!void {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var path_buf: [protocol.MAX_PATH_LEN]u8 = undefined;
        const path_len = protocol.encodePath(path, &path_buf) catch return error.NameTooLong;

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            .CreateDirV3,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsCreateDirRequest.SIZE, path_len });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        var mkdir_req = protocol.HgfsCreateDirRequest{
            .file_name_length = @truncate(path_len),
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsCreateDirRequest.SIZE], std.mem.asBytes(&mkdir_req));
        req_pos += protocol.HgfsCreateDirRequest.SIZE;

        @memcpy(self.request_buf[req_pos..][0..path_len], path_buf[0..path_len]);
        req_pos += path_len;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());
    }

    /// Delete a file
    pub fn unlink(self: *Self, path: []const u8) HgfsError!void {
        return self.deleteHelper(path, .DeleteFileV3);
    }

    /// Remove a directory
    pub fn rmdir(self: *Self, path: []const u8) HgfsError!void {
        return self.deleteHelper(path, .DeleteDirV3);
    }

    fn deleteHelper(self: *Self, path: []const u8, op: protocol.HgfsOp) HgfsError!void {
        if (!self.session_active) return error.SessionDestroyed;

        const held = self.lock.acquire();
        defer held.release();

        var path_buf: [protocol.MAX_PATH_LEN]u8 = undefined;
        const path_len = protocol.encodePath(path, &path_buf) catch return error.NameTooLong;

        var req_pos: usize = 0;

        var header = protocol.HgfsRequestHeader.init(
            op,
            self.allocRequestId(),
            self.session_id,
        );
        header.packet_size = packetSize(&.{ protocol.HgfsRequestHeader.SIZE, protocol.HgfsDeleteRequest.SIZE, path_len });

        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsRequestHeader.SIZE], std.mem.asBytes(&header));
        req_pos += protocol.HgfsRequestHeader.SIZE;

        var delete_req = protocol.HgfsDeleteRequest{
            .file_name_length = @truncate(path_len),
        };
        @memcpy(self.request_buf[req_pos..][0..protocol.HgfsDeleteRequest.SIZE], std.mem.asBytes(&delete_req));
        req_pos += protocol.HgfsDeleteRequest.SIZE;

        @memcpy(self.request_buf[req_pos..][0..path_len], path_buf[0..path_len]);
        req_pos += path_len;

        const resp_len = try self.sendHgfsRequest(self.request_buf[0..req_pos]);

        if (resp_len < protocol.HgfsReplyHeader.SIZE) {
            return error.InvalidResponse;
        }

        const reply_hdr: *const protocol.HgfsReplyHeader = @ptrCast(@alignCast(self.response_buf[0..protocol.HgfsReplyHeader.SIZE].ptr));
        try self.checkStatus(reply_hdr.getStatus());
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    fn allocRequestId(self: *Self) u32 {
        const id = self.next_request_id;
        self.next_request_id +%= 1;
        return id;
    }

    /// Send HGFS request via RPCI and receive response
    fn sendHgfsRequest(self: *Self, request: []const u8) HgfsError!usize {
        // HGFS requests are prefixed with "f " marker
        var full_request: [protocol.MAX_IO_SIZE + 514]u8 = undefined;
        full_request[0] = 'f';
        full_request[1] = ' ';
        @memcpy(full_request[2..][0..request.len], request);

        const sent = self.channel.send(full_request[0 .. 2 + request.len]) catch {
            return error.IoError;
        };
        if (sent != 2 + request.len) {
            return error.IoError;
        }

        // Receive response
        const received = self.channel.receive(&self.response_buf) catch {
            return error.IoError;
        };

        // Response should start with "1 " for success
        if (received < 2) {
            return error.InvalidResponse;
        }

        // Check response prefix
        if (self.response_buf[0] != '1' or self.response_buf[1] != ' ') {
            // Error response starts with "0 "
            return error.ProtocolError;
        }

        // Skip "1 " prefix in response, copy actual data back
        const data_len = received - 2;
        if (data_len > 0) {
            // Shift response data to start of buffer
            var i: usize = 0;
            while (i < data_len) : (i += 1) {
                self.response_buf[i] = self.response_buf[i + 2];
            }
        }

        return data_len;
    }

    fn checkStatus(self: *Self, status: protocol.HgfsStatus) HgfsError!void {
        _ = self;
        return switch (status) {
            .Success => {},
            .NoSuchFile => error.NotFound,
            .PermissionDenied => error.PermissionDenied,
            .InvalidHandle => error.InvalidHandle,
            .OperationNotSupported, .NotSupported => error.NotSupported,
            .NameTooLong => error.NameTooLong,
            .DirNotEmpty => error.NotEmpty,
            .IoError => error.IoError,
            .SessionNotFound, .StaleSession => error.SessionDestroyed,
            else => error.ProtocolError,
        };
    }
};

// =============================================================================
// Public Types
// =============================================================================

/// Open mode flags
pub const OpenMode = struct {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    exclusive: bool = false,
    directory: bool = false,

    pub const Read = OpenMode{ .read = true };
    pub const Write = OpenMode{ .write = true };
    pub const ReadWrite = OpenMode{ .read = true, .write = true };
    pub const Create = OpenMode{ .read = true, .write = true, .create = true };
    pub const Truncate = OpenMode{ .read = true, .write = true, .create = true, .truncate = true };

    fn toHgfsMode(self: OpenMode) protocol.HgfsOpenMode {
        if (self.exclusive and self.create) return .CreateNew;
        if (self.truncate) return .TruncateExisting;
        if (self.create) return .OpenOrCreate;
        return .OpenExisting;
    }

    fn toHgfsFlags(self: OpenMode) u32 {
        var flags: u32 = 0;
        if (self.read) flags |= protocol.HgfsOpenFlags.READ;
        if (self.write) flags |= protocol.HgfsOpenFlags.WRITE;
        if (self.append) flags |= protocol.HgfsOpenFlags.APPEND;
        if (self.create) flags |= protocol.HgfsOpenFlags.CREATE;
        if (self.truncate) flags |= protocol.HgfsOpenFlags.TRUNCATE;
        if (self.exclusive) flags |= protocol.HgfsOpenFlags.EXCL;
        if (self.directory) flags |= protocol.HgfsOpenFlags.DIRECTORY;
        return flags;
    }

    fn toDesiredAccess(self: OpenMode) u32 {
        var access: u32 = 0;
        if (self.read) access |= 0x01; // GENERIC_READ
        if (self.write) access |= 0x02; // GENERIC_WRITE
        return access;
    }
};

/// Directory entry from searchRead
pub const DirEntry = struct {
    name_len: u32,
    attr: protocol.HgfsAttr,
};

// =============================================================================
// Global Instance
// =============================================================================

var g_driver: ?*HgfsDriver = null;

/// Get or create global HGFS driver instance
pub fn getDriver() ?*HgfsDriver {
    return g_driver;
}

/// Initialize global HGFS driver
pub fn initDriver() !*HgfsDriver {
    if (g_driver) |driver| return driver;

    const driver = try HgfsDriver.init();
    try driver.createSession();
    g_driver = driver;
    return driver;
}
