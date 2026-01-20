// VirtIO-GPU Protocol Definitions
//
// Contains GPU command types, response types, pixel formats, and
// protocol structures per the VirtIO GPU Device Specification (OASIS).
//
// Extracted from virtio_gpu.zig for better modularity.

// ============================================================================
// GPU Command Types
// ============================================================================

pub const VIRTIO_GPU_CMD_GET_DISPLAY_INFO: u32 = 0x0100;
pub const VIRTIO_GPU_CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
pub const VIRTIO_GPU_CMD_RESOURCE_UNREF: u32 = 0x0102;
pub const VIRTIO_GPU_CMD_SET_SCANOUT: u32 = 0x0103;
pub const VIRTIO_GPU_CMD_RESOURCE_FLUSH: u32 = 0x0104;
pub const VIRTIO_GPU_CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
pub const VIRTIO_GPU_CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
pub const VIRTIO_GPU_CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
pub const VIRTIO_GPU_CMD_GET_CAPSET_INFO: u32 = 0x0108;
pub const VIRTIO_GPU_CMD_GET_CAPSET: u32 = 0x0109;
pub const VIRTIO_GPU_CMD_GET_EDID: u32 = 0x010A;

// ============================================================================
// Response Types
// ============================================================================

pub const VIRTIO_GPU_RESP_OK_NODATA: u32 = 0x1100;
pub const VIRTIO_GPU_RESP_OK_DISPLAY_INFO: u32 = 0x1101;
pub const VIRTIO_GPU_RESP_OK_CAPSET_INFO: u32 = 0x1102;
pub const VIRTIO_GPU_RESP_OK_CAPSET: u32 = 0x1103;
pub const VIRTIO_GPU_RESP_OK_EDID: u32 = 0x1104;

pub const VIRTIO_GPU_RESP_ERR_UNSPEC: u32 = 0x1200;
pub const VIRTIO_GPU_RESP_ERR_OUT_OF_MEMORY: u32 = 0x1201;
pub const VIRTIO_GPU_RESP_ERR_INVALID_SCANOUT_ID: u32 = 0x1202;
pub const VIRTIO_GPU_RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1203;
pub const VIRTIO_GPU_RESP_ERR_INVALID_CONTEXT_ID: u32 = 0x1204;
pub const VIRTIO_GPU_RESP_ERR_INVALID_PARAMETER: u32 = 0x1205;

// ============================================================================
// Pixel Formats
// ============================================================================

pub const VIRTIO_GPU_FORMAT_B8G8R8A8_UNORM: u32 = 1;
pub const VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM: u32 = 2;
pub const VIRTIO_GPU_FORMAT_A8R8G8B8_UNORM: u32 = 3;
pub const VIRTIO_GPU_FORMAT_X8R8G8B8_UNORM: u32 = 4;
pub const VIRTIO_GPU_FORMAT_R8G8B8A8_UNORM: u32 = 67;
pub const VIRTIO_GPU_FORMAT_X8B8G8R8_UNORM: u32 = 68;
pub const VIRTIO_GPU_FORMAT_A8B8G8R8_UNORM: u32 = 121;
pub const VIRTIO_GPU_FORMAT_R8G8B8X8_UNORM: u32 = 134;

// ============================================================================
// Feature Bits
// ============================================================================

pub const VIRTIO_GPU_F_VIRGL: u32 = 0;
pub const VIRTIO_GPU_F_EDID: u32 = 1;
pub const VIRTIO_GPU_F_RESOURCE_UUID: u32 = 2;
pub const VIRTIO_GPU_F_RESOURCE_BLOB: u32 = 3;
pub const VIRTIO_GPU_F_CONTEXT_INIT: u32 = 4;

// ============================================================================
// Limits
// ============================================================================

pub const MAX_SCANOUTS: usize = 16;

// Security: Maximum display dimensions to prevent integer overflow and DoS
pub const MAX_DISPLAY_WIDTH: u32 = 8192; // 8K resolution
pub const MAX_DISPLAY_HEIGHT: u32 = 8192;

// ============================================================================
// Protocol Structures
// ============================================================================

/// GPU control header (common to all commands)
pub const VirtioGpuCtrlHdr = extern struct {
    type_: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u8,
    _padding: [3]u8 = .{ 0, 0, 0 },

    /// Create a header for a specific command type
    pub fn init(cmd_type: u32) VirtioGpuCtrlHdr {
        return .{
            .type_ = cmd_type,
            .flags = 0,
            .fence_id = 0,
            .ctx_id = 0,
            .ring_idx = 0,
        };
    }
};

/// Rectangle structure
pub const VirtioGpuRect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    /// Create a full rectangle from dimensions
    pub fn full(w: u32, h: u32) VirtioGpuRect {
        return .{ .x = 0, .y = 0, .width = w, .height = h };
    }
};

/// Display info for a single scanout
pub const VirtioGpuDisplayOne = extern struct {
    r: VirtioGpuRect,
    enabled: u32,
    flags: u32,
};

/// Display info response
pub const VirtioGpuRespDisplayInfo = extern struct {
    hdr: VirtioGpuCtrlHdr,
    pmodes: [MAX_SCANOUTS]VirtioGpuDisplayOne,
};

/// Resource create 2D command
pub const VirtioGpuResourceCreate2d = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};

/// Set scanout command
pub const VirtioGpuSetScanout = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    scanout_id: u32,
    resource_id: u32,
};

/// Resource attach backing command
pub const VirtioGpuResourceAttachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    nr_entries: u32,
};

/// Memory entry for attach backing
pub const VirtioGpuMemEntry = extern struct {
    addr: u64,
    length: u32,
    _padding: u32 = 0,
};

/// Transfer to host 2D command
pub const VirtioGpuTransferToHost2d = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    offset: u64,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Resource flush command
pub const VirtioGpuResourceFlush = extern struct {
    hdr: VirtioGpuCtrlHdr,
    r: VirtioGpuRect,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Resource unref command (releases a resource)
pub const VirtioGpuResourceUnref = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    _padding: u32 = 0,
};

/// Resource detach backing command (detaches memory from resource)
pub const VirtioGpuResourceDetachBacking = extern struct {
    hdr: VirtioGpuCtrlHdr,
    resource_id: u32,
    _padding: u32 = 0,
};
