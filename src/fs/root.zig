//! Filesystem Modules
//!
//! Exports the core filesystem implementations and the Virtual File System (VFS).
//!
//! Modules:
//! - `initrd`: Initial RAM Disk (read-only tar archive).
//! - `vfs`: Virtual File System (mount points, path resolution).
//! - `sfs`: Simple File System (basic block-based filesystem).
//! - `partitions`: Partition table handling (MBR/GPT).

pub const initrd = @import("initrd.zig");
pub const vfs = @import("vfs.zig");
pub const sfs = @import("sfs/root.zig");
pub const partitions = @import("partitions");
pub const meta = @import("fs_meta");
pub const virtio9p = @import("virtio9p.zig");
pub const virtiofs = @import("virtiofs.zig");

