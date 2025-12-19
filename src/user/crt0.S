/* Zscapek C Runtime Zero (crt0) - Assembly Implementation */

.section .text
.global _start
.type _start, @function

_start:
    /* Clear frame pointer */
    xor %rbp, %rbp
    
    /* Save argc and argv to callee-saved regs (preserved across syscall) */
    movq (%rsp), %r12      /* argc */
    leaq 8(%rsp), %r13     /* argv */
    
    /* Align stack to 16 bytes */
    andq $-16, %rsp

    /* Initialize TLS: main_thread_tcb[0] = &main_thread_tcb */
    leaq main_thread_tcb(%rip), %rax
    movq %rax, main_thread_tcb(%rip)

    /* sys_arch_prctl(ARCH_SET_FS, &main_thread_tcb) */
    movq $158, %rax         /* SYS_ARCH_PRCTL */
    movq $0x1002, %rdi      /* ARCH_SET_FS */
    leaq main_thread_tcb(%rip), %rsi /* addr */
    syscall

    /* Restore args for main */
    movq %r12, %rdi        /* argc */
    movq %r13, %rsi        /* argv */
    
    /* Call main */
    call main
    
    /* Exit(rax) */
    movq %rax, %rdi
    movq $60, %rax
    syscall
    ud2

.section .data
.align 8
.global main_thread_tcb
.type main_thread_tcb, @object
.size main_thread_tcb, 8
main_thread_tcb:
    .quad 0
