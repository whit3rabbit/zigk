// Simple test binary for exec tests
// This program just prints a message and exits with status 42

const syscall = @import("syscall");

export fn main(argc: i32, argv: [*][*:0]u8) i32 {
    _ = argc;
    _ = argv;

    syscall.debug_print("TEST_BINARY_EXEC_SUCCESS\n");
    return 42;
}
