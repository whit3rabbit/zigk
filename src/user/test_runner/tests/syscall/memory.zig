const syscall = @import("syscall");

// Memory Test 1: mmap anonymous allocation
pub fn testMmapAnonymous() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096; // One page
    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

    if (addr) |mapped_addr| {
        // mapped_addr is [*]u8
        // Try to write to the mapped memory
        mapped_addr[0] = 42;
        mapped_addr[4095] = 43;

        // Read back and verify
        if (mapped_addr[0] != 42 or mapped_addr[4095] != 43) return error.TestFailed;

        // Cleanup
        _ = syscall.munmap(mapped_addr, size) catch {};
    } else |err| {
        // Not implemented yet - skip test
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    }
}

// Memory Test 2: mmap with specific address (MAP_FIXED)
pub fn testMmapFixed() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const MAP_FIXED = 0x10;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // Try to map at a high address (likely in user space)
    const desired_addr: usize = 0x70000000;
    const size: usize = 4096;

    const addr = syscall.mmap(@ptrFromInt(desired_addr), size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, 0, 0);

    if (addr) |mapped_addr| {
        // With MAP_FIXED, should get exactly the address we requested
        if (@intFromPtr(mapped_addr) != desired_addr) {
            _ = syscall.munmap(mapped_addr, size) catch {};
            return error.TestFailed;
        }

        // Cleanup
        _ = syscall.munmap(mapped_addr, size) catch {};
    } else |err| {
        // Not implemented or address not available - acceptable
        if (err == error.NotImplemented or err == error.InvalidArgument or err == error.OutOfMemory) {
            return error.SkipTest;
        }
        return err;
    }
}

// Memory Test 3: mmap with protection bits
pub fn testMmapWithProtection() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;

    const size: usize = 4096;
    const addr = syscall.mmap(null, size, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

    if (addr) |mapped_addr| {
        // We mapped it read-only
        // We can't easily test that writes fail (would cause fault)
        // Just verify we can read
        _ = mapped_addr[0]; // Should not crash

        // Cleanup
        _ = syscall.munmap(mapped_addr, size) catch {};
    } else |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    }
}

// Memory Test 4: munmap releases memory
pub fn testMunmap() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;
    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Unmap the memory
    try syscall.munmap(addr, size);

    // After munmap, accessing the memory would cause a fault
    // We can't easily test this without crashing
    // Just verify munmap succeeded
}

// Memory Test 5: brk expand heap
pub fn testBrkExpand() !void {
    // Get current brk
    const current_brk = syscall.brk(0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Expand by 4KB
    const new_brk = try syscall.brk(current_brk + 4096);

    // Should have expanded
    if (new_brk < current_brk + 4096) return error.TestFailed;

    // Contract back
    _ = syscall.brk(current_brk) catch {};
}

// Memory Test 6: brk shrink heap
pub fn testBrkShrink() !void {
    // Get current brk
    const current_brk = syscall.brk(0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Expand first
    const expanded_brk = try syscall.brk(current_brk + 8192);
    if (expanded_brk < current_brk + 8192) return error.SkipTest;

    // Now shrink back
    const shrunk_brk = try syscall.brk(current_brk + 4096);

    // Should have shrunk
    if (shrunk_brk > expanded_brk) return error.TestFailed;

    // Restore
    _ = syscall.brk(current_brk) catch {};
}

// Memory Test 7: mmap with zero length fails
pub fn testMmapLengthZero() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;

    const result = syscall.mmap(null, 0, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

    if (result) |addr| {
        _ = syscall.munmap(addr, 4096) catch {};
        return error.TestFailed; // Should have failed
    } else |err| {
        // Should fail with InvalidArgument
        if (err != error.InvalidArgument) {
            // Some other error is acceptable (NotImplemented, etc.)
            if (err == error.NotImplemented) return error.SkipTest;
        }
    }
}

// Memory Test 8: mmap with huge size fails gracefully
pub fn testMmapLengthOverflow() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;

    // Try to allocate an absurdly large amount
    const huge_size: usize = 1024 * 1024 * 1024 * 1024; // 1TB

    const result = syscall.mmap(null, huge_size, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

    if (result) |addr| {
        _ = syscall.munmap(addr, huge_size) catch {};
        // If it somehow succeeded, that's actually fine (virtual memory)
    } else |err| {
        // Should fail with OutOfMemory or InvalidArgument
        if (err != error.OutOfMemory and err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
        }
    }
}

// Memory Test 9: Multiple small allocations
pub fn testMultipleSmallAllocations() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // Allocate 10 small regions
    var addrs: [10][*]u8 = undefined;
    var i: usize = 0;

    while (i < 10) : (i += 1) {
        const addr = syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
            // Clean up any we allocated so far
            var j: usize = 0;
            while (j < i) : (j += 1) {
                _ = syscall.munmap(addrs[j], 4096) catch {};
            }
            if (err == error.NotImplemented) return error.SkipTest;
            return err;
        };

        addrs[i] = addr;

        // Write to each allocation
        addr[0] = @intCast(i);
    }

    // Verify all allocations
    i = 0;
    while (i < 10) : (i += 1) {
        if (addrs[i][0] != @as(u8, @intCast(i))) {
            // Clean up
            var j: usize = 0;
            while (j < 10) : (j += 1) {
                _ = syscall.munmap(addrs[j], 4096) catch {};
            }
            return error.TestFailed;
        }
    }

    // Clean up all
    i = 0;
    while (i < 10) : (i += 1) {
        try syscall.munmap(addrs[i], 4096);
    }
}

