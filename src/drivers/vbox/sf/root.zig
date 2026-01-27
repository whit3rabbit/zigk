//! VirtualBox Shared Folders Driver (VBoxSF)
//!
//! Provides access to VirtualBox shared folders via the HGCM protocol.
//! This driver communicates with the VMMDev device to access the
//! VBoxSharedFolders HGCM service.
//!
//! Usage:
//!   const vboxsf = @import("vboxsf");
//!   const driver = vboxsf.init() catch return;
//!   const root = driver.mapFolder("myshare") catch return;
//!   const handle = driver.createFile(root, "test.txt", ...) catch return;

const std = @import("std");
const hal = @import("hal");
const console = @import("console");
const heap = @import("heap");
const sync = @import("sync");
const dma = @import("dma");
const iommu = @import("iommu");

const vmmdev = @import("vmmdev");
pub const config = @import("config.zig");
pub const protocol = @import("protocol.zig");

// ============================================================================
// Error Types
// ============================================================================

pub const VBoxSfError = error{
    VmmDevNotAvailable,
    HgcmNotAvailable,
    ConnectFailed,
    DisconnectFailed,
    CallFailed,
    InvalidParameter,
    NotFound,
    AccessDenied,
    AlreadyExists,
    IsDirectory,
    NotDirectory,
    NotEmpty,
    ReadOnly,
    NoMemory,
    BufferOverflow,
    InvalidHandle,
    Timeout,
    PathTooLong,
};

// ============================================================================
// Global State
// ============================================================================

/// Global VBoxSF driver instance
var g_driver: ?*VBoxSfDriver = null;

/// Get the global driver instance
pub fn getDriver() ?*VBoxSfDriver {
    return g_driver;
}

// ============================================================================
// VBoxSF Driver
// ============================================================================

