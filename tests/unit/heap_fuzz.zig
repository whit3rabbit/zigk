// Heap Allocator Fuzz Tests
//
// Randomized testing for the kernel heap allocator.
// Runs on host (not freestanding) using std.heap.page_allocator as backing.
//
// Tests:
//   1. Random alloc/free sequences verify no corruption
//   2. Coalescing verification by tracking free block count
//   3. Memory pattern writing/checking to detect buffer overflows
//   4. Stress testing with varying allocation sizes
//
// Run with: zig build test

const std = @import("std");
const testing = std.testing;

// Import heap module (host-compatible build)
const heap = @import("heap");

// Backing memory for heap tests
var backing_buffer: [4 * 1024 * 1024]u8 = undefined; // 4 MB test heap

fn initHeap() void {
    heap.reset();
    heap.init(@intFromPtr(&backing_buffer), backing_buffer.len);
}

// Test basic allocation and free
test "heap: basic alloc and free" {
    initHeap();

    // Allocate some memory
    const ptr1 = heap.alloc(100) orelse return error.OutOfMemory;
    const ptr2 = heap.alloc(200) orelse return error.OutOfMemory;
    const ptr3 = heap.alloc(300) orelse return error.OutOfMemory;

    // Verify allocations are distinct
    try testing.expect(@intFromPtr(ptr1.ptr) != @intFromPtr(ptr2.ptr));
    try testing.expect(@intFromPtr(ptr2.ptr) != @intFromPtr(ptr3.ptr));

    // Free in different order
    heap.free(ptr2);
    heap.free(ptr1);
    heap.free(ptr3);

    // All memory should be freed (minus overhead)
    try testing.expectEqual(@as(usize, 0), heap.getAllocationCount());
}

// Test coalescing behavior
test "heap: coalescing adjacent blocks" {
    initHeap();

    const initial_free_blocks = heap.getFreeBlockCount();

    // Allocate three adjacent blocks
    const ptr1 = heap.alloc(64) orelse return error.OutOfMemory;
    const ptr2 = heap.alloc(64) orelse return error.OutOfMemory;
    const ptr3 = heap.alloc(64) orelse return error.OutOfMemory;

    // Free middle block first - should not coalesce
    heap.free(ptr2);
    const after_middle_free = heap.getFreeBlockCount();

    // Free first block - should coalesce with middle
    heap.free(ptr1);
    const after_first_free = heap.getFreeBlockCount();

    // After coalescing, should have fewer free blocks than if they were separate
    try testing.expect(after_first_free <= after_middle_free);

    // Free last block - should coalesce all three
    heap.free(ptr3);
    const final_free_blocks = heap.getFreeBlockCount();

    // Should return to single free block (or close to it)
    try testing.expect(final_free_blocks <= initial_free_blocks);
}

// Test backward coalescing
test "heap: backward coalescing" {
    initHeap();

    // Allocate two blocks
    const ptr1 = heap.alloc(128) orelse return error.OutOfMemory;
    const ptr2 = heap.alloc(128) orelse return error.OutOfMemory;

    // Free first block
    heap.free(ptr1);
    const blocks_after_first = heap.getFreeBlockCount();

    // Free second block - should coalesce backward with first
    heap.free(ptr2);
    const blocks_after_second = heap.getFreeBlockCount();

    // Should have coalesced (fewer or equal blocks)
    try testing.expect(blocks_after_second <= blocks_after_first);
}

// Test memory pattern integrity
test "heap: memory pattern integrity" {
    initHeap();

    const sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
    var allocations: [sizes.len]?[]u8 = undefined;

    // Allocate with patterns
    for (sizes, 0..) |size, i| {
        allocations[i] = heap.alloc(size);
        if (allocations[i]) |ptr| {
            // Write pattern: index repeated
            const slice = ptr[0..size];
            @memset(slice, @truncate(i + 0xAA));
        }
    }

    // Verify patterns
    for (sizes, 0..) |size, i| {
        if (allocations[i]) |ptr| {
            const slice = ptr[0..size];
            const expected: u8 = @truncate(i + 0xAA);
            for (slice) |byte| {
                try testing.expectEqual(expected, byte);
            }
        }
    }

    // Free all
    for (allocations) |maybe_ptr| {
        if (maybe_ptr) |ptr| {
            heap.free(ptr);
        }
    }

    try testing.expectEqual(@as(usize, 0), heap.getAllocationCount());
}

// Test heap integrity check
test "heap: integrity check" {
    initHeap();

    // Do some allocations
    var ptrs: [10]?[]u8 = undefined;
    for (&ptrs) |*p| {
        p.* = heap.alloc(100);
    }

    // Free half
    for (ptrs[0..5]) |maybe_ptr| {
        if (maybe_ptr) |ptr| heap.free(ptr);
    }

    // Check integrity
    try testing.expect(heap.checkIntegrity());

    // Clean up
    for (ptrs[5..]) |maybe_ptr| {
        if (maybe_ptr) |ptr| heap.free(ptr);
    }
}

