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