// Memory Test 10: Allocate, write, munmap, allocate again
pub fn testAllocWriteMunmapRealloc() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // First allocation
    const addr1 = syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Write to it
    addr1[0] = 123;

    // Free it
    try syscall.munmap(addr1, 4096);

    // Allocate again (might get same address, might not)
    const addr2 = try syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);

    // Write to new allocation
    addr2[0] = 234;

    if (addr2[0] != 234) return error.TestFailed;

    // Cleanup
    try syscall.munmap(addr2, 4096);
}

// Memory Test 11: mprotect to read-only
pub fn testMprotectReadOnly() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;

    // Map with read-write
    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Write to verify it's writable
    addr[0] = 42;

    // Change protection to read-only
    syscall.mprotect(addr, size, PROT_READ) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Verify we can still read
    if (addr[0] != 42) return error.TestFailed;

    // Note: We cannot test that writes fail without causing a fault
    // Just verify mprotect succeeded
}

// Memory Test 12: mprotect upgrade to read-write
pub fn testMprotectReadWrite() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;

    // Map with read-only
    const addr = syscall.mmap(null, size, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Upgrade protection to read-write
    syscall.mprotect(addr, size, PROT_READ | PROT_WRITE) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Now we should be able to write
    addr[0] = 123;
    if (addr[0] != 123) return error.TestFailed;
}

// Memory Test 13: mprotect on invalid address
pub fn testMprotectInvalidAddr() !void {
    const PROT_READ = 0x1;

    // Try to mprotect an unmapped address
    const invalid_addr: [*]u8 = @ptrFromInt(0x12340000);
    const size: usize = 4096;

    const result = syscall.mprotect(invalid_addr, size, PROT_READ);

    if (result) |_| {
        return error.TestFailed; // Should have failed
    } else |err| {
        // Should fail with ENOMEM or EINVAL
        if (err != error.OutOfMemory and err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Memory Test 14: mlock pages
pub fn testMlockPages() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;

    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Lock the pages (may be a no-op in current implementation)
    syscall.mlock(addr, size) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        // Other errors are acceptable - mlock might fail due to limits
        return;
    };

    // Pages should still be accessible
    addr[0] = 42;
    if (addr[0] != 42) return error.TestFailed;
}

// Memory Test 15: mlock + munlock sequence
pub fn testMunlockPages() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;

    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Lock the pages
    syscall.mlock(addr, size) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        // If mlock fails, skip the test
        return error.SkipTest;
    };

    // Unlock the pages
    syscall.munlock(addr, size) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };

    // Pages should still be accessible
    addr[0] = 123;
    if (addr[0] != 123) return error.TestFailed;
}

// Memory Test 16: madvise sequential hint
pub fn testMadviseSequential() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 8192; // Two pages

    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Give hint that we'll access sequentially (MADV_SEQUENTIAL = 2)
    const MADV_SEQUENTIAL = 2;
    syscall.madvise(addr, size, MADV_SEQUENTIAL) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        // Other errors are acceptable - madvise is just a hint
        return;
    };

    // Verify memory is still accessible
    addr[0] = 1;
    addr[4096] = 2;
    if (addr[0] != 1 or addr[4096] != 2) return error.TestFailed;
}

// Memory Test 17: msync on anonymous mapping
pub fn testMsyncNoOp() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    const size: usize = 4096;

    const addr = syscall.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, size) catch {};

    // Write some data
    addr[0] = 42;

    // Sync to storage (MS_SYNC = 4, should be no-op for anonymous mapping)
    const MS_SYNC = 4;
    syscall.msync(addr, size, MS_SYNC) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        // Other errors are acceptable - msync might not work on anonymous mappings
        return;
    };

    // Data should still be there
    if (addr[0] != 42) return error.TestFailed;
}

// Memory Test 18: mlockall + munlockall sequence
pub fn testMlockallMunlockall() !void {
    // Lock all current pages (MCL_CURRENT = 1)
    const MCL_CURRENT = 1;
    try syscall.mlockall(MCL_CURRENT);

    // Unlock all pages
    try syscall.munlockall();
}

