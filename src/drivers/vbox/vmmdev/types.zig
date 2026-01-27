//! VMMDev Request/Response Types
//!
//! VirtualBox Guest Additions protocol structures for communicating with
//! the VMMDev PCI device (Vendor 0x80EE, Device 0xCAFE).
//!
//! Reference: VirtualBox source - include/VBox/VMMDevCoreTypes.h

const std = @import("std");

/// VMMDev request types
pub const RequestType = enum(u32) {
    /// Get guest capabilities
    GetMouseStatus = 1,
    SetMouseStatus = 2,
    SetPointerShape = 3,
    GetHostVersion = 4,
    Idle = 5,
    GetHostTime = 10,
    CheckTimerFreq = 11,
    GetVMMDevVersion = 17,
    HgcmConnect = 60,
    HgcmDisconnect = 61,
    HgcmCall32 = 62,
    HgcmCall64 = 63,
    HgcmCancel = 64,
    VideoAccelEnable = 70,
    VideoAccelFlush = 71,
    VideoSetVisibleRegion = 72,
    GetDisplayChangeRequest = 51,
    ReportGuestInfo = 50,
    ReportGuestStatus = 52,
    ReportGuestUserState = 74,
    GetStatisticsChangeRequest = 54,
    CtlGuestFilterMask = 42,
    ReportGuestCapabilities = 55,
    SetGuestCapabilities = 56,
    AcknowledgeEvents = 41,
    GetSessionId = 109,
    WriteCoreDump = 118,
    GuestHeartbeat = 119,
    HeartbeatConfigure = 120,
    _,
};

/// VMMDev return codes
pub const ReturnCode = enum(i32) {
    Success = 0,
    NotImplemented = -1,
    NotSupported = -2,
    InvalidParameter = -3,
    InvalidHandle = -4,
    NotFound = -5,
    InProgress = -6,
    Cancelled = -7,
    BufferTooSmall = -8,
    _,

    pub fn isSuccess(self: ReturnCode) bool {
        return @intFromEnum(self) >= 0;
    }
};

/// VMMDev request header (common to all requests)
pub const RequestHeader = extern struct {
    /// Size of the request in bytes (including header)
    size: u32,
    /// VMMDev version (should be VMMDEV_VERSION = 0x00010004)
    version: u32,
    /// Request type
    request_type: RequestType,
    /// Return code (filled by device)
    rc: i32,
    /// Reserved (must be 0)
    reserved1: u32,
    /// Reserved (must be 0)
    reserved2: u32,

    pub const SIZE: usize = 24;
    pub const VMMDEV_VERSION: u32 = 0x00010004;

    pub fn init(request_type: RequestType, total_size: u32) RequestHeader {
        return .{
            .size = total_size,
            .version = VMMDEV_VERSION,
            .request_type = request_type,
            .rc = 0,
            .reserved1 = 0,
            .reserved2 = 0,
        };
    }

    pub fn getReturnCode(self: *const RequestHeader) ReturnCode {
        return @enumFromInt(self.rc);
    }
};

/// GetVMMDevVersion request
pub const GetVersionRequest = extern struct {
    header: RequestHeader,
    /// Returned: Major version
    major: u32,
    /// Returned: Minor version
    minor: u32,
    /// Returned: Build number
    build: u32,
    /// Returned: Supported features mask
    features: u32,

    pub const SIZE: u32 = RequestHeader.SIZE + 16;

    pub fn init() GetVersionRequest {
        return .{
            .header = RequestHeader.init(.GetVMMDevVersion, SIZE),
            .major = 0,
            .minor = 0,
            .build = 0,
            .features = 0,
        };
    }
};