// Fuzz test: 10,000 random operations
test "heap: fuzz 10000 random operations" {
    initHeap();

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    const max_allocations = 100;
    var allocations: [max_allocations]struct {
        ptr: ?[]u8,
        size: usize,
        pattern: u8,
    } = undefined;

    // Initialize
    for (&allocations) |*a| {
        a.ptr = null;
        a.size = 0;
        a.pattern = 0;
    }

    var total_ops: usize = 0;
    var alloc_ops: usize = 0;
    var free_ops: usize = 0;

    while (total_ops < 10000) : (total_ops += 1) {
        const slot = random.intRangeAtMost(usize, 0, max_allocations - 1);

        if (allocations[slot].ptr == null) {
            // Allocate: random size from 8 bytes to 64KB
            const size = random.intRangeAtMost(usize, 8, 64 * 1024);
            const pattern: u8 = @truncate(random.int(u8));

            if (heap.alloc(size)) |ptr| {
                allocations[slot].ptr = ptr;
                allocations[slot].size = size;
                allocations[slot].pattern = pattern;

                // Write pattern
                @memset(ptr[0..size], pattern);
                alloc_ops += 1;
            }
        } else {
            // Verify pattern before freeing
            const ptr = allocations[slot].ptr.?;
            const size = allocations[slot].size;
            const pattern = allocations[slot].pattern;

            var corrupted = false;
            for (ptr[0..size]) |byte| {
                if (byte != pattern) {
                    corrupted = true;
                    break;
                }
            }
            try testing.expect(!corrupted);

            // Free
            heap.free(ptr);
            allocations[slot].ptr = null;
            allocations[slot].size = 0;
            free_ops += 1;
        }

        // Periodic integrity check
        if (total_ops % 1000 == 0) {
            try testing.expect(heap.checkIntegrity());
        }
    }

    // Clean up remaining allocations
    for (&allocations) |*a| {
        if (a.ptr) |ptr| {
            heap.free(ptr);
            a.ptr = null;
        }
    }

    // Final integrity check
    try testing.expect(heap.checkIntegrity());
    try testing.expectEqual(@as(usize, 0), heap.getAllocationCount());
}

// Test coalescing reduces fragmentation
test "heap: coalescing reduces free block count" {
    initHeap();

    // Allocate many small blocks
    const num_blocks = 50;
    var ptrs: [num_blocks]?[]u8 = undefined;

    for (&ptrs) |*p| {
        p.* = heap.alloc(64);
    }

    // Free all blocks - should coalesce to single block
    for (ptrs) |maybe_ptr| {
        if (maybe_ptr) |ptr| heap.free(ptr);
    }

    // After all frees with coalescing, should have few free blocks
    // (ideally 1, but depends on alignment and boundaries)
    try testing.expect(heap.getFreeBlockCount() <= 2);
}

// Test large allocations
test "heap: large allocations" {
    initHeap();

    // Allocate large blocks
    const ptr1 = heap.alloc(512 * 1024) orelse return error.OutOfMemory; // 512 KB
    const ptr2 = heap.alloc(256 * 1024) orelse return error.OutOfMemory; // 256 KB

    // Write patterns
    @memset(ptr1[0 .. 512 * 1024], 0xAA);
    @memset(ptr2[0 .. 256 * 1024], 0xBB);

    // Verify
    for (ptr1[0 .. 512 * 1024]) |byte| {
        try testing.expectEqual(@as(u8, 0xAA), byte);
    }

    for (ptr2[0 .. 256 * 1024]) |byte| {
        try testing.expectEqual(@as(u8, 0xBB), byte);
    }

    heap.free(ptr1);
    heap.free(ptr2);

    try testing.expectEqual(@as(usize, 0), heap.getAllocationCount());
}

// Test allocation failure
test "heap: allocation failure" {
    initHeap();

    // Try to allocate more than heap size
    const huge = heap.alloc(10 * 1024 * 1024); // 10 MB (heap is 4 MB)
    try testing.expect(huge == null);

    // Verify heap still works after failed allocation
    const small = heap.alloc(100);
    try testing.expect(small != null);
    if (small) |ptr| heap.free(ptr);
}

// Test zero-sized allocation
test "heap: zero-sized allocation" {
    initHeap();

    const ptr = heap.alloc(0);
    try testing.expect(ptr == null);
}

// Test std.mem.Allocator interface
test "heap: std.mem.Allocator interface" {
    initHeap();

    const ally = heap.allocator();

    // Use ArrayListUnmanaged with heap allocator (Zig 0.15.x pattern)
    var list = std.ArrayListUnmanaged(u32){};
    defer list.deinit(ally);

    // Add items
    try list.append(ally, 1);
    try list.append(ally, 2);
    try list.append(ally, 3);

    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(@as(u32, 1), list.items[0]);
    try testing.expectEqual(@as(u32, 2), list.items[1]);
    try testing.expectEqual(@as(u32, 3), list.items[2]);
}

// Test interleaved alloc/free
test "heap: interleaved alloc free" {
    initHeap();

    var ptrs: [20]?[]u8 = [_]?[]u8{null} ** 20;

    // Interleaved pattern
    for (0..5) |round| {
        // Allocate 4 blocks
        for (0..4) |i| {
            const idx = round * 4 + i;
            if (idx < ptrs.len) {
                ptrs[idx] = heap.alloc(128);
            }
        }

        // Free every other block from previous round
        if (round > 0) {
            for (0..4) |i| {
                const idx = (round - 1) * 4 + i;
                if (idx < ptrs.len and i % 2 == 0) {
                    if (ptrs[idx]) |ptr| {
                        heap.free(ptr);
                        ptrs[idx] = null;
                    }
                }
            }
        }
    }

    // Clean up
    for (ptrs) |maybe_ptr| {
        if (maybe_ptr) |ptr| heap.free(ptr);
    }

    try testing.expect(heap.checkIntegrity());
}