pub const VBoxSfDriver = struct {
    /// HGCM client ID
    client_id: u32,

    /// VMMDev reference
    vmmdev_ref: *vmmdev.VmmDevDevice,

    /// DMA buffer for HGCM calls (8KB for calls + data)
    call_dma: dma.DmaBuffer,

    /// DMA buffer for data transfers
    data_dma: dma.DmaBuffer,

    /// Lock for operations
    lock: sync.Spinlock,

    /// UTF-8 mode enabled
    utf8_mode: bool,

    /// Initialized flag
    initialized: bool,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize VBoxSF driver
    pub fn init(self: *Self) VBoxSfError!void {
        self.initialized = false;
        self.utf8_mode = false;
        self.lock = .{};

        // Get VMMDev
        self.vmmdev_ref = vmmdev.getDevice() orelse {
            return error.VmmDevNotAvailable;
        };

        // Check HGCM support
        if (!self.vmmdev_ref.hasHgcm()) {
            return error.HgcmNotAvailable;
        }

        // Allocate DMA buffers
        const bdf = iommu.DeviceBdf{
            .bus = self.vmmdev_ref.pci_dev.bus,
            .device = self.vmmdev_ref.pci_dev.device,
            .func = self.vmmdev_ref.pci_dev.func,
        };

        self.call_dma = dma.allocBuffer(bdf, 8192, false) catch {
            return error.NoMemory;
        };
        errdefer dma.freeBuffer(&self.call_dma);

        self.data_dma = dma.allocBuffer(bdf, config.MAX_IO_SIZE, false) catch {
            return error.NoMemory;
        };
        errdefer dma.freeBuffer(&self.data_dma);

        // Zero-init buffers (security: DMA hygiene)
        @memset(self.getCallBuf(), 0);
        @memset(self.getDataBuf(), 0);

        // Connect to VBoxSharedFolders service
        self.client_id = self.vmmdev_ref.hgcmConnect(config.HGCM_SERVICE_NAME) catch |err| {
            console.err("VBoxSF: HGCM connect failed: {}", .{err});
            return error.ConnectFailed;
        };

        // Enable UTF-8 mode
        self.setUtf8() catch |err| {
            console.warn("VBoxSF: UTF-8 mode failed: {}, using default", .{err});
        };

        self.initialized = true;
        g_driver = self;

        console.info("VBoxSF: Initialized (client_id={d}, utf8={})", .{ self.client_id, self.utf8_mode });
    }

    // ========================================================================
    // Buffer Access
    // ========================================================================

    fn getCallBuf(self: *Self) []u8 {
        const ptr = self.call_dma.getVirt();
        return ptr[0..@intCast(self.call_dma.size)];
    }

    fn getCallPhys(self: *Self) u64 {
        return self.call_dma.phys;
    }

    fn getDataBuf(self: *Self) []u8 {
        const ptr = self.data_dma.getVirt();
        return ptr[0..@intCast(self.data_dma.size)];
    }

    fn getDataPhys(self: *Self) u64 {
        return self.data_dma.phys_addr;
    }

    // ========================================================================
    // HGCM Call Helpers
    // ========================================================================

    /// Build and execute an HGCM call
    fn hgcmCall(self: *Self, function: protocol.Function, params: []const vmmdev.hgcm.HgcmParam) VBoxSfError!void {
        const buf = self.getCallBuf();
        const param_count: u32 = @intCast(params.len);

        // Build header
        const hdr = vmmdev.hgcm.HgcmCallHeader.init(
            .HgcmCall64,
            self.client_id,
            @intFromEnum(function),
            param_count,
        );

        // Copy header
        const hdr_bytes: [*]const u8 = @ptrCast(&hdr);
        @memcpy(buf[0..vmmdev.hgcm.HgcmCallHeader.SIZE], hdr_bytes[0..vmmdev.hgcm.HgcmCallHeader.SIZE]);

        // Copy parameters
        var offset: usize = vmmdev.hgcm.HgcmCallHeader.SIZE;
        for (params) |param| {
            const param_bytes: [*]const u8 = @ptrCast(&param);
            @memcpy(buf[offset..][0..vmmdev.hgcm.HgcmParam.SIZE], param_bytes[0..vmmdev.hgcm.HgcmParam.SIZE]);
            offset += vmmdev.hgcm.HgcmParam.SIZE;
        }

        // Execute call
        self.vmmdev_ref.hgcmCall(buf[0..offset]) catch {
            return error.CallFailed;
        };

        // Check result in header
        const resp_hdr: *vmmdev.types.RequestHeader = @ptrCast(@alignCast(buf.ptr));
        if (resp_hdr.rc < 0) {
            return mapHgcmError(resp_hdr.rc);
        }
    }

    /// Map HGCM error to VBoxSfError
    fn mapHgcmError(rc: i32) VBoxSfError {
        const shfl_err: protocol.ErrorCode = @enumFromInt(rc);
        return switch (shfl_err) {
            .OK => error.CallFailed, // Should not reach here
            .GENERAL_FAILURE => error.CallFailed,
            .INVALID_PARAMETER => error.InvalidParameter,
            .INVALID_HANDLE => error.InvalidHandle,
            .NOT_FOUND => error.NotFound,
            .NO_MEMORY => error.NoMemory,
            .ALREADY_EXISTS => error.AlreadyExists,
            .ACCESS_DENIED => error.AccessDenied,
            .BUFFER_OVERFLOW => error.BufferOverflow,
            .NOT_DIRECTORY => error.NotDirectory,
            .IS_DIRECTORY => error.IsDirectory,
            .NOT_EMPTY => error.NotEmpty,
            .READ_ONLY => error.ReadOnly,
            _ => error.CallFailed,
        };
    }

    // ========================================================================
    // SHFL Operations
    // ========================================================================

    /// Enable UTF-8 encoding for strings
    fn setUtf8(self: *Self) VBoxSfError!void {
        const held = self.lock.acquire();
        defer held.release();

        // SET_UTF8 takes no parameters
        var params: [0]vmmdev.hgcm.HgcmParam = undefined;
        try self.hgcmCall(.SET_UTF8, &params);
        self.utf8_mode = true;
    }

    /// Map a shared folder by name
    /// Returns the root handle (SHFLROOT)
    pub fn mapFolder(self: *Self, name: []const u8) VBoxSfError!u32 {
        if (name.len > config.MAX_NAME_LEN) {
            return error.PathTooLong;
        }

        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        // Build ShflString for folder name
        const str_header = protocol.ShflString.initInBuffer(data_buf, name) orelse {
            return error.BufferOverflow;
        };
        const str_size: u32 = @intCast(str_header.totalSize());

        // Build parameters:
        // [0] IN: pointer to folder name (ShflString)
        // [1] IN/OUT: pointer to root handle (u32)
        // [2] IN: delimiter character ('/')
        // [3] IN: case sensitivity flag (0 = case insensitive)

        // Place root handle after string in data buffer
        const root_offset: usize = protocol.ShflString.HEADER_SIZE + str_size;
        var params = [4]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, str_size),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys + root_offset, 4),
            vmmdev.hgcm.HgcmParam.initU32('/'),
            vmmdev.hgcm.HgcmParam.initU32(0), // case insensitive
        };

        try self.hgcmCall(.MAP_FOLDER, &params);

        // Read root handle from response
        const root_ptr: *align(1) u32 = @ptrCast(data_buf[root_offset..].ptr);
        const root = root_ptr.*;

        if (root == config.SHFLROOT_NIL) {
            return error.NotFound;
        }

        return root;
    }

    /// Unmap a shared folder
    pub fn unmapFolder(self: *Self, root: u32) VBoxSfError!void {
        const held = self.lock.acquire();
        defer held.release();

        var params = [1]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
        };

        try self.hgcmCall(.UNMAP_FOLDER, &params);
    }

    /// Create or open a file/directory
    pub fn createFile(
        self: *Self,
        root: u32,
        path: []const u8,
        create_flags: u32,
    ) VBoxSfError!struct { handle: u64, info: protocol.FsObjInfo, result: config.CreateResult } {
        if (path.len > config.MAX_PATH_LEN) {
            return error.PathTooLong;
        }

        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        // Layout in data buffer:
        // [0..str_size]: ShflString for path
        // [str_size..str_size+80]: CreateParams

        const str_header = protocol.ShflString.initInBuffer(data_buf, path) orelse {
            return error.BufferOverflow;
        };
        const str_size: usize = str_header.totalSize();

        // Initialize CreateParams
        const params_offset = str_size;
        const create_params_ptr: *protocol.CreateParams = @ptrCast(@alignCast(data_buf[params_offset..].ptr));
        create_params_ptr.* = protocol.CreateParams.init(create_flags);

        // Parameters:
        // [0] IN: root handle
        // [1] IN: pointer to path (ShflString)
        // [2] IN/OUT: pointer to CreateParams
        var params = [3]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, @intCast(str_size)),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys + params_offset, protocol.CreateParams.SIZE),
        };

        try self.hgcmCall(.CREATE, &params);

        // Check result
        if (create_params_ptr.result == .FAILED or
            create_params_ptr.result == .FILE_NOT_FOUND or
            create_params_ptr.result == .PATH_NOT_FOUND)
        {
            return error.NotFound;
        }
        if (create_params_ptr.result == .FILE_EXISTS) {
            return error.AlreadyExists;
        }

        return .{
            .handle = create_params_ptr.handle,
            .info = create_params_ptr.info,
            .result = create_params_ptr.result,
        };
    }

    /// Close a file handle
    pub fn closeFile(self: *Self, root: u32, handle: u64) VBoxSfError!void {
        const held = self.lock.acquire();
        defer held.release();

        var params = [2]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initU64(handle),
        };

        try self.hgcmCall(.CLOSE, &params);
    }

    /// Read from a file
    pub fn readFile(
        self: *Self,
        root: u32,
        handle: u64,
        offset: u64,
        out_buf: []u8,
    ) VBoxSfError!usize {
        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        const read_size: u32 = @intCast(@min(out_buf.len, config.MAX_IO_SIZE));

        // Parameters:
        // [0] IN: root handle
        // [1] IN: file handle
        // [2] IN: offset
        // [3] IN/OUT: size (in: requested, out: actual)
        // [4] OUT: pointer to data buffer

        // Store size at start of data buffer
        const size_ptr: *align(1) u32 = @ptrCast(data_buf.ptr);
        size_ptr.* = read_size;

        var params = [5]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initU64(handle),
            vmmdev.hgcm.HgcmParam.initU64(offset),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys, 4), // size
            vmmdev.hgcm.HgcmParam.initLinAddrOut(data_phys + 4, read_size),
        };

        try self.hgcmCall(.READ, &params);

        // Read actual size from response
        const actual_size = size_ptr.*;
        const copy_size = @min(actual_size, @as(u32, @intCast(out_buf.len)));

        // Copy data to output buffer
        @memcpy(out_buf[0..copy_size], data_buf[4..][0..copy_size]);

        return copy_size;
    }

    /// Write to a file
    pub fn writeFile(
        self: *Self,
        root: u32,
        handle: u64,
        offset: u64,
        data: []const u8,
    ) VBoxSfError!usize {
        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        const write_size: u32 = @intCast(@min(data.len, config.MAX_IO_SIZE - 4));

        // Store size at start of data buffer
        const size_ptr: *align(1) u32 = @ptrCast(data_buf.ptr);
        size_ptr.* = write_size;

        // Copy data to buffer
        @memcpy(data_buf[4..][0..write_size], data[0..write_size]);

        // Parameters:
        // [0] IN: root handle
        // [1] IN: file handle
        // [2] IN: offset
        // [3] IN/OUT: size
        // [4] IN: pointer to data

        var params = [5]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initU64(handle),
            vmmdev.hgcm.HgcmParam.initU64(offset),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys, 4),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys + 4, write_size),
        };

        try self.hgcmCall(.WRITE, &params);

        // Read actual written size
        return size_ptr.*;
    }

    /// Get file information
    pub fn getInfo(self: *Self, root: u32, handle: u64) VBoxSfError!protocol.FsObjInfo {
        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        // Parameters:
        // [0] IN: root handle
        // [1] IN: file handle
        // [2] IN: flags (SHFL_INFO_*)
        // [3] IN/OUT: size
        // [4] OUT: pointer to FsObjInfo

        const size_ptr: *align(1) u32 = @ptrCast(data_buf.ptr);
        size_ptr.* = protocol.FsObjInfo.SIZE;

        var params = [5]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initU64(handle),
            vmmdev.hgcm.HgcmParam.initU32(config.FileInfoFlags.ALL),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys, 4),
            vmmdev.hgcm.HgcmParam.initLinAddrOut(data_phys + 4, protocol.FsObjInfo.SIZE),
        };

        try self.hgcmCall(.INFORMATION, &params);

        // Parse response
        const info_ptr: *align(1) protocol.FsObjInfo = @ptrCast(data_buf[4..].ptr);
        return info_ptr.*;
    }

    /// List directory entries
    /// Returns the number of entries read
    pub fn listDir(
        self: *Self,
        root: u32,
        handle: u64,
        resume_point: *u32,
        entries: []DirEntry,
    ) VBoxSfError!usize {
        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        // Build wildcard pattern ("*")
        const pattern = protocol.ShflString.initInBuffer(data_buf, "*") orelse {
            return error.BufferOverflow;
        };
        const pattern_size: u32 = @intCast(pattern.totalSize());

        // Parameters:
        // [0] IN: root handle
        // [1] IN: directory handle
        // [2] IN: flags (0)
        // [3] IN/OUT: size
        // [4] IN: path/pattern (ShflString)
        // [5] OUT: directory info buffer
        // [6] IN: resume point (0 to start)
        // [7] OUT: number of entries

        const buffer_offset: usize = pattern_size;
        const buffer_size: u32 = @intCast(config.MAX_IO_SIZE - buffer_offset);

        // Store size and resume point
        const size_ptr: *align(1) u32 = @ptrCast(data_buf[buffer_offset..].ptr);
        size_ptr.* = buffer_size - 8;

        const count_offset = buffer_offset + 4;
        const count_ptr: *align(1) u32 = @ptrCast(data_buf[count_offset..].ptr);
        count_ptr.* = 0;

        var params = [8]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initU64(handle),
            vmmdev.hgcm.HgcmParam.initU32(0), // flags
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys + buffer_offset, 4),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, pattern_size),
            vmmdev.hgcm.HgcmParam.initLinAddrOut(data_phys + buffer_offset + 8, buffer_size - 8),
            vmmdev.hgcm.HgcmParam.initU32(resume_point.*),
            vmmdev.hgcm.HgcmParam.initLinAddr(data_phys + count_offset, 4),
        };

        try self.hgcmCall(.LIST, &params);

        // Parse directory entries
        const entry_count = count_ptr.*;
        const entry_data = data_buf[buffer_offset + 8 ..];

        var parsed: usize = 0;
        var entry_ptr: ?*protocol.DirInfo = if (entry_count > 0)
            @ptrCast(@alignCast(entry_data.ptr))
        else
            null;

        while (entry_ptr) |entry| {
            if (parsed >= entries.len) break;

            const name_str = entry.getName();
            const name_slice = name_str.getSlice();

            // Copy entry to output
            entries[parsed] = DirEntry{
                .info = entry.info,
                .name_len = @intCast(@min(name_slice.len, 255)),
            };
            @memcpy(entries[parsed].name[0..entries[parsed].name_len], name_slice[0..entries[parsed].name_len]);

            parsed += 1;

            // Update resume point
            resume_point.* += 1;

            // Move to next entry
            entry_ptr = entry.getNext();
        }

        return parsed;
    }

    /// Remove a file
    pub fn removeFile(self: *Self, root: u32, path: []const u8) VBoxSfError!void {
        if (path.len > config.MAX_PATH_LEN) {
            return error.PathTooLong;
        }

        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        const str_header = protocol.ShflString.initInBuffer(data_buf, path) orelse {
            return error.BufferOverflow;
        };
        const str_size: u32 = @intCast(str_header.totalSize());

        // Parameters:
        // [0] IN: root handle
        // [1] IN: path (ShflString)
        // [2] IN: flags (0 = file, 1 = directory)

        var params = [3]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, str_size),
            vmmdev.hgcm.HgcmParam.initU32(0), // file
        };

        try self.hgcmCall(.REMOVE, &params);
    }

    /// Remove a directory
    pub fn removeDir(self: *Self, root: u32, path: []const u8) VBoxSfError!void {
        if (path.len > config.MAX_PATH_LEN) {
            return error.PathTooLong;
        }

        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        const str_header = protocol.ShflString.initInBuffer(data_buf, path) orelse {
            return error.BufferOverflow;
        };
        const str_size: u32 = @intCast(str_header.totalSize());

        var params = [3]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, str_size),
            vmmdev.hgcm.HgcmParam.initU32(1), // directory
        };

        try self.hgcmCall(.REMOVE, &params);
    }

    /// Rename a file or directory
    pub fn rename(self: *Self, root: u32, old_path: []const u8, new_path: []const u8) VBoxSfError!void {
        if (old_path.len > config.MAX_PATH_LEN or new_path.len > config.MAX_PATH_LEN) {
            return error.PathTooLong;
        }

        const held = self.lock.acquire();
        defer held.release();

        const data_buf = self.getDataBuf();
        const data_phys = self.getDataPhys();

        // Build source path string
        const src_str = protocol.ShflString.initInBuffer(data_buf, old_path) orelse {
            return error.BufferOverflow;
        };
        const src_size: usize = src_str.totalSize();

        // Build dest path string
        const dst_str = protocol.ShflString.initInBuffer(data_buf[src_size..], new_path) orelse {
            return error.BufferOverflow;
        };
        const dst_size: u32 = @intCast(dst_str.totalSize());

        // Parameters:
        // [0] IN: root handle
        // [1] IN: source path
        // [2] IN: dest path
        // [3] IN: flags (0)

        var params = [4]vmmdev.hgcm.HgcmParam{
            vmmdev.hgcm.HgcmParam.initU32(root),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys, @intCast(src_size)),
            vmmdev.hgcm.HgcmParam.initLinAddrIn(data_phys + src_size, dst_size),
            vmmdev.hgcm.HgcmParam.initU32(0),
        };

        try self.hgcmCall(.RENAME, &params);
    }

    /// Create a directory
    pub fn mkdir(self: *Self, root: u32, path: []const u8) VBoxSfError!void {
        // Use CREATE with DIRECTORY flag
        const result = try self.createFile(root, path, config.CreateFlags.CREATE_NEW |
            config.CreateFlags.DIRECTORY |
            config.CreateFlags.ACCESS_READ);

        // Close the handle immediately
        self.closeFile(root, result.handle) catch {};
    }
};

/// Simplified directory entry for iteration
pub const DirEntry = struct {
    info: protocol.FsObjInfo,
    name: [256]u8 = undefined,
    name_len: u8 = 0,

    pub fn getName(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ============================================================================
// Public Initialization Function
// ============================================================================

/// Initialize VBoxSF driver
pub fn init() VBoxSfError!*VBoxSfDriver {
    const driver = heap.allocator().create(VBoxSfDriver) catch {
        return error.NoMemory;
    };

    try driver.init();

    return driver;
}
