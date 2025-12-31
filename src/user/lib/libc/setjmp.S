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
#
# sigjmp_buf layout (80 bytes):
#   [0-56]: Same as jmp_buf (8 slots)
#   [64]: savemask flag (1 if signal mask was saved, 0 otherwise)
#   [72]: saved signal mask (64-bit mask)

# Syscall numbers
.equ SYS_rt_sigprocmask, 14

# Signal mask operations
.equ SIG_BLOCK, 0
.equ SIG_SETMASK, 2

# sigsetsize for 64-bit mask
.equ SIGSETSIZE, 8

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

# =============================================================================
# sigsetjmp - Save execution context with optional signal mask
# =============================================================================
# int sigsetjmp(sigjmp_buf env, int savemask)
#   env (RDI): pointer to sigjmp_buf (80 bytes)
#   savemask (RSI): non-zero to save signal mask
#   Returns: 0 on direct call, non-zero from siglongjmp
#
.global sigsetjmp
.type sigsetjmp, @function
sigsetjmp:
    # Check for null
    test %rdi, %rdi
    jz .Lsig_null

    # Save callee-saved registers (same as setjmp)
    mov %rbx, 0(%rdi)
    mov %rbp, 8(%rdi)
    mov %r12, 16(%rdi)
    mov %r13, 24(%rdi)
    mov %r14, 32(%rdi)
    mov %r15, 40(%rdi)

    # Save RSP (value after sigsetjmp returns = current RSP + 8)
    lea 8(%rsp), %rax
    mov %rax, 48(%rdi)

    # Save return address
    mov (%rsp), %rax
    mov %rax, 56(%rdi)

    # Check savemask flag
    test %esi, %esi
    jz .Lno_save_mask

    # savemask != 0: Save signal mask
    # Store savemask flag = 1
    movq $1, 64(%rdi)

    # Call rt_sigprocmask(SIG_BLOCK, NULL, &env[72], 8) to query current mask
    # We use SIG_BLOCK with NULL set pointer, which just queries the mask
    push %rdi                   # Save env pointer (callee-saved not enough)
    lea 72(%rdi), %rdx          # oldset = &env[72]
    xor %esi, %esi              # set = NULL (just query, don't modify)
    xor %edi, %edi              # how = SIG_BLOCK (ignored when set is NULL)
    mov $SIGSETSIZE, %r10       # sigsetsize = 8
    mov $SYS_rt_sigprocmask, %rax
    syscall
    pop %rdi                    # Restore env pointer

    # Ignore syscall errors - mask will just be 0 on failure
    xor %eax, %eax
    ret

.Lno_save_mask:
    # savemask == 0: Don't save signal mask
    movq $0, 64(%rdi)           # savemask flag = 0
    xor %eax, %eax
    ret

.Lsig_null:
    xor %eax, %eax
    ret
.size sigsetjmp, . - sigsetjmp

# =============================================================================
# siglongjmp - Restore execution context with optional signal mask restore
# =============================================================================
# void siglongjmp(sigjmp_buf env, int val)
#   env (RDI): pointer to sigjmp_buf
#   val (RSI): return value (forced to 1 if 0)
#
.global siglongjmp
.type siglongjmp, @function
siglongjmp:
    # Check for null
    test %rdi, %rdi
    jz .Lsiglongjmp_null

    # Ensure val is at least 1
    mov %esi, %eax
    test %eax, %eax
    jnz 1f
    mov $1, %eax
1:
    # Check if signal mask was saved
    cmpq $0, 64(%rdi)
    je .Lno_restore_mask

    # Restore signal mask before restoring other state
    # rt_sigprocmask(SIG_SETMASK, &env[72], NULL, 8)
    push %rdi                   # Save env pointer
    push %rax                   # Save return value
    lea 72(%rdi), %rsi          # set = &env[72] (saved mask)
    mov $SIG_SETMASK, %rdi      # how = SIG_SETMASK
    xor %edx, %edx              # oldset = NULL
    mov $SIGSETSIZE, %r10       # sigsetsize = 8
    mov $SYS_rt_sigprocmask, %rax
    syscall
    pop %rax                    # Restore return value
    pop %rdi                    # Restore env pointer

.Lno_restore_mask:
    # Restore callee-saved registers
    mov 0(%rdi), %rbx
    mov 8(%rdi), %rbp
    mov 16(%rdi), %r12
    mov 24(%rdi), %r13
    mov 32(%rdi), %r14
    mov 40(%rdi), %r15

    # Restore stack pointer
    mov 48(%rdi), %rsp

    # Jump to saved return address
    jmp *56(%rdi)

.Lsiglongjmp_null:
    # Null pointer - exit with SIGABRT code (134)
    mov $60, %rax
    mov $134, %rdi
    syscall
    ud2
.size siglongjmp, . - siglongjmp
