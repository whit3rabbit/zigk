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

fn nanoTimestamp() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @bitCast(@as(i64, ts.sec))) * std.time.ns_per_s + @as(u64, @bitCast(@as(i64, ts.nsec)));
}

test "slab: alloc/free micro benchmark (10k x 64B)" {
    initSlab();

    const iterations = 10_000;
    const ptrs = try testing.allocator.alloc([]u8, iterations);
    defer testing.allocator.free(ptrs);

    const t0 = nanoTimestamp();
    for (ptrs) |*slot| {
        const buf = slab.alloc(64) orelse return error.OutOfMemory;
        slot.* = buf;
    }
    const t1 = nanoTimestamp();

    for (ptrs) |buf| {
        const ok = slab.free(buf);
        try testing.expect(ok);
    }
    const t2 = nanoTimestamp();

    const alloc_ns = t1 - t0;
    const free_ns = t2 - t1;

    std.log.info("slab 64B: alloc {d} ns, free {d} ns, total {d} ns (10k)", .{
        alloc_ns,
        free_ns,
        alloc_ns + free_ns,
    });
}
