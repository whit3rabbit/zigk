//! Host-Guest Communication Manager (HGCM)
//!
//! HGCM provides a mechanism for guest applications to call host services.
//! VBoxSharedFolders is one such HGCM service.
//!
//! Reference: VirtualBox source - include/VBox/VMMDev.h

const std = @import("std");
const types = @import("types.zig");

/// HGCM service location types
pub const LocationType = enum(u32) {
    /// Locate by name string
    LocByName = 1,
    /// Locate by GUID
    LocByGuid = 2,
};

/// HGCM parameter types
pub const ParamType = enum(u32) {
    /// 32-bit unsigned integer
    UInt32 = 1,
    /// 64-bit unsigned integer
    UInt64 = 2,
    /// Linear pointer to guest memory (kernel buffer)
    LinAddr = 3,
    /// Linear pointer for read
    LinAddrIn = 4,
    /// Linear pointer for write
    LinAddrOut = 5,
    /// Kernel-buffer (same as LinAddr)
    LinAddrKernel = 6,
    /// Kernel-buffer for read
    LinAddrKernelIn = 7,
    /// Kernel-buffer for write
    LinAddrKernelOut = 8,
    /// Page list
    PageList = 9,
    /// Embedded buffer
    Embedded = 10,
    /// Page list with physical addresses
    PageListIn = 11,
    /// Page list for write
    PageListOut = 12,
    _,
};

/// HGCM Connect request
pub const HgcmConnectRequest = extern struct {
    header: types.RequestHeader,
    /// Location type (LocByName or LocByGuid)
    loc_type: LocationType,
    /// Service name (null-terminated, 128 bytes max)
    loc_name: [128]u8,
    /// Returned: Client ID
    client_id: u32,

    pub const SIZE: u32 = types.RequestHeader.SIZE + 136;

    pub fn init(service_name: []const u8) HgcmConnectRequest {
        var req = HgcmConnectRequest{
            .header = types.RequestHeader.init(.HgcmConnect, SIZE),
            .loc_type = .LocByName,
            .loc_name = [_]u8{0} ** 128,
            .client_id = 0,
        };

        // Copy service name (truncate if too long)
        const copy_len = @min(service_name.len, 127);
        @memcpy(req.loc_name[0..copy_len], service_name[0..copy_len]);
        req.loc_name[copy_len] = 0;

        return req;
    }
};

/// HGCM Disconnect request
pub const HgcmDisconnectRequest = extern struct {
    header: types.RequestHeader,
    /// Client ID to disconnect
    client_id: u32,

    pub const SIZE: u32 = types.RequestHeader.SIZE + 4;

    pub fn init(client_id: u32) HgcmDisconnectRequest {
        return .{
            .header = types.RequestHeader.init(.HgcmDisconnect, SIZE),
            .client_id = client_id,
        };
    }
};

/// HGCM parameter value union
pub const ParamValue = extern union {
    /// For UInt32
    value32: u32,
    /// For UInt64
    value64: u64,
    /// For linear pointers
    pointer: extern struct {
        /// Size of buffer
        size: u32,
        /// Linear address (physical in guest)
        addr: u64,
    },
};

/// HGCM Call parameter (64-bit version)
pub const HgcmParam = extern struct {
    /// Parameter type
    param_type: ParamType,
    /// Padding for alignment
    _padding: u32 = 0,
    /// Parameter value
    value: ParamValue,

    pub const SIZE: usize = 24;

    pub fn initU32(val: u32) HgcmParam {
        return .{
            .param_type = .UInt32,
            .value = .{ .value32 = val },
        };
    }

    pub fn initU64(val: u64) HgcmParam {
        return .{
            .param_type = .UInt64,
            .value = .{ .value64 = val },
        };
    }

    pub fn initLinAddrIn(phys_addr: u64, size: u32) HgcmParam {
        return .{
            .param_type = .LinAddrKernelIn,
            .value = .{ .pointer = .{ .size = size, .addr = phys_addr } },
        };
    }

    pub fn initLinAddrOut(phys_addr: u64, size: u32) HgcmParam {
        return .{
            .param_type = .LinAddrKernelOut,
            .value = .{ .pointer = .{ .size = size, .addr = phys_addr } },
        };
    }

    pub fn initLinAddr(phys_addr: u64, size: u32) HgcmParam {
        return .{
            .param_type = .LinAddrKernel,
            .value = .{ .pointer = .{ .size = size, .addr = phys_addr } },
        };
    }
};

/// HGCM Call request header (without parameters)
/// Actual request has parameters appended
pub const HgcmCallHeader = extern struct {
    header: types.RequestHeader,
    /// Client ID
    client_id: u32,
    /// Function number
    function: u32,
    /// Number of parameters
    param_count: u32,
    /// Reserved
    reserved: u32,

    pub const SIZE: usize = types.RequestHeader.SIZE + 16;

    pub fn init(request_type: types.RequestType, client_id: u32, function: u32, param_count: u32) HgcmCallHeader {
        // Total size = header + params array
        const total_size: u32 = @intCast(SIZE + param_count * HgcmParam.SIZE);
        return .{
            .header = types.RequestHeader.init(request_type, total_size),
            .client_id = client_id,
            .function = function,
            .param_count = param_count,
            .reserved = 0,
        };
    }
};

/// Maximum number of HGCM parameters per call
pub const MAX_PARAMS: usize = 32;

/// Maximum HGCM call buffer size (header + max params)
pub const MAX_CALL_SIZE: usize = HgcmCallHeader.SIZE + MAX_PARAMS * HgcmParam.SIZE;

/// HGCM result codes (in addition to standard VBox error codes)
pub const HgcmResult = enum(i32) {
    Success = 0,
    InvalidClientId = -2800,
    ServiceNotFound = -2801,
    FunctionNotSupported = -2802,
    BufferTooSmall = -2803,
    InvalidParameter = -2804,
    InvalidHandle = -2805,
    NotFound = -2806,
    Denied = -2807,
    Cancelled = -2808,
    InternalError = -2809,
    _,

    pub fn isSuccess(self: HgcmResult) bool {
        return @intFromEnum(self) >= 0;
    }
};

// Compile-time size checks
comptime {
    if (@sizeOf(HgcmParam) != 24) {
        @compileError("HgcmParam size mismatch");
    }
}
