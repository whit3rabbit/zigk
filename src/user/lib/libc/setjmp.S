# setjmp/longjmp implementation for x86_64
# System V AMD64 ABI: args in RDI, RSI, RDX, RCX, R8, R9; return in RAX
#
# jmp_buf layout (64 bytes):
#   [0]:  RBX
#   [8]:  RBP
#   [16]: R12
#   [24]: R13
#   [32]: R14
#   [40]: R15
#   [48]: RSP (value after setjmp returns)
#   [56]: RIP (return address)

.text
.global setjmp
.type setjmp, @function
setjmp:
    # env pointer is in RDI
    # Check for null
    test %rdi, %rdi
    jz 1f

    # Save callee-saved registers
    mov %rbx, 0(%rdi)
    mov %rbp, 8(%rdi)
    mov %r12, 16(%rdi)
    mov %r13, 24(%rdi)
    mov %r14, 32(%rdi)
    mov %r15, 40(%rdi)

    # Save RSP (value after setjmp returns = current RSP + 8)
    lea 8(%rsp), %rax
    mov %rax, 48(%rdi)

    # Save return address (at top of stack)
    mov (%rsp), %rax
    mov %rax, 56(%rdi)

1:
    # Return 0 on direct call
    xor %eax, %eax
    ret
.size setjmp, . - setjmp

.global longjmp
.type longjmp, @function
longjmp:
    # env pointer in RDI, val in ESI
    # Check for null
    test %rdi, %rdi
    jz 2f

    # Ensure val is at least 1 (longjmp must not return 0)
    mov %esi, %eax
    test %eax, %eax
    jnz 1f
    mov $1, %eax
1:
    # Restore callee-saved registers
    mov 0(%rdi), %rbx
    mov 8(%rdi), %rbp
    mov 16(%rdi), %r12
    mov 24(%rdi), %r13
    mov 32(%rdi), %r14
    mov 40(%rdi), %r15

    # Restore stack pointer
    mov 48(%rdi), %rsp

    # Jump to saved return address (eax already has return value)
    jmp *56(%rdi)

2:
    # Null pointer - exit with SIGABRT code (134)
    mov $60, %rax      # sys_exit
    mov $134, %rdi     # SIGABRT exit code
    syscall
    ud2
.size longjmp, . - longjmp

.global sigsetjmp
.type sigsetjmp, @function
sigsetjmp:
    # Just tail call to setjmp (ignore savemask)
    jmp setjmp
.size sigsetjmp, . - sigsetjmp

.global siglongjmp
.type siglongjmp, @function
siglongjmp:
    # Just tail call to longjmp
    jmp longjmp
.size siglongjmp, . - siglongjmp
