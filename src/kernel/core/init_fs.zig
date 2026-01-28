//! Filesystem Initialization
//!
//! Initializes the Virtual File System (VFS) and mounts core filesystems.
//!
//! Mount layout:
//! - `/`: InitRD (Initial RAM Disk) - read-only, contains init executable
//! - `/dev`: DevFS (Device Filesystem) - virtual device files
//! - `/mnt`: SFS (Simple File System) - read/write persistent storage (on /dev/sda)

const std = @import("std");
const builtin = @import("builtin");
const console = @import("console");
const fs = @import("fs");
const meta = @import("fs").meta;
const devfs = @import("devfs");
const heap = @import("heap");
const fd_mod = @import("fd");

/// Initialize the Virtual File System and mount core filesystems
pub fn initVfs() void {
    console.print("\n");
    console.info("Initializing VFS...", .{});

    // Initialize VFS singleton
    fs.vfs.Vfs.init();

    // Mount InitRD at /
    fs.vfs.Vfs.mount("/", fs.vfs.initrd_fs) catch |err| {
        console.err("Failed to mount InitRD at /: {}", .{err});
    };

    // Mount DevFS at /dev
    fs.vfs.Vfs.mount("/dev", devfs.dev_fs) catch |err| {
        console.err("Failed to mount DevFS at /dev: {}", .{err});
    };

    console.info("VFS initialized (mounted / and /dev)", .{});
}

/// Initialize and mount the block filesystem (SFS)
/// Requires block drivers to be initialized first
pub fn initBlockFs() void {
    console.print("\n");
    console.info("Initializing Block Filesystem...", .{});

    // Check if /dev/sda exists (created by initStorage via DevFS check)
    // SFS.init will attempt to open it using VFS
    const sfs_instance = fs.sfs.SFS.init("/dev/sda") catch |err| {
        console.warn("SFS: Failed to initialize on /dev/sda: {}", .{err});
        return;
    };

    // Mount at /mnt
    fs.vfs.Vfs.mount("/mnt", sfs_instance) catch |err| {
        console.err("SFS: Failed to mount at /mnt: {}", .{err});
        return;
    };

    console.info("SFS: Mounted at /mnt", .{});

    // Run simple filesystem test (debug builds only)
    if (builtin.mode == .Debug) testBlockFs();
}

/// Simple read/write test for the mounted block filesystem
fn testBlockFs() void {
    console.info("SFS: Running read/write test...", .{});

    // Open/Create file
    const path = "/mnt/hello.txt";
    const flags = fd_mod.O_CREAT | fd_mod.O_RDWR;

    const fd = fs.vfs.Vfs.open(path, flags) catch |err| {
        console.err("SFS Test: Failed to open {s}: {}", .{ path, err });
        return;
    };
    defer {
        // Simulate correct cleanup:
        // unref() returns true if refcount reaches 0.
        // If so, call close op and free memory.
        if (fd.unref()) {
            if (fd.ops.close) |close_fn| _ = close_fn(fd);
            const alloc = heap.allocator();
            alloc.destroy(fd);
        }
    }

    // Write data
    const message = "Hello, Block World!";
    if (fd.ops.write) |write_fn| {
        const written = write_fn(fd, message);
        console.info("SFS Test: Wrote {d} bytes", .{written});
    }

    // Seek to beginning
    if (fd.ops.seek) |seek_fn| {
        _ = seek_fn(fd, 0, 0); // SEEK_SET
    }

    // Read back
    var buf: [64]u8 = undefined;
    if (fd.ops.read) |read_fn| {
        const read = read_fn(fd, &buf);
        if (read > 0) {
            const content = buf[0..@intCast(read)];
            console.info("SFS Test: Read back: '{s}'", .{content});

            if (std.mem.eql(u8, content, message)) {
                console.info("SFS Test: PASSED", .{});
            } else {
                console.err("SFS Test: FAILED (content mismatch)", .{});
            }
        } else {
            console.err("SFS Test: FAILED (read 0 bytes)", .{});
        }
    }

    // Test directory operations
    console.info("SFS: Testing directory operations...", .{});

    // Create directory
    const dir_path = "/mnt/testdir";
    fs.vfs.Vfs.mkdir(dir_path, 0o755) catch |err| {
        console.err("SFS Test: mkdir failed: {}", .{err});
        return;
    };
    console.info("SFS Test: Created {s}", .{dir_path});

    // Verify it exists by stat
    const meta_result = fs.vfs.Vfs.statPath(dir_path) orelse {
        console.err("SFS Test: statPath returned null", .{});
        return;
    };

    if (meta_result.mode & meta.S_IFDIR != 0) {
        console.info("SFS Test: Directory verified (mode=0x{x})", .{meta_result.mode});
    } else {
        console.err("SFS Test: FAILED (not a directory, mode=0x{x})", .{meta_result.mode});
        return;
    }

    // Remove directory
    fs.vfs.Vfs.rmdir(dir_path) catch |err| {
        console.err("SFS Test: rmdir failed: {}", .{err});
        return;
    };
    console.info("SFS Test: Removed {s}", .{dir_path});

    // Verify removal (stat should return null)
    if (fs.vfs.Vfs.statPath(dir_path)) |_| {
        console.err("SFS Test: FAILED (directory still exists after rmdir)", .{});
    } else {
        console.info("SFS Directory Test: PASSED", .{});
    }
}
