// ZK Unit Tests
//
// Host-side unit tests for kernel components.
// These run on the host system, not in the kernel environment.
// Use `zig build test` to run.

const std = @import("std");
const testing = std.testing;

// Import all test modules
// The test runner will automatically discover and run tests from these
const heap_tests = @import("heap_fuzz.zig");
const tcp_types_test = @import("tcp_types_test.zig");
const vmm_test = @import("vmm_test.zig");
const msi_allocator_test = @import("msi_allocator_test.zig");
const ipv4_reassembly = @import("ipv4_reassembly.zig");
const slab_bench = @import("slab_bench.zig");

test "placeholder test" {
    // Placeholder test to verify test infrastructure works
    try testing.expect(true);
}

// Reference imported modules to ensure they are compiled
comptime {
    _ = heap_tests;
    _ = tcp_types_test;
    _ = vmm_test;
    _ = msi_allocator_test;
    _ = ipv4_reassembly;
    _ = slab_bench;
}
