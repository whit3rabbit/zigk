// ZigK Unit Tests
//
// Host-side unit tests for kernel components.
// These run on the host system, not in the kernel environment.
// Use `zig build test` to run.

const std = @import("std");
const testing = std.testing;

// Import all test modules
// The test runner will automatically discover and run tests from these
const heap_tests = @import("heap_fuzz.zig");

test "placeholder test" {
    // Placeholder test to verify test infrastructure works
    try testing.expect(true);
}

// Reference imported modules to ensure they are compiled
comptime {
    _ = heap_tests;
}