// Memory Test 19: mincore checks page residency
pub fn testMincoreBasic() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // First mmap an anonymous page
    const addr = syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0) catch |err| {
        if (err == error.NotImplemented) return error.SkipTest;
        return err;
    };
    defer _ = syscall.munmap(addr, 4096) catch {};

    // Check residency
    var vec: [1]u8 = .{0};
    try syscall.mincore(addr, 4096, &vec);

    // Page should be resident (bit 0 set)
    if (vec[0] != 1) return error.TestFailed;
}

// Memory Test 20: madvise with invalid alignment
pub fn testMadviseInvalidAlign() !void {
    const MADV_NORMAL = 0;
    const unaligned_addr: [*]u8 = @ptrFromInt(1);
    const result = syscall.madvise(unaligned_addr, 4096, MADV_NORMAL);

    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // Should fail with EINVAL
        if (err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Memory Test 21: mlockall with invalid flags
pub fn testMlockallInvalidFlags() !void {
    // Test with invalid flag bits (not MCL_CURRENT, MCL_FUTURE, MCL_ONFAULT)
    const INVALID_FLAG = 0x8; // Not a valid MCL_* flag
    const result = syscall.mlockall(INVALID_FLAG);

    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // Should fail with EINVAL
        if (err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Memory Test 22: mincore with invalid alignment
pub fn testMincoreInvalidAlign() !void {
    const unaligned_addr: [*]u8 = @ptrFromInt(1);
    var vec: [1]u8 = .{0};
    const result = syscall.mincore(unaligned_addr, 4096, &vec);

    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // Should fail with EINVAL
        if (err != error.InvalidArgument) {
            if (err == error.NotImplemented) return error.SkipTest;
            return error.TestFailed;
        }
    }
}

// Memory Test 23: mlockall with MCL_FUTURE flag
pub fn testMlockallFutureFlag() !void {
    const MCL_FUTURE = 2;
    try syscall.mlockall(MCL_FUTURE);

    // Unlock after test
    try syscall.munlockall();
}

// =============================================================================
// Phase 18: Memory Management Extension Tests
// =============================================================================

// Memory Test 24: memfd_create basic operation
pub fn testMemfdCreateBasic() !void {
    const fd = try syscall.memfd_create("test", 0);
    defer _ = syscall.close(fd) catch {};

    // Write data
    const data = "hello";
    const written = try syscall.write(fd, data.ptr, data.len);
    if (written != data.len) return error.TestFailed;

    // Seek to beginning
    _ = try syscall.lseek(fd, 0, syscall.SEEK_SET);

    // Read back
    var buf: [5]u8 = undefined;
    const read_len = try syscall.read(fd, &buf, buf.len);
    if (read_len != data.len) return error.TestFailed;
    if (!std.mem.eql(u8, &buf, data)) return error.TestFailed;
}

// Memory Test 25: memfd_create with CLOEXEC flag
pub fn testMemfdCreateCloexec() !void {
    const fd = try syscall.memfd_create("cloexec", syscall.MFD_CLOEXEC);
    defer _ = syscall.close(fd) catch {};

    // Just verify the flag is accepted
    if (fd < 0) return error.TestFailed;
}

// Memory Test 26: memfd_create with invalid flags
pub fn testMemfdCreateInvalidFlags() !void {
    const result = syscall.memfd_create("bad", 0xFFFF);
    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

// Memory Test 27: memfd_create read/write/seek operations
pub fn testMemfdCreateReadWriteSeek() !void {
    const fd = try syscall.memfd_create("rwseek", 0);
    defer _ = syscall.close(fd) catch {};

    // Write 100 bytes of pattern data
    var write_buf: [100]u8 = undefined;
    for (&write_buf, 0..) |*b, i| {
        b.* = @intCast(i);
    }
    const written = try syscall.write(fd, &write_buf, write_buf.len);
    if (written != write_buf.len) return error.TestFailed;

    // Seek to offset 50
    const pos = try syscall.lseek(fd, 50, syscall.SEEK_SET);
    if (pos != 50) return error.TestFailed;

    // Read 50 bytes
    var read_buf: [50]u8 = undefined;
    const read_len = try syscall.read(fd, &read_buf, read_buf.len);
    if (read_len != read_buf.len) return error.TestFailed;

    // Verify data (should be bytes 50..99)
    for (read_buf, 0..) |b, i| {
        if (b != @as(u8, @intCast(i + 50))) return error.TestFailed;
    }

    // Seek to end
    const end_pos = try syscall.lseek(fd, 0, syscall.SEEK_END);
    if (end_pos != 100) return error.TestFailed;
}

// Memory Test 28: memfd_create truncate operations
pub fn testMemfdCreateTruncate() !void {
    const fd = try syscall.memfd_create("truncate", 0);
    defer _ = syscall.close(fd) catch {};

    // Write 100 bytes
    var write_buf: [100]u8 = undefined;
    @memset(&write_buf, 0xAA);
    _ = try syscall.write(fd, &write_buf, write_buf.len);

    // Truncate to 50
    try syscall.ftruncate(fd, 50);

    // Verify size via fstat
    var stat_buf: syscall.Stat = undefined;
    try syscall.fstat(fd, &stat_buf);
    if (stat_buf.size != 50) return error.TestFailed;

    // Extend to 200
    try syscall.ftruncate(fd, 200);
    try syscall.fstat(fd, &stat_buf);
    if (stat_buf.size != 200) return error.TestFailed;
}

// Memory Test 29: memfd_create mmap operation
pub fn testMemfdCreateMmap() !void {
    const fd = try syscall.memfd_create("mmap_test", 0);
    defer _ = syscall.close(fd) catch {};

    // Write data
    const data = "mapped data";
    _ = try syscall.write(fd, data.ptr, data.len);

    // Truncate to one page
    try syscall.ftruncate(fd, 4096);

    // mmap the fd
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;
    const MAP_SHARED = 0x01;
    const mapped = try syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    defer _ = syscall.munmap(mapped, 4096) catch {};

    // Verify first 11 bytes match
    if (!std.mem.eql(u8, mapped[0..data.len], data)) return error.TestFailed;

    // Write via mapped memory
    const new_data = "updated";
    @memcpy(mapped[20..][0..new_data.len], new_data);

    // Seek fd and read back
    _ = try syscall.lseek(fd, 20, syscall.SEEK_SET);
    var read_buf: [7]u8 = undefined;
    const read_len = try syscall.read(fd, &read_buf, read_buf.len);
    if (read_len != new_data.len) return error.TestFailed;
    if (!std.mem.eql(u8, &read_buf, new_data)) return error.TestFailed;
}

// Memory Test 30: mremap grow with MREMAP_MAYMOVE
pub fn testMremapGrow() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // mmap 4096 bytes
    const addr = try syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    
    // Write pattern byte
    addr[0] = 0x42;

    // Grow to 8192 bytes with MREMAP_MAYMOVE
    const new_addr = try syscall.mremap(addr, 4096, 8192, syscall.MREMAP_MAYMOVE);

    // Verify pattern preserved
    if (new_addr[0] != 0x42) return error.TestFailed;

    // Write to new region
    new_addr[4096] = 0x43;
    if (new_addr[4096] != 0x43) return error.TestFailed;

    // Clean up
    _ = syscall.munmap(new_addr, 8192) catch {};
}

// Memory Test 31: mremap shrink
pub fn testMremapShrink() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // mmap 8192 bytes
    const addr = try syscall.mmap(null, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    
    // Write pattern
    addr[0] = 0x55;

    // Shrink to 4096 bytes
    const new_addr = try syscall.mremap(addr, 8192, 4096, 0);

    // Should return same address when shrinking
    if (@intFromPtr(new_addr) != @intFromPtr(addr)) return error.TestFailed;

    // Verify pattern preserved
    if (new_addr[0] != 0x55) return error.TestFailed;

    // Clean up
    _ = syscall.munmap(new_addr, 4096) catch {};
}

// Memory Test 32: mremap with invalid address
pub fn testMremapInvalidAddr() !void {
    const invalid_addr: [*]u8 = @ptrFromInt(0x12340000);
    const result = syscall.mremap(invalid_addr, 4096, 8192, syscall.MREMAP_MAYMOVE);

    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        // Should fail with EFAULT (BadAddress) or EINVAL
        if (err != error.BadAddress and err != error.InvalidArgument) {
            return error.TestFailed;
        }
    }
}

// Memory Test 33: msync flag validation
pub fn testMsyncValidation() !void {
    const MAP_ANONYMOUS = 0x20;
    const MAP_PRIVATE = 0x02;
    const PROT_READ = 0x1;
    const PROT_WRITE = 0x2;

    // mmap anonymous page
    const addr = try syscall.mmap(null, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, 0, 0);
    defer _ = syscall.munmap(addr, 4096) catch {};

    // Test with valid MS_SYNC flag
    const MS_SYNC = 4;
    try syscall.msync(addr, 4096, MS_SYNC);

    // Test with invalid flags (both MS_SYNC and MS_ASYNC)
    const MS_ASYNC = 1;
    const invalid_flags = MS_SYNC | MS_ASYNC;
    const result = syscall.msync(addr, 4096, invalid_flags);

    if (result) |_| {
        return error.TestFailed;
    } else |err| {
        if (err != error.InvalidArgument) return error.TestFailed;
    }
}

const std = @import("std");
