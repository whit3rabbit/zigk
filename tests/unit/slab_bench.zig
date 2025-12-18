// Slab Allocator Micro-Benchmark
//
// Measures allocation/free time for 10k small objects on host.

const std = @import("std");
const testing = std.testing;
const slab = @import("slab");

fn backingAlloc(size: usize) ?[]u8 {
    return std.heap.page_allocator.alloc(u8, size) catch null;
}

fn backingFree(buf: []u8) void {
    std.heap.page_allocator.free(buf);
}

fn initSlab() void {
    slab.setBackingAllocator(backingAlloc, backingFree);
    slab.init();
}

test "slab: alloc/free micro benchmark (10k x 64B)" {
    initSlab();

    const iterations = 10_000;
    const ptrs = try testing.allocator.alloc([]u8, iterations);
    defer testing.allocator.free(ptrs);

    var timer = try std.time.Timer.start();
    for (ptrs) |*slot| {
        const buf = slab.alloc(64) orelse return error.OutOfMemory;
        slot.* = buf;
    }
    const alloc_ns = timer.lap();

    for (ptrs) |buf| {
        const ok = slab.free(buf);
        try testing.expect(ok);
    }
    const free_ns = timer.lap();

    std.log.info("slab 64B: alloc {d} ns, free {d} ns, total {d} ns (10k)", .{
        alloc_ns,
        free_ns,
        alloc_ns + free_ns,
    });
}
