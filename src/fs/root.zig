//! Filesystem Modules
//!
//! Exports the core filesystem implementations and the Virtual File System (VFS).
//!
//! Modules:
//! - `initrd`: Initial RAM Disk (read-only tar archive).
//! - `vfs`: Virtual File System (mount points, path resolution).
//! - `sfs`: Simple File System (basic block-based filesystem).
//! - `partitions`: Partition table handling (MBR/GPT).
//! - `block_device`: Driver-portable LBA-based block I/O interface.
//! - `ext2`: ext2 filesystem on-disk type definitions.

pub const initrd = @import("initrd.zig");
pub const vfs = @import("vfs.zig");
pub const sfs = @import("sfs/root.zig");
pub const partitions = @import("partitions");
pub const meta = @import("fs_meta");
pub const virtio9p = @import("virtio9p.zig");
pub const virtiofs = @import("virtiofs.zig");
pub const vboxsf = @import("vboxsf.zig");
pub const hgfs = @import("hgfs.zig");
pub const block_device = @import("block_device.zig");
pub const ext2 = @import("ext2/types.zig");
pub const ext2_mount = @import("ext2/mount.zig");

