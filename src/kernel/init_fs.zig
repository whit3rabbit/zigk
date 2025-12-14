const std = @import("std");
const console = @import("console");
const fs = @import("fs");
const devfs = @import("devfs");
const heap = @import("heap");
const fd_mod = @import("fd");

pub fn initVfs() void {
    console.print("\n");
    console.info("Initializing VFS...", .{});

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

    // Run simple filesystem test
    testBlockFs();
}

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
        if (fd.ops.close) |close_fn| _ = close_fn(fd);
        // heap.allocator().destroy(fd); // Vfs.open doesn't use heap? It does. But who owns fd?
        // sys_close destroys it. We should manually destroy if not using sys_close.
        // Actually, Vfs.open returns a pointer allocated on heap.
        // And FileDescriptor.unref calls destroy.
        // So we should simulate unref/close.
        const alloc = heap.allocator();
        alloc.destroy(fd); // fd.close is not enough, need to free struct. But unref does it.
        // We haven't ref-ed it, createFd sets ref=1.
        // So calling ops.close is part of it, but we need to free the memory too.
        // Correct usage:
        // if (fd.unref()) { if (fd.ops.close) |c| _ = c(fd); alloc.destroy(fd); }
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
}
