// ZigK C Runtime Zero (crt0)
//
// Userland entry point providing SysV ABI compliant stack setup.
// This is the first code executed when a userland process starts.
//
// Stack layout at _start (set up by kernel):
//   RSP+0:    argc (u64)
//   RSP+8:    argv[0] (pointer to first arg string)
//   RSP+16:   argv[1]
//   ...
//   RSP+8*(argc+1): NULL (argv terminator)
//   RSP+8*(argc+2): envp[0] (optional, environment)
//
// Responsibilities:
//   1. Clear RBP (frame pointer) to mark stack base
//   2. Extract argc from RSP
//   3. Calculate argv pointer from RSP+8
//   4. Align RSP to 16 bytes (SysV ABI requirement)
//   5. Call main(argc, argv)
//   6. Pass main's return value to sys_exit
//
// Reference: System V AMD64 ABI specification

// Note: syscall module is imported via build system as "syscall"
// However, crt0 only uses inline assembly for the syscall instruction
// to avoid circular dependencies during early startup.

// External main function provided by the user program
extern fn main(argc: i32, argv: [*]const [*:0]const u8) i32;

/// _start - Userland entry point
///
/// This function is marked naked because we need full control over
/// the stack and registers. No prologue/epilogue is generated.
///
/// The assembly performs:
///   1. xor rbp, rbp    - Clear frame pointer (marks stack base for debuggers)
///   2. mov rdi, [rsp]  - Load argc into first argument register
///   3. lea rsi, [rsp+8]- Load argv pointer into second argument register
///   4. and rsp, -16    - Align stack to 16 bytes (SysV ABI)
///   5. call main       - Call the user's main function
///   6. mov rdi, rax    - Move return value to first syscall arg
///   7. mov rax, 60     - sys_exit syscall number
///   8. syscall         - Exit process with main's return value
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        // Clear frame pointer to mark stack base
        \\xor %%rbp, %%rbp
        // Load argc from stack (set up by kernel)
        \\mov (%%rsp), %%rdi
        // Calculate argv pointer (RSP + 8)
        \\lea 8(%%rsp), %%rsi
        // Align stack to 16 bytes (SysV ABI requirement)
        // Stack may be misaligned after kernel sets it up
        \\and $-16, %%rsp
        // Call main(argc, argv)
        // Return value will be in RAX
        \\call main
        // Pass main's return value to sys_exit
        \\mov %%rax, %%rdi
        // sys_exit syscall number
        \\mov $60, %%rax
        // Terminate process
        \\syscall
        // Never reached, but required for noreturn
        \\ud2
    );
}

// Provide a default weak main for programs that don't define one
// This allows the crt0 to compile standalone for testing
export fn main_default(argc: i32, argv: [*]const [*:0]const u8) i32 {
    _ = argc;
    _ = argv;
    // Default: just exit with 0
    return 0;
}

comptime {
    // Weak symbol for main - user program's main will override this
    @export(&main_default, .{ .name = "main", .linkage = .weak });
}
