// VirtIO-SCSI Device Configuration
//
// Device configuration structures and feature bits per VirtIO Specification 1.1 Section 5.6
//
// Reference: https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html

const std = @import("std");

// ============================================================================
// PCI Device Identification
// ============================================================================

/// VirtIO vendor ID
pub const PCI_VENDOR_VIRTIO: u16 = 0x1AF4;

/// VirtIO-SCSI modern device ID (VirtIO 1.0+)
pub const PCI_DEVICE_SCSI_MODERN: u16 = 0x1048; // 0x1040 + 8

/// VirtIO-SCSI legacy device ID
pub const PCI_DEVICE_SCSI_LEGACY: u16 = 0x1004;

/// PCI class for mass storage
pub const PCI_CLASS_STORAGE: u8 = 0x01;

/// PCI subclass for SCSI
pub const PCI_SUBCLASS_SCSI: u8 = 0x00;

// ============================================================================
// VirtIO-SCSI Feature Bits
// ============================================================================

/// Feature flags for VirtIO-SCSI devices (Section 5.6.3)
pub const Features = struct {
    /// Supports bidirectional data transfer commands
    pub const INOUT: u64 = 1 << 0;
    /// Supports hotplug events on event virtqueue
    pub const HOTPLUG: u64 = 1 << 1;
    /// Supports LUN change events on event virtqueue
    pub const CHANGE: u64 = 1 << 2;
    /// Supports T10 Protection Information (DIF/DIX)
    pub const T10_PI: u64 = 1 << 3;
};

// ============================================================================
// VirtIO-SCSI Configuration Space
// ============================================================================

/// VirtIO-SCSI device configuration (Section 5.6.4)
/// This structure is read from the device-specific configuration space
pub const VirtioScsiConfig = extern struct {
    /// Number of request virtqueues (excluding control and event queues)
    num_queues: u32 align(1),
    /// Maximum number of segments in any single request
    seg_max: u32 align(1),
    /// Maximum size of any single sector-aligned buffer
    max_sectors: u32 align(1),
    /// Maximum number of linked commands per LUN
    cmd_per_lun: u32 align(1),
    /// Size of event information (used for event virtqueue)
    event_info_size: u32 align(1),
    /// Maximum size of sense data (typically 96)
    sense_size: u32 align(1),
    /// Maximum CDB size (typically 16 or 32)
    cdb_size: u32 align(1),
    /// Maximum supported channel number
    max_channel: u16 align(1),
    /// Maximum supported target number
    max_target: u16 align(1),
    /// Maximum supported LUN number
    max_lun: u32 align(1),

    /// Get the total config size
    pub fn size() usize {
        return @sizeOf(VirtioScsiConfig);
    }
};

// Compile-time verification of config structure size
comptime {
    // VirtIO-SCSI config is 36 bytes per spec
    if (@sizeOf(VirtioScsiConfig) != 36) {
        @compileError("VirtioScsiConfig size mismatch - expected 36 bytes");
    }
}

// ============================================================================
// Default Configuration Values
// ============================================================================

/// Default configuration values (QEMU virtio-scsi-pci defaults)
pub const Defaults = struct {
    /// Default number of request queues
    pub const NUM_QUEUES: u32 = 1;
    /// Default maximum segments per request
    pub const SEG_MAX: u32 = 128;
    /// Default maximum sectors per request
    pub const MAX_SECTORS: u32 = 0xFFFF;
    /// Default commands per LUN
    pub const CMD_PER_LUN: u32 = 128;
    /// Default sense data size
    pub const SENSE_SIZE: u32 = 96;
    /// Default CDB size
    pub const CDB_SIZE: u32 = 32;
    /// Default max target
    pub const MAX_TARGET: u16 = 255;
    /// Default max LUN
    pub const MAX_LUN: u32 = 16383; // Per SAM-5 spec
};

// ============================================================================
// VirtIO Queue Indices
// ============================================================================

/// VirtIO-SCSI virtqueue indices
pub const QueueIndex = struct {
    /// Control virtqueue (TMF commands)
    pub const CONTROL: u16 = 0;
    /// Event virtqueue (async notifications)
    pub const EVENT: u16 = 1;
    /// First request virtqueue (I/O)
    pub const REQUEST_BASE: u16 = 2;
};

// ============================================================================
// Limits
// ============================================================================

/// Driver-imposed limits
pub const Limits = struct {
    /// Maximum request queues we support
    pub const MAX_REQUEST_QUEUES: usize = 4;
    /// Maximum LUNs we track
    pub const MAX_LUNS: usize = 32;
    /// Maximum pending requests per queue
    pub const MAX_PENDING_PER_QUEUE: usize = 128;
    /// Maximum CDB size we support
    pub const MAX_CDB_SIZE: usize = 32;
    /// Sense data buffer size
    pub const SENSE_SIZE: usize = 96;
    /// Queue size (typical VirtIO queue size)
    pub const DEFAULT_QUEUE_SIZE: u16 = 128;
};
