// Zscapek C Runtime Zero (crt0)
//
// Userland entry point providing SysV ABI compliant stack setup.
// This is the first code executed when a userland process starts.

// Note: syscall module is imported via build system as "syscall"
// However, crt0 only uses inline assembly for the syscall instruction
// to avoid circular dependencies during early startup.

// External main function provided by the user program
extern fn main(argc: i32, argv: [*]const [*:0]const u8) i32;

// Global assembly entry point
comptime {
    asm (
        \\.global _start
        \\_start:
        // Clear frame pointer
        \\xor %rbp, %rbp
        
        // Save argc and argv to callee-saved regs (preserved across syscall)
        \\movq (%rsp), %r12      // argc
        \\leaq 8(%rsp), %r13     // argv
        
        // Align stack
        \\andq $-16, %rsp

        // Initialize TLS: main_thread_tcb[0] = &main_thread_tcb
        \\leaq main_thread_tcb(%rip), %rax
        \\movq %rax, main_thread_tcb(%rip)

        // sys_arch_prctl(ARCH_SET_FS, &main_thread_tcb)
        \\movq $158, %rax         // SYS_ARCH_PRCTL
        \\movq $0x1002, %rdi      // ARCH_SET_FS
        \\leaq main_thread_tcb(%rip), %rsi // addr
        \\syscall

        // Restore args for main
        \\movq %r12, %rdi        // argc
        \\movq %r13, %rsi        // argv
        
        // Call main
        \\call main
        
        // Exit(rax)
        \\movq %rax, %rdi
        \\movq $60, %rax
        \\syscall
        \\ud2

        // Define TCB in data section
        \\.data
        \\.align 8
        \\.global main_thread_tcb
        \\main_thread_tcb: .quad 0
        \\.text
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