/// ReportGuestInfo request
pub const ReportGuestInfoRequest = extern struct {
    header: RequestHeader,
    /// Interface version (VMMDEV_VERSION)
    interface_version: u32,
    /// OS type (VBOXOSTYPE_*)
    os_type: u32,

    pub const SIZE: u32 = RequestHeader.SIZE + 8;

    // OS type constants
    pub const OS_UNKNOWN: u32 = 0x00000;
    pub const OS_DOS: u32 = 0x10000;
    pub const OS_WIN31: u32 = 0x15000;
    pub const OS_WIN9X: u32 = 0x20000;
    pub const OS_WINNT: u32 = 0x30000;
    pub const OS_WINNT4: u32 = 0x31000;
    pub const OS_WIN2K: u32 = 0x32000;
    pub const OS_WINXP: u32 = 0x33000;
    pub const OS_WIN2K3: u32 = 0x34000;
    pub const OS_WINVISTA: u32 = 0x35000;
    pub const OS_WIN2K8: u32 = 0x36000;
    pub const OS_WIN7: u32 = 0x37000;
    pub const OS_WIN8: u32 = 0x38000;
    pub const OS_WIN81: u32 = 0x39000;
    pub const OS_WIN10: u32 = 0x3A000;
    pub const OS_WIN2K16: u32 = 0x3B000;
    pub const OS_WIN2K19: u32 = 0x3C000;
    pub const OS_OS2: u32 = 0x40000;
    pub const OS_LINUX: u32 = 0x50000;
    pub const OS_LINUX22: u32 = 0x51000;
    pub const OS_LINUX24: u32 = 0x52000;
    pub const OS_LINUX26: u32 = 0x53000;
    pub const OS_FREEBSD: u32 = 0x60000;
    pub const OS_OPENBSD: u32 = 0x61000;
    pub const OS_NETBSD: u32 = 0x62000;
    pub const OS_NETWARE: u32 = 0x70000;
    pub const OS_SOLARIS: u32 = 0x80000;
    pub const OS_MACOS: u32 = 0x90000;
    pub const OS_HAIKU: u32 = 0xA0000;
    pub const OS_OTHER: u32 = 0xFF000;

    // 64-bit flag
    pub const OS_64BIT: u32 = 0x100;

    pub fn init(os_type: u32) ReportGuestInfoRequest {
        return .{
            .header = RequestHeader.init(.ReportGuestInfo, SIZE),
            .interface_version = RequestHeader.VMMDEV_VERSION,
            .os_type = os_type,
        };
    }
};

/// AcknowledgeEvents request
pub const AcknowledgeEventsRequest = extern struct {
    header: RequestHeader,
    /// Events to acknowledge (bitmask)
    events: u32,

    pub const SIZE: u32 = RequestHeader.SIZE + 4;

    pub fn init(events: u32) AcknowledgeEventsRequest {
        return .{
            .header = RequestHeader.init(.AcknowledgeEvents, SIZE),
            .events = events,
        };
    }
};

/// CtlGuestFilterMask request - set event filter
pub const CtlGuestFilterMaskRequest = extern struct {
    header: RequestHeader,
    /// Events to enable
    or_mask: u32,
    /// Events to disable
    not_mask: u32,

    pub const SIZE: u32 = RequestHeader.SIZE + 8;

    pub fn init(or_mask: u32, not_mask: u32) CtlGuestFilterMaskRequest {
        return .{
            .header = RequestHeader.init(.CtlGuestFilterMask, SIZE),
            .or_mask = or_mask,
            .not_mask = not_mask,
        };
    }
};

/// Event types that VMMDev can signal
pub const Event = struct {
    pub const HGCM: u32 = 1 << 0;
    pub const MOUSE_POSITION_CHANGED: u32 = 1 << 9;
    pub const DISPLAY_CHANGE_REQUEST: u32 = 1 << 2;
    pub const JUDGED_CREDENTIALS: u32 = 1 << 3;
    pub const SEAMLESS_MODE_CHANGE_REQUEST: u32 = 1 << 5;
    pub const MEMORY_BALLOON_CHANGE_REQUEST: u32 = 1 << 6;
    pub const STATISTICS_INTERVAL_CHANGE_REQUEST: u32 = 1 << 7;
    pub const VRDP_STATE: u32 = 1 << 8;
    pub const MOUSE_CAPABILITIES_CHANGED: u32 = 1 << 10;
    pub const GRAPHICS_MODE_CHANGED: u32 = 1 << 11;
};

/// Guest capabilities that can be reported
pub const GuestCaps = struct {
    pub const SEAMLESS: u32 = 1 << 0;
    pub const GRAPHICS: u32 = 1 << 1;
    pub const MOUSE_POINTER_SHAPE: u32 = 1 << 2;
    pub const AUTO_LOGON: u32 = 1 << 3;
    pub const GUEST_MEMORY_BALLOON: u32 = 1 << 4;
};

// Compile-time size checks
comptime {
    if (@sizeOf(RequestHeader) != 24) {
        @compileError("RequestHeader size mismatch");
    }
    if (@sizeOf(GetVersionRequest) != 40) {
        @compileError("GetVersionRequest size mismatch");
    }
    if (@sizeOf(ReportGuestInfoRequest) != 32) {
        @compileError("ReportGuestInfoRequest size mismatch");
    }
}
