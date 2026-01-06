// VirtIO driver common module
// Provides virtqueue primitives for VirtIO device drivers

pub const common = @import("common.zig");
pub const rng = @import("rng.zig");

// Re-export commonly used types
pub const Virtqueue = common.Virtqueue;
pub const VirtqDesc = common.VirtqDesc;
pub const VirtioPciCommonCfg = common.VirtioPciCommonCfg;
pub const VirtioRngDriver = rng.VirtioRngDriver;

// Re-export status bits
pub const VIRTIO_STATUS_ACKNOWLEDGE = common.VIRTIO_STATUS_ACKNOWLEDGE;
pub const VIRTIO_STATUS_DRIVER = common.VIRTIO_STATUS_DRIVER;
pub const VIRTIO_STATUS_DRIVER_OK = common.VIRTIO_STATUS_DRIVER_OK;
pub const VIRTIO_STATUS_FEATURES_OK = common.VIRTIO_STATUS_FEATURES_OK;
pub const VIRTIO_STATUS_FAILED = common.VIRTIO_STATUS_FAILED;

// Re-export feature bits
pub const VIRTIO_F_VERSION_1 = common.VIRTIO_F_VERSION_1;

// Re-export descriptor flags
pub const VIRTQ_DESC_F_NEXT = common.VIRTQ_DESC_F_NEXT;
pub const VIRTQ_DESC_F_WRITE = common.VIRTQ_DESC_F_WRITE;
pub const VIRTQ_DESC_F_INDIRECT = common.VIRTQ_DESC_F_INDIRECT;
