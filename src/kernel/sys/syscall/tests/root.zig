//! Root test file for syscall unit tests
//! This file is imported by build.zig to run all unit tests

// Import all test modules
test {
    // Mock tests
    _ = @import("mocks/vfs.zig");
    _ = @import("mocks/process.zig");
    _ = @import("mocks/user_mem.zig");

    // Syscall tests
    _ = @import("dir_test.zig");
}
